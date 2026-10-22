import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/guardian_settings.dart';

void main() {
  test(
    'new sound rules wait thirty seconds for crying and never record by default',
    () {
      final settings = GuardianSettings.restore(null);
      expect(settings.rules['crying']!.minimumSeconds, 30);
      expect(settings.rules['coughing']!.minimumSeconds, 8);
      expect(settings.rules.values.every((rule) => !rule.recordAudio), isTrue);
    },
  );

  test(
    'legacy crying default migrates without changing custom timing or recording consent',
    () {
      final settings = GuardianSettings.restore(
        jsonEncode({
          'version': 1,
          'rules': {
            'crying': {'minimumSeconds': 1},
            'barking': {'minimumSeconds': 4},
          },
        }),
      );
      expect(settings.rules['crying']!.minimumSeconds, 30);
      expect(settings.rules['barking']!.minimumSeconds, 4);
      expect(settings.rules.values.every((rule) => !rule.recordAudio), isTrue);
      final custom = GuardianSettings.restore(
        jsonEncode({
          'version': 1,
          'rules': {
            'crying': {'minimumSeconds': 0},
          },
        }),
      );
      expect(custom.rules['crying']!.minimumSeconds, 0);
    },
  );

  test(
    'recording is selected independently per category and survives restore',
    () {
      final settings = GuardianSettings(
        rules: {
          'crying': const SoundRule(minimumSeconds: 30, recordAudio: true),
          'coughing': const SoundRule(minimumSeconds: 8),
        },
      );
      final restored = GuardianSettings.restore(settings.encode());
      expect(restored.rules['crying']!.recordAudio, isTrue);
      expect(restored.rules['coughing']!.recordAudio, isFalse);
      expect(restored.rules['crying']!.minimumSeconds, 30);
      expect(
        restored.rules['crying']!.copyWith(recordAudio: false).recordAudio,
        isFalse,
      );
    },
  );

  test(
    'new settings preserve a custom one-second cry rule and support minutes',
    () {
      final settings = GuardianSettings(
        rules: {
          'crying': const SoundRule(minimumSeconds: 1),
          'coughing': const SoundRule().copyWith(minimumSeconds: 120),
        },
      );
      final restored = GuardianSettings.restore(settings.encode());
      expect(restored.rules['crying']!.minimumSeconds, 1);
      expect(restored.rules['coughing']!.minimumSeconds, 120);
      expect(
        const SoundRule().copyWith(minimumSeconds: 900).minimumSeconds,
        300,
      );
      expect(const SoundRule().copyWith(minimumSeconds: -5).minimumSeconds, 0);
    },
  );

  test('invalid recording values do not opt a user into saving audio', () {
    final settings = GuardianSettings.restore(
      jsonEncode({
        'rules': {
          'crying': {'recordAudio': 'true'},
          'coughing': {'recordAudio': 1},
        },
      }),
    );
    expect(settings.rules['crying']!.recordAudio, isFalse);
    expect(settings.rules['coughing']!.recordAudio, isFalse);
  });
}
