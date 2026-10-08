import 'dart:collection';
import 'dart:typed_data';

/// A bounded, sequence-aware playout queue. Delayed packets can arrive before
/// their playout deadline; missing frames become PLC rather than time skips.
class JitterBuffer {
  JitterBuffer({this.initialFrames = 3, this.maxFrames = 10})
    : _target = initialFrames;

  final int initialFrames;
  final int maxFrames;
  final Map<int, Uint8List> _packets = HashMap();
  int? _next;
  bool _started = false;
  int _target;
  int _quietTicks = 0;
  int received = 0;
  int lost = 0;
  int late = 0;

  int get depth => _packets.length;
  int get targetFrames => _target;
  bool get hasStarted => _started;
  double get lossRate => lost / (received + lost).clamp(1, 1 << 30);

  void add(int sequence, Uint8List payload) {
    sequence &= 0xffff;
    _next ??= sequence;
    final delta = (sequence - _next!) & 0xffff;
    if (delta >= 0x8000) {
      // Allow the initial first frame to have arrived out of order.
      if (!_started && ((_next! - sequence) & 0xffff) <= maxFrames) {
        _next = sequence;
      } else {
        late++;
        return;
      }
    } else if (delta > maxFrames * 3) {
      // After a long pause, skip the obsolete backlog and start from now.
      reset();
      _next = sequence;
    }
    if (_packets.containsKey(sequence)) return;
    _packets[sequence] = payload;
    received++;
    while (_packets.length > maxFrames) {
      _packets.remove(_next);
      _next = (_next! + 1) & 0xffff;
    }
  }

  /// Null while warming up. After start, a null payload means exactly one lost
  /// 20 ms frame, which the decoder can conceal without changing timing.
  ({Uint8List? payload})? take() {
    if (!_started) {
      if (_packets.length < _target) return null;
      _started = true;
    }
    if (_packets.length > _target + 3) {
      // Keep latency bounded when scheduler pauses leave a backlog.
      while (_packets.length > _target + 1) {
        _packets.remove(_next);
        _next = (_next! + 1) & 0xffff;
      }
    }
    final payload = _packets.remove(_next);
    _next = (_next! + 1) & 0xffff;
    if (payload == null) {
      lost++;
      _quietTicks = 0;
      _target = (_target + 1).clamp(initialFrames, 6);
      if (_packets.isEmpty) _started = false;
    } else if (++_quietTicks > 250) {
      _target = (_target - 1).clamp(initialFrames, 6);
      _quietTicks = 0;
    }
    return (payload: payload);
  }

  void reset() {
    _packets.clear();
    _next = null;
    _started = false;
    _target = initialFrames;
    _quietTicks = 0;
  }
}
