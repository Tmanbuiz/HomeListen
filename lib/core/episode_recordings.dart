import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// A receiver-local, uncompressed mono WAV clip. No audio is uploaded.
class RecordingClip {
  const RecordingClip({
    required this.name,
    required this.path,
    required this.category,
    required this.startedAt,
    required this.durationMs,
  });

  final String name, path, category;
  final DateTime startedAt;
  final int durationMs;

  Map<String, Object> toJson() => {
    'name': name,
    'category': category,
    'startedAt': startedAt.toIso8601String(),
    'durationMs': durationMs,
  };
}

/// Saves only opted-in sound episodes on the receiving phone.
///
/// Feed the incoming 16 kHz mono PCM before sending its classifier verdict to
/// [observe]. A one-second memory ring includes the first analysis window.
/// Opted-in candidates use a temporary file while waiting for the duration
/// threshold. Candidates that never qualify are deleted, not kept as clips.
/// A two-second detection gap closes the episode and is trimmed from its WAV.
/// Call [stop] immediately on disconnect, Stop, or recording-policy changes.
class EpisodeRecordings {
  EpisodeRecordings({
    required Future<Directory> Function() directory,
    this.onChanged,
    this.onError,
    DateTime Function()? clock,
    this.maximumClipSeconds = 600,
    this.maximumClips = 100,
    this.maximumBytes = 200 * 1024 * 1024,
  }) : _directory = directory,
       _clock = clock ?? DateTime.now;

  static const sampleRate = 16000;
  static const gapSamples = sampleRate * 2;
  static const _maximumPendingSamples = sampleRate * 4;
  final Future<Directory> Function() _directory;
  final DateTime Function() _clock;
  final void Function()? onChanged;
  final void Function(String)? onError;
  final int maximumClipSeconds, maximumClips, maximumBytes;
  int retentionDays = 7;
  final List<RecordingClip> _clips = [];
  final List<int> _ring = [];
  Future<void> _tail = Future<void>.value();
  Directory? _root;
  _Candidate? _candidate;
  int _cursor = 0, _pendingSamples = 0, _serial = 0;
  bool _overflow = false;

  List<RecordingClip> get clips => List.unmodifiable(_clips);
  bool get recording => _candidate?.qualified == true;
  bool get buffering => _candidate != null && !recording;

  Future<void> initialize() => _enqueue(_initialize);
  Future<void> drain() => _tail;

  Future<void> _initialize() async {
    if (_root != null) return;
    final root = await _directory();
    await root.create(recursive: true);
    _root = root;
    // A killed receiver must not leave unqualified sound candidates behind.
    await for (final entity in root.list()) {
      if (entity is File &&
          entity.uri.pathSegments.last.startsWith('.pending_')) {
        await entity.delete();
      }
    }
    final index = File('${root.path}/clips.json');
    if (await index.exists()) {
      try {
        final rows = jsonDecode(await index.readAsString());
        if (rows is List) {
          for (final row in rows.take(1000)) {
            if (row is! Map ||
                row['name'] is! String ||
                row['category'] is! String ||
                row['durationMs'] is! int)
              continue;
            final name = row['name'] as String;
            if (!RegExp(r'^[A-Za-z0-9_-]+\.wav$').hasMatch(name)) continue;
            final at = DateTime.tryParse('${row['startedAt']}');
            final path = '${root.path}/$name';
            if (at == null || !await File(path).exists()) continue;
            _clips.add(
              RecordingClip(
                name: name,
                path: path,
                category: row['category'],
                startedAt: at,
                durationMs: row['durationMs'],
              ),
            );
          }
        }
      } on FormatException {
        onError?.call('The recording list could not be restored.');
      }
    }
    await _recoverClips(root);
    await _prune();
    onChanged?.call();
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _tail = _tail.then((_) => action()).catchError((Object error) async {
      await _discard();
      _ring.clear();
      onError?.call(
        'Audio recording could not be saved. Check available storage.',
      );
      onChanged?.call();
    });
    return _tail;
  }

  /// This call never blocks the playback or capture stream on disk I/O.
  void feed(Int16List pcm) {
    if (pcm.isEmpty) return;
    if (_pendingSamples + pcm.length > _maximumPendingSamples) {
      if (!_overflow) {
        _overflow = true;
        unawaited(
          _enqueue(() async {
            await _discard();
            _ring.clear();
            _overflow = false;
            onError?.call(
              'Recording stopped because audio arrived faster than it could be saved.',
            );
            onChanged?.call();
          }),
        );
      }
      return;
    }
    final copy = Int16List.fromList(pcm);
    _pendingSamples += copy.length;
    unawaited(
      _enqueue(() async {
        try {
          _cursor += copy.length;
          var candidate = _candidate;
          if (candidate != null && _cursor - candidate.lastMatch > gapSamples) {
            // A stalled classifier must not leave an episode recording silence
            // indefinitely. The sample clock works even without null verdicts.
            await _finish();
            candidate = null;
          }
          if (candidate != null) {
            final remaining =
                maximumClipSeconds * sampleRate - candidate.samples;
            final count = math.min(copy.length, math.max(0, remaining));
            if (count > 0) {
              await candidate.file.writeFrom(_bytes(copy, count));
              candidate.samples += count;
            }
            if (candidate.samples >= maximumClipSeconds * sampleRate) {
              final qualified = candidate.qualified;
              final nextStart = candidate.startSample + candidate.samples;
              final nextAt = candidate.startedAt.add(
                Duration(
                  microseconds: candidate.samples * 1000000 ~/ sampleRate,
                ),
              );
              await _finish(trimSilence: false);
              // Keep an already qualified episode qualified across file limits.
              // Audio after the boundary is never dropped or made to wait for
              // another 30-second threshold.
              if (qualified) {
                final rest = Int16List.sublistView(copy, count);
                final next = await _beginCandidate(
                  category: candidate.category,
                  startedAt: nextAt,
                  startSample: nextStart,
                  lastMatch: candidate.lastMatch,
                  minimumSamples: 0,
                  initial: rest,
                );
                next.qualified = true;
                onChanged?.call();
              }
            }
          }
          _ring.addAll(copy);
          if (_ring.length > sampleRate)
            _ring.removeRange(0, _ring.length - sampleRate);
        } finally {
          _pendingSamples -= copy.length;
        }
      }),
    );
  }

  void observe(
    String? category,
    DateTime at, {
    required int minimumSeconds,
    required bool recordAudio,
  }) {
    unawaited(
      _enqueue(() async {
        var candidate = _candidate;
        if (candidate != null && category != candidate.category) {
          // Short unmatched windows are part of one episode. A different
          // opted-in sound begins its own clip instead of merging sound types.
          if ((category != null && recordAudio) ||
              _cursor - candidate.lastMatch >= gapSamples) {
            await _finish();
            candidate = null;
          }
        }
        if (category == null) return;
        if (!recordAudio) {
          if (candidate?.category == category) {
            await _finish();
            onChanged?.call();
          }
          return;
        }
        if (candidate == null) {
          if (_ring.isEmpty) return;
          await _initialize();
          final startedAt = at.subtract(
            Duration(microseconds: _ring.length * 1000000 ~/ sampleRate),
          );
          candidate = await _beginCandidate(
            category: category,
            startedAt: startedAt,
            startSample: _cursor - _ring.length,
            lastMatch: _cursor,
            minimumSamples: minimumSeconds.clamp(0, 300) * sampleRate,
            initial: Int16List.fromList(_ring),
          );
          onChanged?.call();
        }
        if (candidate.category == category) {
          candidate.lastMatch = _cursor;
          final wasQualified = candidate.qualified;
          candidate.qualified =
              candidate.qualified ||
              candidate.lastMatch - candidate.startSample >=
                  candidate.minimumSamples;
          if (wasQualified != candidate.qualified) onChanged?.call();
        }
      }),
    );
  }

  /// Finalize qualified audio; discard short, unqualified candidates.
  Future<void> stop() => _enqueue(() async {
    await _finish();
    _ring.clear();
    _cursor = 0;
    onChanged?.call();
  });

  Future<_Candidate> _beginCandidate({
    required String category,
    required DateTime startedAt,
    required int startSample,
    required int lastMatch,
    required int minimumSamples,
    required Int16List initial,
  }) async {
    final temp = File(
      '${_root!.path}/.pending_${_clock().microsecondsSinceEpoch}_${_serial++}.pcm',
    );
    final file = await temp.open(mode: FileMode.write);
    final candidate = _Candidate(
      category: category,
      startedAt: startedAt,
      temp: temp,
      file: file,
      startSample: startSample,
      lastMatch: lastMatch,
      samples: initial.length,
      minimumSamples: minimumSamples,
    );
    _candidate = candidate;
    if (initial.isNotEmpty)
      await file.writeFrom(_bytes(initial, initial.length));
    return candidate;
  }

  Future<void> _finish({bool trimSilence = true}) async {
    final candidate = _candidate;
    if (candidate == null) return;
    _candidate = null;
    await candidate.file.close();
    if (!candidate.qualified) {
      await candidate.temp.delete();
      onChanged?.call();
      return;
    }
    final count = trimSilence
        ? math.min(
            candidate.samples,
            candidate.lastMatch - candidate.startSample,
          )
        : candidate.samples;
    if (count <= 0) {
      await candidate.temp.delete();
      onChanged?.call();
      return;
    }
    final local = candidate.startedAt.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    final label = candidate.category.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    final prefix =
        '${local.year}-${two(local.month)}-${two(local.day)}_'
        '${two(local.hour)}-${two(local.minute)}-${two(local.second)}-'
        '${local.millisecond.toString().padLeft(3, '0')}_${label}';
    var name = '${prefix}_${_serial++}.wav';
    while (await File('${_root!.path}/$name').exists()) {
      name = '${prefix}_${_serial++}.wav';
    }
    final output = File('${_root!.path}/$name');
    final writing = File('${_root!.path}/.pending_$name');
    RandomAccessFile? target;
    var complete = false;
    try {
      target = await writing.open(mode: FileMode.write);
      await target.writeFrom(_wavHeader(count * 2));
      var left = count * 2;
      await for (final chunk in candidate.temp.openRead(0, left)) {
        await target.writeFrom(chunk);
        left -= chunk.length;
      }
      complete = left == 0;
      if (!complete)
        throw const FileSystemException('Incomplete audio candidate');
    } finally {
      await target?.close();
      await candidate.temp.delete();
      if (!complete && await writing.exists()) await writing.delete();
    }
    await writing.rename(output.path);
    _clips.insert(
      0,
      RecordingClip(
        name: name,
        path: output.path,
        category: candidate.category,
        startedAt: candidate.startedAt,
        durationMs: count * 1000 ~/ sampleRate,
      ),
    );
    await _prune();
    onChanged?.call();
  }

  /// Recover only WAV files whose names and headers match our own format.
  /// A successful WAV rename followed by an index-write failure is recoverable;
  /// unrelated files in the directory are left alone.
  Future<void> _recoverClips(Directory root) async {
    final pattern = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})-(\d{3})_([A-Za-z0-9_]+)_(\d+)\.wav$',
    );
    final known = _clips.map((c) => c.name).toSet();
    await for (final entity in root.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (known.contains(name)) continue;
      final match = pattern.firstMatch(name);
      if (match == null) continue;
      final bytes = await entity
          .openRead(0, math.min(44, await entity.length()))
          .fold<List<int>>([], (result, chunk) => result..addAll(chunk));
      if (bytes.length != 44) {
        await entity.delete();
        continue;
      }
      final header = ByteData.sublistView(Uint8List.fromList(bytes));
      final dataBytes = header.getUint32(40, Endian.little);
      if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
          String.fromCharCodes(bytes.sublist(8, 16)) != 'WAVEfmt ' ||
          header.getUint16(20, Endian.little) != 1 ||
          header.getUint16(22, Endian.little) != 1 ||
          header.getUint32(24, Endian.little) != sampleRate ||
          header.getUint16(34, Endian.little) != 16 ||
          dataBytes == 0 ||
          dataBytes.isOdd ||
          await entity.length() != dataBytes + 44) {
        await entity.delete();
        continue;
      }
      final at = DateTime(
        int.parse(match[1]!),
        int.parse(match[2]!),
        int.parse(match[3]!),
        int.parse(match[4]!),
        int.parse(match[5]!),
        int.parse(match[6]!),
        int.parse(match[7]!),
      );
      _clips.add(
        RecordingClip(
          name: name,
          path: entity.path,
          category: match[8]!.replaceAll('_', ' '),
          startedAt: at,
          durationMs: dataBytes * 1000 ~/ (sampleRate * 2),
        ),
      );
    }
  }

  Future<void> _discard() async {
    final candidate = _candidate;
    _candidate = null;
    if (candidate == null) return;
    try {
      await candidate.file.close();
    } catch (_) {
      /* Already closed. */
    }
    try {
      if (await candidate.temp.exists()) await candidate.temp.delete();
    } catch (_) {
      /* Startup cleanup retries deleting abandoned candidates. */
    }
  }

  Future<void> prune({int? retentionDays}) => _enqueue(() async {
    if (retentionDays != null) this.retentionDays = retentionDays.clamp(1, 30);
    await _initialize();
    await _prune();
    onChanged?.call();
  });

  Future<void> _prune() async {
    final root = _root;
    if (root == null) return;
    _clips.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final cutoff = _clock().subtract(Duration(days: retentionDays));
    var bytes = 0, kept = 0;
    for (final clip in List<RecordingClip>.from(_clips)) {
      final file = File(clip.path);
      final exists = await file.exists();
      final size = exists ? await file.length() : 0;
      if (!exists ||
          clip.startedAt.isBefore(cutoff) ||
          kept >= maximumClips ||
          bytes + size > maximumBytes) {
        if (exists) await file.delete();
        _clips.remove(clip);
      } else {
        kept++;
        bytes += size;
      }
    }
    final index = File('${root.path}/clips.json.tmp');
    await index.writeAsString(
      jsonEncode(_clips.map((c) => c.toJson()).toList()),
      flush: true,
    );
    await index.rename('${root.path}/clips.json');
  }

  Future<void> delete(RecordingClip clip) => _enqueue(() async {
    if (!_clips.contains(clip)) return;
    final file = File(clip.path);
    if (await file.exists()) await file.delete();
    _clips.remove(clip);
    await _prune();
    onChanged?.call();
  });

  Future<void> clear() => _enqueue(() async {
    await _discard();
    _ring.clear();
    await _initialize();
    for (final clip in _clips) {
      final file = File(clip.path);
      if (await file.exists()) await file.delete();
    }
    _clips.clear();
    await _prune();
    onChanged?.call();
  });

  static Uint8List _bytes(Int16List samples, int count) {
    final bytes = ByteData(count * 2);
    for (var i = 0; i < count; i++)
      bytes.setInt16(i * 2, samples[i], Endian.little);
    return bytes.buffer.asUint8List();
  }

  static Uint8List _wavHeader(int dataBytes) {
    final bytes = ByteData(44);
    void text(int offset, String value) {
      for (var i = 0; i < value.length; i++)
        bytes.setUint8(offset + i, value.codeUnitAt(i));
    }

    text(0, 'RIFF');
    bytes.setUint32(4, dataBytes + 36, Endian.little);
    text(8, 'WAVE');
    text(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    text(36, 'data');
    bytes.setUint32(40, dataBytes, Endian.little);
    return bytes.buffer.asUint8List();
  }
}

class _Candidate {
  _Candidate({
    required this.category,
    required this.startedAt,
    required this.temp,
    required this.file,
    required this.startSample,
    required this.lastMatch,
    required this.samples,
    required this.minimumSamples,
  });
  final String category;
  final DateTime startedAt;
  final File temp;
  final RandomAccessFile file;
  final int startSample, minimumSamples;
  int lastMatch, samples;
  bool qualified = false;
}
