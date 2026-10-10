import 'dart:async';
import 'dart:convert';

import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:mqtt5_client/mqtt5_server_client.dart';

import 'smart_home_settings.dart';

abstract class SmartHomeTransport {
  bool get connected;
  Future<void> connect(
    SmartHomeSettings settings,
    String password,
    SmartHomeTopics topics,
    void Function(String topic, String payload, bool retained) onMessage,
    void Function() onDisconnected,
  );
  Future<void> publish(String topic, String payload, {bool retain = false});
  Future<void> close();
}

class MqttSmartHomeTransport implements SmartHomeTransport {
  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _incoming;
  StreamSubscription<MqttPublishMessage>? _published;
  StreamSubscription<MqttPublishAckMessage>? _rejected;
  final Map<int, Completer<void>> _acks = {};
  bool _closing = false;

  @override
  bool get connected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;

  @override
  Future<void> connect(
    SmartHomeSettings settings,
    String password,
    SmartHomeTopics topics,
    void Function(String, String, bool) onMessage,
    void Function() onDisconnected,
  ) async {
    _closing = false;
    final client =
        MqttServerClient(
            settings.host,
            'hl_${topics.id}',
            maxConnectionAttempts: 1,
          )
          ..port = settings.port
          ..secure = settings.tls
          ..keepAlivePeriod = 20
          ..socketTimeout = 5000
          ..autoReconnect = false;
    _client = client;
    client.logging(on: false);
    // The platform trust store verifies TLS certificates. No bad-certificate override.
    final will = MqttPayloadBuilder()..addUTF8String('offline');
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier('hl_${topics.id}')
        .startClean()
        .keepAliveFor(20)
        .withWillTopic(topics.availability)
        .withWillPayload(will.payload!)
        .withWillQos(MqttQos.atLeastOnce)
        .withWillRetain()
        .will();
    client.onDisconnected = () {
      for (final ack in _acks.values) {
        if (!ack.isCompleted) {
          ack.completeError(StateError('Broker disconnected.'));
        }
      }
      _acks.clear();
      if (!_closing) onDisconnected();
    };
    try {
      final connecting = client.connect(settings.username, password);
      unawaited(
        connecting.then((_) {
          // A timed-out connection must not leave a socket alive after close.
          if (_closing || !identical(_client, client)) client.disconnect();
        }, onError: (Object _) {}),
      );
      await connecting.timeout(const Duration(seconds: 10));
      if (!connected) throw StateError('Broker refused the connection.');
      _published = client.published!.listen((message) {
        final id = message.variableHeader?.messageIdentifier;
        final ack = _acks.remove(id);
        if (ack != null && !ack.isCompleted) ack.complete();
      });
      _rejected = client.publishFail!.listen((message) {
        final ack = _acks.remove(message.variableHeader?.messageIdentifier);
        if (ack != null && !ack.isCompleted) {
          ack.completeError(StateError('Broker rejected the message.'));
        }
      });
      _incoming = client.updates!.listen((messages) {
        for (final message in messages) {
          final data = message.payload;
          if (data is! MqttPublishMessage ||
              message.topic == null ||
              data.payload.message == null ||
              data.payload.message!.length > 256) {
            continue;
          }
          try {
            final payload = utf8.decode(data.payload.message!);
            onMessage(message.topic!, payload, data.header?.retain == true);
          } on FormatException {
            /* Reject malformed command text. */
          }
        }
      });
      client.subscribe(
        '${settings.discoveryPrefix}/status',
        MqttQos.atLeastOnce,
      );
      if (settings.allowControls) {
        for (final topic in [topics.command, topics.profileSet]) {
          // Preserve RETAIN on live deliveries too, so stored commands cannot
          // stop or change context during either a reconnect or a live session.
          final option = MqttSubscriptionOption()
            ..maximumQos = MqttQos.atMostOnce
            ..retainAsPublished = true;
          client.subscribeWithSubscription(
            MqttSubscription(MqttSubscriptionTopic(topic), option),
          );
        }
      }
    } catch (_) {
      await close();
      rethrow;
    }
  }

  @override
  Future<void> publish(
    String topic,
    String payload, {
    bool retain = false,
  }) async {
    if (!connected) throw StateError('Broker is unavailable.');
    final data = MqttPayloadBuilder()..addUTF8String(payload);
    final id = _client!.publishMessage(
      topic,
      MqttQos.atLeastOnce,
      data.payload!,
      retain: retain,
    );
    final ack = Completer<void>();
    _acks[id] = ack;
    try {
      await ack.future.timeout(const Duration(seconds: 5));
    } finally {
      _acks.remove(id);
    }
  }

  @override
  Future<void> close() async {
    _closing = true;
    for (final ack in _acks.values) {
      if (!ack.isCompleted) {
        ack.completeError(StateError('Broker connection closed.'));
      }
    }
    _acks.clear();
    await _incoming?.cancel();
    await _published?.cancel();
    await _rejected?.cancel();
    _incoming = null;
    _published = null;
    _rejected = null;
    final client = _client;
    _client = null;
    client?.disconnect();
  }
}
