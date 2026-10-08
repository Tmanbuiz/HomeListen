import 'dart:math' as math;
import 'dart:typed_data';

/// Turns steady background hiss down without cutting speech or events.
///
/// A phone microphone in a quiet room is not silent: it produces a constant
/// low hiss (its own electronics plus room tone), and played back through a
/// speaker that hiss is the first thing the listener hears. It is not a bug in
/// the stream, so no amount of fixing the transport removes it.
///
/// This is a soft downward expander, not a hard gate:
///
///  * It *learns* the room: the floor follows the quietest recent frames
///    quickly downward and creeps upward slowly, so a fan or air conditioner
///    becomes "the floor" within a minute while a voice never does.
///  * Frames clearly above the floor pass at full volume. Frames near the
///    floor are turned down to [quietGain], not to zero, so the line never
///    sounds dead and a listener can tell the connection is alive.
///  * A short hold keeps it open across the gaps between words, and gain
///    changes are ramped across the frame so there are no clicks.
///
/// It is applied on the listening phone only, after the audio has been handed
/// to Sound Watch, so alerts always see the unmodified sound.
class NoiseGate {
  NoiseGate({
    this.quietGain = 0.12,
    this.openRatio = 3.0,
    this.closeRatio = 2.0,
    this.holdFrames = 10,
    this.warmupFrames = 25,
  });

  /// Gain applied to background-only frames (0.12 is about -18 dB).
  final double quietGain;

  /// A frame must be this many times the floor to open the gate.
  final double openRatio;

  /// The gate closes once frames fall back under this many times the floor.
  final double closeRatio;

  /// Frames the gate stays open after the last loud one (20 ms each).
  final int holdFrames;

  /// Frames passed through untouched while the floor is first learned.
  final int warmupFrames;

  static const double _minFloor = 0.0008;
  static const double _maxFloor = 0.03;

  double _floor = 0.01;
  double _gain = 1;
  int _hold = 0;
  int _seen = 0;
  bool _open = true;

  /// The learned background level, as a fraction of full scale.
  double get floor => _floor;

  /// The gain the last frame ended on, 1 meaning untouched.
  double get gain => _gain;

  /// Returns [frame] shaped by the gate. The input is not modified.
  Int16List process(Int16List frame) {
    if (frame.isEmpty) return frame;
    var sum = 0.0;
    for (final s in frame) {
      final v = s / 32768.0;
      sum += v * v;
    }
    final rms = math.sqrt(sum / frame.length);

    if (_seen < warmupFrames) {
      // Learn first, shape later: opening with a guess would clip the first
      // second of a connection.
      _seen++;
      _learn(rms);
      return frame;
    }
    _learn(rms);

    if (rms > _floor * openRatio) {
      _open = true;
      _hold = holdFrames;
    } else if (rms < _floor * closeRatio) {
      if (_hold > 0) {
        _hold--;
      } else {
        _open = false;
      }
    }

    final target = _open ? 1.0 : quietGain;
    final start = _gain;
    // Open fast, close slowly: opening late would swallow the start of a word,
    // and closing slowly makes the tail of a sound fade instead of snap.
    final end = target > start ? target : math.max(target, start - 0.2);
    _gain = end;

    if (start == 1 && end == 1) return frame;
    final out = Int16List(frame.length);
    for (var i = 0; i < frame.length; i++) {
      final g = start + (end - start) * (i + 1) / frame.length;
      out[i] = (frame[i] * g).round().clamp(-32768, 32767);
    }
    return out;
  }

  void _learn(double rms) {
    if (rms < _floor) {
      // Quiet frames pull the floor down quickly, but not to a single
      // outlier: a lone near-zero frame must not make the room "silent".
      _floor = _floor * 0.9 + rms * 0.1;
    } else {
      // Anything louder nudges it up, slowly enough that speech and one-off
      // sounds never become the floor, fast enough that a fan switching on
      // is absorbed within a minute or so.
      _floor += (rms - _floor) * 0.0003;
    }
    _floor = _floor.clamp(_minFloor, _maxFloor);
  }

  void reset() {
    _floor = 0.01;
    _gain = 1;
    _hold = 0;
    _seen = 0;
    _open = true;
  }
}
