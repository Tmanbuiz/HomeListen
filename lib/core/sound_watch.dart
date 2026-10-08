import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// A duration gate with per-category cooldowns. Scores are model outputs, not
/// calibrated probabilities; alerts deliberately say "Possible".
///
/// Sustained sounds (crying) need [requiredHits] windows in a row, so a single
/// odd moment does not wake anyone. Short sounds ([immediate]: a bark, a knock,
/// a bang) last a fraction of a second and are, by nature, in one analysis
/// window only; requiring two in a row meant they could never alert.
class SoundGate {
  SoundGate({
    this.requiredHits = 2,
    this.cooldown = const Duration(seconds: 30),
    this.immediate = const {},
  });
  final int requiredHits;
  final Duration cooldown;
  final Set<String> immediate;
  final Map<String, DateTime> _last = {};
  String? _candidate;
  int _hits = 0;

  bool accept(String? category, DateTime at) {
    if (category == null) {
      reset();
      return false;
    }
    _hits = category == _candidate ? _hits + 1 : 1;
    _candidate = category;
    final needed = immediate.contains(category) ? 1 : requiredHits;
    if (_hits < needed) return false;
    final last = _last[category];
    if (last != null && at.difference(last) < cooldown) return false;
    _last[category] = at;
    _hits = 0;
    return true;
  }

  void reset() {
    _candidate = null;
    _hits = 0;
  }
}

/// Which YAMNet classes count toward each alert category.
///
/// A dog barking is rarely scored as plain "Bark": the model spreads it across
/// "Dog", "Bark", "Bow-wow" and friends, so matching one label made real
/// barking fall under the threshold. Each category takes the best score among
/// its related classes.
const Map<String, Set<String>> soundGroups = {
  'crying': {'Baby cry, infant cry', 'Crying, sobbing', 'Whimper'},
  'barking': {'Bark', 'Bow-wow', 'Yip', 'Howl', 'Dog', 'Growling'},
  'knocking': {'Knock', 'Doorbell', 'Ding-dong', 'Tap'},
};

/// The loudest 20 ms frame in a window must beat this for "loud sound", unless
/// the room's calibrated noise is high enough to need more.
const double loudFloor = 0.15;

class SoundVerdict {
  const SoundVerdict(this.category, this.heard, this.heardScore);

  /// The alert category that fired, or null.
  final String? category;

  /// The single best class in the window, for showing what the detector hears.
  final String heard;
  final double heardScore;
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
    immediate: {'barking', 'knocking', 'loud sound'},
  );
  bool _busy = false;
  bool _disposed = false;
  int _generation = 0;
  double _windowPeak = 0;
  bool enabled = false;
  double sensitivity = 0.4;
  final Set<String> categories = {
    'crying',
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
    _gate.reset();
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
  }) {
    final count = math.min(labels.length, scores.length);
    var topIndex = 0;
    for (var i = 1; i < count; i++) {
      if (scores[i] > scores[topIndex]) topIndex = i;
    }

    String? category;
    var best = sensitivity;
    soundGroups.forEach((group, names) {
      if (!categories.contains(group)) return;
      for (var i = 0; i < count; i++) {
        if (names.contains(labels[i]) && scores[i] > best) {
          best = scores[i];
          category = group;
        }
      }
    });
    if (category == null &&
        categories.contains('loud sound') &&
        peak > math.max(loudFloor, noiseFloor * 10)) {
      category = 'loud sound';
    }
    return SoundVerdict(
      category,
      count == 0 ? '' : labels[topIndex],
      count == 0 ? 0 : scores[topIndex],
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
      if (_gate.accept(verdict.category, DateTime.now())) {
        onEvent?.call('Possible ${verdict.category}');
      }
    } catch (e) {
      if (_disposed) return;
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
    _gate.reset();
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
