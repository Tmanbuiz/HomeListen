import 'dart:async';

import 'package:flutter/foundation.dart';

import 'cloud_pairing.dart';

enum AwayInvitePermission { allowed, unsupported, unavailable, restricted }

enum AwayInviteFailure {
  unsupported,
  accessChanged,
  restricted,
  roomFull,
  retry,
}

/// A missing room or expired membership on an advertised server is an access
/// change. Only an explicitly unsupported action disables this feature.
AwayInviteFailure awayInviteFailure({int? statusCode, String? code}) {
  if (code == 'share_not_allowed') return AwayInviteFailure.restricted;
  if (code == 'room_full') return AwayInviteFailure.roomFull;
  if (const {
    'access_expired',
    'access_revoked',
    'membership_revoked',
    'membership_missing',
    'not_paired',
  }.contains(code)) {
    return AwayInviteFailure.accessChanged;
  }
  if (statusCode == 405 ||
      const {'route_not_found', 'unsupported_action'}.contains(code)) {
    return AwayInviteFailure.unsupported;
  }
  if (statusCode == 401 || statusCode == 403 || statusCode == 404) {
    return AwayInviteFailure.accessChanged;
  }
  return AwayInviteFailure.retry;
}

extension AwayInvitePermissionMessage on AwayInvitePermission {
  String get message => switch (this) {
    AwayInvitePermission.allowed =>
      'Invite another phone to the selected room.',
    AwayInvitePermission.unsupported =>
      'Update this cloud server to invite from a paired phone.',
    AwayInvitePermission.unavailable =>
      'Room access must be verified before you can invite another phone.',
    AwayInvitePermission.restricted =>
      'Only a permanent caregiver can invite another phone.',
  };
}

/// Missing access metadata is the original, permanent caregiver membership.
/// Any expiry, including an invalid or already elapsed expiry, fails closed.
AwayInvitePermission awayInvitePermission({
  required bool supported,
  required bool home,
  required bool closed,
  required String? uid,
  required String? roomId,
  required Map<String, dynamic>? room,
}) {
  if (home || closed || uid == null || roomId == null || room == null) {
    return AwayInvitePermission.unavailable;
  }
  if (!supported) return AwayInvitePermission.unsupported;
  final members = room['members'];
  if (members is! Map || members[uid] != true) {
    return AwayInvitePermission.unavailable;
  }
  final allAccess = room['memberAccess'];
  if (allAccess != null && allAccess is! Map) {
    return AwayInvitePermission.restricted;
  }
  final access = allAccess is Map ? allAccess[uid] : null;
  if (access != null &&
      (access is! Map ||
          (access['role'] ?? 'caregiver') != 'caregiver' ||
          access['expiresAtMs'] != null)) {
    return AwayInvitePermission.restricted;
  }
  if (room['generation'] is! int) return AwayInvitePermission.unavailable;
  if (room['invitationEpoch'] != null && room['invitationEpoch'] is! int) {
    return AwayInvitePermission.unavailable;
  }
  return AwayInvitePermission.allowed;
}

/// The selected room is captured before any asynchronous work starts.
class AwayInviteRoom {
  const AwayInviteRoom({
    required this.origin,
    required this.roomId,
    required this.name,
    required this.generation,
    this.invitationEpoch = 0,
  });

  final String origin, roomId, name;
  final int generation, invitationEpoch;

  bool sameAccessAs(AwayInviteRoom other) =>
      origin == other.origin &&
      roomId == other.roomId &&
      generation == other.generation &&
      invitationEpoch == other.invitationEpoch;
}

class AwayInviteException implements Exception {
  const AwayInviteException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The secret only lives in the dialog's controller; it is never persisted.
class AwayRoomInvite {
  const AwayRoomInvite({
    required this.room,
    required this.code,
    required this.expiresAt,
    required this.issuerEpoch,
  });

  final AwayInviteRoom room;
  final String code, issuerEpoch;
  final DateTime expiresAt;

  static AwayRoomInvite fromResponse(
    AwayInviteRoom room,
    Map<String, dynamic> response,
    DateTime now,
  ) {
    final secret = response['secret'];
    final rawExpiry = response['expiresAt'];
    final epoch = response['issuerEpoch'];
    final expiry = rawExpiry is String ? DateTime.tryParse(rawExpiry) : null;
    final code = secret is String
        ? CloudPairing(room.origin, room.roomId, secret).toCode()
        : '';
    final parsed = CloudPairing.parse(code);
    if (response['roomId'] != room.roomId ||
        response['generation'] is! int ||
        response['generation'] != room.generation ||
        parsed == null ||
        parsed.origin != room.origin ||
        expiry == null ||
        !expiry.isAfter(now) ||
        epoch is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(epoch)) {
      throw const AwayInviteException(
        'The server did not return a current pairing code. Try again.',
      );
    }
    return AwayRoomInvite(
      room: room,
      code: code,
      expiresAt: expiry,
      issuerEpoch: epoch,
    );
  }
}

/// Binds the dialog to one membership, including legacy memberships whose
/// nonce is first established by this request. A delayed room watch may still
/// show the old missing nonce until it observes the issued value once.
class AwayInviteBinding {
  AwayInviteBinding({
    required this.room,
    required this.uid,
    required String? issuerEpoch,
  }) : _expectedEpoch = issuerEpoch,
       _legacy = issuerEpoch == null;

  final AwayInviteRoom room;
  final String uid;
  final bool _legacy;
  String? _expectedEpoch, _establishingEpoch;
  bool _issuing = false, _observedEpoch = false, _valid = true;

  void beginIssuing() => _issuing = true;
  void endIssuing() => _issuing = false;

  bool accept(AwayRoomInvite invite) {
    if (!_valid ||
        !room.sameAccessAs(invite.room) ||
        (_expectedEpoch != null && _expectedEpoch != invite.issuerEpoch) ||
        (_establishingEpoch != null &&
            _establishingEpoch != invite.issuerEpoch)) {
      _valid = false;
      return false;
    }
    _expectedEpoch = invite.issuerEpoch;
    _observedEpoch = _observedEpoch || _establishingEpoch == invite.issuerEpoch;
    return true;
  }

  bool matches({
    required AwayInviteRoom? current,
    required String? currentUid,
    required String? issuerEpoch,
  }) {
    if (!_valid) return false;
    if (current == null || currentUid != uid || !room.sameAccessAs(current)) {
      _valid = false;
      return false;
    }
    if (_expectedEpoch != null) {
      if (issuerEpoch == _expectedEpoch) {
        _observedEpoch = true;
        return true;
      }
      if (_legacy && !_observedEpoch && issuerEpoch == null) return true;
    } else {
      if (issuerEpoch == null && _establishingEpoch == null) return true;
      if (_issuing &&
          (_establishingEpoch == null || _establishingEpoch == issuerEpoch)) {
        _establishingEpoch = issuerEpoch;
        return true;
      }
    }
    _valid = false;
    return false;
  }
}

/// Owns one visible invitation without changing any audio or recording state.
class AwayRoomInviteController extends ChangeNotifier {
  AwayRoomInviteController({
    required this.room,
    required Future<AwayRoomInvite> Function() generate,
    required bool Function() isCurrent,
    DateTime Function()? clock,
    VoidCallback? onDispose,
  }) : _generate = generate,
       _isCurrent = isCurrent,
       _clock = clock ?? DateTime.now,
       _onDispose = onDispose;

  final AwayInviteRoom room;
  final Future<AwayRoomInvite> Function() _generate;
  final bool Function() _isCurrent;
  final DateTime Function() _clock;
  final VoidCallback? _onDispose;
  AwayRoomInvite? _invite;
  Timer? _expiry;
  int _request = 0;
  bool _disposed = false;
  bool generating = false, invalidated = false, expired = false;
  String? error;

  AwayRoomInvite? get invite => _invite;

  bool validate() {
    if (_disposed || invalidated) return false;
    if (!_isCurrent()) {
      invalidate();
      return false;
    }
    if (_invite != null && !_invite!.expiresAt.isAfter(_clock())) _expire();
    return true;
  }

  Future<void> generate() async {
    if (generating || !validate()) return;
    final request = ++_request;
    _expiry?.cancel();
    _invite = null;
    error = null;
    expired = false;
    generating = true;
    notifyListeners();
    try {
      final result = await _generate();
      if (_disposed || request != _request || !validate()) return;
      if (!room.sameAccessAs(result.room) ||
          !result.expiresAt.isAfter(_clock())) {
        throw const AwayInviteException(
          'The server did not return a current pairing code. Try again.',
        );
      }
      _invite = result;
      _expiry = Timer(result.expiresAt.difference(_clock()), _expire);
    } catch (problem) {
      if (!_disposed && request == _request && validate()) {
        error = problem is AwayInviteException ? problem.message : 'Could not create a pairing code. Check your connection and try again.';
      }
    } finally {
      if (!_disposed && request == _request) {
        generating = false;
        notifyListeners();
      }
    }
  }

  void _expire() {
    if (_disposed || invalidated || _invite == null) return;
    _expiry?.cancel();
    _invite = null;
    expired = true;
    notifyListeners();
  }

  void invalidate() {
    if (_disposed || invalidated) return;
    _request++;
    _expiry?.cancel();
    _invite = null;
    error = null;
    generating = false;
    invalidated = true;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _request++;
    _expiry?.cancel();
    _invite = null;
    generating = false;
    _onDispose?.call();
    super.dispose();
  }
}
