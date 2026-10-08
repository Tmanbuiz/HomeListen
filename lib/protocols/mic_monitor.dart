import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

import 'jitter_buffer.dart';
import 'noise_gate.dart';

/// "Listen to home": the microphone of a phone left at home, heard on a phone
/// somewhere else over the VPN.
///
/// This is a monitor for your own phone in your own home — a pet, a baby
/// sleeping down the hall, checking the house is quiet. It is built to be
/// obvious rather than discreet, and that is a design constraint, not a
/// styling choice: the talker only runs behind a foreground service whose
/// notification says the microphone is on, and it refuses to start when that
/// notification cannot be shown. Nothing in this file or its callers hides,
/// delays or disguises the capture.
///
/// The wire format is plain: Opus in RTP, registration by a short hello, and
/// the talker answering from the same socket it sends audio from, which is
/// what lets the stream cross NAT and a VPN without any port forwarding.
class MicStream {
  /// 16 kHz is the narrowest rate Opus accepts that still carries intelligible
  /// speech and household sound, and it is a third of the bandwidth of 48 kHz.
  static const int sampleRate = 16000;
  static const int channels = 1;

  /// Opus works in fixed frames. Twenty milliseconds is the usual voice
  /// compromise between packet overhead and the delay a lost packet costs.
  static const int frameMs = 20;
  static const int frameSamples = sampleRate * frameMs ~/ 1000; // 320

  /// RTP timestamps for Opus always tick at 48 kHz regardless of the encoded
  /// rate (RFC 7587), so one 20 ms frame advances the clock by 960.
  static const int rtpTimestampStep = 48000 * frameMs ~/ 1000;

  /// Dynamic payload type; nothing negotiates it, both ends just agree.
  static const int payloadType = 111;

  /// Where a listener announces itself and where the talker answers.
  static const int controlPort = 6972;

  /// Marks a registration. Any UDP port attracts stray traffic, and sending
  /// room audio to a stranger is worth one cheap check.
  static const String hello = 'URMIC001';
  static const String statusTag = 'URSTATUS1:';

  /// Prefix of a Sound Watch alert sent from the home phone.
  static const String alertTag = 'URALERT1:';

  /// Appended to a hello by a phone that wants alerts but no audio.
  static const String alertsSuffix = ':alerts';

  /// Voice quality at a bitrate a mobile link will not notice.
  static const int bitrate = 24000;

  /// A listener that has not announced itself for this long is assumed gone,
  /// which matters because a phone that loses signal cannot say goodbye.
  static const Duration listenerTimeout = Duration(seconds: 45);

  /// How often a listener re-announces. Three announcements per timeout.
  static const Duration announceEvery = Duration(seconds: 10);

  /// The talker's answer to a hello: the tag plus the format of what follows,
  /// so the listener configures its decoder from what is actually sent
  /// rather than from a constant that could drift.
  static String get announcement => '$hello:$sampleRate:$channels';

  /// The registration a listener sends. With a pairing token it is
  /// `URMIC001:<token>`; the talker drops anything that does not match, so a
  /// stranger on the same tailnet gets silence rather than the room.
  static String helloFor(String? token, {bool alertsOnly = false}) {
    final base = token == null ? hello : '$hello:$token';
    return alertsOnly ? '$base$alertsSuffix' : base;
  }

  /// Reads the talker's answer. Null for anything that is not one, including
  /// the stray datagrams any UDP port attracts.
  static ({int sampleRate, int channels})? parseAnnouncement(String text) {
    final parts = text.split(':');
    if (parts.length != 3 || parts[0] != hello) return null;
    final rate = int.tryParse(parts[1]);
    final channels = int.tryParse(parts[2]);
    if (rate == null || channels == null) return null;
    if (rate <= 0 || channels < 1 || channels > 2) return null;
    return (sampleRate: rate, channels: channels);
  }
}

/// Slices the arbitrary-sized chunks a recorder emits into the fixed frames
/// Opus requires.
///
/// Recorders hand back whatever the audio driver delivered — 20 ms one moment,
/// 37 the next, and on some devices an odd number of bytes — so frame
/// boundaries cannot be assumed. Anything left over is carried to the next
/// call rather than padded, because padding would insert silence into live
/// audio every time a chunk ended mid-frame.
class PcmFramer {
  PcmFramer({this.frameSamples = MicStream.frameSamples});

  final int frameSamples;
  final List<int> _pending = [];
  int? _straddlingByte;

  /// Samples held back, waiting for the rest of a frame.
  int get buffered => _pending.length;

  /// Accepts little-endian 16-bit PCM and returns every complete frame.
  List<Int16List> add(Uint8List bytes) {
    var start = 0;
    if (_straddlingByte != null && bytes.isNotEmpty) {
      // A sample was split across two chunks; this byte completes it.
      _pending.add(_signed(_straddlingByte! | (bytes[0] << 8)));
      _straddlingByte = null;
      start = 1;
    }
    var i = start;
    for (; i + 1 < bytes.length; i += 2) {
      _pending.add(_signed(bytes[i] | (bytes[i + 1] << 8)));
    }
    if (i < bytes.length) _straddlingByte = bytes[i];

    final frames = <Int16List>[];
    while (_pending.length >= frameSamples) {
      frames.add(Int16List.fromList(_pending.sublist(0, frameSamples)));
      _pending.removeRange(0, frameSamples);
    }
    return frames;
  }

  void reset() {
    _pending.clear();
    _straddlingByte = null;
  }

  static int _signed(int unsigned) =>
      unsigned >= 0x8000 ? unsigned - 0x10000 : unsigned;
}

/// Wraps Opus frames in RTP, producing exactly what
/// [RtpPacketizer.payloadOf] unwraps.
///
/// The marker bit is never set: for Opus it is only a talkspurt hint, and
/// leaving it clear keeps every packet identical in shape.
class RtpPacketizer {
  RtpPacketizer({int? ssrc, int sequence = 0, int timestamp = 0})
    : ssrc = ssrc ?? DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF,
      _sequence = sequence & 0xFFFF,
      _timestamp = timestamp & 0xFFFFFFFF;

  final int ssrc;
  int _sequence;
  int _timestamp;

  int get nextSequence => _sequence;
  int get nextTimestamp => _timestamp;

  /// The 12-byte header plus [payload], advancing the sequence number and
  /// clock. Both wrap, as RTP requires.
  Uint8List wrap(Uint8List payload) {
    final packet = Uint8List(12 + payload.length);
    packet[0] = 0x80; // version 2, no padding, no extension, no CSRC
    packet[1] = MicStream.payloadType; // marker clear — see class comment
    packet[2] = (_sequence >> 8) & 0xFF;
    packet[3] = _sequence & 0xFF;
    packet[4] = (_timestamp >> 24) & 0xFF;
    packet[5] = (_timestamp >> 16) & 0xFF;
    packet[6] = (_timestamp >> 8) & 0xFF;
    packet[7] = _timestamp & 0xFF;
    packet[8] = (ssrc >> 24) & 0xFF;
    packet[9] = (ssrc >> 16) & 0xFF;
    packet[10] = (ssrc >> 8) & 0xFF;
    packet[11] = ssrc & 0xFF;
    packet.setRange(12, packet.length, payload);

    _sequence = (_sequence + 1) & 0xFFFF;
    _timestamp = (_timestamp + MicStream.rtpTimestampStep) & 0xFFFFFFFF;
    return packet;
  }

  /// Strips the RTP header (12 bytes, plus 4 per CSRC, plus any extension and
  /// trailing padding) and returns the Opus payload. Null for anything that is
  /// not a well-formed RTP version 2 packet, which includes stray traffic.
  static Uint8List? payloadOf(Uint8List packet) {
    if (packet.length < 12) return null;
    if ((packet[0] >> 6) != 2) return null;

    var offset = 12 + (packet[0] & 0x0F) * 4;
    if (packet.length < offset) return null;

    if ((packet[0] & 0x10) != 0) {
      if (packet.length < offset + 4) return null;
      final words = (packet[offset + 2] << 8) | packet[offset + 3];
      offset += 4 + words * 4;
      if (packet.length < offset) return null;
    }

    var end = packet.length;
    if ((packet[0] & 0x20) != 0) {
      // The padding bit: the final byte says how many bytes to drop.
      final padding = packet[end - 1];
      if (padding == 0 || end - padding < offset) return null;
      end -= padding;
    }
    return packet.sublist(offset, end);
  }

  /// The 16-bit sequence number of a packet [wrap] produced.
  static int sequenceOf(Uint8List packet) => (packet[2] << 8) | packet[3];

  /// Whether [candidate] is later than [last], allowing for wrap-around.
  ///
  /// UDP over a VPN reorders and duplicates; decoding a stale frame after a
  /// newer one plays a fragment of the past into the present. Half the
  /// sequence space is the conventional window for "newer".
  static bool isNewer(int candidate, int? last) {
    if (last == null) return true;
    final delta = (candidate - last) & 0xFFFF;
    return delta != 0 && delta < 0x8000;
  }
}

/// Turns 20 ms of PCM into one Opus frame. Injected so tests can run without
/// the native library, which only exists inside a built app.
typedef OpusFrameEncoder = Uint8List Function(Int16List pcm);

/// The home end: encodes microphone audio and sends it to whoever registered.
///
/// Capturing is not this class's job — it is handed a PCM stream. That keeps
/// the part that decides what leaves the phone (the listener check, the
/// framing, the destination) testable on its own, and keeps the part that
/// touches the microphone in one place where the visible notification is
/// also managed. See HomeMonitor.
class MicTalker {
  MicTalker({
    this.controlPort = MicStream.controlPort,
    this.bindAddress,
    this.encoder,
    this.token,
    this.statusProvider,
    this.listenerKey = addressKey,
  });

  /// 0 asks the OS for a free port, which is what tests use.
  final int controlPort;

  /// Null binds every interface, so a LAN and a Tailscale listener both work.
  final InternetAddress? bindAddress;

  /// The secret a listener must present. Null accepts any hello, which only
  /// tests use; the app always pairs with one.
  final String? token;
  final Map<String, Object?> Function()? statusProvider;

  /// What makes two registrations "the same phone". Production uses the
  /// address, so a phone that reconnects from a new port replaces itself.
  /// Tests pass the port instead, because a CI machine has only one loopback
  /// address and so cannot play several phones by address.
  final String Function(InternetAddress address, int port) listenerKey;

  static String addressKey(InternetAddress address, int port) =>
      address.address;

  /// Replaces real Opus encoding; only tests pass this.
  final OpusFrameEncoder? encoder;
  OpusFrameEncoder? _encode;
  SimpleOpusEncoder? _opus;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSub;
  StreamSubscription<Uint8List>? _pcmSub;
  Timer? _sweep;
  final PcmFramer _framer = PcmFramer();
  final RtpPacketizer _packetizer = RtpPacketizer();

  /// Every phone currently listening, keyed by its address. A phone that
  /// reconnects from a new port replaces its own entry instead of counting
  /// twice, and one phone can never use up the other slots.
  final Map<String, _Registration> _listeners = {};
  bool _running = false;
  int _sent = 0;

  /// How many phones may listen at once. The audio is encoded once and the same
  /// packet is sent to each, so the cost per extra listener is about 3 kB/s of
  /// upload; the cap exists to bound that, and so that a leaked pairing code
  /// cannot attach an unlimited number of listeners.
  static const int maxListeners = 5;

  bool get isRunning => _running;

  /// Phones that are being sent audio. Alerts-only phones are not counted:
  /// they hear nothing, and the notification must not claim otherwise.
  bool get hasListener => listenerCount > 0;
  int get listenerCount => _listeners.values.where((r) => !r.alertsOnly).length;

  /// Phones registered for alerts only.
  int get watcherCount => _listeners.values.where((r) => r.alertsOnly).length;
  int get packetsSent => _sent;

  /// The addresses currently listening, for showing on the home phone.
  List<String> get listenerAddresses => List.unmodifiable(_listeners.keys);

  /// The port actually bound; differs from [controlPort] when that was 0.
  int get boundPort => _socket?.port ?? 0;

  void Function()? onChanged;
  void Function(String)? onFailure;

  static bool _opusInitialised = false;

  static Future<void> _ensureOpus() async {
    if (_opusInitialised) return;
    initOpus(await opus_flutter.load());
    _opusInitialised = true;
  }

  /// Starts answering registrations and sending [pcm] to the registered
  /// listener.
  ///
  /// Audio produced while nobody is registered is dropped here rather than
  /// buffered: a listener who joins late should hear now, not a backlog, and
  /// nothing the microphone hears is retained on this phone.
  Future<void> start(Stream<Uint8List> pcm) async {
    if (_running) return;

    _encode = encoder;
    if (_encode == null) {
      await _ensureOpus();
      _opus = SimpleOpusEncoder(
        sampleRate: MicStream.sampleRate,
        channels: MicStream.channels,
        application: Application.voip,
      );
      _encode = (frame) => _opus!.encode(input: frame);
    }

    try {
      _socket = await RawDatagramSocket.bind(
        bindAddress ?? InternetAddress.anyIPv4,
        controlPort,
      );
    } on SocketException {
      _opus?.destroy();
      _opus = null;
      throw StateError(
        'Port $controlPort is already in use. Another copy of the monitor may '
        'be running on this phone.',
      );
    }

    _socketSub = _socket!.listen(_onControl);
    _pcmSub = pcm.listen(
      _onPcm,
      onError: (_) => onFailure?.call(
        'The microphone stream stopped. Start sharing again on this phone.',
      ),
      onDone: () {
        if (_running) onFailure?.call('The microphone stream ended.');
      },
    );
    _sweep = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _dropStaleListener(),
    );
    _running = true;
    _sent = 0;
    debugPrint('mic talker: listening for registrations on ${_socket!.port}');
    onChanged?.call();
  }

  void _onControl(RawSocketEvent event) {
    if (event == RawSocketEvent.write) {
      _flushUnsent();
      return;
    }
    if (event != RawSocketEvent.read) return;
    // See MicListener: drain the queue, or a second phone saying hello at the
    // same moment as the first is only noticed at the next datagram.
    Datagram? next;
    while ((next = _socket?.receive()) != null) {
      _onHello(next!);
    }
  }

  void _onHello(Datagram datagram) {
    final text = String.fromCharCodes(datagram.data);
    final alertsOnly = text == MicStream.helloFor(token, alertsOnly: true);
    if (!alertsOnly && text != MicStream.helloFor(token)) return;

    // The endpoint comes from the datagram, not from anything it claims, so a
    // listener behind NAT registers the address that actually works.
    final key = listenerKey(datagram.address, datagram.port);
    final existing = _listeners[key];
    if (existing == null && _listeners.length >= maxListeners) {
      // Full. Staying silent rather than answering means the extra phone
      // sees "did not answer" instead of a stream that never starts.
      debugPrint('mic talker: listener limit reached, ignoring $key');
      return;
    }
    final changed =
        existing == null ||
        existing.port != datagram.port ||
        existing.alertsOnly != alertsOnly;
    _listeners[key] = _Registration(
      datagram.address,
      datagram.port,
      alertsOnly: alertsOnly,
    );

    _transmit(
      Uint8List.fromList(MicStream.announcement.codeUnits),
      datagram.address,
      datagram.port,
    );
    final status = statusProvider?.call();
    if (status != null) {
      final bytes = utf8.encode('${MicStream.statusTag}${jsonEncode(status)}');
      if (bytes.length <= 2048) {
        _transmit(bytes, datagram.address, datagram.port);
      }
    }
    if (changed) {
      debugPrint(
        'mic talker: listener ${datagram.address.address}:${datagram.port}',
      );
      onChanged?.call();
    }
  }

  void _onPcm(Uint8List chunk) {
    // Nobody listening means nothing is even encoded. A phone that only wants
    // alerts does not count: no audio is sent to it.
    if (!hasListener) {
      _framer.reset();
      return;
    }
    for (final frame in _framer.add(chunk)) {
      final Uint8List opus;
      try {
        opus = _encode!(frame);
      } catch (_) {
        // One bad frame is a click, not a reason to stop the monitor.
        continue;
      }
      _send(_packetizer.wrap(opus));
    }
  }

  /// Datagrams the OS had no room for, waiting for the socket to be writable.
  ///
  /// A non-blocking UDP send returns 0 — nothing sent, no error — when the
  /// socket's buffer is momentarily busy, which is easy to hit when one frame
  /// goes to several phones back to back. Dropping those would mean the second
  /// and later phones lose audio at random, so they are retried on the next
  /// write event. Only a few are kept: a frame that is a few hundred
  /// milliseconds late is worth less than the current one.
  final List<(Uint8List, InternetAddress, int)> _unsent = [];
  final Set<Uint8List> _countOnFlush = Set.identity();
  static const int _maxUnsent = 20;

  /// Sends one datagram, queueing it for a retry if the OS is busy. Returns
  /// true when it went out immediately. Every send in this class goes through
  /// here, so none can be dropped silently.
  bool _transmit(Uint8List data, InternetAddress address, int port) {
    try {
      final n = _socket?.send(data, address, port);
      if (n == 0) {
        if (_unsent.length < _maxUnsent) _unsent.add((data, address, port));
        _socket?.writeEventsEnabled = true;
        return false;
      }
      return n != null;
    } on SocketException {
      // The VPN drops and returns; the next datagram tries again. One phone's
      // dead link must not stop the others from hearing.
      return false;
    }
  }

  void _send(Uint8List packet) {
    var delivered = false;
    for (final listener in _listeners.values) {
      if (listener.alertsOnly) continue;
      if (_transmit(packet, listener.address, listener.port)) {
        delivered = true;
      }
    }
    if (delivered) {
      _sent++;
    } else if (_unsent.any((u) => identical(u.$1, packet))) {
      // Nothing went out yet; count the frame once a retry gets it out.
      _countOnFlush.add(packet);
    }
  }

  void _flushUnsent() {
    while (_unsent.isNotEmpty) {
      final (data, address, port) = _unsent.first;
      try {
        final n = _socket?.send(data, address, port);
        if (n == 0) {
          _socket?.writeEventsEnabled = true;
          return;
        }
      } on SocketException {
        // Give up on this one; the stream moves on.
      }
      if (_countOnFlush.remove(data)) _sent++;
      _unsent.removeAt(0);
    }
  }

  /// Sends a Sound Watch alert to every registered phone, listening or not.
  ///
  /// It is a few dozen bytes of text, never audio. UDP can lose it, so it goes
  /// out twice, half a second apart, carrying an id the receiver uses to show
  /// it once.
  ///
  /// Returns how many phones it was sent to, so a caller can say "nobody is
  /// connected" instead of pretending it worked.
  int sendAlert(String title, String room) {
    if (!_running || _listeners.isEmpty) return 0;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final bytes = utf8.encode(
      '${MicStream.alertTag}${jsonEncode({'id': id, 'title': title, 'room': room})}',
    );
    void send() {
      for (final listener in _listeners.values.toList()) {
        _transmit(bytes, listener.address, listener.port);
      }
    }

    send();
    Timer(const Duration(milliseconds: 500), () {
      if (_running) send();
    });
    return _listeners.length;
  }

  void _dropStaleListener() {
    final now = DateTime.now();
    final before = _listeners.length;
    _listeners.removeWhere(
      (_, r) => now.difference(r.lastSeen) >= MicStream.listenerTimeout,
    );
    if (_listeners.length == before) return;
    debugPrint(
      'mic talker: ${before - _listeners.length} listener(s) went quiet',
    );
    onChanged?.call();
  }

  Future<void> stop() async {
    _running = false;
    _sweep?.cancel();
    _sweep = null;
    await _pcmSub?.cancel();
    _pcmSub = null;
    await _socketSub?.cancel();
    _socketSub = null;
    _socket?.close();
    _socket = null;
    _opus?.destroy();
    _opus = null;
    _encode = null;
    _framer.reset();
    _listeners.clear();
    _unsent.clear();
    _countOnFlush.clear();
    onChanged?.call();
  }
}

/// One phone that has said hello and is being sent audio.
class _Registration {
  _Registration(this.address, this.port, {this.alertsOnly = false})
    : lastSeen = DateTime.now();

  /// True for a phone that asked for alerts and no audio.
  final bool alertsOnly;

  final InternetAddress address;
  final int port;
  final DateTime lastSeen;
}

/// The far end: registers with the home phone and plays what it sends.
///
/// The registration socket doubles as the audio socket: the talker sends to
/// the endpoint the hello arrived from, so a second socket would be a port
/// nothing is sending to.
class MicListener {
  int _epoch = 0;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;
  Timer? _announceTimer;
  Timer? _watchdog;
  Timer? _playout;
  Timer? _initialAudioTimer;
  final JitterBuffer _buffer = JitterBuffer();
  SimpleOpusDecoder? _decoder;
  InternetAddress? _talker;
  int _talkerPort = MicStream.controlPort;
  String? _token;
  int? _ssrc;
  bool _running = false;
  bool _heardAudio = false;
  int _packets = 0;
  DateTime? _lastAudio;
  DateTime? _startedAt;
  bool _reportedStall = false;
  double volume = 1;

  /// Turn steady background hiss down. On by default: a phone microphone is
  /// never silent, and its constant hiss is the first thing a listener hears.
  bool reduceHiss = true;
  final NoiseGate _gate = NoiseGate();
  bool get isMuted => volume == 0;
  DateTime? get lastAudio => _lastAudio;
  double get lossRate => _buffer.lossRate;
  int get bufferMs => _buffer.targetFrames * MicStream.frameMs;
  int get droppedPackets => _buffer.lost + _buffer.late;

  bool get isRunning => _running;
  bool get hasAudio => _heardAudio;
  int get packetsReceived => _packets;

  /// Whether audio arrived recently — "connected" and "can hear" are different
  /// states, and only the second one means the monitor is working.
  bool get isHearing {
    final last = _lastAudio;
    return last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 3);
  }

  void Function()? onChanged;
  void Function(String reason)? onFailure;
  void Function()? onStalled;
  void Function(Int16List pcm)? onPcm;
  void Function(Map<String, dynamic> status)? onStatus;

  /// A Sound Watch alert sent by the home phone.
  void Function(Map<String, dynamic> alert)? onAlert;

  bool _alertsOnly = false;
  DateTime? _lastContact;
  final List<String> _seenAlerts = [];

  /// True when this phone asked for alerts and no audio.
  bool get alertsOnly => _alertsOnly;

  /// Whether the home phone has answered recently. For an alerts-only phone
  /// this is the whole health check: there is no audio to go quiet.
  bool get isInContact {
    final last = _lastContact;
    return last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 35);
  }

  static bool _opusInitialised = false;

  static Future<void> _ensureOpus() async {
    if (_opusInitialised) return;
    initOpus(await opus_flutter.load());
    _opusInitialised = true;
  }

  /// Registers with the talker at [host] and starts playing.
  ///
  /// Throws if the talker does not answer, which is the only way a UDP-only
  /// protocol can say "nobody is home".
  Future<void> start(
    String host, {
    int port = MicStream.controlPort,
    String? token,
    bool alertsOnly = false,
  }) async {
    if (_running) return;
    final epoch = ++_epoch;
    _alertsOnly = alertsOnly;
    _lastContact = null;
    _seenAlerts.clear();
    // Alerts-only never decodes anything, so it skips loading the audio codec.
    if (!alertsOnly) await _ensureOpus();
    if (epoch != _epoch) return;

    _talker = InternetAddress(host);
    _talkerPort = port;
    _token = token;
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    if (epoch != _epoch) {
      socket.close();
      return;
    }
    _socket = socket;

    final reply = Completer<({int sampleRate, int channels})?>();
    void handle(Datagram datagram) {
      // A pairing handshake and its audio must come from the requested peer.
      if (datagram.address.address != _talker?.address ||
          datagram.port != _talkerPort) {
        return;
      }
      // Anything from the home phone proves it is there.
      _lastContact = DateTime.now();
      if (!reply.isCompleted) {
        final format = MicStream.parseAnnouncement(
          String.fromCharCodes(datagram.data),
        );
        if (format != null) reply.complete(format);
        return;
      }
      if (datagram.data.length <= 2048 &&
          datagram.data.isNotEmpty &&
          datagram.data[0] != 0x80) {
        try {
          final text = utf8.decode(datagram.data);
          if (text.startsWith(MicStream.alertTag)) {
            _handleAlert(text.substring(MicStream.alertTag.length));
            return;
          }
          if (text.startsWith(MicStream.statusTag)) {
            final data = jsonDecode(text.substring(MicStream.statusTag.length));
            if (data is Map<String, dynamic>) onStatus?.call(data);
            return;
          }
          if (MicStream.parseAnnouncement(text) != null) return;
        } catch (_) {
          return;
        }
      }
      _onAudio(datagram.data);
    }

    _sub = _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      // Drain everything queued: a read event is not repeated for datagrams
      // that arrived while an earlier one was being handled, so reading just
      // one per event can strand audio behind it.
      Datagram? next;
      while ((next = _socket?.receive()) != null) {
        handle(next!);
      }
    });
    // Repeated: the first datagram over a sleeping tunnel is the likeliest lost.
    ({int sampleRate, int channels})? format;
    for (
      var attempt = 0;
      attempt < 5 && format == null && epoch == _epoch;
      attempt++
    ) {
      _announce();
      format = await Future.any([
        reply.future,
        Future<({int sampleRate, int channels})?>.delayed(
          const Duration(milliseconds: 600),
          () => null,
        ),
      ]);
    }
    if (epoch != _epoch) return;
    if (format == null) {
      await stop();
      throw StateError(
        'The phone at $host did not answer. Check that Listen from here is '
        'switched on there, and that Tailscale is connected on both phones.',
      );
    }

    if (alertsOnly) {
      _beginAlertsOnly();
      return;
    }

    _decoder = SimpleOpusDecoder(
      sampleRate: format.sampleRate,
      channels: format.channels,
    );
    await FlutterPcmSound.setup(
      sampleRate: format.sampleRate,
      channelCount: format.channels,
      iosAllowBackgroundAudio: true,
    );
    if (epoch != _epoch) {
      await stop();
      return;
    }
    FlutterPcmSound.start();

    _running = true;
    _heardAudio = false;
    _packets = 0;
    _ssrc = null;
    _buffer.reset();
    _gate.reset();
    _startedAt = DateTime.now();
    _reportedStall = false;
    _playout = Timer.periodic(
      const Duration(milliseconds: MicStream.frameMs),
      (_) => _playFrame(),
    );
    _announceTimer = Timer.periodic(
      MicStream.announceEvery,
      (_) => _announce(),
    );

    // A talker that is registered but silent (microphone blocked, phone
    // asleep, tunnel down) looks exactly like a quiet room. Say so.
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      final since = _lastAudio ?? _startedAt;
      if (!_reportedStall &&
          since != null &&
          DateTime.now().difference(since) > const Duration(seconds: 6)) {
        _reportedStall = true;
        onStalled?.call();
      }
      onChanged?.call();
    });
    _initialAudioTimer = Timer(const Duration(seconds: 6), () {
      if (_running && !_heardAudio) {
        onFailure?.call(
          'Connected, but no audio is arriving. The phone at home may be '
          'asleep, or its microphone may be in use by another app.',
        );
      }
    });
    onChanged?.call();
  }

  /// The quiet half of start(): no decoder, no speaker, no playout timer. Only
  /// the periodic hello that keeps this phone registered, and a health check.
  void _beginAlertsOnly() {
    _running = true;
    _heardAudio = false;
    _packets = 0;
    _startedAt = DateTime.now();
    _reportedStall = false;
    _announceTimer = Timer.periodic(
      MicStream.announceEvery,
      (_) => _announce(),
    );
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_reportedStall && !isInContact) {
        _reportedStall = true;
        onStalled?.call();
      }
      onChanged?.call();
    });
    onChanged?.call();
  }

  /// Parses an alert and hands it up once. The home phone sends each alert
  /// twice in case one datagram is lost, so repeats are dropped by id.
  void _handleAlert(String json) {
    try {
      final data = jsonDecode(json);
      if (data is! Map<String, dynamic>) return;
      final id = data['id'];
      if (id is! String || data['title'] is! String) return;
      if (_seenAlerts.contains(id)) return;
      _seenAlerts.add(id);
      if (_seenAlerts.length > 20) _seenAlerts.removeAt(0);
      onAlert?.call(data);
    } catch (_) {
      // Not an alert we understand.
    }
  }

  void _announce() {
    final talker = _talker;
    final socket = _socket;
    if (talker == null || socket == null) return;
    try {
      socket.send(
        MicStream.helloFor(_token, alertsOnly: _alertsOnly).codeUnits,
        talker,
        _talkerPort,
      );
    } on SocketException {
      // The next tick tries again.
    }
  }

  void _onAudio(Uint8List packet) {
    if (!_running ||
        _alertsOnly ||
        packet.length < 12 ||
        (packet[1] & 0x7f) != MicStream.payloadType) {
      return;
    }
    final payload = RtpPacketizer.payloadOf(packet);
    if (payload == null) return;
    final ssrc = ByteData.sublistView(packet).getUint32(8, Endian.big);
    if (_ssrc != ssrc) {
      _ssrc = ssrc;
      _buffer.reset();
    }
    _buffer.add(RtpPacketizer.sequenceOf(packet), payload);
    _packets++;
    _lastAudio = DateTime.now();
    if (!_heardAudio) {
      _heardAudio = true;
      onChanged?.call();
    }
  }

  void _playFrame() {
    final frame = _buffer.take();
    if (frame == null || _decoder == null) return;
    Int16List pcm;
    try {
      pcm = _decoder!.decode(
        input: frame.payload,
        loss: frame.payload == null ? MicStream.frameMs : null,
      );
    } catch (_) {
      pcm = Int16List(MicStream.frameSamples);
    }
    // Missing audio is never passed to the classifier as an actual sound.
    if (frame.payload != null) {
      try {
        onPcm?.call(pcm);
      } catch (_) {
        // The meter and Sound Watch are extras; they must never be able to
        // stop the sound itself.
      }
    }
    final shaped = reduceHiss ? _gate.process(pcm) : pcm;
    final output = volume == 1
        ? shaped
        : Int16List.fromList(
            shaped
                .map((v) => (v * volume).round().clamp(-32768, 32767))
                .toList(),
          );
    FlutterPcmSound.feed(PcmArrayInt16.fromList(output));
  }

  Future<void> stop() async {
    _epoch++;
    _running = false;
    _announceTimer?.cancel();
    _announceTimer = null;
    _watchdog?.cancel();
    _watchdog = null;
    _playout?.cancel();
    _playout = null;
    _initialAudioTimer?.cancel();
    _initialAudioTimer = null;
    _buffer.reset();
    await _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
    _decoder?.destroy();
    _decoder = null;
    try {
      await FlutterPcmSound.release();
    } catch (_) {
      // Releasing a player that never started is not an error worth raising.
    }
    _lastAudio = null;
    onChanged?.call();
  }
}
