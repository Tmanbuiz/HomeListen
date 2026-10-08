import 'dart:convert';

enum ActivityKind { connected, disconnected, sound, battery, session }

class ActivityEvent {
  const ActivityEvent({
    required this.kind,
    required this.title,
    required this.room,
    required this.at,
  });

  final ActivityKind kind;
  final String title;
  final String room;
  final DateTime at;

  Map<String, Object> toJson() => {
    'kind': kind.name,
    'title': title,
    'room': room,
    'at': at.toIso8601String(),
  };

  static List<ActivityEvent> restore(String? json) {
    if (json == null) return [];
    try {
      final list = jsonDecode(json);
      if (list is! List) return [];
      final events = <ActivityEvent>[];
      for (final row in list.take(100)) {
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
