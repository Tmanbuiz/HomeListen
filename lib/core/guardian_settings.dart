import 'dart:convert';

const guardianCategories = ['crying', 'barking', 'knocking', 'loud sound'];

/// A detector score is a model output, not a probability of danger.
class SoundRule {
  const SoundRule({
    this.threshold = 0.4,
    this.minimumSeconds = 0,
    this.cooldownSeconds = 30,
    this.duringQuietHours = false,
  });
  final double threshold;
  final int minimumSeconds;
  final int cooldownSeconds;
  final bool duringQuietHours;

  SoundRule copyWith({
    double? threshold,
    int? minimumSeconds,
    int? cooldownSeconds,
    bool? duringQuietHours,
  }) => SoundRule(
    threshold: (threshold ?? this.threshold).clamp(0.2, 0.9),
    minimumSeconds: (minimumSeconds ?? this.minimumSeconds).clamp(0, 10),
    cooldownSeconds: (cooldownSeconds ?? this.cooldownSeconds).clamp(5, 600),
    duringQuietHours: duringQuietHours ?? this.duringQuietHours,
  );

  Map<String, Object> toJson() => {
    'threshold': threshold,
    'minimumSeconds': minimumSeconds,
    'cooldownSeconds': cooldownSeconds,
    'duringQuietHours': duringQuietHours,
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
               SoundRule(minimumSeconds: name == 'crying' ? 1 : 0),
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
    'version': 1,
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
            minimumSeconds: name == 'crying' ? 1 : 0,
          ),
      },
    );
    try {
      final row = jsonDecode(raw ?? '{}');
      if (row is! Map) return fallback;
      final stored = row['rules'];
      return fallback.copyWith(
        quietEnabled: row['quietEnabled'] is bool ? row['quietEnabled'] : null,
        quietStart: row['quietStart'] is int ? row['quietStart'] : null,
        quietEnd: row['quietEnd'] is int ? row['quietEnd'] : null,
        retentionDays: row['retentionDays'] is int
            ? row['retentionDays']
            : null,
        rules: {
          for (final name in guardianCategories)
            name: stored is Map && stored[name] is Map
                ? SoundRule.fromJson(stored[name], fallback.rules[name]!)
                : fallback.rules[name]!,
        },
      );
    } on FormatException {
      return fallback;
    }
  }
}
