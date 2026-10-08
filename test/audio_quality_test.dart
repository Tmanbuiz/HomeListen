import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/sound_watch.dart';
import 'package:home_listen/protocols/noise_gate.dart';

/// 20 ms of deterministic pseudo-noise at [rms] (fraction of full scale).
Int16List noise(double rms, int seed) {
  final random = math.Random(seed);
  final out = Int16List(320);
  for (var i = 0; i < out.length; i++) {
    // Uniform noise scaled so its RMS is [rms].
    final v = (random.nextDouble() * 2 - 1) * rms * math.sqrt(3);
    out[i] = (v * 32768).round().clamp(-32768, 32767);
  }
  return out;
}

double rmsOf(Int16List f) {
  var s = 0.0;
  for (final v in f) {
    s += (v / 32768) * (v / 32768);
  }
  return math.sqrt(s / f.length);
}

void main() {
  group('Noise gate', () {
    test('steady hiss is turned down once the room has been learned', () {
      final gate = NoiseGate();
      Int16List last = Int16List(320);
      for (var i = 0; i < 200; i++) {
        last = gate.process(noise(0.004, i));
      }
      // About -18 dB below what went in.
      expect(rmsOf(last), lessThan(0.004 * 0.25));
      expect(gate.gain, closeTo(gate.quietGain, 0.02));
    });

    test('the first moments of a connection pass untouched', () {
      final gate = NoiseGate();
      final input = noise(0.004, 1);
      expect(gate.process(input), input);
    });

    test('a voice-level sound passes at full volume, from the first frame', () {
      final gate = NoiseGate();
      for (var i = 0; i < 200; i++) {
        gate.process(noise(0.004, i));
      }
      final voice = noise(0.1, 999);
      final out = gate.process(voice);
      // It was shaped for the hiss a moment ago; the opening ramp must not
      // swallow the start of the sound.
      expect(rmsOf(out), greaterThan(rmsOf(voice) * 0.5));
      final next = gate.process(noise(0.1, 1000));
      expect(rmsOf(next), closeTo(0.1, 0.01));
      expect(gate.gain, 1);
    });

    test('it stays open across the short gap between words', () {
      final gate = NoiseGate();
      for (var i = 0; i < 200; i++) {
        gate.process(noise(0.004, i));
      }
      gate.process(noise(0.1, 1));
      // Five quiet frames (100 ms), then speech again: still fully open.
      for (var i = 0; i < 5; i++) {
        gate.process(noise(0.004, 50 + i));
      }
      expect(gate.gain, 1);
    });

    test('a steady louder background becomes the new floor, slowly', () {
      final gate = NoiseGate();
      for (var i = 0; i < 100; i++) {
        gate.process(noise(0.004, i));
      }
      final before = gate.floor;
      // A fan switches on.
      for (var i = 0; i < 6000; i++) {
        gate.process(noise(0.012, i));
      }
      expect(gate.floor, greaterThan(before * 1.5));
    });

    test('digital silence stays silent and never overflows', () {
      final gate = NoiseGate();
      for (var i = 0; i < 100; i++) {
        final out = gate.process(Int16List(320));
        expect(out.every((s) => s == 0), isTrue);
      }
      final loud = Int16List.fromList(List.filled(320, 32767));
      expect(() => gate.process(loud), returnsNormally);
    });

    test('output has the same length and the input is not modified', () {
      final gate = NoiseGate();
      final input = noise(0.004, 3);
      final copy = Int16List.fromList(input);
      for (var i = 0; i < 100; i++) {
        gate.process(noise(0.004, i));
      }
      final out = gate.process(input);
      expect(out.length, input.length);
      expect(input, copy);
    });
  });

  group('Sound alerts', () {
    final labels = [
      'Speech',
      'Dog',
      'Bark',
      'Knock',
      'Baby cry, infant cry',
      'Silence',
    ];
    List<double> scores(Map<String, double> by) =>
        labels.map((l) => by[l] ?? 0.0).toList();

    SoundVerdict decide(
      Map<String, double> by, {
      double sensitivity = 0.4,
      double peak = 0.02,
      Set<String>? categories,
    }) => SoundWatch.decide(
      scores: scores(by),
      labels: labels,
      categories: categories ?? {'crying', 'barking', 'knocking', 'loud sound'},
      sensitivity: sensitivity,
      peak: peak,
      noiseFloor: 0.015,
    );

    test('a bark scored mostly as "Dog" still counts as barking', () {
      expect(decide({'Dog': 0.62, 'Bark': 0.2}).category, 'barking');
    });

    test('knocks and crying are recognised', () {
      expect(decide({'Knock': 0.5}).category, 'knocking');
      expect(decide({'Baby cry, infant cry': 0.7}).category, 'crying');
    });

    test('weak scores and unwatched categories do not alert', () {
      expect(decide({'Bark': 0.2}).category, isNull);
      expect(decide({'Bark': 0.9}, categories: {'crying'}).category, isNull);
    });

    test('the best-scoring group wins', () {
      expect(decide({'Bark': 0.5, 'Knock': 0.7}).category, 'knocking');
    });

    test('a short loud bang alerts even when the average is quiet', () {
      expect(decide({'Silence': 0.5}, peak: 0.4).category, 'loud sound');
      expect(decide({'Silence': 0.5}, peak: 0.05).category, isNull);
    });

    test('the verdict says what the detector heard, alert or not', () {
      final v = decide({'Speech': 0.8});
      expect(v.category, isNull);
      expect(v.heard, 'Speech');
      expect(v.heardScore, closeTo(0.8, 1e-9));
    });

    test('a single bark alerts, but crying must be sustained', () {
      final gate = SoundGate(immediate: {'barking', 'knocking', 'loud sound'});
      final t = DateTime(2026);
      expect(gate.accept('barking', t), isTrue);
      expect(gate.accept('crying', t), isFalse);
      expect(gate.accept('crying', t), isTrue);
    });
  });
}
