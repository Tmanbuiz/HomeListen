import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/guardian_settings.dart';
import 'package:home_listen/core/sound_watch.dart';

void main() {
  final start = DateTime(2026, 10, 26, 12);
  DateTime at(int milliseconds) =>
      start.add(Duration(milliseconds: milliseconds));

  SoundGate cryingGate() => SoundGate(
    immediate: {'knocking', 'coughing'},
    burst: {'coughing': 2},
    toleratedGap: const Duration(seconds: 2),
  )..rules = {'crying': const SoundRule(minimumSeconds: 30)};

  test('a brief knock does not restart the thirty-second crying timer', () {
    final gate = cryingGate();
    for (var i = 0; i <= 60; i++) {
      final category = i == 40 ? 'knocking' : 'crying';
      expect(
        gate.accept(category, at(i * 500)),
        i == 40 || i == 60,
        reason: '$category at ${i * 500}ms',
      );
    }
    expect(gate.acceptedSpanMs, 30000);
  });

  test('two seconds of another category start a fresh crying timer', () {
    final gate = cryingGate();
    for (var i = 0; i < 40; i++) {
      expect(gate.accept('crying', at(i * 500)), isFalse);
    }
    for (var i = 40; i < 44; i++) {
      gate.accept('knocking', at(i * 500));
    }
    for (var i = 44; i < 104; i++) {
      expect(gate.accept('crying', at(i * 500)), isFalse);
    }
    expect(gate.accept('crying', at(52000)), isTrue);
    expect(gate.acceptedSpanMs, 30000);
  });

  test('a pending cough cannot extend the last matching cry time', () {
    final gate = cryingGate()
      ..rules = {'crying': const SoundRule(minimumSeconds: 2)};
    expect(gate.accept('crying', at(0)), isFalse);
    expect(gate.accept('crying', at(500)), isFalse);
    expect(gate.accept('coughing', at(2000)), isFalse);
    expect(gate.accept('crying', at(2500)), isFalse);
    expect(gate.accept('crying', at(3000)), isFalse);
    expect(gate.accept('crying', at(4000)), isFalse);
    expect(gate.accept('crying', at(4500)), isTrue);
    expect(gate.acceptedSpanMs, 2000);
  });

  test('reset discards sustained evidence from the previous session', () {
    final gate = cryingGate();
    for (var i = 0; i < 60; i++) {
      expect(gate.accept('crying', at(i * 500)), isFalse);
    }
    gate.reset(clearBursts: true);
    for (var i = 60; i < 120; i++) {
      expect(gate.accept('crying', at(i * 500)), isFalse);
    }
    expect(gate.accept('crying', at(60000)), isTrue);
  });

  for (final category in ['coughing', 'barking']) {
    group('$category burst evidence', () {
      SoundGate gate() => SoundGate(
        immediate: {category},
        burst: {category: 2},
        toleratedGap: const Duration(seconds: 2),
      );

      test('one continuous detection run never counts as two sounds', () {
        final sounds = gate();
        for (var i = 0; i < 20; i++) {
          expect(sounds.accept(category, at(i * 487)), isFalse);
        }
      });

      test(
        'a different verdict rearms a distinct sound within eight seconds',
        () {
          final sounds = gate();
          expect(sounds.accept(category, at(0)), isFalse);
          expect(sounds.accept(category, at(487)), isFalse);
          expect(sounds.accept('crying', at(1000)), isFalse);
          expect(sounds.accept(category, at(1500)), isTrue);
        },
      );

      test('brief overlapping detections cannot bypass minimum spacing', () {
        final sounds = gate();
        expect(sounds.accept(category, at(0)), isFalse);
        expect(sounds.accept(null, at(300)), isFalse);
        expect(sounds.accept(category, at(487)), isFalse);
        expect(sounds.accept(category, at(975)), isFalse);
        expect(sounds.accept(null, at(1500)), isFalse);
        expect(sounds.accept(category, at(2000)), isTrue);
      });

      for (final seconds in [8, 15]) {
        test('an established pair supports a $seconds-second duration', () {
          final sounds = gate()
            ..rules = {category: SoundRule(minimumSeconds: seconds)};
          expect(sounds.accept(category, at(0)), isFalse);
          expect(sounds.accept(category, at(500)), isFalse);
          expect(sounds.accept(null, at(1000)), isFalse);
          for (var ms = 1500; ms < 1500 + seconds * 1000; ms += 500) {
            expect(sounds.accept(category, at(ms)), isFalse);
          }
          expect(sounds.accept(category, at(1500 + seconds * 1000)), isTrue);
          expect(sounds.acceptedSpanMs, seconds * 1000);
        });
      }

      test(
        'fresh pairs respect cooldown and expired evidence is not reused',
        () {
          final sounds = gate();
          expect(sounds.accept(category, at(0)), isFalse);
          sounds.accept(null, at(1000));
          expect(sounds.accept(category, at(2000)), isTrue);
          sounds.accept(null, at(3000));
          expect(sounds.accept(category, at(4000)), isFalse);
          sounds.accept(null, at(5000));
          expect(sounds.accept(category, at(6000)), isFalse);
          sounds.accept(null, at(33000));
          expect(sounds.accept(category, at(34000)), isFalse);
          sounds.accept(null, at(35000));
          expect(sounds.accept(category, at(36000)), isTrue);
        },
      );
    });
  }
}
