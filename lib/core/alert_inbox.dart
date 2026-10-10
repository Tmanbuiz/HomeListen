import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'activity_event.dart';
import 'guardian_settings.dart';

/// Background notifications retain metadata only. Each ID has its own key so
/// a receiver isolate cannot overwrite the foreground activity list.
class AlertInbox {
  static const prefix = 'received_alert_';

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
        sentAt == null)
      return null;
    final ageMs = now.millisecondsSinceEpoch - sentAt;
    if (ageMs < -30000 || ageMs >= 15 * 60 * 1000) return null;
    final at = DateTime.fromMillisecondsSinceEpoch(sentAt);
    return ActivityEvent(
      kind: ActivityKind.sound,
      title: title,
      room: room,
      at: at,
      id: id,
      category: guardianCategories.contains(data['kind']) ? data['kind'] : null,
      delivery: AlertDelivery.received,
    );
  }

  static Future<void> save(
    SharedPreferences prefs,
    Map<String, dynamic> data,
  ) async {
    await prefs.reload();
    final event = parse(
      data,
      prefs.getString('cloud_paired_room'),
      DateTime.now(),
    );
    if (event == null) return;
    final keys = prefs.getKeys().where((k) => k.startsWith(prefix)).toList()
      ..sort();
    for (final key in keys.take((keys.length - 49).clamp(0, keys.length))) {
      await prefs.remove(key);
    }
    await prefs.setString(
      '$prefix${event.id}',
      jsonEncode({'roomId': data['roomId'], 'event': event.toJson()}),
    );
  }

  static Future<List<ActivityEvent>> pending(SharedPreferences prefs) async {
    await prefs.reload();
    final events = <ActivityEvent>[];
    for (final key in prefs.getKeys().where((k) => k.startsWith(prefix))) {
      try {
        final row = jsonDecode(prefs.getString(key) ?? '{}');
        if (row is Map &&
            row['roomId'] == prefs.getString('cloud_paired_room')) {
          events.addAll(ActivityEvent.restore(jsonEncode([row['event']])));
        }
      } on FormatException {
        /* Ignore an interrupted or old write. */
      }
    }
    return events;
  }

  static Future<void> clear(SharedPreferences prefs) async {
    for (final key in prefs.getKeys().where((k) => k.startsWith(prefix))) {
      await prefs.remove(key);
    }
  }
}
