import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/activity_event.dart';
import 'package:home_listen/core/alert_inbox.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const origin = 'https://home.example';
  Map<String, Object> notification(String room, {String? id}) => {
    'id': id ?? 'event_1234567890123456',
    'title': 'Possible crying',
    'room': room == 'home_one' ? 'Bedroom' : 'Children room',
    'roomId': room,
    'kind': 'crying',
    'sentAt': '${DateTime.now().millisecondsSinceEpoch}',
  };
  Future<SharedPreferences> preferences({bool registry = true}) async {
    SharedPreferences.setMockInitialValues({
      'cloud_server': origin,
      'cloud_paired_room': 'home_one',
      if (registry)
        AlertInbox.savedRoomsKey: jsonEncode([
          {'roomId': 'home_one', 'origin': origin, 'name': 'Bedroom'},
          {'roomId': 'home_two', 'origin': origin, 'name': 'Children room'},
        ]),
    });
    return SharedPreferences.getInstance();
  }

  test(
    'a saved unselected room can deliver an attributed background alert',
    () async {
      final prefs = await preferences();
      await AlertInbox.save(prefs, notification('home_two'));
      final events = await AlertInbox.pending(prefs);
      expect(events, hasLength(1));
      expect(events.single.roomId, 'home_two');
      expect(events.single.room, 'Children room');
      expect(events.single.origin, origin);
    },
  );

  test('the same event ID in different rooms is not overwritten or acknowledged together', () async {
    final prefs = await preferences();
    await AlertInbox.save(prefs, notification('home_one'));
    await AlertInbox.save(prefs, notification('home_two'));
    final events = await AlertInbox.pending(prefs);
    expect(events, hasLength(2));
    expect(events.map((e) => e.identity).toSet(), hasLength(2));
    await AlertInbox.acknowledge(
      prefs,
      events.where((e) => e.roomId == 'home_one'),
    );
    expect((await AlertInbox.pending(prefs)).single.roomId, 'home_two');
  });

  test(
    'logging out of one room rejects its alerts and retains the other room',
    () async {
      final prefs = await preferences();
      await prefs.setString(
        AlertInbox.savedRoomsKey,
        jsonEncode([
          {'roomId': 'home_two', 'origin': origin, 'name': 'Children room'},
        ]),
      );
      await AlertInbox.save(prefs, notification('home_one'));
      await AlertInbox.save(prefs, notification('home_two'));
      expect((await AlertInbox.pending(prefs)).single.roomId, 'home_two');
      expect(AlertInbox.pairedRooms(prefs), {'home_two'});
    },
  );

  test(
    'an empty or corrupt registry cannot revive a legacy selected room',
    () async {
      final prefs = await preferences();
      for (final raw in ['[]', '{}', 'invalid']) {
        await prefs.setString(AlertInbox.savedRoomsKey, raw);
        expect(
          AlertInbox.parseSaved(
            notification('home_one'),
            prefs,
            DateTime.now(),
          ),
          isNull,
        );
      }
      await prefs.setBool(AlertInbox.savedRoomsKey, true);
      expect(AlertInbox.pairedRooms(prefs), isEmpty);
    },
  );

  test(
    'a room saved under a different cloud origin is not authorized here',
    () async {
      final prefs = await preferences();
      await prefs.setString(
        AlertInbox.savedRoomsKey,
        jsonEncode([
          {
            'roomId': 'home_one',
            'origin': 'https://other.example',
            'name': 'Other home',
          },
        ]),
      );
      expect(
        AlertInbox.parseSaved(notification('home_one'), prefs, DateTime.now()),
        isNull,
      );
    },
  );

  test(
    'legacy inbox entries migrate room attribution and are removed precisely',
    () async {
      final prefs = await preferences(registry: false);
      const id = 'event_1234567890123456';
      final event = ActivityEvent(
        kind: ActivityKind.sound,
        title: 'Possible crying',
        room: 'Bedroom',
        at: DateTime.now(),
        id: id,
      );
      await prefs.setString(
        '${AlertInbox.prefix}$id',
        jsonEncode({'roomId': 'home_one', 'event': event.toJson()}),
      );
      final events = await AlertInbox.pending(prefs);
      expect(events.single.roomId, 'home_one');
      await AlertInbox.acknowledge(prefs, events);
      expect(prefs.containsKey('${AlertInbox.prefix}$id'), isFalse);
      expect(
        AlertInbox.parseSaved(notification('home_two'), prefs, DateTime.now()),
        isNull,
      );
    },
  );

  test(
    'event room identity survives persistence and delivery updates',
    () async {
      final prefs = await preferences();
      final event = AlertInbox.parseSaved(
        notification('home_two'),
        prefs,
        DateTime.now(),
      )!;
      final updated = event.withDelivery(AlertDelivery.submitted);
      final restored = ActivityEvent.restore(jsonEncode([updated.toJson()]))
          .single;
      expect(restored.identity, event.identity);
      expect(restored.room, 'Children room');
      expect(restored.delivery, AlertDelivery.submitted);
    },
  );
}
