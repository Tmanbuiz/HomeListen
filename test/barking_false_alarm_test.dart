import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/sound_watch.dart';

void main() {
  const labels = [
    'Speech',
    'Bark',
    'Bow-wow',
    'Yip',
    'Howl',
    'Dog',
    'Growling',
    'Knock',
    'Silence',
  ];
  List<double> scores(Map<String, double> by) =>
      labels.map((l) => by[l] ?? 0.0).toList();
  SoundVerdict decide(Map<String, double> by, {double sensitivity = 0.4}) =>
      SoundWatch.decide(
        scores: scores(by),
        labels: labels,
        categories: {'barking'},
        sensitivity: sensitivity,
        peak: 0.02,
        noiseFloor: 0.015,
      );

  group('barking false alarms', () {
    test('a specific bark clears the normal threshold', () {
      expect(decide({'Bark': 0.45}).category, 'barking');
      expect(decide({'Bow-wow': 0.45}).category, 'barking');
    });

    test('the broad dog classes need a clearly higher score', () {
      expect(decide({'Dog': 0.45}).category, isNull);
      expect(decide({'Growling': 0.5}).category, isNull);
      expect(decide({'Howl': 0.55}).category, isNull);
      expect(decide({'Dog': 0.65}).category, 'barking');
    });

    test('a low dog score is ignored when something else dominates', () {
      expect(decide({'Speech': 0.8, 'Bark': 0.45}).category, isNull);
      // A confident bark still counts even with speech around.
      expect(decide({'Speech': 0.8, 'Bark': 0.7}).category, 'barking');
    });
  });

  group('barking needs two separate barks', () {
    SoundGate gate() =>
        SoundGate(immediate: {'barking'}, burst: {'barking': 2});
    final t0 = DateTime(2026, 10, 10, 12);

    test('one bark does not alert', () {
      expect(gate().accept('barking', t0), isFalse);
    });

    test('the same bark seen in two overlapping windows does not alert', () {
      final g = gate();
      expect(g.accept('barking', t0), isFalse);
      expect(
        g.accept('barking', t0.add(const Duration(milliseconds: 490))),
        isFalse,
      );
    });

    test('two barks a couple of seconds apart do alert, gaps included', () {
      final g = gate();
      expect(g.accept('barking', t0), isFalse);
      expect(g.accept(null, t0.add(const Duration(seconds: 1))), isFalse);
      expect(g.accept('barking', t0.add(const Duration(seconds: 2))), isTrue);
    });

    test('barks too far apart are separate single barks', () {
      final g = gate();
      expect(g.accept('barking', t0), isFalse);
      expect(g.accept('barking', t0.add(const Duration(seconds: 20))), isFalse);
    });

    test(
      'after an alert it needs a fresh pair, and the cooldown still holds',
      () {
        final g = gate();
        g.accept('barking', t0);
        expect(g.accept('barking', t0.add(const Duration(seconds: 2))), isTrue);
        expect(
          g.accept('barking', t0.add(const Duration(seconds: 4))),
          isFalse,
        );
        expect(
          g.accept('barking', t0.add(const Duration(seconds: 6))),
          isFalse,
        );
      },
    );
  });
}
