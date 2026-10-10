import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:home_listen/core/activity_event.dart';
import 'package:home_listen/core/alert_outbox.dart';
import 'package:home_listen/core/alert_inbox.dart';
import 'package:home_listen/core/guardian_settings.dart';
import 'package:home_listen/core/home_monitor.dart';
import 'package:home_listen/core/sound_watch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'clearing history also removes queued sends and background receipts',
    () async {
      final at = DateTime.now();
      const id = 'event_1234567890123456';
      final event = ActivityEvent(
        kind: ActivityKind.sound,
        title: 'Possible crying',
        room: 'Home',
        at: at,
        id: id,
        delivery: AlertDelivery.queued,
      );
      SharedPreferences.setMockInitialValues({
        'activity': jsonEncode([event.toJson()]),
        'alert_outbox': jsonEncode([
          PendingAlert(id: id, title: event.title, at: at).toJson(),
        ]),
        '${AlertInbox.prefix}$id': jsonEncode({
          'roomId': 'room',
          'event': event.toJson(),
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      final monitor = HomeMonitor(prefs: prefs);
      expect(monitor.queuedAlertCount, 1);
      await monitor.clearActivity();
      expect(monitor.events, isEmpty);
      expect(monitor.queuedAlertCount, 0);
      expect(
        PendingAlert.restore(prefs.getString('alert_outbox'), at),
        isEmpty,
      );
      expect(
        prefs.getKeys().where((k) => k.startsWith(AlertInbox.prefix)),
        isEmpty,
      );
      monitor.dispose();
    },
  );
  test('background alerts validate pairing, freshness and stable IDs', () async {
    final now = DateTime.now();
    final data = <String, dynamic>{
      'id': 'event_1234567890123456',
      'title': 'Possible crying',
      'kind': 'crying',
      'room': 'Bedroom',
      'roomId': 'paired-room',
      'sentAt': '${now.millisecondsSinceEpoch}',
    };
    expect(AlertInbox.parse(data, 'different-room', now), isNull);
    expect(
      AlertInbox.parse(
        {
          ...data,
          'sentAt':
              '${now.subtract(const Duration(minutes: 15)).millisecondsSinceEpoch}',
        },
        'paired-room',
        now,
      ),
      isNull,
    );
    expect(
      AlertInbox.parse(
        {...data, 'sentAt': '9223372036854775807'},
        'paired-room',
        now,
      ),
      isNull,
    );
    SharedPreferences.setMockInitialValues({
      'cloud_paired_room': 'paired-room',
    });
    final prefs = await SharedPreferences.getInstance();
    await AlertInbox.save(prefs, data);
    await AlertInbox.save(prefs, data);
    final pending = await AlertInbox.pending(prefs);
    expect(pending, hasLength(1));
    expect(pending.single.delivery, AlertDelivery.received);
    expect(
      pending.single.at.millisecondsSinceEpoch,
      now.millisecondsSinceEpoch,
    );
    expect(pending.single.modelVersion, isNull);
    await AlertInbox.clear(prefs);
    expect(await AlertInbox.pending(prefs), isEmpty);
  });
  test('quiet hours cross midnight and allow a selected category through', () {
    final settings = GuardianSettings(
      quietEnabled: true,
      rules: {'crying': const SoundRule(duringQuietHours: true)},
    );
    expect(settings.quietAt(DateTime(2026, 10, 10, 23)), isTrue);
    expect(settings.quietAt(DateTime(2026, 10, 11, 6, 59)), isTrue);
    expect(settings.quietAt(DateTime(2026, 10, 11, 7)), isFalse);
    expect(settings.suppresses('crying', DateTime(2026, 10, 10, 23)), isFalse);
    expect(settings.suppresses('barking', DateTime(2026, 10, 10, 23)), isTrue);
    expect(
      settings
          .copyWith(quietStart: 300, quietEnd: 300)
          .quietAt(DateTime(2026, 10, 10, 5)),
      isFalse,
    );
  });
  test('saved settings tolerate corruption and bound timings and scores', () {
    expect(GuardianSettings.restore('broken').quietEnabled, isFalse);
    final settings = GuardianSettings.restore(
      jsonEncode({
        'quietStart': 10000,
        'rules': {
          'crying': {
            'threshold': 1.4,
            'minimumSeconds': -1,
            'cooldownSeconds': 2000,
          },
        },
      }),
    );
    expect(settings.quietStart, 1439);
    expect(settings.rules['crying']!.threshold, .9);
    expect(settings.rules['crying']!.minimumSeconds, 0);
    expect(settings.rules['crying']!.cooldownSeconds, 600);
  });
  test('duration rules require elapsed time; overlapping hits alone do not suffice', () {
    final gate = SoundGate(immediate: {'barking'})
      ..rules = {
        'barking': const SoundRule(minimumSeconds: 2, cooldownSeconds: 60),
      };
    final at = DateTime(2026);
    expect(gate.accept('barking', at), isFalse);
    expect(gate.accept('barking', at.add(const Duration(seconds: 1))), isFalse);
    expect(gate.accept('barking', at.add(const Duration(seconds: 2))), isTrue);
    expect(
      gate.accept('barking', at.add(const Duration(seconds: 10))),
      isFalse,
    );
    expect(gate.accept('barking', at.add(const Duration(seconds: 63))), isTrue);
  });
  test('per-category thresholds prevent a lower threshold from winning accidentally', () {
    final result = SoundWatch.decide(
      scores: [.75, .7],
      labels: ['Bark', 'Knock'],
      categories: {'barking', 'knocking'},
      sensitivity: .4,
      peak: .01,
      noiseFloor: .01,
      thresholds: {'barking': .8, 'knocking': .5},
    );
    expect(result.category, 'knocking');
    expect(result.categoryScore, .7);
    expect(result.heard, 'Bark');
  });
  test('a restarted outbox preserves event identity and drops stale or corrupt entries', () {
    final at = DateTime(2026, 10, 10, 12);
    final alert = PendingAlert(
      id: 'event_1234567890123456',
      title: 'Possible crying',
      at: at,
    );
    final retried = alert.retry(at);
    final restored = PendingAlert.restore(
      jsonEncode([
        retried.toJson(),
        {'id': 'bad'},
        retried.toJson(),
      ]),
      at,
    );
    expect(restored, hasLength(1));
    expect(restored.single.id, alert.id);
    expect(restored.single.due(at), isFalse);
    expect(restored.single.due(at.add(const Duration(seconds: 6))), isTrue);
    expect(
      PendingAlert.restore(
        jsonEncode([alert.toJson()]),
        at.add(const Duration(minutes: 15)),
      ),
      isEmpty,
    );
  });
  test(
    'old activity rows migrate and new delivery records contain only metadata',
    () {
      final event = ActivityEvent(
        kind: ActivityKind.sound,
        title: 'Possible crying',
        room: 'Home',
        at: DateTime(2026),
        id: 'event_1234567890123456',
        modelScore: .62,
        category: 'crying',
        modelVersion: 'yamnet-audioset-v1',
        delivery: AlertDelivery.queued,
      );
      final restored = ActivityEvent.restore(
        jsonEncode([event.withDelivery(AlertDelivery.submitted).toJson()]),
      );
      expect(restored.single.delivery, AlertDelivery.submitted);
      expect(restored.single.modelScore, .62);
      expect(restored.single.toJson().containsKey('audio'), isFalse);
      expect(
        ActivityEvent.restore(
          '[{"kind":"sound","title":"Old alert","room":"Home","at":"2026-10-10T12:00:00Z"}]',
        ).single.delivery,
        AlertDelivery.local,
      );
    },
  );
  test(
    'Guardian preference survives a relaunch without starting capture',
    () async {
      SharedPreferences.setMockInitialValues({'device_role': 'home'});
      final prefs = await SharedPreferences.getInstance();
      final monitor = HomeMonitor(prefs: prefs);
      expect(monitor.guardianOnly, isTrue);
      expect(monitor.isMonitoring, isFalse);
      await monitor.setGuardianOnly(false);
      final restored = HomeMonitor(prefs: prefs);
      expect(restored.guardianOnly, isFalse);
      expect(restored.isMonitoring, isFalse);
      await restored.setQuietHours(enabled: true, start: 1200, end: 420);
      expect(
        GuardianSettings.restore(prefs.getString('guardian_settings'))
            .quietStart,
        1200,
      );
      monitor.dispose();
      restored.dispose();
    },
  );
}
