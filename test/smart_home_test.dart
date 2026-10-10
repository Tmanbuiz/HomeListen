import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/activity_event.dart';
import 'package:home_listen/core/smart_home.dart';
import 'package:home_listen/core/smart_home_settings.dart';
import 'package:home_listen/core/smart_home_transport.dart';

const deviceId = '0123456789abcdef01234567';
const settings = SmartHomeSettings(
  enabled: true,
  host: '192.168.1.20',
  port: 1883,
  tls: false,
  username: 'home-phone',
);

class FakeTransport implements SmartHomeTransport {
  @override
  bool connected = false;
  bool fail = false;
  final messages = <({String topic, String payload, bool retain})>[];
  late void Function(String, String, bool) receive;
  @override
  Future<void> connect(
    SmartHomeSettings settings,
    String password,
    SmartHomeTopics topics,
    void Function(String, String, bool) onMessage,
    void Function() onDisconnected,
  ) async {
    receive = onMessage;
    connected = true;
  }

  @override
  Future<void> publish(
    String topic,
    String payload, {
    bool retain = false,
  }) async {
    if (fail) throw StateError('offline');
    messages.add((topic: topic, payload: payload, retain: retain));
  }

  @override
  Future<void> close() async {
    connected = false;
  }
}

void main() {
  group('smart home settings and discovery', () {
    test(
      'defaults are optional and credentials are absent from preferences',
      () {
        expect(const SmartHomeSettings().enabled, isFalse);
        expect(const SmartHomeSettings().tls, isTrue);
        expect(const SmartHomeSettings().allowControls, isFalse);
        expect(settings.toJson().keys, isNot(contains('password')));
        expect(
          SmartHomeSettings.restore(jsonEncode(settings.toJson())).problem,
          isNull,
        );
        expect(SmartHomeSettings.restore('{bad').enabled, isFalse);
        expect(
          SmartHomeSettings.newDeviceId(),
          matches(RegExp(r'^[a-f0-9]{24}$')),
        );
      },
    );
    test('plaintext is restricted to private hosts and valid ports', () {
      expect(settings.problem, isNull);
      expect(
        const SmartHomeSettings(
          host: 'public.example',
          username: 'phone',
          tls: false,
        ).problem,
        isNotNull,
      );
      expect(
        const SmartHomeSettings(
          host: 'public.example',
          username: 'phone',
        ).problem,
        isNull,
      );
      expect(
        const SmartHomeSettings(
          host: 'https://broker.local',
          username: 'phone',
        ).problem,
        isNotNull,
      );
      expect(
        const SmartHomeSettings(
          host: 'broker.local',
          username: 'phone',
          port: 0,
        ).problem,
        isNotNull,
      );
      expect(
        const SmartHomeSettings(
          host: 'broker.local',
          username: 'phone',
          discoveryPrefix: 'ha/#',
        ).problem,
        isNotNull,
      );
      for (final host in [
        '192.168.1.2',
        '10.1.2.3',
        '172.16.2.3',
        '127.0.0.1',
        'fd12::1',
        '::1',
        'homeassistant.local',
      ]) {
        expect(SmartHomeSettings.isPrivateHost(host), isTrue, reason: host);
      }
      for (final host in [
        '8.8.8.8',
        '172.32.0.1',
        '2001:4860::1',
        'public.example',
        'bad/.local',
      ]) {
        expect(SmartHomeSettings.isPrivateHost(host), isFalse, reason: host);
      }
    });
    test('Home Assistant links permit HTTPS and private HTTP without embedded credentials', () {
      expect(
        SmartHomeSettings.assistantUri('http://homeassistant.local:8123'),
        isNotNull,
      );
      expect(SmartHomeSettings.assistantUri('https://ha.example'), isNotNull);
      for (final url in [
        'http://ha.example',
        'https://user:password@ha.example',
        'javascript:alert(1)',
        'https://ha.example?token=secret',
        'https://ha.example#token',
      ]) {
        expect(SmartHomeSettings.assistantUri(url), isNull);
      }
    });
    test('discovery separates monitoring from microphone, detector and connection health', () {
      final topics = SmartHomeTopics(deviceId, 'homeassistant');
      final configs = topics.discoveryMessages('Bedroom', false);
      expect(configs.length, 8);
      for (final key in ['monitoring', 'microphone', 'detector', 'charging']) {
        final data = configs[topics.discovery('binary_sensor', key)]!;
        expect(data['expire_after'], 45);
        expect(
          data['value_template'],
          "{{ 'true' if value_json.$key else 'false' }}",
        );
        expect(data['availability_topic'], topics.availability);
      }
      expect(
        configs[topics.discovery('event', 'sound')]!['state_topic'],
        topics.events,
      );
      expect(
        configs.keys.any(
          (key) => key.contains('/button/') || key.contains('/select/'),
        ),
        isFalse,
      );
      expect(topics.discoveryMessages('Bedroom', true).length, 10);
    });
    test('only explicitly enabled non-retained stop and house-mode commands are accepted', () {
      final topics = SmartHomeTopics(deviceId, 'homeassistant');
      expect(topics.parseCommand(topics.command, 'stop', false, true), 'stop');
      expect(
        topics.parseCommand(topics.profileSet, 'night', false, true),
        'night',
      );
      expect(topics.parseCommand(topics.command, 'stop', true, true), isNull);
      expect(topics.parseCommand(topics.command, 'stop', false, false), isNull);
      for (final command in ['start', 'listen', 'guardian', 'STOP', 'stop\n']) {
        expect(
          topics.parseCommand(topics.command, command, false, true),
          isNull,
        );
      }
      expect(
        topics.parseCommand(topics.profileSet, 'start', false, true),
        isNull,
      );
    });
  });

  group('event delivery and reconnection', () {
    late FakeTransport transport;
    late SmartHomeIntegration hub;
    late DateTime now;
    late List<String> commands;
    bool allowed = true;
    ActivityEvent sound(
      String id, {
      DateTime? at,
      AlertDelivery delivery = AlertDelivery.local,
    }) => ActivityEvent(
      id: id,
      kind: ActivityKind.sound,
      title: 'Possible crying',
      room: 'Bedroom',
      at: at ?? now,
      category: 'crying',
      modelScore: 0.8,
      modelVersion: 'yamnet-audioset-v1',
      delivery: delivery,
    );
    setUp(() {
      now = DateTime.utc(2026, 10, 10, 12);
      commands = [];
      allowed = true;
      transport = FakeTransport();
      hub = SmartHomeIntegration(
        deviceId: deviceId,
        health: () => {'monitoring': false},
        roomName: () => 'Bedroom',
        onChanged: () {},
        onCommand: (command) async {
          commands.add(command);
        },
        clock: () => now,
        transportFactory: () => transport,
        canSend: (_, _) => allowed,
      );
    });
    tearDown(() async {
      await hub.dispose();
    });
    test('discovery and health are retained, sound metadata is fresh and never retained', () async {
      await hub.configure(settings, 'password');
      expect(hub.status, 'Broker connected');
      expect(
        transport.messages
            .where((m) => m.topic.endsWith('/config'))
            .every((m) => m.retain),
        isTrue,
      );
      hub.event(sound('event-1'), 'night');
      await hub.settle();
      final message = transport.messages.singleWhere(
        (m) => m.topic == hub.topics.events,
      );
      expect(message.retain, isFalse);
      final payload = jsonDecode(message.payload) as Map;
      expect(payload['event_id'], 'event-1');
      expect(payload['event_type'], 'crying');
      expect(payload['profile'], 'night');
      expect(payload.keys, isNot(contains('audio')));
      expect(payload.keys, isNot(contains('password')));
      expect(hub.queued, 0);
    });
    test('repeated detections and quiet, old or future events do not become actions', () async {
      await hub.configure(settings, 'password');
      hub.event(sound('duplicate'), 'home');
      hub.event(sound('duplicate'), 'home');
      hub.event(sound('quiet', delivery: AlertDelivery.quiet), 'home');
      hub.event(
        sound('old', at: now.subtract(const Duration(seconds: 60))),
        'home',
      );
      hub.event(
        sound('future', at: now.add(const Duration(seconds: 31))),
        'home',
      );
      await hub.settle();
      hub.event(sound('duplicate'), 'home');
      await hub.settle();
      expect(
        transport.messages.where((m) => m.topic == hub.topics.events).length,
        1,
      );
    });
    test(
      'an offline queue expires and is rechecked against current quiet hours',
      () async {
        await hub.configure(settings, 'password');
        transport.connected = false;
        hub.event(sound('expired'), 'home');
        now = now.add(const Duration(seconds: 61));
        hub.event(sound('quiet-on-retry'), 'night');
        allowed = false;
        transport.connected = true;
        hub.tick(force: true);
        await hub.settle();
        expect(hub.queued, 0);
        expect(
          transport.messages.where((m) => m.topic == hub.topics.events),
          isEmpty,
        );
      },
    );
    test(
      'queue is bounded and Stop can discard unsent household actions',
      () async {
        await hub.configure(settings, 'password');
        transport.connected = false;
        for (var i = 0; i < 70; i++) {
          hub.event(sound('event-$i'), 'home');
        }
        expect(hub.queued, 50);
        hub.clearPending();
        transport.connected = true;
        hub.tick(force: true);
        await hub.settle();
        expect(hub.queued, 0);
        expect(
          transport.messages.where((m) => m.topic == hub.topics.events),
          isEmpty,
        );
      },
    );
    test('Home Assistant birth re-announces entities without replaying sound events', () async {
      await hub.configure(settings, 'password');
      hub.event(sound('one'), 'home');
      await hub.settle();
      final count = transport.messages
          .where((m) => m.topic.endsWith('/config'))
          .length;
      transport.receive('homeassistant/status', 'online', true);
      await hub.settle();
      expect(
        transport.messages.where((m) => m.topic.endsWith('/config')).length,
        count * 2,
      );
      expect(
        transport.messages.where((m) => m.topic == hub.topics.events).length,
        1,
      );
    });
    test('remote control is opt in, cannot start capture, and ignores retained commands', () async {
      await hub.configure(settings, 'password');
      transport.receive(hub.topics.command, 'stop', false);
      expect(commands, isEmpty);
      await hub.configure(
        const SmartHomeSettings(
          enabled: true,
          host: '192.168.1.20',
          port: 1883,
          tls: false,
          username: 'phone',
          allowControls: true,
        ),
        'password',
      );
      transport.receive(hub.topics.command, 'stop', true);
      transport.receive(hub.topics.command, 'start', false);
      transport.receive(hub.topics.profileSet, 'night', false);
      transport.receive(hub.topics.command, 'stop', false);
      expect(commands, ['night', 'stop']);
    });
    test(
      'broker errors are reported without throwing through monitoring',
      () async {
        transport.fail = true;
        await hub.configure(settings, 'password');
        expect(hub.connected, isFalse);
        expect(hub.problem, isNotNull);
        expect(hub.status, contains('retrying'));
      },
    );
  });
}
