import 'dart:async';

/// A join cancelled locally before it could change server membership.
class RoomJoinCancelled implements Exception {
  const RoomJoinCancelled();
}

/// Orders membership changes without coupling independent room transports.
class RoomMembershipQueue {
  final Set<RoomJoinTicket> _joins = {};
  final Map<(String, String), _RoomLeave> _leaves = {};

  RoomJoinTicket beginJoin({required String origin, String? roomId}) {
    // Capture only leaves which already exist. A later leave may wait for this
    // raw join, so looking up its tail after registration would create a cycle.
    final before = Future.wait([
      for (final entry in _leaves.entries)
        if (entry.key.$1 == origin &&
            (roomId == null || entry.key.$2 == roomId))
          entry.value.settled.future,
    ]);
    final ticket = RoomJoinTicket._(this, origin, roomId, before);
    _joins.add(ticket);
    return ticket;
  }

  Future<void> logout({
    required String origin,
    required String roomId,
    required Future<void> Function(Future<void> olderJoins) leave,
  }) {
    final key = (origin, roomId);
    final older = <Future<void>>[];
    for (final ticket in _joins) {
      if (ticket.origin == origin &&
          (ticket.roomId == null || ticket.roomId == roomId)) {
        ticket._loggedOut.add(roomId);
        older.add(ticket._settled.future);
      }
    }
    final existing = _leaves[key];
    if (existing != null) return existing.result.future;
    final pending = _RoomLeave();
    _leaves[key] = pending;
    // Invoke leave now so its local pause/Stop runs before any asynchronous
    // barrier. Only its server operation waits for already-registered joins.
    unawaited(_leave(key, pending, Future.wait(older), leave));
    return pending.result.future;
  }

  Future<void> _leave(
    (String, String) key,
    _RoomLeave pending,
    Future<void> olderJoins,
    Future<void> Function(Future<void>) work,
  ) async {
    try {
      await work(olderJoins);
      pending.result.complete();
    } catch (error, stack) {
      pending.result.completeError(error, stack);
    } finally {
      if (identical(_leaves[key], pending)) _leaves.remove(key);
      pending.settled.complete();
    }
  }
}

class _RoomLeave {
  final result = Completer<void>();
  // Join dependencies always settle successfully, including an offline leave.
  final settled = Completer<void>();
}

class RoomJoinTicket {
  RoomJoinTicket._(this._owner, this.origin, this.roomId, this._before);
  final RoomMembershipQueue _owner;
  final String origin;
  final String? roomId;
  final Future<void> _before;
  final Set<String> _loggedOut = {};
  final _settled = Completer<void>();
  bool _requested = false;

  bool cancelledFor(String roomId) => _loggedOut.contains(roomId);

  Future<T> request<T>(Future<T> Function() join) async {
    if (_requested) throw StateError('This join was already requested.');
    _requested = true;
    try {
      await _before;
      final target = roomId;
      if ((target == null && _loggedOut.isNotEmpty) ||
          (target != null && cancelledFor(target))) {
        throw const RoomJoinCancelled();
      }
      return await join();
    } finally {
      _settled.complete();
    }
  }

  void finish() {
    _owner._joins.remove(this);
    if (!_requested && !_settled.isCompleted) _settled.complete();
  }
}
