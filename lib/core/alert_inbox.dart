import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'activity_event.dart';
import 'guardian_settings.dart';

/// Background notifications retain metadata only. Each ID has its own key so
/// a receiver isolate cannot overwrite the foreground activity list.
class AlertInbox {
  static const prefix = 'received_alert_';
  static const savedRoomsKey = 'cloud_saved_rooms_v1';

  /// The selected room is only a view. Other saved rooms may still send alerts.
  /// Once a registry exists, an empty or malformed registry never falls back to
  /// an old selected-room key and accidentally restores a logged-out room.
  static Set<String> pairedRooms(SharedPreferences prefs) {
    if (!prefs.containsKey(savedRoomsKey)) {
      final room = prefs.getString('cloud_paired_room');
      return room == null ? {} : {room};
    }
    try {
      final raw = prefs.get(savedRoomsKey);
      if (raw is! String) return {};
      final rows = jsonDecode(raw);
      if (rows is! List) return {};
      final origin = prefs.getString('cloud_server');
      return {
        for (final row in rows.take(1000))
          if (row is Map &&
              row['roomId'] is String &&
              RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(row['roomId']) &&
              row['origin'] is String &&
              (origin == null || row['origin'] == origin))
            row['roomId'] as String,
      };
    } on FormatException {
      return {};
    }
  }

  static ActivityEvent? parseSaved(
    Map<String, dynamic> data,
    SharedPreferences prefs,
    DateTime now,
  ) {
    final id = data['roomId'];
    if (id is! String || !pairedRooms(prefs).contains(id)) return null;
    final event = parse(data, id, now);
    if (event == null) return null;
    return ActivityEvent(
      kind: event.kind,
      title: event.title,
      room: event.room,
      at: event.at,
      id: event.id,
      roomId: id,
      origin: prefs.getString('cloud_server'),
      category: event.category,
      delivery: event.delivery,
    );
  }

  static ActivityEvent? parse(
    Map<String, dynamic> data,
    String? pairedRoom,
    DateTime now,
  ) {
    if (pairedRoom == null || data['roomId'] != pairedRoom) return null;
    final id = data['id'];
    final title = data['title'];
    final room = data['room'];
    final sentAt = int.tryParse('${data['sentAt']}');
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(id) ||
        title is! String ||
        title.isEmpty ||
        title.length > 80 ||
        room is! String ||
        room.isEmpty ||
        room.length > 32 ||
        sentAt == null) {
      return null;
    }
    final ageMs = now.millisecondsSinceEpoch - sentAt;
    if (ageMs < -30000 || ageMs >= 15 * 60 * 1000) return null;
    final at = DateTime.fromMillisecondsSinceEpoch(sentAt);
    return ActivityEvent(
      kind: ActivityKind.sound,
      title: title,
      room: room,
      at: at,
      id: id,
      roomId: pairedRoom,
      category: guardianCategories.contains(data['kind']) ? data['kind'] : null,
      delivery: AlertDelivery.received,
    );
  }

  static Future<void> save(
    SharedPreferences prefs,
    Map<String, dynamic> data,
  ) async {
    await prefs.reload();
    final event = parseSaved(data, prefs, DateTime.now());
    if (event == null) return;
    final keys = prefs.getKeys().where((k) => k.startsWith(prefix)).toList()
      ..sort();
    for (final key in keys.take((keys.length - 49).clamp(0, keys.length))) {
      await prefs.remove(key);
    }
    await prefs.setString(
      _keyFor(event),
      jsonEncode({'roomId': data['roomId'], 'event': event.toJson()}),
    );
  }

  static Future<List<ActivityEvent>> pending(SharedPreferences prefs) async {
    await prefs.reload();
    final events = <ActivityEvent>[];
    final rooms = pairedRooms(prefs);
    for (final key in prefs.getKeys().where((k) => k.startsWith(prefix))) {
      try {
        final row = jsonDecode(prefs.getString(key) ?? '{}');
        if (row is Map &&
            rooms.contains(row['roomId']) &&
            row['event'] is Map) {
          final event = Map<String, dynamic>.from(row['event']);
          if (event['roomId'] != null && event['roomId'] != row['roomId'])
            continue;
          events.addAll(
            ActivityEvent.restore(
              jsonEncode([
                {
                  ...event,
                  'roomId': row['roomId'],
                  'origin': event['origin'] ?? prefs.getString('cloud_server'),
                },
              ]),
            ),
          );
        }
      } on FormatException {
        /* Ignore an interrupted or old write. */
      }
    }
    return events;
  }

  static String _keyFor(ActivityEvent event) =>
      '$prefix${event.roomId ?? ''}_${event.id}';

  static Future<void> acknowledge(
    SharedPreferences prefs,
    Iterable<ActivityEvent> events,
  ) async {
    for (final event in events) {
      for (final key in {_keyFor(event), '$prefix${event.id}'}) {
        try {
          final raw = prefs.getString(key);
          if (raw == null) continue;
          final row = jsonDecode(raw);
          if (row is Map && row['roomId'] == event.roomId)
            await prefs.remove(key);
        } on FormatException {
          // Another room or interrupted write is not this event to remove.
        }
      }
    }
  }

  static Future<void> clear(SharedPreferences prefs) async {
    for (final key in prefs.getKeys().where((k) => k.startsWith(prefix))) {
      await prefs.remove(key);
    }
  }
}
