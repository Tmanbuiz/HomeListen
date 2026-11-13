import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/guardian_settings.dart';
import 'package:home_listen/core/sound_watch.dart';

void main() {
  test(
    'new sound rules wait thirty seconds for crying and never record by default',
    () {
      final settings = GuardianSettings.restore(null);
      expect(settings.rules['crying']!.minimumSeconds, 30);
      expect(
        GuardianSettings.restore(settings.encode()).rules['crying']!
            .minimumSeconds,
        30,
      );
      expect(settings.rules['coughing']!.minimumSeconds, 0);
      expect(settings.rules['crying']!.recordingMinimumSeconds, 30);
      expect(settings.rules['coughing']!.recordingMinimumSeconds, 8);
      expect(settings.rules['knocking']!.recordingMinimumSeconds, 0);
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

  test('saved recording durations clamp safely without enabling recording', () {
    final settings = GuardianSettings.restore(
      jsonEncode({
        'version': 3,
        'rules': {
          'crying': {'recordingMinimumSeconds': -5},
          'coughing': {'recordingMinimumSeconds': true},
          'knocking': {'recordingMinimumSeconds': 10000},
        },
      }),
    );
    expect(settings.rules['crying']!.recordingMinimumSeconds, 0);
    expect(settings.rules['coughing']!.recordingMinimumSeconds, 8);
    expect(settings.rules['knocking']!.recordingMinimumSeconds, 300);
    expect(settings.rules.values.every((rule) => !rule.recordAudio), isTrue);
  });

  test('legacy cough duration is reviewed without changing chosen timings', () {
    final legacy = GuardianSettings.restore(
      jsonEncode({
        'version': 2,
        'rules': {
          'coughing': {'minimumSeconds': 8, 'recordAudio': true},
        },
      }),
    );
    final cough = legacy.rules['coughing']!;
    expect(cough.minimumSeconds, 8);
    expect(cough.recordingMinimumSeconds, 8);
    expect(cough.recordAudio, isTrue);
    expect(cough.durationNeedsReview, isTrue);
    expect(cough.copyWith(threshold: .6).durationNeedsReview, isTrue);
    expect(
      cough.copyWith(recordingMinimumSeconds: 15).durationNeedsReview,
      isTrue,
    );
    expect(
      GuardianSettings.restore(legacy.encode())
          .rules['coughing']!
          .durationNeedsReview,
      isTrue,
    );

    final recommended = cough.copyWith(minimumSeconds: 0);
    expect(recommended.minimumSeconds, 0);
    expect(recommended.recordingMinimumSeconds, 8);
    expect(recommended.recordAudio, isTrue);
    expect(recommended.durationNeedsReview, isFalse);
    final kept = cough.copyWith(durationNeedsReview: false);
    final confirmed = GuardianSettings(rules: {'coughing': kept});
    expect(GuardianSettings.restore(confirmed.encode()).rules['coughing']!
        .durationNeedsReview, isFalse);
    expect(kept.minimumSeconds, 8);
  });

  test('legacy recordings retain opt-in thresholds independently of alerts', () {
    for (final seconds in [0, 1, 8, 120]) {
      final enabled = GuardianSettings.restore(
        jsonEncode({
          'version': 2,
          'rules': {
            'coughing': {'minimumSeconds': seconds, 'recordAudio': true},
            'crying': {'minimumSeconds': seconds, 'recordAudio': true},
          },
        }),
      );
      for (final name in ['crying', 'coughing']) {
        final rule = enabled.rules[name]!;
        expect(rule.minimumSeconds, seconds);
        expect(rule.recordingMinimumSeconds, seconds);
        expect(rule.recordAudio, isTrue);
      }
      expect(
        enabled.rules['coughing']!.durationNeedsReview,
        seconds == 8,
      );
      final unselected = GuardianSettings.restore(
        jsonEncode({
          'version': 2,
          'rules': {
            'coughing': {'minimumSeconds': seconds, 'recordAudio': false},
          },
        }),
      ).rules['coughing']!;
      expect(unselected.minimumSeconds, seconds);
      expect(unselected.recordingMinimumSeconds, seconds == 0 ? 8 : seconds);
      expect(unselected.recordAudio, isFalse);
    }
    final off = GuardianSettings.restore(
      jsonEncode({
        'version': 2,
        'rules': {
          'coughing': {'minimumSeconds': 0, 'recordAudio': false},
        },
      }),
    );
    expect(off.rules['coughing']!.minimumSeconds, 0);
    expect(off.rules['coughing']!.recordingMinimumSeconds, 8);
    expect(off.rules['coughing']!.recordAudio, isFalse);
  });

  test('recommended cough repair alerts on a short pair and keeps clip duration',
      () {
    final saved = GuardianSettings.restore(
      jsonEncode({
        'version': 2,
        'rules': {
          'coughing': {'minimumSeconds': 8, 'recordAudio': true},
        },
      }),
    ).rules['coughing']!;
    final fixed = saved.copyWith(minimumSeconds: 0);
    final at = DateTime(2026);
    SoundGate gate(SoundRule rule) => SoundGate(
      immediate: {'coughing'},
      burst: {'coughing': 2},
      toleratedGap: const Duration(seconds: 2),
    )..rules = {'coughing': rule};
    final oldGate = gate(saved);
    expect(oldGate.accept('coughing', at), isFalse);
    expect(oldGate.accept('coughing', at.add(const Duration(seconds: 1))),
        isFalse);
    final fixedGate = gate(fixed);
    expect(fixedGate.accept('coughing', at), isFalse);
    expect(fixedGate.accept('coughing', at.add(const Duration(seconds: 1))),
        isTrue);
    expect(fixed.recordingMinimumSeconds, 8);
    expect(fixed.recordAudio, isTrue);
  });

  test('current custom rules round-trip without being treated as old defaults', () {
    for (final seconds in [0, 1, 8, 120]) {
      final settings = GuardianSettings(
        rules: {
          'coughing': SoundRule(
            minimumSeconds: seconds,
            recordingMinimumSeconds: 15,
            recordAudio: true,
          ),
          'crying': const SoundRule(minimumSeconds: 1),
        },
      );
      final restored = GuardianSettings.restore(settings.encode());
      final cough = restored.rules['coughing']!;
      expect(cough.minimumSeconds, seconds);
      expect(cough.recordingMinimumSeconds, 15);
      expect(cough.durationNeedsReview, isFalse);
      expect(cough.recordAudio, isTrue);
      expect(restored.rules['crying']!.minimumSeconds, 1);
      expect(cough.copyWith(minimumSeconds: 0).recordingMinimumSeconds, 15);
      expect(cough.copyWith(recordingMinimumSeconds: 0).minimumSeconds, seconds);
    }
    expect(
      const SoundRule().copyWith(recordingMinimumSeconds: 900)
          .recordingMinimumSeconds,
      300,
    );
    expect(
      const SoundRule().copyWith(recordingMinimumSeconds: -5)
          .recordingMinimumSeconds,
      0,
    );
  });
}
