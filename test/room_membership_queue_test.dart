import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/room_membership_queue.dart';
import 'package:home_listen/core/saved_rooms.dart';

const _origin = 'https://home.example';

void _check(bool value, String reason) => expect(value, isTrue, reason: reason);

class _Session implements SavedRoomSession {
  _Session(this.roomId, this.members, this.changed);
  @override
  final String roomId;
  final Set<String> members;
  final void Function() changed;
  @override
  Map<String, dynamic> get room => {'roomName': roomId};
  @override
  bool paired = true, online = true, liveAvailable = true;
  @override
  bool listening = false, hearing = false, alertsEnabled = false;
  @override
  String? get connectionProblem => null;
  int starts = 0, stops = 0, closes = 0, leaves = 0;
  double volume = 0;
  bool records = false, failLeave = false;
  Completer<void>? leaveGate, closeGate, leaveStarted, closeStarted;
  @override
  Future<void> ensureReady() async {}
  @override
  Future<void> startAway(double value) async {
    starts++;
    volume = value;
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
    leaveStarted?.complete();
    await leaveGate?.future;
    if (failLeave) throw StateError('Offline');
    members.remove(roomId);
    paired = false;
    changed();
  }

  @override
  Future<void> close() async {
    closes++;
    closeStarted?.complete();
    await closeGate?.future;
    listening = hearing = false;
  }

  @override
  void setVolume(double value) => volume = value;
  @override
  void requestRecordingAudio(bool value) => records = value;
}

class _Harness {
  _Harness({String selected = 'a'}) {
    pool = SavedRoomCoordinator(
      rooms: const [
        SavedCloudRoom(roomId: 'a', origin: _origin, name: 'A'),
        SavedCloudRoom(roomId: 'b', origin: _origin, name: 'B'),
      ],
      selectedRoomId: selected,
      create: (room, changed, problem) =>
          sessions[room.roomId] = _Session(room.roomId, members, changed),
      persist: (rooms, _) async => saved = rooms,
      onChanged: () {},
      beforeSelectionChange: () async {},
    );
  }

  final queue = RoomMembershipQueue();
  final members = <String>{'a', 'b'};
  final sessions = <String, _Session>{};
  final temporary = <_Session>[];
  late final SavedRoomCoordinator pool;
  List<SavedCloudRoom> saved = [];
  int rawStarts = 0;

  Future<void> start() async {
    await pool.start();
    pool.requestRecording(true);
  }

  Future<void> logout(String id) => queue.logout(
    origin: _origin,
    roomId: id,
    leave: (older) => pool.logout(id, beforeLeave: older),
  );

  Future<bool> pair(
    String id, {
    bool unknown = false,
    Completer<void>? rawGate,
    Completer<void>? rawStarted,
    _Session? incoming,
  }) async {
    final ticket = queue.beginJoin(
      origin: _origin,
      roomId: unknown ? null : id,
    );
    final connection = incoming ?? _Session(id, members, () {});
    temporary.add(connection);
    var handedToPool = false;
    try {
      await ticket.request(() async {
        rawStarts++;
        rawStarted?.complete();
        await rawGate?.future;
        members.add(id);
      });
      bool current() => !ticket.cancelledFor(id);
      if (!current()) return false;
      handedToPool = true;
      return await pool.add(
        SavedCloudRoom(roomId: id, origin: _origin, name: id),
        session: connection,
        isCurrent: current,
      );
    } on RoomJoinCancelled {
      return false;
    } finally {
      ticket.finish();
      if (!handedToPool) await connection.close();
    }
  }
}

void main() {
  for (final unknown in [false, true]) {
    test(
      'logout follows an older ${unknown ? 'unknown code' : 'known link'} join without restoring the room',
      () async {
        final h = _Harness();
        addTearDown(h.pool.close);
        await h.start();
        final a = h.sessions['a']!, b = h.sessions['b']!;
        final gate = Completer<void>(), started = Completer<void>();
        final joining = h.pair(
          'a',
          unknown: unknown,
          rawGate: gate,
          rawStarted: started,
        );
        await started.future;
        final leaving = h.logout('a');
        _check(
          !a.listening && a.volume == 0 && !a.records,
          'The target peer pauses immediately.',
        );
        _check(a.leaves == 0, 'Server leave waits for the raw join.');
        _check(
          b.hearing && b.starts == 1 && b.stops == 0,
          'The other peer stays connected.',
        );
        gate.complete();
        _check(!await joining, 'The delayed join cannot update the UI.');
        await leaving;
        _check(
          !h.members.contains('a'),
          'Leave removes the late server membership grant.',
        );
        _check(
          h.pool.rooms.length == 1 && h.pool.rooms.single.roomId == 'b',
          'The logged-out room stays removed.',
        );
        _check(
          h.pool.selectedRoomId == 'b' && b.volume == 1,
          'The retained peer becomes audible.',
        );
        _check(
          a.leaves == 1 && h.temporary.single.closes == 1,
          'Exactly one leave and temporary cleanup run.',
        );
        _check(
          b.starts == 1 && b.stops == 0 && b.closes == 0,
          'No other room transport restarts.',
        );
      },
    );
  }

  test(
    'an already-started unknown join to another room remains applicable',
    () async {
      final h = _Harness();
      addTearDown(h.pool.close);
      await h.start();
      final gate = Completer<void>(), started = Completer<void>();
      final joining = h.pair(
        'b',
        unknown: true,
        rawGate: gate,
        rawStarted: started,
      );
      await started.future;
      final leaving = h.logout('a');
      gate.complete();
      _check(await joining, 'Only the returned logged-out room is cancelled.');
      await leaving;
      final b = h.sessions['b']!;
      _check(
        h.members.contains('b') && !h.members.contains('a'),
        'Only A leaves the server.',
      );
      _check(
        b.hearing && b.starts == 1 && b.stops == 0 && b.volume == 1,
        'B keeps its original live peer.',
      );
    },
  );

  test(
    'a fresh same-room pair waits queued leave while a different room proceeds',
    () async {
      final h = _Harness();
      addTearDown(h.pool.close);
      await h.start();
      final a = h.sessions['a']!, b = h.sessions['b']!;
      final gate = a.leaveGate = Completer<void>();
      final started = a.leaveStarted = Completer<void>();
      final leaving = h.logout('a');
      await started.future;
      final newA = h.pair('a');
      _check(await h.pair('b'), 'A queued leave does not block known room B.');
      _check(h.rawStarts == 1, 'Only B has started its raw request.');
      gate.complete();
      await leaving;
      _check(await newA, 'A fresh intentional pair succeeds after leave.');
      _check(
        h.members.contains('a') && h.pool.rooms.length == 2,
        'The newer membership survives the older leave.',
      );
      _check(h.pool.selectedRoomId == 'a', 'The fresh pair selects A.');
      _check(
        b.starts == 1 && b.stops == 0 && b.closes == 0,
        'B never restarts.',
      );
    },
  );

  for (final unknown in [false, true]) {
    test(
      'a second logout cancels a ${unknown ? 'code' : 'link'} request waiting the first leave',
      () async {
        final h = _Harness();
        addTearDown(h.pool.close);
        await h.start();
        final a = h.sessions['a']!;
        final gate = a.leaveGate = Completer<void>();
        final started = a.leaveStarted = Completer<void>();
        final first = h.logout('a');
        await started.future;
        final joining = h.pair('a', unknown: unknown);
        final second = h.logout('a');
        gate.complete();
        await Future.wait([first, second]);
        _check(
          !await joining && h.rawStarts == 0,
          'The waiting request is cancelled before it grants membership.',
        );
        _check(
          a.leaves == 1 && !h.members.contains('a'),
          'The existing leave suffices without duplicate requests.',
        );
        _check(
          h.pool.rooms.length == 1 && h.pool.rooms.single.roomId == 'b',
          'A cannot reappear.',
        );
      },
    );
  }

  test('offline leave keeps saved authorization paused and retry precedes fresh pairing', () async {
    final h = _Harness();
    addTearDown(h.pool.close);
    await h.start();
    final a = h.sessions['a']!, b = h.sessions['b']!;
    a.failLeave = true;
    var failed = false;
    try {
      await h.logout('a');
    } on StateError {
      failed = true;
    }
    _check(
      failed && h.pool.rooms.length == 2 && h.members.contains('a'),
      'Offline failure retains saved server authorization.',
    );
    final savedA = h.saved.singleWhere((room) => room.roomId == 'a');
    _check(
      !savedA.listen &&
          !savedA.alerts &&
          !a.hearing &&
          h.pool.status('a').contains('Paused'),
      'The failed room remains paused for retry.',
    );
    a.failLeave = false;
    final gate = a.leaveGate = Completer<void>();
    final started = a.leaveStarted = Completer<void>();
    final retry = h.logout('a');
    await started.future;
    final fresh = h.pair('a');
    _check(
      h.rawStarts == 0,
      'Fresh pairing waits the already-registered retry.',
    );
    gate.complete();
    await retry;
    _check(
      await fresh && h.members.contains('a'),
      'Retry cannot later revoke the fresh pairing.',
    );
    _check(
      b.hearing && b.starts == 1 && b.stops == 0,
      'The healthy peer survives failure and retry.',
    );
  });

  test('logout during asynchronous adoption prevents late selection and persistence', () async {
    final h = _Harness(selected: 'b');
    addTearDown(h.pool.close);
    await h.start();
    final incoming = _Session('a', h.members, () {});
    final gate = incoming.closeGate = Completer<void>();
    final started = incoming.closeStarted = Completer<void>();
    final joining = h.pair('a', incoming: incoming);
    await started.future;
    await h.logout('a');
    gate.complete();
    _check(
      !await joining,
      'Cancellation is checked after awaiting temporary close.',
    );
    _check(
      h.pool.rooms.length == 1 && h.pool.selectedRoomId == 'b',
      'A is neither re-saved nor selected.',
    );
    final b = h.sessions['b']!;
    _check(
      b.hearing && b.volume == 1 && b.starts == 1 && b.stops == 0,
      'B stays audible on its original peer.',
    );
    _check(
      !h.members.contains('a') && incoming.closes == 1,
      'The server leave and temporary cleanup finish once.',
    );
  });
}
