import 'dart:async';

/// Reattaches terminal signaling streams without changing pairing or capture.
class RecoveringWatch<T> {
  RecoveringWatch(
    this.source, {
    required this.onData,
    required this.onError,
    this.accept,
  }) {
    _connect();
  }

  final Stream<T> Function() source;
  final void Function(T) onData;
  final void Function(Object) onError;
  final bool Function(T)? accept;
  StreamSubscription<T>? _subscription;
  Timer? _retry;
  bool _closed = false;
  int _generation = 0, _failures = 0;

  void _connect() {
    if (_closed) return;
    final generation = ++_generation;
    try {
      _subscription = source().listen(
        (value) {
          if (_closed || generation != _generation) return;
          if (accept?.call(value) == false) return;
          _failures = 0;
          onData(value);
        },
        onError: (Object error) => _failed(error, generation),
        onDone: () =>
            _failed(StateError('Signaling stream closed.'), generation),
      );
    } catch (error) {
      _failed(error, generation);
    }
  }

  void _failed(Object error, int generation) {
    if (_closed || generation != _generation) return;
    _generation++;
    unawaited(_subscription?.cancel());
    _subscription = null;
    final seconds = [2, 4, 8, 16, 30, 60][_failures.clamp(0, 5)];
    _failures++;
    _retry = Timer(Duration(seconds: seconds), _connect);
    onError(error);
  }

  Future<void> cancel() async {
    _closed = true;
    _generation++;
    _retry?.cancel();
    await _subscription?.cancel();
    _subscription = null;
  }
}

/// A connected peer must recover from a handover or yield to a fresh session.
class PeerConnectionDeadline {
  PeerConnectionDeadline(this.onFailure) {
    _timer = Timer(const Duration(seconds: 35), _fail);
  }
  final void Function() onFailure;
  Timer? _timer;
  bool _closed = false;

  void connected() => _timer?.cancel();

  void disconnected() {
    if (_closed || _timer?.isActive == true) return;
    _timer = Timer(const Duration(seconds: 12), _fail);
  }

  void _fail() {
    if (_closed) return;
    _closed = true;
    onFailure();
  }

  void cancel() {
    _closed = true;
    _timer?.cancel();
  }
}
