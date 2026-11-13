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
  _ => 0,
};

int defaultRecordingDuration(String category) => switch (category) {
  'crying' => 30,
  'coughing' => 8,
  _ => 0,
};

/// A detector score is a model output, not a probability of danger.
class SoundRule {
  const SoundRule({
    this.threshold = 0.4,
    this.minimumSeconds = 0,
    int? recordingMinimumSeconds,
    this.cooldownSeconds = 30,
    this.duringQuietHours = false,
    this.recordAudio = false,
    this.durationNeedsReview = false,
  }) : recordingMinimumSeconds = recordingMinimumSeconds ?? minimumSeconds;
  final double threshold;

  /// Home-phone push-alert duration, independent of receiver recording rules.
  final int minimumSeconds;
  final int recordingMinimumSeconds;
  final int cooldownSeconds;
  final bool duringQuietHours;

  /// Older settings cannot distinguish the former cough default from a custom
  /// eight-second rule. Ask the owner to choose instead of changing it silently.
  final bool durationNeedsReview;

  /// Save qualifying episodes only on an actively listening receiving phone.
  final bool recordAudio;

  SoundRule copyWith({
    double? threshold,
    int? minimumSeconds,
    int? recordingMinimumSeconds,
    int? cooldownSeconds,
    bool? duringQuietHours,
    bool? recordAudio,
    bool? durationNeedsReview,
  }) => SoundRule(
    threshold: (threshold ?? this.threshold).clamp(0.2, 0.9),
    minimumSeconds: (minimumSeconds ?? this.minimumSeconds).clamp(0, 300),
    recordingMinimumSeconds:
        (recordingMinimumSeconds ?? this.recordingMinimumSeconds).clamp(0, 300),
    cooldownSeconds: (cooldownSeconds ?? this.cooldownSeconds).clamp(5, 600),
    duringQuietHours: duringQuietHours ?? this.duringQuietHours,
    recordAudio: recordAudio ?? this.recordAudio,
    durationNeedsReview:
        durationNeedsReview ??
        (minimumSeconds == null ? this.durationNeedsReview : false),
  );

  Map<String, Object> toJson() => {
    'threshold': threshold,
    'minimumSeconds': minimumSeconds,
    'recordingMinimumSeconds': recordingMinimumSeconds,
    'cooldownSeconds': cooldownSeconds,
    'duringQuietHours': duringQuietHours,
    'recordAudio': recordAudio,
    'durationNeedsReview': durationNeedsReview,
  };

  static SoundRule fromJson(Map row, SoundRule fallback) => fallback.copyWith(
    threshold: row['threshold'] is num
        ? (row['threshold'] as num).toDouble()
        : null,
    minimumSeconds: row['minimumSeconds'] is int ? row['minimumSeconds'] : null,
    recordingMinimumSeconds: row['recordingMinimumSeconds'] is int
        ? row['recordingMinimumSeconds']
        : null,
    cooldownSeconds: row['cooldownSeconds'] is int
        ? row['cooldownSeconds']
        : null,
    duringQuietHours: row['duringQuietHours'] is bool
        ? row['duringQuietHours']
        : null,
    recordAudio: row['recordAudio'] is bool ? row['recordAudio'] : null,
    durationNeedsReview: row['durationNeedsReview'] == true,
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
               SoundRule(
                 minimumSeconds: defaultSoundDuration(name),
                 recordingMinimumSeconds: defaultRecordingDuration(name),
               ),
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
    'version': 3,
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
            recordingMinimumSeconds: defaultRecordingDuration(name),
          ),
      },
    );
    try {
      final row = jsonDecode(raw ?? '{}');
      if (row is! Map) return fallback;
      final stored = row['rules'];
      // Version 1 used a one-second crying default. Upgrade that default while
      // retaining custom timings, including an explicit immediate alert.
      final version = row['version'] is int ? row['version'] as int : 1;
      SoundRule restoreRule(String name) {
        if (stored is! Map || stored[name] is! Map) {
          return fallback.rules[name]!;
        }
        var rule = SoundRule.fromJson(stored[name], fallback.rules[name]!);
        if (version < 2 && name == 'crying' && rule.minimumSeconds == 1) {
          rule = rule.copyWith(minimumSeconds: 30);
        }
        if (version < 3) {
          rule = rule.copyWith(
            // Keep opted-in recordings and custom durations, even if recording
            // is currently unchecked. Unselected defaults match the web viewer.
            recordingMinimumSeconds:
                rule.recordAudio ||
                    rule.minimumSeconds != defaultSoundDuration(name)
                ? rule.minimumSeconds
                : defaultRecordingDuration(name),
            durationNeedsReview: name == 'coughing' && rule.minimumSeconds == 8,
          );
        }
        return rule;
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
