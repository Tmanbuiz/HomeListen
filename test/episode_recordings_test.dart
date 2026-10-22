import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/episode_recordings.dart';

void main() {
  late Directory root;
  late EpisodeRecordings recordings;
  final now = DateTime(2026, 10, 22, 1, 30);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('homelisten_recordings_');
    recordings = EpisodeRecordings(
      directory: () async => root,
      clock: () => now,
    );
  });
  tearDown(() async {
    await recordings.stop();
    await root.delete(recursive: true);
  });

  Future<void> second(
    int at,
    String? category, {
    bool enabled = true,
    int minimum = 30,
  }) async {
    recordings.feed(Int16List.fromList(List.filled(16000, at + 1)));
    recordings.observe(
      category,
      now.add(Duration(seconds: at + 1)),
      minimumSeconds: minimum,
      recordAudio: enabled,
    );
    await recordings.drain();
  }

  test('disabled rules never write audio', () async {
    for (var i = 0; i < 35; i++) {
      await second(i, 'crying', enabled: false);
    }
    await recordings.stop();
    expect(recordings.clips, isEmpty);
    expect(await root.list().toList(), isEmpty);
  });

  test('short opted-in candidate is discarded on stop', () async {
    for (var i = 0; i < 29; i++) {
      await second(i, 'crying');
    }
    expect(recordings.buffering, isTrue);
    expect(recordings.recording, isFalse);
    await recordings.stop();
    expect(recordings.clips, isEmpty);
    expect(
      (await root.list().toList()).whereType<File>().where(
        (f) => f.path.endsWith('.pcm'),
      ),
      isEmpty,
    );
  });

  test(
    '30 seconds qualifies and saves whole episode with initial audio',
    () async {
      for (var i = 0; i < 32; i++) {
        await second(i, 'crying');
      }
      expect(recordings.recording, isTrue);
      await second(32, null);
      await second(33, null);
      expect(recordings.clips, hasLength(1));
      final clip = recordings.clips.single;
      expect(clip.durationMs, 32000);
      expect(clip.name, startsWith('2026-10-22_01-30-00-000_crying_'));
      final bytes = await File(clip.path).readAsBytes();
      final header = ByteData.sublistView(bytes);
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(header.getUint32(24, Endian.little), 16000);
      expect(header.getUint32(40, Endian.little), 32000 * 32);
      expect(bytes.length, 44 + 32000 * 32);
      expect(header.getInt16(44, Endian.little), 1);
      expect(header.getInt16(bytes.length - 2, Endian.little), 32);
    },
  );

  test('brief gaps stay in an episode, prolonged gaps close it', () async {
    await second(0, 'coughing', minimum: 3);
    await second(1, null, minimum: 3);
    await second(2, 'coughing', minimum: 3);
    await second(3, null, minimum: 3);
    await second(4, null, minimum: 3);
    expect(recordings.clips.single.durationMs, 3000);
  });

  test(
    'clips restore without trusting stored paths; delete removes file',
    () async {
      await second(0, 'knocking', minimum: 0);
      await recordings.stop();
      final clip = recordings.clips.single;
      final restored = EpisodeRecordings(
        directory: () async => root,
        clock: () => now,
      );
      await restored.initialize();
      expect(restored.clips.single.path, clip.path);
      await restored.delete(restored.clips.single);
      expect(await File(clip.path).exists(), isFalse);
      expect(restored.clips, isEmpty);
    },
  );

  test('startup deletes abandoned unqualified PCM files', () async {
    final candidate = File('${root.path}/.pending_abandoned.pcm');
    await candidate.writeAsBytes([1, 2]);
    await recordings.initialize();
    expect(await candidate.exists(), isFalse);
  });

  test('clip count limit deletes oldest audio', () async {
    recordings = EpisodeRecordings(
      directory: () async => root,
      clock: () => now,
      maximumClips: 1,
    );
    await second(0, 'knocking', minimum: 0);
    await recordings.stop();
    final old = recordings.clips.single;
    await second(2, 'barking', minimum: 0);
    await recordings.stop();
    expect(recordings.clips.single.category, 'barking');
    expect(await File(old.path).exists(), isFalse);
  });

  test('clear cancels pending audio and removes saved clips', () async {
    await second(0, 'knocking', minimum: 0);
    await recordings.stop();
    final old = recordings.clips.single;
    await second(1, 'crying');
    await recordings.clear();
    expect(recordings.clips, isEmpty);
    expect(recordings.buffering, isFalse);
    expect(await File(old.path).exists(), isFalse);
    expect(
      (await root.list().toList()).whereType<File>().where(
        (f) => f.path.endsWith('.pcm') || f.path.endsWith('.wav'),
      ),
      isEmpty,
    );
  });

  test('stalled classifier closes recording from PCM sample clock', () async {
    await second(0, 'knocking', minimum: 0);
    for (var i = 0; i < 3; i++) {
      recordings.feed(Int16List(16000));
      await recordings.drain();
    }
    expect(recordings.recording, isFalse);
    expect(recordings.clips.single.durationMs, 1000);
  });

  test('stalled classifier discards unqualified candidate', () async {
    await second(0, 'crying');
    recordings.feed(Int16List(48000));
    await recordings.drain();
    expect(recordings.buffering, isFalse);
    expect(recordings.clips, isEmpty);
    expect(
      (await root.list().toList()).whereType<File>().where(
        (f) => f.path.endsWith('.pcm'),
      ),
      isEmpty,
    );
  });

  test(
    'long qualified episode continues across clip-size boundaries',
    () async {
      recordings = EpisodeRecordings(
        directory: () async => root,
        clock: () => now,
        maximumClipSeconds: 3,
      );
      for (var i = 0; i < 8; i++) {
        await second(i, 'crying', minimum: 2);
      }
      await recordings.stop();
      final clips = recordings.clips.toList()
        ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
      expect(clips.map((c) => c.durationMs), [3000, 3000, 2000]);
      expect(clips.map((c) => c.durationMs).reduce((a, b) => a + b), 8000);
      for (var i = 0; i < clips.length; i++) {
        final bytes = await File(clips[i].path).readAsBytes();
        expect(
          ByteData.sublistView(bytes).getInt16(44, Endian.little),
          i * 3 + 1,
        );
      }
    },
  );

  test(
    'turning recording off finalizes episode and never restarts it',
    () async {
      await second(0, 'crying', minimum: 0);
      await recordings.stop();
      await second(1, 'crying', enabled: false, minimum: 0);
      expect(recordings.clips.single.durationMs, 1000);
      expect(recordings.recording, isFalse);
      expect(recordings.buffering, isFalse);
    },
  );

  test('storage byte cap deletes audio exceeding configured budget', () async {
    recordings = EpisodeRecordings(
      directory: () async => root,
      clock: () => now,
      maximumBytes: 32044,
    );
    await second(0, 'knocking', minimum: 0);
    await recordings.stop();
    final old = recordings.clips.single;
    await second(1, 'barking', minimum: 0);
    await recordings.stop();
    expect(recordings.clips, hasLength(1));
    expect(await File(old.path).exists(), isFalse);
    final files = (await root.list().toList()).whereType<File>().where(
      (f) => f.path.endsWith('.wav'),
    );
    var size = 0;
    for (final file in files) {
      size += await file.length();
    }
    expect(size, lessThanOrEqualTo(32044));
  });

  test(
    'missing index recovers valid owned WAV and ignores unrelated files',
    () async {
      await second(0, 'knocking', minimum: 0);
      await recordings.stop();
      final clip = recordings.clips.single;
      await File('${root.path}/clips.json').delete();
      final unrelated = File('${root.path}/personal.wav');
      await unrelated.writeAsBytes([1, 2, 3]);
      final restored = EpisodeRecordings(
        directory: () async => root,
        clock: () => now,
      );
      await restored.initialize();
      expect(restored.clips.single.name, clip.name);
      expect(restored.clips.single.durationMs, 1000);
      expect(await unrelated.exists(), isTrue);
      expect(await File('${root.path}/clips.json').exists(), isTrue);
    },
  );

  test('corrupt owned orphan WAV is deleted instead of indexed', () async {
    final broken = File('${root.path}/2026-10-22_01-30-00-000_crying_99.wav');
    await broken.writeAsBytes([1, 2, 3]);
    await recordings.initialize();
    expect(recordings.clips, isEmpty);
    expect(await broken.exists(), isFalse);
  });
}
