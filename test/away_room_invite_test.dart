import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/away_room_invite.dart';
import 'package:home_listen/core/cloud_pairing.dart';

const bedroom = AwayInviteRoom(
  origin: 'https://home.example',
  roomId: 'AAAAAAAAAAAAAAAAAAAAAAAA',
  name: 'Bedroom',
  generation: 4,
);
const kitchen = AwayInviteRoom(
  origin: 'https://home.example',
  roomId: 'CCCCCCCCCCCCCCCCCCCCCCCC',
  name: 'Kitchen',
  generation: 4,
);
final now = DateTime.utc(2026, 11, 16, 12);

AwayRoomInvite inviteFor(
  AwayInviteRoom room, {
  String epoch = 'membership-first',
  DateTime? expiry,
  String secret = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
}) => AwayRoomInvite(
  room: room,
  code: CloudPairing(room.origin, room.roomId, secret).toCode(),
  expiresAt: expiry ?? now.add(const Duration(minutes: 10)),
  issuerEpoch: epoch,
);

void main() {
  test('expired or missing membership does not disable an advertised sharing feature', () {
    for (final failure in [
      (404, 'access_expired'),
      (404, null),
      (403, 'access_revoked'),
      (403, 'membership_revoked'),
      (401, null),
    ]) {
      expect(
        awayInviteFailure(statusCode: failure.$1, code: failure.$2),
        AwayInviteFailure.accessChanged,
      );
    }
    expect(awayInviteFailure(statusCode: 405), AwayInviteFailure.unsupported);
    expect(
      awayInviteFailure(statusCode: 404, code: 'route_not_found'),
      AwayInviteFailure.unsupported,
    );
    expect(
      awayInviteFailure(statusCode: 403, code: 'share_not_allowed'),
      AwayInviteFailure.restricted,
    );
    expect(
      awayInviteFailure(statusCode: 409, code: 'room_full'),
      AwayInviteFailure.roomFull,
    );
    expect(awayInviteFailure(statusCode: 503), AwayInviteFailure.retry);
  });

  group('paired phone invitation permission', () {
    Map<String, dynamic> room([Object? access]) => {
      'generation': 4,
      'members': {'phone': true},
      if (access != null) 'memberAccess': {'phone': access},
    };
    AwayInvitePermission permission(
      Map<String, dynamic>? data, {
      bool supported = true,
      bool home = false,
      bool closed = false,
    }) => awayInvitePermission(
      supported: supported,
      home: home,
      closed: closed,
      uid: 'phone',
      roomId: bedroom.roomId,
      room: data,
    );

    test('legacy and explicit permanent caregivers can invite', () {
      expect(permission(room()), AwayInvitePermission.allowed);
      expect(
        permission(room({'role': 'caregiver', 'expiresAtMs': null})),
        AwayInvitePermission.allowed,
      );
    });

    test(
      'alerts, guests, all expiring access and malformed access cannot invite',
      () {
        for (final access in <Object>[
          {'role': 'alerts'},
          {'role': 'guest'},
          {
            'role': 'caregiver',
            'expiresAtMs': now.millisecondsSinceEpoch + 10000,
          },
          {
            'role': 'caregiver',
            'expiresAtMs': now.millisecondsSinceEpoch - 10000,
          },
          {'role': 'caregiver', 'expiresAtMs': 'invalid'},
          {'role': 'unknown'},
          'invalid',
        ]) {
          expect(permission(room(access)), AwayInvitePermission.restricted);
        }
        expect(
          permission({...room(), 'memberAccess': 'invalid'}),
          AwayInvitePermission.restricted,
        );
      },
    );

    test('revoked, unverified, home and closed connections cannot invite', () {
      expect(permission(null), AwayInvitePermission.unavailable);
      expect(
        permission({...room(), 'members': {}}),
        AwayInvitePermission.unavailable,
      );
      expect(
        permission({...room(), 'generation': null}),
        AwayInvitePermission.unavailable,
      );
      expect(
        permission({...room(), 'invitationEpoch': 'invalid'}),
        AwayInvitePermission.unavailable,
      );
      expect(permission(room(), home: true), AwayInvitePermission.unavailable);
      expect(
        permission(room(), closed: true),
        AwayInvitePermission.unavailable,
      );
      expect(
        permission(room(), supported: false),
        AwayInvitePermission.unsupported,
      );
    });
  });

  group('invitation response', () {
    Map<String, dynamic> response() => {
      'roomId': bedroom.roomId,
      'secret': 'B' * 43,
      'expiresAt': now.add(const Duration(minutes: 10)).toIso8601String(),
      'generation': 4,
      'issuerEpoch': 'membership-first',
    };

    test('uses the existing fragment-only pairing format', () {
      final invite = AwayRoomInvite.fromResponse(bedroom, response(), now);
      final parsed = CloudPairing.parse(invite.code)!;
      expect(parsed.roomId, bedroom.roomId);
      expect(parsed.origin, bedroom.origin);
      expect(parsed.secret, 'B' * 43);
      expect(Uri.parse(invite.code).query, isEmpty);
      expect(invite.room.name, 'Bedroom');
    });

    test('rejects another room, generation, missing nonce, malformed secret or expiry', () {
      for (final change in <Map<String, dynamic>>[
        {'roomId': kitchen.roomId},
        {'generation': 5},
        {'issuerEpoch': null},
        {'issuerEpoch': 'bad nonce'},
        {'secret': 'short'},
        {'expiresAt': 'invalid'},
        {'expiresAt': now.toIso8601String()},
      ]) {
        expect(
          () => AwayRoomInvite.fromResponse(bedroom, {
            ...response(),
            ...change,
          }, now),
          throwsA(isA<AwayInviteException>()),
        );
      }
    });
  });

  group('membership binding', () {
    AwayInviteBinding binding({String? epoch = 'membership-first'}) =>
        AwayInviteBinding(room: bedroom, uid: 'phone', issuerEpoch: epoch);
    bool matches(
      AwayInviteBinding value, {
      AwayInviteRoom? room = bedroom,
      String uid = 'phone',
      String? epoch = 'membership-first',
    }) => value.matches(current: room, currentUid: uid, issuerEpoch: epoch);

    test('rejects room/server, generation, invitation epoch, role, identity and nonce changes', () {
      expect(matches(binding()), isTrue);
      for (final target in <AwayInviteRoom?>[
        kitchen,
        const AwayInviteRoom(
          origin: 'https://other.example',
          roomId: 'AAAAAAAAAAAAAAAAAAAAAAAA',
          name: 'Bedroom',
          generation: 4,
        ),
        const AwayInviteRoom(
          origin: 'https://home.example',
          roomId: 'AAAAAAAAAAAAAAAAAAAAAAAA',
          name: 'Bedroom',
          generation: 5,
        ),
        const AwayInviteRoom(
          origin: 'https://home.example',
          roomId: 'AAAAAAAAAAAAAAAAAAAAAAAA',
          name: 'Bedroom',
          generation: 4,
          invitationEpoch: 1,
        ),
        null,
      ]) {
        final value = binding();
        expect(matches(value, room: target), isFalse);
        expect(
          matches(value),
          isFalse,
          reason:
              'Returning to the old room cannot revive an invalidated code.',
        );
      }
      expect(matches(binding(), uid: 'another-phone'), isFalse);
      expect(matches(binding(), epoch: 'new-membership'), isFalse);
    });

    test('legacy nonce can be established by this in-flight request', () {
      final value = binding(epoch: null);
      expect(matches(value, epoch: null), isTrue);
      value.beginIssuing();
      expect(matches(value), isTrue);
      expect(value.accept(inviteFor(bedroom)), isTrue);
      value.endIssuing();
      expect(matches(value), isTrue);
      expect(matches(value, epoch: null), isFalse);
    });

    test('response may precede the first server room snapshot', () {
      final value = binding(epoch: null)..beginIssuing();
      expect(value.accept(inviteFor(bedroom)), isTrue);
      value.endIssuing();
      expect(matches(value, epoch: null), isTrue);
      expect(matches(value), isTrue);
      expect(matches(value, epoch: 'rotated-membership'), isFalse);
    });

    test(
      'an unsolicited nonce or conflicting response does not get adopted',
      () {
        expect(matches(binding(epoch: null)), isFalse);
        final value = binding(epoch: null)..beginIssuing();
        expect(matches(value), isTrue);
        expect(
          value.accept(inviteFor(bedroom, epoch: 'another-membership')),
          isFalse,
        );
        value.endIssuing();
        expect(matches(value), isFalse);
      },
    );
  });

  group('in-memory invitation lifecycle', () {
    test(
      'creation is explicit, double taps are ignored, renewal clears old code',
      () async {
        var calls = 0;
        var pending = Completer<AwayRoomInvite>();
        final value = AwayRoomInviteController(
          room: bedroom,
          clock: () => now,
          isCurrent: () => true,
          generate: () {
            calls++;
            return pending.future;
          },
        );
        addTearDown(value.dispose);
        expect(calls, 0);
        expect(value.invite, isNull);
        final first = value.generate();
        await value.generate();
        expect(calls, 1);
        pending.complete(inviteFor(bedroom));
        await first;
        expect(value.invite?.room, same(bedroom));
        pending = Completer<AwayRoomInvite>();
        final second = value.generate();
        expect(value.invite, isNull);
        expect(calls, 2);
        pending.complete(inviteFor(bedroom, secret: 'D' * 43));
        await second;
        expect(CloudPairing.parse(value.invite!.code)!.secret, 'D' * 43);
      },
    );

    test(
      'selection or permission loss suppresses an in-flight response',
      () async {
        var current = true;
        final pending = Completer<AwayRoomInvite>();
        final value = AwayRoomInviteController(
          room: bedroom,
          clock: () => now,
          isCurrent: () => current,
          generate: () => pending.future,
        );
        addTearDown(value.dispose);
        final request = value.generate();
        current = false;
        expect(value.validate(), isFalse);
        pending.complete(inviteFor(bedroom));
        await request;
        expect(value.invalidated, isTrue);
        expect(value.invite, isNull);
        expect(value.generating, isFalse);
        expect(value.error, isNull);
      },
    );

    test(
      'expiry clears the secret and permits another explicit generation',
      () async {
        var clock = now;
        final value = AwayRoomInviteController(
          room: bedroom,
          clock: () => clock,
          isCurrent: () => true,
          generate: () async => inviteFor(
            bedroom,
            expiry: clock.add(const Duration(minutes: 10)),
          ),
        );
        addTearDown(value.dispose);
        await value.generate();
        clock = clock.add(const Duration(minutes: 10));
        expect(value.validate(), isTrue);
        expect(value.invite, isNull);
        expect(value.expired, isTrue);
        await value.generate();
        expect(value.invite, isNotNull);
        expect(value.expired, isFalse);
      },
    );

    test('a response for a different room is rejected', () async {
      final value = AwayRoomInviteController(
        room: bedroom,
        clock: () => now,
        isCurrent: () => true,
        generate: () async => inviteFor(kitchen),
      );
      addTearDown(value.dispose);
      await value.generate();
      expect(value.invite, isNull);
      expect(value.error, contains('current pairing code'));
    });

    test(
      'a response bound to a different invitation epoch is rejected',
      () async {
        const renewed = AwayInviteRoom(
          origin: 'https://home.example',
          roomId: 'AAAAAAAAAAAAAAAAAAAAAAAA',
          name: 'Bedroom',
          generation: 4,
          invitationEpoch: 1,
        );
        final value = AwayRoomInviteController(
          room: renewed,
          clock: () => now,
          isCurrent: () => true,
          generate: () async => inviteFor(bedroom),
        );
        addTearDown(value.dispose);
        await value.generate();
        expect(value.invite, isNull);
        expect(value.error, contains('current pairing code'));
        final binding = AwayInviteBinding(
          room: renewed,
          uid: 'phone',
          issuerEpoch: 'membership-first',
        );
        expect(binding.accept(inviteFor(bedroom)), isFalse);
        expect(
          bedroom.invitationEpoch,
          0,
          reason: 'Legacy room snapshots default to zero.',
        );
      },
    );

    test(
      'disposing during a request cannot repopulate or notify the dialog',
      () async {
        final pending = Completer<AwayRoomInvite>();
        var notices = 0, disposals = 0;
        final value = AwayRoomInviteController(
          room: bedroom,
          clock: () => now,
          isCurrent: () => true,
          generate: () => pending.future,
          onDispose: () => disposals++,
        )..addListener(() => notices++);
        final request = value.generate();
        expect(notices, 1);
        value.dispose();
        value.dispose();
        pending.complete(inviteFor(bedroom));
        await request;
        expect(value.invite, isNull);
        expect(notices, 1);
        expect(disposals, 1);
      },
    );

    test('unexpected failures do not expose server data in the UI', () async {
      final value = AwayRoomInviteController(
        room: bedroom,
        clock: () => now,
        isCurrent: () => true,
        generate: () async => throw StateError('private response contents'),
      );
      addTearDown(value.dispose);
      await value.generate();
      expect(value.error, isNot(contains('private response')));
      expect(value.invite, isNull);
    });
  });
}
