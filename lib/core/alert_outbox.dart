import 'dart:convert';

/// Only event metadata is retained here. IDs survive retries and app restarts.
class PendingAlert {
  const PendingAlert({
    required this.id,
    required this.title,
    required this.at,
    this.roomId,
    this.origin,
    this.attempts = 0,
    this.nextAttempt,
  });
  final String id, title;
  final String? roomId, origin;
  final DateTime at;
  final int attempts;
  final DateTime? nextAttempt;
  bool expired(DateTime now) =>
      now.difference(at) >= const Duration(minutes: 15);
  bool due(DateTime now) =>
      !expired(now) && (nextAttempt == null || !nextAttempt!.isAfter(now));

  PendingAlert retry(DateTime now) {
    final seconds = [6, 15, 30, 60, 120][attempts.clamp(0, 4)];
    return PendingAlert(
      id: id,
      title: title,
      at: at,
      roomId: roomId,
      origin: origin,
      attempts: attempts + 1,
      nextAttempt: now.add(Duration(seconds: seconds)),
    );
  }

  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    'at': at.toIso8601String(),
    'attempts': attempts,
    'roomId': ?roomId,
    'origin': ?origin,
    'nextAttempt': ?nextAttempt?.toIso8601String(),
  };
  static List<PendingAlert> restore(String? raw, DateTime now) {
    try {
      final rows = jsonDecode(raw ?? '[]');
      if (rows is! List) return [];
      final result = <PendingAlert>[];
      final ids = <String>{};
      for (final row in rows.take(50)) {
        if (row is! Map || row['id'] is! String || row['title'] is! String) {
          continue;
        }
        if (!RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(row['id'])) continue;
        final at = DateTime.tryParse('${row['at']}');
        if (at == null ||
            at.isAfter(now) ||
            now.difference(at) >= const Duration(minutes: 15)) {
          continue;
        }
        if (!ids.add(row['id'])) continue;
        result.add(
          PendingAlert(
            id: row['id'],
            title: row['title'],
            at: at,
            roomId: row['roomId'] is String ? row['roomId'] : null,
            origin: row['origin'] is String ? row['origin'] : null,
            attempts: row['attempts'] is int
                ? (row['attempts'] as int).clamp(0, 100)
                : 0,
            nextAttempt: DateTime.tryParse('${row['nextAttempt']}'),
          ),
        );
      }
      return result;
    } on FormatException {
      return [];
    }
  }
}
