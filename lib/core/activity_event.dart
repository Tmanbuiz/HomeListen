import 'dart:convert';

enum ActivityKind { connected, disconnected, sound, battery, session }

enum AlertDelivery {
  local,
  quiet,
  queued,
  submitted,
  noRecipients,
  failed,
  expired,
  received,
}

class ActivityEvent {
  const ActivityEvent({
    required this.kind,
    required this.title,
    required this.room,
    required this.at,
    this.id,
    this.category,
    this.modelScore,
    this.modelVersion,
    this.durationMs,
    this.delivery = AlertDelivery.local,
  });

  final ActivityKind kind;
  final String title;
  final String room;
  final DateTime at;
  final String? id, category, modelVersion;
  final double? modelScore;
  final int? durationMs;
  final AlertDelivery delivery;

  ActivityEvent withDelivery(AlertDelivery value) => ActivityEvent(
    kind: kind,
    title: title,
    room: room,
    at: at,
    id: id,
    category: category,
    modelScore: modelScore,
    modelVersion: modelVersion,
    durationMs: durationMs,
    delivery: value,
  );

  String get deliveryLabel => switch (delivery) {
    AlertDelivery.local => 'Saved on this phone',
    AlertDelivery.quiet => 'Saved · quiet hours',
    AlertDelivery.queued => 'Waiting to send · retrying',
    AlertDelivery.submitted => 'Accepted by push provider',
    AlertDelivery.noRecipients => 'No listening phone registered for alerts',
    AlertDelivery.failed => 'Could not submit alert',
    AlertDelivery.expired => 'Retry window ended',
    AlertDelivery.received => 'Received on this phone',
  };

  Map<String, Object> toJson() => {
    'kind': kind.name,
    'title': title,
    'room': room,
    'at': at.toIso8601String(),
    if (id != null) 'id': id!,
    if (id != null) 'schemaVersion': 2,
    if (category != null) 'category': category!,
    if (modelScore != null) 'modelScore': modelScore!,
    if (modelVersion != null) 'modelVersion': modelVersion!,
    if (durationMs != null) 'durationMs': durationMs!,
    if (id != null) 'delivery': delivery.name,
  };

  static List<ActivityEvent> restore(String? json) {
    if (json == null) return [];
    try {
      final list = jsonDecode(json);
      if (list is! List) return [];
      final events = <ActivityEvent>[];
      for (final row in list.take(500)) {
        if (row is! Map) continue;
        final kind = ActivityKind.values
            .where((k) => k.name == row['kind'])
            .firstOrNull;
        final at = DateTime.tryParse('${row['at']}');
        if (kind != null &&
            at != null &&
            row['title'] is String &&
            row['room'] is String) {
          events.add(
            ActivityEvent(
              kind: kind,
              title: row['title'],
              room: row['room'],
              at: at,
              id: row['id'] is String ? row['id'] : null,
              category: row['category'] is String ? row['category'] : null,
              modelScore:
                  row['modelScore'] is num &&
                      (row['modelScore'] as num).isFinite
                  ? (row['modelScore'] as num).toDouble().clamp(0, 1)
                  : null,
              modelVersion: row['modelVersion'] is String
                  ? row['modelVersion']
                  : null,
              durationMs: row['durationMs'] is int
                  ? (row['durationMs'] as int).clamp(0, 60000)
                  : null,
              delivery:
                  AlertDelivery.values
                      .where((v) => v.name == row['delivery'])
                      .firstOrNull ??
                  AlertDelivery.local,
            ),
          );
        }
      }
      return events;
    } on FormatException {
      return [];
    }
  }
}
