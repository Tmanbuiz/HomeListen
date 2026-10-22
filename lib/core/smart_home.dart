import 'dart:async';
import 'dart:convert';

import 'activity_event.dart';
import 'smart_home_settings.dart';
import 'smart_home_transport.dart';

/// Independent of cloud push and audio streaming. Only fresh metadata is sent.
class SmartHomeIntegration {
  SmartHomeIntegration({
    required this.deviceId,
    required this.health,
    required this.roomName,
    required this.onChanged,
    required this.onCommand,
    this.canSend,
    SmartHomeTransport Function()? transportFactory,
    DateTime Function()? clock,
  }) : _factory = transportFactory ?? MqttSmartHomeTransport.new,
       _clock = clock ?? DateTime.now;

  final String deviceId;
  final Map<String, Object?> Function() health;
  final String Function() roomName;
  final void Function() onChanged;
  final Future<void> Function(String command) onCommand;
  final bool Function(String category, DateTime now)? canSend;
  final SmartHomeTransport Function() _factory;
  final DateTime Function() _clock;
  SmartHomeSettings _settings = const SmartHomeSettings();
  String _password = '';
  SmartHomeTransport? _transport;
  Timer? _retry;
  Future<void> _tail = Future<void>.value();
  int _epoch = 0, _failures = 0;
  bool _disposed = false, _stateQueued = false;
  DateTime? _lastState;
  final List<Map<String, Object?>> _pending = [];
  final Map<String, DateTime> _sent = {};
  String status = 'Not connected';
  String? problem;
  int get queued => _pending.length;
  bool get connected =>
      _transport?.connected == true && _retry?.isActive != true;
  SmartHomeTopics get topics =>
      SmartHomeTopics(deviceId, _settings.discoveryPrefix);

  Future<void> configure(SmartHomeSettings settings, String password) async {
    final epoch = ++_epoch;
    _retry?.cancel();
    _retry = null;
    _pending.clear();
    _sent.clear();
    _lastState = null;
    _failures = 0;
    final old = _transport;
    final previousTopics = topics;
    _transport = null;
    if (old != null) {
      if (old.connected) {
        try {
          await old.publish(
            previousTopics.availability,
            'offline',
            retain: true,
          );
        } catch (_) {}
      }
      await old.close();
    }
    if (_disposed || epoch != _epoch) return;
    _settings = settings;
    _password = password;
    problem = null;
    if (!settings.enabled) {
      status = 'Integration off';
      onChanged();
      return;
    }
    if (settings.problem != null || password.isEmpty) {
      problem = settings.problem ?? 'Enter your broker password.';
      status = 'Setup needed';
      onChanged();
      return;
    }
    await _connect(epoch);
  }

  Future<void> _connect(int epoch) async {
    if (_disposed || epoch != _epoch || !_settings.enabled) return;
    status = 'Connecting to Mosquitto';
    onChanged();
    final transport = _factory();
    _transport = transport;
    try {
      await transport.connect(_settings, _password, topics, (
        topic,
        payload,
        retained,
      ) {
        if (epoch != _epoch || _disposed || !identical(_transport, transport)) {
          return;
        }
        if (topic == '${_settings.discoveryPrefix}/status' &&
            payload == 'online') {
          unawaited(
            _sync(epoch).catchError((Object _) {
              _failed(epoch, transport);
            }),
          );
          return;
        }
        final command = topics.parseCommand(
          topic,
          payload,
          retained,
          _settings.allowControls,
        );
        if (command != null) {
          unawaited(onCommand(command).catchError((Object _) {}));
        }
      }, () => _failed(epoch, transport));
      if (_disposed || epoch != _epoch) {
        await transport.close();
        return;
      }
      await _sync(epoch);
      if (epoch != _epoch || _disposed) return;
      _failures = 0;
      problem = null;
      status = 'Broker connected';
      onChanged();
    } catch (_) {
      await transport.close();
      _failed(epoch, transport);
    }
  }

  void _failed(int epoch, [SmartHomeTransport? expected]) {
    if (_disposed ||
        epoch != _epoch ||
        !_settings.enabled ||
        (expected != null && !identical(_transport, expected))) {
      return;
    }
    status = 'Broker unavailable · retrying';
    problem = 'Check the broker address, TLS certificate, credentials and topic permissions.';
    onChanged();
    if (_retry?.isActive == true) return;
    final seconds = [5, 15, 30, 60][_failures.clamp(0, 3)];
    _failures++;
    _retry = Timer(Duration(seconds: seconds), () async {
      _retry = null;
      await _transport?.close();
      if (epoch == _epoch && !_disposed) await _connect(epoch);
    });
  }

  Future<void> _serial(Future<void> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _sync(int epoch) => _serial(() async {
    if (epoch != _epoch || !connected || _disposed) return;
    final transport = _transport!;
    final address = topics;
    // Clear optional controls when their owner turns the permission off.
    if (!_settings.allowControls) {
      await transport.publish(
        address.discovery('select', 'profile_control'),
        '',
        retain: true,
      );
      if (epoch != _epoch || _disposed) return;
      await transport.publish(
        address.discovery('button', 'stop'),
        '',
        retain: true,
      );
    }
    for (final entry
        in address
            .discoveryMessages(roomName(), _settings.allowControls)
            .entries) {
      if (epoch != _epoch || _disposed) return;
      await transport.publish(entry.key, jsonEncode(entry.value), retain: true);
    }
    if (epoch != _epoch || _disposed) return;
    await transport.publish(address.state, jsonEncode(health()), retain: true);
    if (epoch != _epoch || _disposed) return;
    await transport.publish(address.availability, 'online', retain: true);
    _lastState = _clock();
    await _flush(epoch);
  });

  void tick({bool force = false}) {
    if (!connected || _disposed || _stateQueued) return;
    if (!force &&
        _lastState != null &&
        _clock().difference(_lastState!) < const Duration(seconds: 15)) {
      return;
    }
    final epoch = _epoch;
    _stateQueued = true;
    unawaited(
      _serial(() async {
            if (epoch != _epoch || !connected || _disposed) return;
            await _transport!.publish(
              topics.state,
              jsonEncode(health()),
              retain: true,
            );
            _lastState = _clock();
            await _flush(epoch);
          })
          .catchError((Object _) {
            _failed(epoch);
          })
          .whenComplete(() {
            _stateQueued = false;
          }),
    );
  }

  void event(ActivityEvent event, String profile) {
    if (!_settings.enabled ||
        _disposed ||
        event.id == null ||
        event.kind != ActivityKind.sound ||
        event.delivery == AlertDelivery.quiet ||
        _clock().difference(event.at) >= const Duration(seconds: 60) ||
        event.at.isAfter(_clock().add(const Duration(seconds: 30)))) {
      return;
    }
    final category = event.category == 'loud sound'
        ? 'loud_sound'
        : event.category;
    if (![
      'crying',
      'coughing',
      'barking',
      'knocking',
      'loud_sound',
      'test',
    ].contains(category)) {
      return;
    }
    if (canSend?.call(category ?? '', _clock()) == false) return;
    _sent.removeWhere(
      (_, at) => _clock().difference(at) > const Duration(minutes: 2),
    );
    if (_sent.containsKey(event.id) ||
        _pending.any((row) => row['event_id'] == event.id)) {
      return;
    }
    _pending.add({
      'event_type': category,
      'event_id': event.id,
      'observed_at_ms': event.at.millisecondsSinceEpoch,
      'room': event.room,
      'title': event.title,
      'profile': profile,
      'quiet': false,
      'model_score': event.modelScore,
      'detector_version': event.modelVersion,
      'duration_ms': event.durationMs,
    });
    while (_pending.length > 50) {
      _pending.removeAt(0);
    }
    final epoch = _epoch;
    if (connected) {
      unawaited(
        _serial(() => _flush(epoch)).catchError((Object _) {
          _failed(epoch);
        }),
      );
    }
    onChanged();
  }

  Future<void> _flush(int epoch) async {
    while (_pending.isNotEmpty && epoch == _epoch && !_disposed && connected) {
      final row = _pending.first;
      final age =
          _clock().millisecondsSinceEpoch - (row['observed_at_ms'] as int);
      if (age >= 60_000 ||
          age < -30_000 ||
          canSend?.call(row['event_type'] as String, _clock()) == false) {
        _pending.remove(row);
        continue;
      }
      // Event messages are never retained: a new subscriber must not replay old sounds.
      await _transport!.publish(topics.events, jsonEncode(row));
      if (epoch != _epoch || _disposed) return;
      _pending.remove(row);
      _sent[row['event_id'] as String] = _clock();
      onChanged();
    }
  }

  void clearPending() => _pending.clear();
  void resync() {
    final epoch = _epoch;
    if (connected) {
      unawaited(
        _sync(epoch).catchError((Object _) {
          _failed(epoch);
        }),
      );
    }
  }

  Future<void> settle() => _tail;
  Future<void> dispose() async {
    _disposed = true;
    _epoch++;
    _retry?.cancel();
    _pending.clear();
    final transport = _transport;
    _transport = null;
    if (transport == null) return;
    if (transport.connected) {
      try {
        await transport.publish(topics.availability, 'offline', retain: true);
      } catch (_) {}
    }
    await transport.close();
  }
}
