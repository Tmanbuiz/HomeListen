import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/away_room_invite.dart';
import 'package:home_listen/core/cloud_pairing.dart';
import 'package:home_listen/core/saved_rooms.dart';

const _origin = 'https://home.example';
const _bedroom = 'AAAAAAAAAAAAAAAAAAAAAAAA';
const _kitchen = 'CCCCCCCCCCCCCCCCCCCCCCCC';

class _Session implements SavedRoomSession {
  _Session(this.roomId, this.changed)
    : room = {
        'roomName': roomId == _bedroom ? 'Bedroom' : 'Kitchen',
        'generation': 4,
        'invitationEpoch': 0,
        'members': {'issuer': true, 'unrelated-member': true},
        'shareInviteEpochs': {'issuer': 'membership-first'},
      };

  @override
  final String roomId;
  @override
  final Map<String, dynamic> room;
  final void Function() changed;
  @override
  bool paired = true, online = true, liveAvailable = true;
  @override
  bool listening = false, hearing = false, alertsEnabled = false;
  @override
  String? get connectionProblem => null;
  int starts = 0, stops = 0, closes = 0, leaves = 0;
  double volume = 0;
  bool records = false;
  @override
  Future<void> ensureReady() async {}
  @override
  Future<void> startAway(double volume) async {
    starts++;
    this.volume = volume;
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
    paired = false;
  }

  @override
  Future<void> close() async {
    closes++;
    listening = hearing = false;
  }

  @override
  void setVolume(double value) => volume = value;
  @override
  void requestRecordingAudio(bool enabled) => records = enabled;

  AwayInviteRoom get target => AwayInviteRoom(
    origin: _origin,
    roomId: roomId,
    name: room['roomName'] as String,
    generation: room['generation'] as int,
    invitationEpoch: room['invitationEpoch'] as int? ?? 0,
  );
}

void main() {
  for (final inFlight in [false, true]) {
    test(
      'another member revocation clears ${inFlight ? 'in-flight' : 'displayed'} QR while both room sessions and selected recording continue',
      () async {
        final now = DateTime.utc(2026, 11, 16, 12);
        final sessions = <String, _Session>{};
        AwayRoomInviteController? controller;
        final pool = SavedRoomCoordinator(
          rooms: const [
            SavedCloudRoom(roomId: _bedroom, origin: _origin, name: 'Bedroom'),
            SavedCloudRoom(roomId: _kitchen, origin: _origin, name: 'Kitchen'),
          ],
          selectedRoomId: _bedroom,
          create: (room, changed, problem) =>
              sessions[room.roomId] = _Session(room.roomId, changed),
          persist: (_, _) async {},
          onChanged: () {
            controller?.validate();
          },
          beforeSelectionChange: () async {},
        );
        addTearDown(pool.close);
        await pool.initialize();
        pool.requestRecording(true);
        await pool.start();
        final bedroom = sessions[_bedroom]!, kitchen = sessions[_kitchen]!;
        final captured = bedroom.target;
        final binding = AwayInviteBinding(
          room: captured,
          uid: 'issuer',
          issuerEpoch: 'membership-first',
        );
        final response = AwayRoomInvite(
          room: captured,
          code: CloudPairing(_origin, _bedroom, 'B' * 43).toCode(),
          expiresAt: now.add(const Duration(minutes: 10)),
          issuerEpoch: 'membership-first',
        );
        final pending = Completer<AwayRoomInvite>();
        final invite = AwayRoomInviteController(
          room: captured,
          clock: () => now,
          isCurrent: () => binding.matches(
            current: bedroom.target,
            currentUid: 'issuer',
            issuerEpoch: 'membership-first',
          ),
          generate: () => pending.future,
        );
        controller = invite;
        addTearDown(invite.dispose);
        final request = invite.generate();
        if (!inFlight) {
          pending.complete(response);
          await request;
          expect(invite.invite, isNotNull);
        }

        // Revoking a different phone changes only the invitation epoch. The
        // issuer's membership nonce and every active session remain current.
        (bedroom.room['members'] as Map).remove('unrelated-member');
        bedroom.room['invitationEpoch'] = 1;
        bedroom.changed();
        if (inFlight) pending.complete(response);
        await request;
        await pool.tick();

        expect(invite.invalidated, isTrue);
        expect(invite.invite, isNull);
        expect(pool.selectedRoomId, _bedroom);
        expect(pool.connectedCount, 2);
        expect(bedroom.room['generation'], captured.generation);
        expect(
          (bedroom.room['shareInviteEpochs'] as Map)['issuer'],
          'membership-first',
        );
        for (final session in sessions.values) {
          expect(session.listening, isTrue);
          expect(session.hearing, isTrue);
          expect(session.alertsEnabled, isTrue);
          expect(session.starts, 1);
          expect(session.stops, 0);
          expect(session.closes, 0);
          expect(session.leaves, 0);
        }
        expect(bedroom.volume, 1);
        expect(kitchen.volume, 0);
        expect(bedroom.records, isTrue);
        expect(kitchen.records, isFalse);
      },
    );
  }
}
