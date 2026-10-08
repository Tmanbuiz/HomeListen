import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/activity_event.dart';
import 'package:home_listen/core/sound_watch.dart';
import 'package:home_listen/protocols/jitter_buffer.dart';

void main() {
  Uint8List payload(int n) => Uint8List.fromList([n]);
  group('Audio playout', () {
    test('reorders arrivals before their playout deadline', () {
      final buffer = JitterBuffer();
      buffer.add(11, payload(11));
      buffer.add(10, payload(10));
      buffer.add(12, payload(12));
      expect(buffer.take()!.payload, payload(10));
      expect(buffer.take()!.payload, payload(11));
      expect(buffer.take()!.payload, payload(12));
    });
    test('duplicate and expired frames never replay', () {
      final buffer = JitterBuffer();
      for (var i = 1; i <= 3; i++) {
        buffer.add(i, payload(i));
      }
      buffer.add(1, payload(99));
      expect(buffer.take()!.payload, payload(1));
      buffer.add(1, payload(99));
      expect(buffer.take()!.payload, payload(2));
      expect(buffer.received, 3);
      expect(buffer.late, 1);
    });
    test('a lost frame preserves timing and adapts the queue', () {
      final buffer = JitterBuffer();
      for (final i in [1, 3, 4]) {
        buffer.add(i, payload(i));
      }
      expect(buffer.take()!.payload, payload(1));
      expect(buffer.take()!.payload, isNull);
      expect(buffer.lost, 1);
      expect(buffer.targetFrames, 4);
      expect(buffer.take()!.payload, payload(3));
    });
    test('sequence wrap works and long gaps discard obsolete audio', () {
      final buffer = JitterBuffer();
      for (final i in [65534, 65535, 0]) {
        buffer.add(i, payload(i & 255));
      }
      expect(buffer.take()!.payload, payload(254));
      expect(buffer.take()!.payload, payload(255));
      expect(buffer.take()!.payload, payload(0));
      for (final i in [100, 101, 102]) {
        buffer.add(i, payload(i));
      }
      expect(buffer.take()!.payload, payload(100));
      expect(buffer.depth, lessThanOrEqualTo(buffer.maxFrames));
    });
    test('queue depth stays bounded under burst traffic', () {
      final buffer = JitterBuffer();
      for (var i = 0; i < 100; i++) {
        buffer.add(i, payload(i));
      }
      expect(buffer.depth, lessThanOrEqualTo(buffer.maxFrames));
    });
  });
  group('Sound alerts', () {
    test('requires sustained detections and throttles duplicate alerts', () {
      final gate = SoundGate();
      final start = DateTime(2026);
      expect(gate.accept('crying', start), isFalse);
      expect(
        gate.accept('crying', start.add(const Duration(seconds: 1))),
        isTrue,
      );
      expect(
        gate.accept('crying', start.add(const Duration(seconds: 2))),
        isFalse,
      );
      expect(
        gate.accept('crying', start.add(const Duration(seconds: 3))),
        isFalse,
      );
      expect(
        gate.accept('crying', start.add(const Duration(seconds: 32))),
        isTrue,
      );
    });
    test(
      'a gap resets the duration gate; category cooldowns are independent',
      () {
        final gate = SoundGate();
        final start = DateTime(2026);
        expect(gate.accept('crying', start), isFalse);
        expect(gate.accept(null, start), isFalse);
        expect(gate.accept('crying', start), isFalse);
        expect(gate.accept('crying', start), isTrue);
        expect(gate.accept('barking', start), isFalse);
        expect(gate.accept('barking', start), isTrue);
      },
    );
  });
  test('history tolerates corrupt rows and never stores sound samples', () {
    expect(ActivityEvent.restore('broken json'), isEmpty);
    final events = ActivityEvent.restore(
      '[{"kind":"sound","title":"Possible barking","room":"Bedroom","at":"2026-10-06T18:00:00Z"}, {"kind":"bogus"}]',
    );
    expect(events, hasLength(1));
    expect(
      events.single.toJson().keys,
      unorderedEquals(['kind', 'title', 'room', 'at']),
    );
  });
}
