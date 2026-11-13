import 'dart:async';
import 'dart:convert';

import 'cloud_pairing.dart';

/// Receiver-local room preferences. Invitations and authenticator secrets are
/// never stored here. A room belongs to the server that authorized its pairing.
class SavedCloudRoom {
  const SavedCloudRoom({
    required this.roomId,
    required this.origin,
    required this.name,
    this.listen = true,
    this.alerts = true,
    this.alias,
  });
  final String roomId, origin, name;
  final String? alias;
  final bool listen, alerts;
  String get displayName => alias?.trim().isNotEmpty == true ? alias! : name;
  String get key => '$origin|$roomId';

  SavedCloudRoom copyWith({String? name, bool? listen, bool? alerts}) =>
      SavedCloudRoom(
        roomId: roomId,
        origin: origin,
        name: name ?? this.name,
        listen: listen ?? this.listen,
        alerts: alerts ?? this.alerts,
        alias: alias,
      );

  Map<String, Object> toJson() => {
    'roomId': roomId,
    'origin': origin,
    'name': name,
    'listen': listen,
    'alerts': alerts,
    if (alias != null) 'alias': alias!,
  };

  static List<SavedCloudRoom> restore(
    String? raw, {
    String? legacyRoomId,
    String? legacyOrigin,
    bool legacyAlerts = false,
    bool legacyListen = true,
  }) {
    // An explicitly empty registry is authoritative after the last logout.
    if (raw != null) {
      try {
        final value = jsonDecode(raw);
        if (value is! List) return [];
        final rooms = <String, SavedCloudRoom>{};
        for (final row in value.take(100)) {
          if (row is! Map) continue;
          final id = row['roomId'];
          final origin = row['origin'] is String
              ? CloudPairing.serverOrigin(row['origin'])
              : null;
          if (id is! String ||
              !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ||
              origin == null)
            continue;
          final room = SavedCloudRoom(
            roomId: id,
            origin: origin,
            name:
                row['name'] is String &&
                    (row['name'] as String).trim().isNotEmpty
                ? (row['name'] as String).trim().substring(
                    0,
                    (row['name'] as String).trim().length.clamp(0, 80),
                  )
                : 'Home phone',
            alias: row['alias'] is String ? row['alias'] : null,
            listen: row['listen'] == true,
            alerts: row['alerts'] == true,
          );
          rooms[room.key] = room;
        }
        return rooms.values.toList();
      } on FormatException {
        return [];
      }
    }
    final origin = legacyOrigin == null
        ? null
        : CloudPairing.serverOrigin(legacyOrigin);
    if (origin == null ||
        legacyRoomId == null ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(legacyRoomId))
      return [];
    return [
      SavedCloudRoom(
        roomId: legacyRoomId,
        origin: origin,
        name: 'Home phone',
        listen: legacyListen,
        alerts: legacyAlerts,
      ),
    ];
  }

  static String encode(Iterable<SavedCloudRoom> rooms) =>
      jsonEncode(rooms.map((room) => room.toJson()).toList());
}

/// One authorized receive-only transport. The coordinator is independent of
/// Firebase/WebRTC so switching, cancellation and logout can be tested with fakes.
abstract interface class SavedRoomSession {
  String? get roomId;
  Map<String, dynamic>? get room;
  bool get online;
  bool get liveAvailable;
  bool get paired;
  bool get listening;
  bool get hearing;
  bool get alertsEnabled;
  String? get connectionProblem;
  Future<void> ensureReady();
  Future<void> startAway(double volume);
  Future<void> stopAway({bool disableAlerts = true});
  Future<void> enableAlerts();
  Future<void> disableAlerts();
  Future<void> forget();
  Future<void> close();
  void setVolume(double volume);
  void requestRecordingAudio(bool enabled);
}

class SavedRoomCoordinator {
  SavedRoomCoordinator({
    required Iterable<SavedCloudRoom> rooms,
    required this.create,
    required this.persist,
    required this.onChanged,
    required this.beforeSelectionChange,
    String? selectedRoomId,
    DateTime Function()? clock,
  }) : _rooms = _index(rooms),
       _selected = selectedRoomId,
       _clock = clock ?? DateTime.now {
    if (!_rooms.containsKey(_selected)) _selected = _rooms.keys.firstOrNull;
  }
  static Map<String, SavedCloudRoom> _index(Iterable<SavedCloudRoom> value) {
    final rooms = value.toList();
    if (rooms.map((room) => room.origin).toSet().length > 1) {
      throw ArgumentError('A room coordinator belongs to one cloud server.');
    }
    return {for (final room in rooms) room.roomId: room};
  }

  final SavedRoomSession Function(
    SavedCloudRoom room,
    void Function() changed,
    void Function(String) problem,
  )
  create;
  final Future<void> Function(List<SavedCloudRoom>, String?) persist;
  final void Function() onChanged;
  final Future<void> Function() beforeSelectionChange;
  final DateTime Function() _clock;
  final Map<String, SavedCloudRoom> _rooms;
  final Map<String, SavedRoomSession> _sessions = {};
  final Set<String> _busy = {}, _ready = {}, _paused = {};
  final Map<String, String> _problems = {};
  final Map<String, DateTime> _retryAt = {};
  final Map<String, int> _failures = {};
  Future<void> _saveTail = Future<void>.value();
  Future<void>? _initializing;
  String? _selected;
  bool _running = false, _closed = false, _recording = false;
  bool _selecting = false;
  Future<void>? _stopping;
  final Map<String, Future<void>> _removing = {};
  final Map<String, Future<void>> _loggingOut = {};
  int _generation = 0, _selectionGeneration = 0;
  double _volume = 1;
  List<SavedCloudRoom> get rooms => List.unmodifiable(_rooms.values);
  String? get selectedRoomId => _selected;
  SavedRoomSession? get selected =>
      _closed || _selected == null || !_rooms.containsKey(_selected)
      ? null
      : _session(_selected!);
  bool get running => _running;
  int get connectedCount => _sessions.values.where((s) => s.hearing).length;
  SavedRoomSession? session(String id) => _sessions[id];

  Future<void> _save() {
    final rooms = this.rooms, selected = _selected;
    return _saveTail = _saveTail
        .catchError((Object _) {})
        .then((_) => persist(rooms, selected));
  }

  SavedRoomSession _session(String id) => _sessions.putIfAbsent(
    id,
    () => create(_rooms[id]!, () => _changed(id), (problem) {
      if (!_closed && _rooms.containsKey(id)) {
        _problems[id] = problem;
        onChanged();
      }
    }),
  );

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    if (_closed) return;
    await _save();
    await Future.wait(_rooms.keys.toList().map((id) => _connect(id)));
  }

  void refreshRoom(String? id) {
    if (id != null) _changed(id);
  }

  void reportProblem(String? id, String problem) {
    if (id != null && !_closed && _rooms.containsKey(id)) {
      _problems[id] = problem;
      onChanged();
    }
  }

  void _changed(String id) {
    if (_closed || !_rooms.containsKey(id)) return;
    final session = _sessions[id];
    final name = session?.room?['roomName'];
    if (name is String && name.trim().isNotEmpty && _rooms[id]!.name != name) {
      _rooms[id] = _rooms[id]!.copyWith(name: name);
      unawaited(_save());
    }
    if (_ready.contains(id) && session?.paired == false) {
      unawaited(removeRevoked(id));
      return;
    }
    _routeAudio();
    onChanged();
    if (_running) unawaited(_connect(id));
  }

  Future<void> add(SavedCloudRoom room, {SavedRoomSession? session}) async {
    if (_closed) return;
    final origin = _rooms.values.firstOrNull?.origin;
    if (origin != null && origin != room.origin) {
      throw ArgumentError('Use a room from the configured cloud server.');
    }
    final previous = _rooms[room.roomId];
    _rooms[room.roomId] = previous?.copyWith(name: room.name) ?? room;
    if (session != null) {
      final old = _sessions[room.roomId];
      if (old != null && old != session) {
        // Re-pairing an already saved room selects its existing live peer.
        await session.close();
      } else {
        _sessions[room.roomId] = session;
      }
      _ready.add(room.roomId);
    }
    await select(room.roomId);
    await _save();
    if (_running) await _connect(room.roomId);
  }

  Future<void> select(String id) async {
    if (_closed || !_rooms.containsKey(id) || id == _selected) return;
    final generation = ++_selectionGeneration;
    _selecting = true;
    // Mute before awaiting file finalization; there is never overlapping audio.
    for (final session in _sessions.values) {
      session.setVolume(0);
      session.requestRecordingAudio(false);
    }
    try {
      await beforeSelectionChange();
      if (_closed ||
          generation != _selectionGeneration ||
          !_rooms.containsKey(id))
        return;
      _selected = id;
      await _save();
    } finally {
      if (generation == _selectionGeneration) {
        _selecting = false;
        _routeAudio();
        if (!_closed) onChanged();
      }
    }
  }

  void _routeAudio() {
    for (final session in _sessions.values) session.setVolume(0);
    for (final entry in _sessions.entries) {
      final chosen =
          _running &&
          !_closed &&
          !_selecting &&
          !_paused.contains(entry.key) &&
          entry.key == _selected;
      entry.value.requestRecordingAudio(chosen && _recording);
      if (chosen) entry.value.setVolume(_volume);
    }
  }

  void setVolume(double value) {
    _volume = value.clamp(0, 1);
    _routeAudio();
  }

  void requestRecording(bool enabled) {
    _recording = enabled;
    _routeAudio();
  }

  Future<void> start({bool restorePreferences = false}) async {
    await _stopping;
    if (_closed) return;
    _running = true;
    _generation++;
    _retryAt.clear();
    if (!restorePreferences) {
      _paused.removeWhere((id) => !_loggingOut.containsKey(id));
      for (final room in rooms) {
        if (!_paused.contains(room.roomId)) {
          _rooms[room.roomId] = room.copyWith(listen: true, alerts: true);
        }
      }
    }
    await _save();
    await tick();
    _routeAudio();
    onChanged();
  }

  Future<void> tick() async {
    if (_closed) return;
    await Future.wait(_rooms.keys.toList().map(_connect));
  }

  Future<void> _connect(String id) async {
    if (_closed ||
        !_rooms.containsKey(id) ||
        _paused.contains(id) ||
        !_busy.add(id))
      return;
    final generation = _generation;
    SavedRoomSession? attempt;
    try {
      final retry = _retryAt[id];
      if (retry != null && _clock().isBefore(retry)) return;
      final session = _session(id);
      attempt = session;
      await session.ensureReady();
      if (_closed || !_rooms.containsKey(id) || _sessions[id] != session)
        return;
      _ready.add(id);
      if (!session.paired) {
        await removeRevoked(id);
        return;
      }
      if (!_running || generation != _generation || _paused.contains(id))
        return;
      final room = _rooms[id]!;
      if (room.listen &&
          session.online &&
          session.liveAvailable &&
          !session.listening) {
        // A new peer starts muted, including when another room is selected.
        await session.startAway(0);
        if (_closed ||
            !_running ||
            _paused.contains(id) ||
            generation != _generation ||
            !_rooms.containsKey(id) ||
            _sessions[id] != session) {
          await session.stopAway(disableAlerts: false);
          return;
        }
      }
      if (room.alerts && !session.alertsEnabled) await session.enableAlerts();
      if (_closed ||
          !_running ||
          _paused.contains(id) ||
          generation != _generation ||
          !_rooms.containsKey(id) ||
          _sessions[id] != session) {
        await session.stopAway();
        return;
      }
      _problems.remove(id);
      _failures.remove(id);
      _retryAt.remove(id);
      _routeAudio();
    } catch (error) {
      if (!_closed &&
          _rooms.containsKey(id) &&
          !_paused.contains(id) &&
          generation == _generation &&
          _sessions[id] == attempt) {
        // A failed negotiation may already own a peer. Close that transport
        // before retrying, so listening cannot stay stuck on a broken peer.
        await attempt?.stopAway(disableAlerts: false);
        _problems[id] = error.toString();
        final failures = (_failures[id] ?? 0) + 1;
        _failures[id] = failures;
        _retryAt[id] = _clock().add(
          Duration(seconds: (5 * failures).clamp(5, 30)),
        );
      }
    } finally {
      _busy.remove(id);
      if (!_closed) onChanged();
    }
  }

  Future<void> logout(String id) =>
      _loggingOut[id] ??= _logout(id).whenComplete(() {
        _loggingOut.remove(id);
      });

  Future<void> _logout(String id) async {
    if (_closed || !_rooms.containsKey(id)) return;
    final session = _session(id);
    _paused.add(id);
    _rooms[id] = _rooms[id]!.copyWith(listen: false, alerts: false);
    _routeAudio();
    final finishing = _selected == id
        ? beforeSelectionChange()
        : Future<void>.value();
    final stopping = session.stopAway(disableAlerts: false);
    onChanged();
    // /leave must succeed before dropping the saved authorization. Offline
    // failures keep the room visible and paused for an explicit retry.
    try {
      await Future.wait([finishing, stopping, _save()]);
      await session.ensureReady();
      if (_closed || _sessions[id] != session) return;
      await session.forget();
      await removeRevoked(id);
    } catch (error) {
      if (!_closed && _rooms.containsKey(id)) {
        _problems[id] = 'Paused · logout failed. Retry logout when connected.';
        onChanged();
      }
      rethrow;
    }
  }

  Future<void> removeRevoked(String id) =>
      _removing[id] ??= _removeRevoked(id).whenComplete(() {
        _removing.remove(id);
      });

  Future<void> _removeRevoked(String id) async {
    if (!_rooms.containsKey(id)) return;
    if (_selected == id) {
      _selected = null;
      _selectionGeneration++;
      _selecting = false;
      _routeAudio();
      await beforeSelectionChange();
    }
    _rooms.remove(id);
    final session = _sessions.remove(id);
    _ready.remove(id);
    _paused.remove(id);
    _problems.remove(id);
    _retryAt.remove(id);
    await session?.close();
    if (_selected == null) _selected = _rooms.keys.firstOrNull;
    if (_rooms.isEmpty) {
      _running = false;
      _generation++;
    }
    _routeAudio();
    await _save();
    onChanged();
  }

  Future<void> stop() =>
      _stopping ??= _stop().whenComplete(() => _stopping = null);

  Future<void> _stop() async {
    _running = false;
    _generation++;
    _selectionGeneration++;
    _selecting = false;
    _routeAudio();
    for (final room in rooms) {
      _rooms[room.roomId] = room.copyWith(listen: false, alerts: false);
    }
    await Future.wait(_sessions.values.toList().map((s) => s.stopAway()));
    await _save();
    onChanged();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _running = false;
    _generation++;
    _selectionGeneration++;
    _selecting = false;
    _routeAudio();
    await Future.wait(_sessions.values.toList().map((s) => s.close()));
    _sessions.clear();
  }

  String status(String id) {
    final session = _sessions[id];
    if (_problems[id] != null) return _problems[id]!;
    if (session?.connectionProblem != null) return session!.connectionProblem!;
    if (_paused.contains(id)) return 'Paused · logging out';
    if (session?.hearing == true)
      return id == _selected
          ? 'Connected · selected audio'
          : 'Connected · muted';
    if (!_running) return 'Stopped';
    if (session?.online == false) return 'Waiting for home phone';
    if (session?.liveAvailable == false) return 'Guardian · alerts only';
    if (session?.listening == true) return 'Connecting live audio';
    return 'Connecting';
  }
}
