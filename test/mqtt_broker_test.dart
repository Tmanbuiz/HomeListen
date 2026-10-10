import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/activity_event.dart';
import 'package:home_listen/core/smart_home.dart';
import 'package:home_listen/core/smart_home_settings.dart';
import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:mqtt5_client/mqtt5_server_client.dart';

Future<void> until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Expected MQTT delivery did not arrive.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('MQTT 5 works with authenticated Mosquitto, discovery, events and safe commands', () async {
    const id = 'fedcba9876543210fedcba98';
    final topics = SmartHomeTopics(id, 'homeassistant');
    final observer =
        MqttServerClient(
            '127.0.0.1',
            'homelisten-test-observer',
            maxConnectionAttempts: 1,
          )
          ..port = 1884
          ..keepAlivePeriod = 20;
    observer.logging(on: false);
    observer.connectionMessage = MqttConnectMessage()
        .withClientIdentifier('homelisten-test-observer')
        .startClean();
    await observer.connect('homelisten-ci', 'homelisten-ci-only');
    final received = <({String topic, String payload, bool retain})>[];
    final incoming = observer.updates!.listen((messages) {
      for (final update in messages) {
        if (update.topic == null) continue;
        final message = update.payload as MqttPublishMessage;
        received.add((
          topic: update.topic!,
          payload: utf8.decode(message.payload.message!),
          retain: message.header!.retain,
        ));
      }
    });
    final subscribed = <String>{};
    observer.onSubscribed = (subscription) {
      subscribed.add(subscription.topic.rawTopic!);
    };
    observer.subscribe('homeassistant/#', MqttQos.atLeastOnce);
    observer.subscribe('${topics.base}/#', MqttQos.atLeastOnce);
    await until(() => subscribed.length == 2);
    final commands = <String>[];
    final hub = SmartHomeIntegration(
      deviceId: id,
      health: () => {
        'monitoring': false,
        'microphone': false,
        'detector': false,
      },
      roomName: () => 'Test room',
      onChanged: () {},
      onCommand: (command) async {
        commands.add(command);
      },
    );
    try {
      await hub.configure(
        const SmartHomeSettings(
          enabled: true,
          host: '127.0.0.1',
          port: 1884,
          tls: false,
          username: 'homelisten-ci',
          allowControls: true,
        ),
        'homelisten-ci-only',
      );
      expect(hub.problem, isNull);
      await until(
        () => received.any(
          (m) => m.topic == topics.availability && m.payload == 'online',
        ),
      );
      expect(received.where((m) => m.topic.endsWith('/config')).length, 10);
      hub.event(
        ActivityEvent(
          kind: ActivityKind.sound,
          title: 'Test alert',
          room: 'Test room',
          at: DateTime.now(),
          category: 'test',
          id: '00112233445566778899aabb',
        ),
        'night',
      );
      await hub.settle();
      await until(() => received.any((m) => m.topic == topics.events));
      final event = received.singleWhere((m) => m.topic == topics.events);
      expect(event.retain, isFalse);
      expect(jsonDecode(event.payload)['event_id'], '00112233445566778899aabb');
      void send(String topic, String text, {bool retain = false}) {
        final data = MqttPayloadBuilder()..addUTF8String(text);
        observer.publishMessage(
          topic,
          MqttQos.atLeastOnce,
          data.payload!,
          retain: retain,
        );
      }

      // A live retained command must preserve its flag, not just retained replay.
      send(topics.profileSet, 'night', retain: true);
      send(topics.command, 'start');
      send(topics.command, 'stop');
      await until(() => commands.isNotEmpty);
      expect(commands, ['stop']);
      final configCount = received
          .where((m) => m.topic.endsWith('/config'))
          .length;
      send('homeassistant/status', 'online', retain: true);
      await until(
        () =>
            received.where((m) => m.topic.endsWith('/config')).length ==
            configCount + 10,
      );
      await hub.settle();
      expect(received.where((m) => m.topic == topics.events).length, 1);
      // Retained discovery is available to a new subscription; events are absent.
      received.clear();
      observer.unsubscribeStringTopic('homeassistant/#');
      observer.unsubscribeStringTopic('${topics.base}/#');
      subscribed.clear();
      observer.subscribe('homeassistant/#', MqttQos.atLeastOnce);
      observer.subscribe('${topics.base}/#', MqttQos.atLeastOnce);
      await until(
        () =>
            subscribed.length == 2 &&
            received.where((m) => m.topic.endsWith('/config')).length == 10,
      );
      expect(received.where((m) => m.topic == topics.events), isEmpty);
      expect(
        received
            .where((m) => m.topic.endsWith('/config'))
            .every((m) => m.retain),
        isTrue,
      );
      await hub.dispose();
      await until(
        () => received.any(
          (m) => m.topic == topics.availability && m.payload == 'offline',
        ),
      );
    } finally {
      await hub.dispose();
      await incoming.cancel();
      observer.disconnect();
    }
  }, skip: Platform.environment['HOME_LISTEN_TEST_MQTT'] != 'true');
}
