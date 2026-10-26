import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'guardian_settings.dart';

/// A duration gate with per-category cooldowns. Scores are model outputs, not
/// calibrated probabilities; alerts deliberately say "Possible".
///
/// Sustained sounds (crying) need [requiredHits] matching windows and their
/// configured duration. Each category keeps its own evidence across gaps
/// shorter than [toleratedGap], including brief competing classifications.
/// Short sounds in [immediate] do not need consecutive matching windows.
class SoundGate {
  SoundGate({
    this.requiredHits = 2,
    this.cooldown = const Duration(seconds: 30),
    this.immediate = const {},
    this.burst = const {},
    this.toleratedGap = Duration.zero,
  });
  final int requiredHits;
  final Duration cooldown;
  final Duration toleratedGap;
  final Set<String> immediate;

  /// Categories that need this many separate detections close together, such as
  /// two distinct barks, before alerting. One mislabeled sound or a single bark
  /// does not fire. Two windows only 0.5 s apart can contain the same sound
  /// (they overlap by half), so hits must be [burstGap] apart and have a
  /// nonmatching classification between them to count as separate.
  final Map<String, int> burst;
  static const burstGap = Duration(milliseconds: 700);
  static const burstSpan = Duration(seconds: 8);
  final Map<String, List<DateTime>> _recent = {};
  final Map<String, DateTime> _last = {};
  final Map<String, _SoundCandidate> _candidates = {};
  Map<String, SoundRule> rules = {};
  String? _previousCategory;
  int acceptedSpanMs = 0;

  bool accept(String? category, DateTime at) {
    final previous = _previousCategory;
    _previousCategory = category;
    if (toleratedGap > Duration.zero) {
      _candidates.removeWhere(
        (_, candidate) => at.difference(candidate.lastHitAt) >= toleratedGap,
      );
    } else {
      _candidates.removeWhere((name, _) => name != category);
    }
    if (category == null) return false;
    // Once a distinct pair establishes a candidate, keep its evidence while
    // that sound continues. A configured duration can exceed the burst span.
    if (burst.containsKey(category) && !_candidates.containsKey(category)) {
      final hits = _recent.putIfAbsent(category, () => []);
      hits.removeWhere((t) => at.difference(t) > burstSpan);
      if (previous != category &&
          (hits.isEmpty || at.difference(hits.last) >= burstGap)) {
        hits.add(at);
      }
      if (hits.length < burst[category]!) return false;
    }
    final candidate = _candidates.putIfAbsent(
      category,
      () => _SoundCandidate(at),
    );
    candidate.lastHitAt = at;
    candidate.hits++;
    final needed = immediate.contains(category) ? 1 : requiredHits;
    if (candidate.hits < needed) return false;
    final rule = rules[category];
    if (rule != null &&
        at.difference(candidate.startedAt) <
            Duration(seconds: rule.minimumSeconds)) {
      return false;
    }
    final last = _last[category];
    if (last != null &&
        at.difference(last) <
            (rule == null
                ? cooldown
                : Duration(seconds: rule.cooldownSeconds))) {
      return false;
    }
    _last[category] = at;
    _recent[category]?.clear();
    acceptedSpanMs = at.difference(candidate.startedAt).inMilliseconds;
    if (burst.containsKey(category)) {
      _candidates.remove(category);
    } else {
      candidate.hits = 0;
      candidate.startedAt = at;
    }
    return true;
  }

  void reset({bool clearBursts = false}) {
    _candidates.clear();
    _previousCategory = null;
    acceptedSpanMs = 0;
    if (clearBursts) _recent.clear();
  }
}

class _SoundCandidate {
  _SoundCandidate(this.startedAt) : lastHitAt = startedAt;
  DateTime startedAt, lastHitAt;
  int hits = 0;
}

/// Which YAMNet classes count toward each alert category.
///
/// A dog barking is rarely scored as plain "Bark": the model spreads it across
/// "Dog", "Bark", "Bow-wow" and friends, so matching one label made real
/// barking fall under the threshold. Each category takes the best score among
/// its related classes.
const Map<String, Set<String>> soundGroups = {
  'crying': {'Baby cry, infant cry', 'Crying, sobbing', 'Whimper'},
  'coughing': {'Cough'},
  'barking': {'Bark', 'Bow-wow', 'Yip', 'Howl', 'Dog', 'Growling'},
  'knocking': {'Knock', 'Doorbell', 'Ding-dong', 'Tap'},
};

/// "Dog", "Growling" and "Howl" are broad: they light up for panting, whining,
/// toys and other sounds a model confuses with a dog, so they have to clear a
/// higher bar than a specific bark. And if something else clearly outranks the
/// dog classes in the window, a low dog score is probably a mislabel.
const Set<String> weakBarkClasses = {'Howl', 'Dog', 'Growling'};
const double weakBarkMargin = 0.2;
const double outrankedBarkCeiling = 0.6;

/// The loudest 20 ms frame in a window must beat this for "loud sound", unless
/// the room's calibrated noise is high enough to need more.
const double loudFloor = 0.15;

class SoundVerdict {
  const SoundVerdict(
    this.category,
    this.heard,
    this.heardScore, [
    this.categoryScore,
  ]);

  /// The alert category that fired, or null.
  final String? category;

  /// The single best class in the window, for showing what the detector hears.
  final String heard;
  final double heardScore;
  final double? categoryScore;
}

class SoundDetection {
  const SoundDetection(this.category, this.at, this.score, this.durationMs);
  final String category;
  final DateTime at;
  final double? score;
  final int durationMs;
  String get title => switch (category) {
    'barking' => 'Possible dog sound',
    'knocking' => 'Possible knock or doorbell',
    _ => 'Possible $category',
  };
}

class SoundWatch {
  static const sampleCount = 15600;

  /// Windows overlap by half. Back-to-back windows can split a short sound
  /// across two of them, leaving each with half of it.
  static const hopCount = sampleCount ~/ 2;

  Interpreter? _interpreter;
  IsolateInterpreter? _runner;
  Future<void>? _initializing;
  List<String> _labels = [];
  final List<double> _window = [];
  late final SoundGate _gate = SoundGate(
    immediate: {'barking', 'knocking', 'loud sound', 'coughing'},
    burst: {'barking': 2, 'coughing': 2},
    toleratedGap: const Duration(seconds: 2),
  );
  bool _busy = false;
  bool _disposed = false;
  int _generation = 0;
  double _windowPeak = 0;
  bool enabled = false;
  Map<String, SoundRule> rules = {};
  double sensitivity = 0.4;
  final Set<String> categories = {
    'crying',
    'coughing',
    'barking',
    'knocking',
    'loud sound',
  };
  double noiseFloor = 0.015;
  int _calibrationLeft = 0;
  double _calibrationTotal = 0;
  int _calibrationCount = 0;
  bool get calibrating => _calibrationLeft > 0;
  bool get ready => _runner != null;

  /// What the detector last heard, whether or not it was alert-worthy. Shown
  /// in the app so it is obvious the detector is alive and what it thinks.
  String? lastHeard;
  double lastHeardScore = 0;
  DateTime? lastWindowAt;

  /// Counters that make the detector's health visible. A detector that is
  /// switched on but silently analysing nothing looks exactly like a quiet
  /// room, so the app shows these.
  int framesFed = 0;
  int windowsAnalysed = 0;
  String? lastError;

  /// One sentence on what the detector is doing right now.
  String get status {
    if (!enabled) return 'Sound alerts are off.';
    if (lastError != null) return 'Detector problem: $lastError';
    if (!ready) return 'Detector is loading…';
    if (framesFed == 0) return 'Waiting for audio to analyse.';
    if (windowsAnalysed == 0) return 'Collecting the first second of sound…';
    final at = lastWindowAt;
    final ago = at == null
        ? ''
        : ' • last ${DateTime.now().difference(at).inSeconds}s ago';
    return 'Analysing sound ($windowsAnalysed checks$ago).';
  }

  void Function(String title)? onEvent;
  void Function(SoundDetection event)? onDetection;
  void Function(SoundVerdict verdict, DateTime at)? onVerdict;
  void Function()? onHeard;
  void Function(double noiseFloor)? onCalibrated;
  void Function(String reason)? onError;

  Future<void> initialize() {
    if (_disposed || ready) return Future<void>.value();
    return _initializing ??= _initialize().whenComplete(() {
      _initializing = null;
    });
  }

  Future<void> _initialize() async {
    _labels = (await rootBundle.loadString('assets/models/yamnet_labels.txt'))
        .trim()
        .split('\n')
        .map((l) => l.trim())
        .toList();
    final interpreter = await Interpreter.fromAsset(
      'assets/models/yamnet.tflite',
      options: InterpreterOptions()..threads = 2,
    );
    if (_disposed) {
      interpreter.close();
      return;
    }
    IsolateInterpreter runner;
    try {
      runner = await IsolateInterpreter.create(address: interpreter.address);
    } catch (_) {
      interpreter.close();
      rethrow;
    }
    if (_disposed) {
      await runner.close();
      interpreter.close();
      return;
    }
    _interpreter = interpreter;
    _runner = runner;
  }

  void calibrate() {
    // Eight seconds of audio, measured on this phone's current stream.
    _calibrationLeft = 16000 * 8;
    _calibrationTotal = 0;
    _calibrationCount = 0;
    _gate.reset(clearBursts: true);
  }

  void feed(Int16List pcm) {
    if (_disposed || (!enabled && !calibrating)) return;
    var energy = 0.0;
    for (final sample in pcm) {
      final v = sample / 32768.0;
      energy += v * v;
    }
    if (calibrating) {
      _calibrationTotal += energy;
      _calibrationCount += pcm.length;
      _calibrationLeft -= pcm.length;
      if (_calibrationLeft <= 0) {
        noiseFloor = math
            .sqrt(_calibrationTotal / _calibrationCount)
            .clamp(0.003, 0.5);
        onCalibrated?.call(noiseFloor);
      }
      return;
    }
    framesFed++;
    if (framesFed == 1 || framesFed % 500 == 0) {
      debugPrint('sound watch: fed $framesFed frames, ready=$ready');
    }
    if (!ready) return;

    // The loudest short frame matters more than the window average: a clap or
    // a bang is a few milliseconds in a second of quiet.
    _windowPeak = math.max(_windowPeak, math.sqrt(energy / pcm.length));
    _window.addAll(pcm.map((s) => s / 32768.0));
    if (_window.length < sampleCount) return;
    if (_busy) {
      // Still analysing the last window: keep only the newest second.
      _window.removeRange(0, _window.length - sampleCount);
      return;
    }

    final input = Float32List.fromList(_window.sublist(0, sampleCount));
    _window.removeRange(0, hopCount);
    final peak = _windowPeak;
    _windowPeak = 0;
    unawaited(_classify(input, peak, _generation));
  }

  /// Chooses the alert category for one window. Pure, so it can be tested
  /// without the model.
  static SoundVerdict decide({
    required List<double> scores,
    required List<String> labels,
    required Set<String> categories,
    required double sensitivity,
    required double peak,
    required double noiseFloor,
    Map<String, double>? thresholds,
  }) {
    final count = math.min(labels.length, scores.length);
    var topIndex = 0;
    for (var i = 1; i < count; i++) {
      if (scores[i] > scores[topIndex]) topIndex = i;
    }

    String? category;
    var best = -1.0;
    soundGroups.forEach((group, names) {
      if (!categories.contains(group)) return;
      for (var i = 0; i < count; i++) {
        if (!names.contains(labels[i])) continue;
        var needed = thresholds?[group] ?? sensitivity;
        if (group == 'barking') {
          if (weakBarkClasses.contains(labels[i])) {
            needed = math.min(0.9, needed + weakBarkMargin);
          }
          // Another sound dominates the window: only a confident bark counts.
          if (!names.contains(labels[topIndex]) &&
              scores[i] < outrankedBarkCeiling) {
            continue;
          }
        }
        if (scores[i] > needed && scores[i] > best) {
          best = scores[i];
          category = group;
        }
      }
    });
    if (category == null &&
        categories.contains('loud sound') &&
        peak >
            math.max(loudFloor, noiseFloor * 10) *
                ((thresholds?['loud sound'] ?? .4) / .4)) {
      category = 'loud sound';
    }
    return SoundVerdict(
      category,
      count == 0 ? '' : labels[topIndex],
      count == 0 ? 0 : scores[topIndex],
      category == null || category == 'loud sound' ? null : best,
    );
  }

  Future<void> _classify(Float32List input, double peak, int generation) async {
    _busy = true;
    try {
      final output = [List<double>.filled(521, 0)];
      await _runner!.run(input, output);
      if (_disposed || !enabled || generation != _generation) return;
      final verdict = decide(
        scores: output.single,
        labels: _labels,
        categories: categories,
        sensitivity: sensitivity,
        peak: peak,
        noiseFloor: noiseFloor,
        thresholds: {for (final e in rules.entries) e.key: e.value.threshold},
      );
      windowsAnalysed++;
      lastError = null;
      lastHeard = verdict.heard;
      lastHeardScore = verdict.heardScore;
      lastWindowAt = DateTime.now();
      debugPrint(
        'sound watch: heard ${verdict.heard} '
        '${(verdict.heardScore * 100).round()}% peak ${peak.toStringAsFixed(3)}'
        '${verdict.category == null ? '' : ' -> ${verdict.category}'}',
      );
      onHeard?.call();
      onVerdict?.call(verdict, lastWindowAt!);
      _gate.rules = rules;
      if (_gate.accept(verdict.category, lastWindowAt!)) {
        final detection = SoundDetection(
          verdict.category!,
          lastWindowAt!,
          verdict.categoryScore,
          math.max(975, _gate.acceptedSpanMs + 975),
        );
        onDetection?.call(detection);
        onEvent?.call(detection.title);
      }
    } catch (e) {
      if (_disposed || !enabled || generation != _generation) return;
      lastError = '$e';
      debugPrint('sound watch: analysis failed: $e');
      enabled = false;
      onError?.call(
        'Sound Watch could not analyze audio. Live listening is still available.',
      );
    } finally {
      _busy = false;
    }
  }

  void reset() {
    _generation++;
    _window.clear();
    _windowPeak = 0;
    _gate.reset(clearBursts: true);
    _calibrationLeft = 0;
    lastHeard = null;
    lastHeardScore = 0;
    lastWindowAt = null;
    framesFed = 0;
    windowsAnalysed = 0;
  }

  Future<void> dispose() async {
    _disposed = true;
    reset();
    try {
      await _initializing;
    } catch (_) {
      // Initialization already released its interpreter on failure.
    }
    // Let a running inference release its tensor access before destroying it.
    while (_busy) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await _runner?.close();
    _interpreter?.close();
    _runner = null;
    _interpreter = null;
  }
}
