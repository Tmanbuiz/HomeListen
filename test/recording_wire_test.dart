import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/recording_wire.dart';
import 'package:home_listen/core/sound_watch.dart';
import 'package:home_listen/core/guardian_settings.dart';

void main() {
  test(
    'recording transport preserves signed PCM, sequence and wrapped clock',
    () {
      final pcm = Uint8List.fromList([0, 128, 255, 127, 0, 0]);
      final packet = AlertAudioPacket.decode(
        AlertAudioPacket.encode(17, 0x100000001, pcm),
      )!;
      expect(packet.sequence, 17);
      expect(packet.clock, 1);
      expect(packet.pcm, [-32768, 32767, 0]);
    },
  );

  test('malformed or excessive recording payloads are rejected', () {
    expect(AlertAudioPacket.decode(Uint8List(6414)), isNull);
    expect(AlertAudioPacket.decode(Uint8List(14)), isNull);
    expect(
      AlertAudioPacket.decode(AlertAudioPacket.encode(1, 1, Uint8List(3))),
      isNull,
    );
  });

  test(
    'crying must span 30 seconds and brief detection gaps are tolerated',
    () {
      final gate = SoundGate(toleratedGap: const Duration(seconds: 2))
        ..rules = {'crying': const SoundRule(minimumSeconds: 30)};
      final start = DateTime(2026);
      for (var i = 0; i < 60; i++) {
        final at = start.add(Duration(milliseconds: i * 500));
        expect(gate.accept(i == 20 ? null : 'crying', at), isFalse);
      }
      expect(
        gate.accept('crying', start.add(const Duration(seconds: 30))),
        isTrue,
      );
    },
  );

  test('a sustained gap starts a new crying duration', () {
    final gate = SoundGate(toleratedGap: const Duration(seconds: 2))
      ..rules = {'crying': const SoundRule(minimumSeconds: 30)};
    final at = DateTime(2026);
    gate.accept('crying', at);
    gate.accept('crying', at.add(const Duration(seconds: 1)));
    gate.accept(null, at.add(const Duration(seconds: 3)));
    expect(gate.accept('crying', at.add(const Duration(seconds: 30))), isFalse);
  });

  test('coughs use the actual model cough class', () {
    final verdict = SoundWatch.decide(
      scores: [.8],
      labels: ['Cough'],
      categories: {'coughing'},
      sensitivity: .4,
      peak: .01,
      noiseFloor: .01,
    );
    expect(verdict.category, 'coughing');
  });
}
