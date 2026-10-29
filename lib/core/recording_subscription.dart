import 'dart:async';

/// Retries the receiver's opt-in until the home acknowledges or sends audio.
class RecordingSubscription {
  RecordingSubscription({
    required this.send,
    required this.isOpen,
    this.onChanged,
  });
  final Future<void> Function(String) send;
  final bool Function() isOpen;
  final void Function()? onChanged;
  Timer? _retry;
  bool _enabled = false, _closed = false, ready = false, exhausted = false;
  int _generation = 0, _attempts = 0;

  void request(bool enabled) {
    if (_closed) return;
    _retry?.cancel();
    final generation = ++_generation;
    _enabled = enabled;
    ready = exhausted = false;
    _attempts = 0;
    if (!enabled) {
      if (isOpen()) unawaited(send('unsubscribe').catchError((Object _) {}));
    } else {
      _attempt(generation);
    }
    onChanged?.call();
  }

  void opened() => request(_enabled);

  void _attempt(int generation) {
    if (_closed ||
        !_enabled ||
        ready ||
        generation != _generation ||
        !isOpen()) {
      return;
    }
    if (_attempts >= 5) {
      exhausted = true;
      onChanged?.call();
      return;
    }
    _attempts++;
    unawaited(send('subscribe').catchError((Object _) {}));
    _retry = Timer(const Duration(seconds: 1), () => _attempt(generation));
  }

  void acknowledge() {
    if (_closed || !_enabled) return;
    if (ready && !exhausted) return;
    ready = true;
    exhausted = false;
    _retry?.cancel();
    onChanged?.call();
  }

  void close() {
    _closed = true;
    _generation++;
    _retry?.cancel();
  }
}
