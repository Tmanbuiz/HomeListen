import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/saved_rooms.dart';

const _origin = 'https://home.example';
const _rooms = [
  SavedCloudRoom(roomId: 'bedroom', origin: _origin, name: 'Bedroom'),
  SavedCloudRoom(roomId: 'children', origin: _origin, name: 'Children room'),
];

class _Session implements SavedRoomSession {
  _Session(this.roomId, this.changed);
  @override
  final String roomId;
  final void Function() changed;
  @override
  Map<String, dynamic> get room => {'roomName': roomId};
  @override
  bool paired = true, online = true, liveAvailable = true;
  @override
  bool listening = false, hearing = false, alertsEnabled = false;
  @override
  String? connectionProblem;
  int starts = 0, stops = 0, closes = 0, leaves = 0;
  double volume = 0;
  bool records = false;
  bool failStart = false, failLeave = false;
  Completer<void>? pendingStart, pendingLeave;
  @override
  Future<void> ensureReady() async {}
  @override
  Future<void> startAway(double volume) async {
    starts++;
    this.volume = volume;
    if (failStart) {
      listening = true;
      throw StateError('Network unavailable');
    }
    await pendingStart?.future;
    listening = hearing = true;
  }

  @override
  Future<void> stopAway({bool disableAlerts = true}) async {
    stops++;
    listening = hearing = false;
    if (disableAlerts) alertsEnabled = false;
  }

  @override
  Future<void> enableAlerts() async {
    alertsEnabled = true;
  }

  @override
  Future<void> disableAlerts() async {
    alertsEnabled = false;
  }

  @override
  Future<void> forget() async {
    leaves++;
    await pendingLeave?.future;
    if (failLeave) throw StateError('Offline');
    paired = false;
    listening = hearing = alertsEnabled = false;
    changed();
  }

  @override
  Future<void> close() async {
    closes++;
    listening = hearing = false;
    volume = 0;
  }

  @override
  void setVolume(double volume) {
    this.volume = volume;
  }

  @override
  void requestRecordingAudio(bool enabled) {
    records = enabled;
  }
}

void main() {
  test(
    'legacy pairing migrates without a secret and empty registry remains empty',
    () {
      final migrated = SavedCloudRoom.restore(
        null,
        legacyRoomId: 'bedroom',
        legacyOrigin: _origin,
        legacyAlerts: true,
      );
      expect(migrated.single.roomId, 'bedroom');
      expect(migrated.single.listen, isTrue);
      expect(migrated.single.alerts, isTrue);
      expect(
        SavedCloudRoom.restore(
          '[]',
          legacyRoomId: 'bedroom',
          legacyOrigin: _origin,
        ),
        isEmpty,
      );
      final encoded = SavedCloudRoom.encode(migrated);
      expect(encoded, isNot(contains('secret')));
      expect(SavedCloudRoom.restore(encoded).single.key, migrated.single.key);
      final alertsOnly = SavedCloudRoom.restore(
        null,
        legacyRoomId: 'bedroom',
        legacyOrigin: _origin,
        legacyAlerts: true,
        legacyListen: false,
      );
      expect(alertsOnly.single.listen, isFalse);
    },
  );

  test(
    'malformed and wrong-origin entries do not replace a valid saved room',
    () {
      final rooms = SavedCloudRoom.restore(
        jsonEncode([
          _rooms.first.toJson(),
          {'roomId': '../bad', 'origin': _origin},
          {'roomId': 'bad', 'origin': 'http://insecure.example'},
        ]),
      );
      expect(rooms, hasLength(1));
      expect(rooms.single.roomId, 'bedroom');
    },
  );

  late SavedRoomCoordinator pool;
  late Map<String, _Session> sessions;
  late DateTime now;
  late List<SavedCloudRoom> saved;
  late String? selected;
  Future<void> Function()? beforeSelect;
  _Session Function(String, void Function())? factory;

  setUp(() {
    sessions = {};
    saved = [];
    selected = null;
    beforeSelect = null;
    factory = null;
    now = DateTime(2026);
    pool = SavedRoomCoordinator(
      rooms: _rooms,
      selectedRoomId: 'bedroom',
      clock: () => now,
      create: (room, changed, problem) => sessions[room.roomId] =
          factory?.call(room.roomId, changed) ?? _Session(room.roomId, changed),
      persist: (rooms, id) async {
        saved = rooms;
        selected = id;
      },
      onChanged: () {},
      beforeSelectionChange: () async {
        await beforeSelect?.call();
      },
    );
  });
  tearDown(() async {
    await pool.close();
  });

  test('switching only routes audio and recordings while both live peers remain open', () async {
    await pool.initialize();
    pool.requestRecording(true);
    await pool.start();
    final first = sessions['bedroom']!, second = sessions['children']!;
    expect(pool.connectedCount, 2);
    expect(first.volume, 1);
    expect(second.volume, 0);
    expect(first.records, isTrue);
    expect(second.records, isFalse);
    await pool.select('children');
    expect(first.listening, isTrue);
    expect(second.listening, isTrue);
    expect(first.starts, 1);
    expect(second.starts, 1);
    expect(first.stops, 0);
    expect(second.stops, 0);
    expect(first.volume, 0);
    expect(second.volume, 1);
    expect(first.records, isFalse);
    expect(second.records, isTrue);
    expect(selected, 'children');
    expect(saved, hasLength(2));
  });

  test(
    'an asynchronous selection cannot rearm old-room audio or recording',
    () async {
      await pool.start();
      final gate = Completer<void>();
      beforeSelect = () => gate.future;
      final changing = pool.select('children');
      pool.requestRecording(true);
      pool.refreshRoom('bedroom');
      expect(sessions.values.every((s) => s.volume == 0 && !s.records), isTrue);
      gate.complete();
      await changing;
      expect(sessions['children']!.volume, 1);
      expect(sessions['children']!.records, isTrue);
      expect(sessions['bedroom']!.records, isFalse);
    },
  );

  test(
    'Stop during a room switch lets a later Start route the selected audio',
    () async {
      await pool.start();
      final gate = Completer<void>();
      beforeSelect = () => gate.future;
      final changing = pool.select('children');
      await pool.stop();
      gate.complete();
      await changing;
      beforeSelect = null;
      await pool.start();
      expect(pool.selectedRoomId, 'bedroom');
      expect(sessions['bedroom']!.volume, 1);
      expect(sessions['children']!.volume, 0);
    },
  );

  test(
    'logging out leaves only the chosen room and selects another existing peer',
    () async {
      await pool.start();
      final first = sessions['bedroom']!, second = sessions['children']!;
      await pool.logout('bedroom');
      expect(first.leaves, 1);
      expect(first.closes, 1);
      expect(second.leaves, 0);
      expect(second.closes, 0);
      expect(second.listening, isTrue);
      expect(second.volume, 1);
      expect(pool.rooms.single.roomId, 'children');
      expect(pool.selectedRoomId, 'children');
      await pool.logout('children');
      expect(pool.rooms, isEmpty);
      expect(pool.running, isFalse);
    },
  );

  test(
    'logout immediately pauses its peer before the server confirms leave',
    () async {
      await pool.start();
      pool.requestRecording(true);
      final first = sessions['bedroom']!, second = sessions['children']!;
      final gate = first.pendingLeave = Completer<void>();
      final leaving = pool.logout('bedroom');
      expect(first.volume, 0);
      expect(first.records, isFalse);
      expect(first.listening, isFalse);
      await Future<void>.delayed(Duration.zero);
      await pool.tick();
      expect(first.starts, 1);
      expect(second.listening, isTrue);
      expect(second.stops, 0);
      expect(saved.first.listen, isFalse);
      gate.complete();
      await leaving;
      expect(second.volume, 1);
    },
  );

  test(
    'an offline logout preserves saved authorization and the other peer',
    () async {
      await pool.start();
      sessions['bedroom']!.failLeave = true;
      await expectLater(pool.logout('bedroom'), throwsStateError);
      expect(pool.rooms, hasLength(2));
      expect(sessions['bedroom']!.listening, isFalse);
      expect(sessions['bedroom']!.volume, 0);
      expect(pool.status('bedroom'), contains('Paused'));
      now = now.add(const Duration(minutes: 1));
      await pool.tick();
      expect(sessions['bedroom']!.starts, 1);
      expect(sessions['children']!.listening, isTrue);
      expect(sessions['children']!.closes, 0);
    },
  );

  test(
    'one failed room retries without replacing the healthy room session',
    () async {
      factory = (id, changed) =>
          _Session(id, changed)..failStart = id == 'children';
      await pool.start();
      expect(sessions['bedroom']!.hearing, isTrue);
      expect(sessions['children']!.hearing, isFalse);
      expect(sessions['children']!.listening, isFalse);
      sessions['children']!.failStart = false;
      await pool.tick();
      expect(sessions['children']!.starts, 1);
      now = now.add(const Duration(seconds: 6));
      await pool.tick();
      expect(sessions['children']!.hearing, isTrue);
      expect(sessions['bedroom']!.starts, 1);
    },
  );

  test(
    'Stop cancels a pending connection and does not resurrect listening',
    () async {
      final gate = Completer<void>();
      factory = (id, changed) =>
          _Session(id, changed)..pendingStart = id == 'children' ? gate : null;
      final starting = pool.start();
      await Future<void>.delayed(Duration.zero);
      await pool.stop();
      gate.complete();
      await starting;
      expect(pool.running, isFalse);
      expect(
        sessions.values.every((s) => !s.listening && s.volume == 0),
        isTrue,
      );
      expect(saved.every((r) => !r.listen && !r.alerts), isTrue);
      await pool.tick();
      expect(sessions['children']!.starts, 1);
    },
  );

  test('logout cancels an in-flight start for only that room', () async {
    final gate = Completer<void>();
    factory = (id, changed) =>
        _Session(id, changed)..pendingStart = id == 'children' ? gate : null;
    final starting = pool.start();
    await Future<void>.delayed(Duration.zero);
    await pool.logout('children');
    gate.complete();
    await starting;
    expect(pool.rooms.single.roomId, 'bedroom');
    expect(sessions['bedroom']!.listening, isTrue);
    expect(sessions['children']!.listening, isFalse);
    expect(sessions['children']!.volume, 0);
  });

  test(
    'disposing cancels a pending connection and every room closes',
    () async {
      final gate = Completer<void>();
      factory = (id, changed) =>
          _Session(id, changed)..pendingStart = id == 'children' ? gate : null;
      final starting = pool.start();
      await Future<void>.delayed(Duration.zero);
      await pool.close();
      gate.complete();
      await starting;
      expect(
        sessions.values.every((s) => !s.listening && s.volume == 0),
        isTrue,
      );
      expect(pool.selected, isNull);
    },
  );

  test('re-pairing an existing room keeps its original live peer', () async {
    await pool.start();
    final old = sessions['bedroom']!;
    final duplicate = _Session('bedroom', () {});
    await pool.add(_rooms.first, session: duplicate);
    expect(duplicate.closes, 1);
    expect(old.closes, 0);
    expect(old.starts, 1);
    expect(pool.session('bedroom'), same(old));
  });

  test(
    'a coordinator cannot mix equal room IDs from different cloud origins',
    () {
      expect(
        () => SavedRoomCoordinator(
          rooms: [
            _rooms.first,
            const SavedCloudRoom(
              roomId: 'bedroom',
              origin: 'https://other.example',
              name: 'Other',
            ),
          ],
          create: (room, changed, problem) => _Session(room.roomId, changed),
          persist: (_, _) async {},
          onChanged: () {},
          beforeSelectionChange: () async {},
        ),
        throwsArgumentError,
      );
    },
  );
}
