import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/home_monitor.dart';
import 'package:home_listen/protocols/mic_monitor.dart';

void main() {
  group('Home Listen framing', () {
    Uint8List pcmBytes(List<int> samples) {
      final data = ByteData(samples.length * 2);
      for (var i = 0; i < samples.length; i++) {
        data.setInt16(i * 2, samples[i], Endian.little);
      }
      return data.buffer.asUint8List();
    }

    test('a 20 ms frame at 16 kHz is 320 samples and 960 RTP ticks', () {
      // Opus RTP always runs a 48 kHz clock, whatever rate was encoded.
      expect(MicStream.frameSamples, 320);
      expect(MicStream.rtpTimestampStep, 960);
    });

    test('the framer emits only complete frames and carries the rest', () {
      final framer = PcmFramer(frameSamples: 4);
      expect(framer.add(pcmBytes([1, 2, 3])), isEmpty);
      expect(framer.buffered, 3);

      final frames = framer.add(pcmBytes([4, 5, 6, 7, 8, 9]));
      expect(frames.map((f) => f.toList()), [
        [1, 2, 3, 4],
        [5, 6, 7, 8],
      ]);
      expect(framer.buffered, 1);
    });

    test('a sample split across two chunks is rejoined, signs intact', () {
      final framer = PcmFramer(frameSamples: 2);
      final bytes = pcmBytes([-2, 300]);
      // Cut through the middle of the second sample.
      expect(framer.add(bytes.sublist(0, 3)), isEmpty);
      final frames = framer.add(bytes.sublist(3));
      expect(frames.single.toList(), [-2, 300]);
    });

    test('RTP built by the talker is read back by the listener', () {
      final packetizer = RtpPacketizer(ssrc: 0xDEADBEEF);
      final payload = Uint8List.fromList(List.generate(40, (i) => i + 1));
      final packet = packetizer.wrap(payload);

      expect(packet.length, 52);
      expect(packet[0] >> 6, 2); // RTP version
      expect(packet[1] & 0x7F, MicStream.payloadType);
      // Opus gains nothing from the marker, so it stays clear.
      expect(packet[1] & 0x80, 0);
      expect(RtpPacketizer.payloadOf(packet), payload);
    });

    test('sequence and timestamp advance by one frame per packet', () {
      final packetizer = RtpPacketizer(ssrc: 1);
      final first = packetizer.wrap(Uint8List(3));
      final second = packetizer.wrap(Uint8List(3));
      expect(
        RtpPacketizer.sequenceOf(second),
        RtpPacketizer.sequenceOf(first) + 1,
      );
      expect(packetizer.nextTimestamp, 2 * MicStream.rtpTimestampStep);
    });

    test('sequence and timestamp wrap instead of overflowing', () {
      final packetizer = RtpPacketizer(
        ssrc: 1,
        sequence: 0xFFFF,
        timestamp: 0xFFFFFFFF,
      );
      packetizer.wrap(Uint8List(1));
      expect(packetizer.nextSequence, 0);
      expect(packetizer.nextTimestamp, MicStream.rtpTimestampStep - 1);
    });

    test('stale and duplicate packets are not newer, wrap-around is', () {
      expect(RtpPacketizer.isNewer(5, null), isTrue);
      expect(RtpPacketizer.isNewer(6, 5), isTrue);
      expect(RtpPacketizer.isNewer(5, 5), isFalse);
      expect(RtpPacketizer.isNewer(4, 5), isFalse);
      expect(RtpPacketizer.isNewer(0, 0xFFFF), isTrue);
    });

    test('the talker announces the format the listener will decode', () {
      final format = MicStream.parseAnnouncement(MicStream.announcement);
      expect(format?.sampleRate, 16000);
      expect(format?.channels, 1);
    });

    test('anything that is not an announcement is ignored', () {
      expect(MicStream.parseAnnouncement('URRELAY1'), isNull);
      expect(MicStream.parseAnnouncement('192.168.1.5:6970'), isNull);
      expect(MicStream.parseAnnouncement('URMIC001:abc:1'), isNull);
      expect(MicStream.parseAnnouncement('URMIC001:16000:9'), isNull);
    });

    test('padding and CSRC entries are skipped when reading a payload', () {
      final packet = Uint8List.fromList([
        0xA1, 111, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, // padding bit, one CSRC
        9, 9, 9, 9, // the CSRC entry
        1, 2, 3, // payload
        0, 0, 3, // three bytes of padding, the last says so
      ]);
      expect(RtpPacketizer.payloadOf(packet), [1, 2, 3]);
    });

    test('short or foreign packets are not audio', () {
      expect(RtpPacketizer.payloadOf(Uint8List(5)), isNull);
      expect(RtpPacketizer.payloadOf(Uint8List(20)), isNull); // version 0
    });

    test('the notification says whether anyone is listening', () {
      expect(
        HomeMonitor.notificationText(hasListener: true),
        'Microphone on — streaming to your other device',
      );
      expect(
        HomeMonitor.notificationText(hasListener: false),
        contains('waiting'),
      );
    });
  });

  group('Home Listen handshake', () {
    // The real Opus library only exists inside a built app, so the encoder is
    // replaced by one that tags each frame with its first sample. Everything
    // else — sockets, registration, framing, RTP — is the real thing.
    Uint8List fakeOpus(Int16List pcm) =>
        Uint8List.fromList([pcm.first & 0xFF, (pcm.first >> 8) & 0xFF, 0xAA]);

    Uint8List frameOf(int value) {
      final data = ByteData(MicStream.frameSamples * 2);
      for (var i = 0; i < MicStream.frameSamples; i++) {
        data.setInt16(i * 2, value, Endian.little);
      }
      return data.buffer.asUint8List();
    }

    late MicTalker talker;
    late StreamController<Uint8List> mic;
    late RawDatagramSocket client;
    late List<Uint8List> received;

    setUp(() async {
      mic = StreamController<Uint8List>();
      talker = MicTalker(
        controlPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        encoder: fakeOpus,
      );
      await talker.start(mic.stream);
      client = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      received = [];
      client.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = client.receive();
        if (datagram != null) received.add(datagram.data);
      });
    });

    tearDown(() async {
      client.close();
      await talker.stop();
      await mic.close();
    });

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 80));

    test('a talker sends nothing until someone registers', () async {
      expect(talker.hasListener, isFalse);
      mic.add(frameOf(7));
      await settle();
      expect(talker.packetsSent, 0);
      expect(received, isEmpty);
    });

    test('registering is answered with the stream format', () async {
      client.send(
        MicStream.hello.codeUnits,
        InternetAddress.loopbackIPv4,
        talker.boundPort,
      );
      await settle();

      expect(talker.hasListener, isTrue);
      expect(String.fromCharCodes(received.single), MicStream.announcement);
    });

    test('a stranger\'s datagram does not register anyone', () async {
      client.send(
        'hello?'.codeUnits,
        InternetAddress.loopbackIPv4,
        talker.boundPort,
      );
      client.send(
        'URRELAY1'.codeUnits,
        InternetAddress.loopbackIPv4,
        talker.boundPort,
      );
      await settle();

      expect(talker.hasListener, isFalse);
      expect(received, isEmpty);
    });

    test('once registered, microphone frames arrive as ordered RTP', () async {
      client.send(
        MicStream.hello.codeUnits,
        InternetAddress.loopbackIPv4,
        talker.boundPort,
      );
      await settle();
      received.clear();

      mic.add(frameOf(11));
      mic.add(frameOf(22));
      for (var i = 0; i < 100 && received.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(talker.packetsSent, 2);
      expect(received, hasLength(2));
      final first = received[0];
      final second = received[1];
      expect(
        RtpPacketizer.sequenceOf(second),
        RtpPacketizer.sequenceOf(first) + 1,
      );
      // The payload the listener would hand to its Opus decoder.
      expect(RtpPacketizer.payloadOf(first), [11, 0, 0xAA]);
      expect(RtpPacketizer.payloadOf(second), [22, 0, 0xAA]);
    });

    test('chunks that straddle frames still produce whole frames', () async {
      client.send(
        MicStream.hello.codeUnits,
        InternetAddress.loopbackIPv4,
        talker.boundPort,
      );
      await settle();
      received.clear();

      final bytes = frameOf(5);
      mic.add(bytes.sublist(0, 101));
      mic.add(bytes.sublist(101));
      await settle();

      expect(received, hasLength(1));
    });

    test('stopping closes the port and forgets the listener', () async {
      client.send(
        MicStream.hello.codeUnits,
        InternetAddress.loopbackIPv4,
        talker.boundPort,
      );
      await settle();
      expect(talker.hasListener, isTrue);

      await talker.stop();
      expect(talker.isRunning, isFalse);
      expect(talker.hasListener, isFalse);
      expect(talker.boundPort, 0);
    });

    test('an idle listener reports nothing heard', () async {
      // Registering needs the native Opus library, so the unreachable-talker
      // path is covered by the on-device smoke test; this checks idle state.
      final listener = MicListener();
      expect(listener.isRunning, isFalse);
      expect(listener.isHearing, isFalse);
      await listener.stop();
    });
  });
}
