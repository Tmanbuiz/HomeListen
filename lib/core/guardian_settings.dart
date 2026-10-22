import 'dart:convert';

const guardianCategories = [
  'crying',
  'coughing',
  'barking',
  'knocking',
  'loud sound',
];

int defaultSoundDuration(String category) => switch (category) {
  'crying' => 30,
  'coughing' => 8,
  _ => 0,
};

/// A detector score is a model output, not a probability of danger.
class SoundRule {
  const SoundRule({
    this.threshold = 0.4,
    this.minimumSeconds = 0,
    this.cooldownSeconds = 30,
    this.duringQuietHours = false,
    this.recordAudio = false,
  });
  final double threshold;
  final int minimumSeconds;
  final int cooldownSeconds;
  final bool duringQuietHours;

  /// Save qualifying episodes only on an actively listening receiving phone.
  final bool recordAudio;

  SoundRule copyWith({
    double? threshold,
    int? minimumSeconds,
    int? cooldownSeconds,
    bool? duringQuietHours,
    bool? recordAudio,
  }) => SoundRule(
    threshold: (threshold ?? this.threshold).clamp(0.2, 0.9),
    minimumSeconds: (minimumSeconds ?? this.minimumSeconds).clamp(0, 300),
    cooldownSeconds: (cooldownSeconds ?? this.cooldownSeconds).clamp(5, 600),
    duringQuietHours: duringQuietHours ?? this.duringQuietHours,
    recordAudio: recordAudio ?? this.recordAudio,
  );

  Map<String, Object> toJson() => {
    'threshold': threshold,
    'minimumSeconds': minimumSeconds,
    'cooldownSeconds': cooldownSeconds,
    'duringQuietHours': duringQuietHours,
    'recordAudio': recordAudio,
  };

  static SoundRule fromJson(Map row, SoundRule fallback) => fallback.copyWith(
    threshold: row['threshold'] is num
        ? (row['threshold'] as num).toDouble()
        : null,
    minimumSeconds: row['minimumSeconds'] is int ? row['minimumSeconds'] : null,
    cooldownSeconds: row['cooldownSeconds'] is int
        ? row['cooldownSeconds']
        : null,
    duringQuietHours: row['duringQuietHours'] is bool
        ? row['duringQuietHours']
        : null,
    recordAudio: row['recordAudio'] is bool ? row['recordAudio'] : null,
  );
}

class GuardianSettings {
  GuardianSettings({
    this.quietEnabled = false,
    this.quietStart = 22 * 60,
    this.quietEnd = 7 * 60,
    this.retentionDays = 7,
    Map<String, SoundRule>? rules,
  }) : rules = {
         for (final name in guardianCategories)
           name:
               rules?[name] ??
               SoundRule(minimumSeconds: defaultSoundDuration(name)),
       };

  final bool quietEnabled;
  final int quietStart, quietEnd, retentionDays;
  final Map<String, SoundRule> rules;

  /// Uses this phone's local clock, including its current time-zone offset.
  /// Matching start/end times mean no quiet interval.
  bool quietAt(DateTime at) {
    if (!quietEnabled || quietStart == quietEnd) return false;
    final local = at.toLocal();
    final minute = local.hour * 60 + local.minute;
    return quietStart < quietEnd
        ? minute >= quietStart && minute < quietEnd
        : minute >= quietStart || minute < quietEnd;
  }

  bool suppresses(String category, DateTime at) =>
      quietAt(at) && !(rules[category]?.duringQuietHours ?? false);

  GuardianSettings copyWith({
    bool? quietEnabled,
    int? quietStart,
    int? quietEnd,
    int? retentionDays,
    Map<String, SoundRule>? rules,
  }) => GuardianSettings(
    quietEnabled: quietEnabled ?? this.quietEnabled,
    quietStart: (quietStart ?? this.quietStart).clamp(0, 1439),
    quietEnd: (quietEnd ?? this.quietEnd).clamp(0, 1439),
    retentionDays: [1, 7, 30].contains(retentionDays)
        ? retentionDays!
        : this.retentionDays,
    rules: rules ?? this.rules,
  );

  String encode() => jsonEncode({
    'version': 2,
    'quietEnabled': quietEnabled,
    'quietStart': quietStart,
    'quietEnd': quietEnd,
    'retentionDays': retentionDays,
    'rules': {for (final e in rules.entries) e.key: e.value.toJson()},
  });

  static GuardianSettings restore(String? raw, {double threshold = 0.4}) {
    final fallback = GuardianSettings(
      rules: {
        for (final name in guardianCategories)
          name: SoundRule(
            threshold: threshold.clamp(0.2, 0.9),
            minimumSeconds: defaultSoundDuration(name),
          ),
      },
    );
    try {
      final row = jsonDecode(raw ?? '{}');
      if (row is! Map) return fallback;
      final stored = row['rules'];
      // Version 1 used a one-second crying default. Upgrade that default while
      // retaining custom timings, including an explicit immediate alert.
      final legacy = row['version'] != 2;
      SoundRule restoreRule(String name) {
        if (stored is! Map || stored[name] is! Map) {
          return fallback.rules[name]!;
        }
        final rule = SoundRule.fromJson(stored[name], fallback.rules[name]!);
        return legacy && name == 'crying' && rule.minimumSeconds == 1
            ? rule.copyWith(minimumSeconds: 30)
            : rule;
      }

      return fallback.copyWith(
        quietEnabled: row['quietEnabled'] is bool ? row['quietEnabled'] : null,
        quietStart: row['quietStart'] is int ? row['quietStart'] : null,
        quietEnd: row['quietEnd'] is int ? row['quietEnd'] : null,
        retentionDays: row['retentionDays'] is int
            ? row['retentionDays']
            : null,
        rules: {for (final name in guardianCategories) name: restoreRule(name)},
      );
    } on FormatException {
      return fallback;
    }
  }
}
