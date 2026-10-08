import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/home_monitor.dart';
import 'package:home_listen/core/pairing.dart';
import 'package:home_listen/protocols/mic_monitor.dart';

void main() {
  multiListenerTests();
  group('Tailscale addresses', () {
    test('only 100.64.0.0/10 counts', () {
      expect(PairingInfo.isTailscaleAddress('100.64.0.1'), isTrue);
      expect(PairingInfo.isTailscaleAddress('100.95.6.24'), isTrue);
      expect(PairingInfo.isTailscaleAddress('100.127.255.254'), isTrue);
      expect(PairingInfo.isTailscaleAddress('100.63.0.1'), isFalse);
      expect(PairingInfo.isTailscaleAddress('100.128.0.1'), isFalse);
      expect(PairingInfo.isTailscaleAddress('10.0.0.8'), isFalse);
      expect(PairingInfo.isTailscaleAddress('192.168.1.5'), isFalse);
      expect(PairingInfo.isTailscaleAddress('100.95.6'), isFalse);
      expect(PairingInfo.isTailscaleAddress('100.95.6.999'), isFalse);
      expect(PairingInfo.isTailscaleAddress('example.com'), isFalse);
    });
  });

  group('Pairing codes', () {
    final token = PairingInfo.newToken();

    test('a code round-trips', () {
      final code = PairingInfo(host: '100.90.213.113', token: token).toCode();
      final parsed = PairingInfo.parse(code)!;
      expect(parsed.host, '100.90.213.113');
      expect(parsed.token, token);
      expect(parsed.port, MicStream.controlPort);
    });

    test('tokens are 128 bits and not repeated', () {
      expect(token, hasLength(32));
      expect(PairingInfo.newToken(), isNot(token));
    });

    test('surrounding whitespace from a paste is tolerated', () {
      final code = PairingInfo(host: '100.90.213.113', token: token).toCode();
      expect(PairingInfo.parse('  $code\n'), isNotNull);
    });

    test('a code aimed at a non-Tailscale host is refused', () {
      // A crafted code must not be able to point the hello at the internet.
      final code = Uri(
        scheme: 'homelisten',
        host: 'pair',
        queryParameters: {
          'host': '203.0.113.9',
          'port': '6972',
          'token': token,
        },
      ).toString();
      expect(PairingInfo.parse(code), isNull);
    });

    test('codes for other apps and malformed codes are refused', () {
      expect(PairingInfo.parse('https://example.com'), isNull);
      expect(PairingInfo.parse('homelisten://pair'), isNull);
      expect(
        PairingInfo.parse('homelisten://other?host=100.90.213.113'),
        isNull,
      );
      expect(
        PairingInfo.parse(
          'homelisten://pair?host=100.90.213.113&port=6972&token=short',
        ),
        isNull,
      );
      expect(
        PairingInfo.parse(
          'homelisten://pair?host=100.90.213.113&port=80&token=$token',
        ),
        isNull,
      );
      expect(PairingInfo.parse(''), isNull);
    });
  });

  group('Paired registration', () {
    Uint8List fakeOpus(Int16List pcm) => Uint8List.fromList([1, 2, 3]);

    late MicTalker talker;
    late StreamController<Uint8List> mic;
    late RawDatagramSocket client;
    late List<Uint8List> received;
    const token = 'abcdef0123456789abcdef0123456789';

    setUp(() async {
      mic = StreamController<Uint8List>();
      talker = MicTalker(
        controlPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        encoder: fakeOpus,
        token: token,
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

    void hello(String text) => client.send(
      text.codeUnits,
      InternetAddress.loopbackIPv4,
      talker.boundPort,
    );

    test('a hello without the secret is ignored', () async {
      hello(MicStream.hello);
      await settle();
      expect(talker.hasListener, isFalse);
      expect(received, isEmpty);
    });

    test('a hello with the wrong secret is ignored', () async {
      hello(MicStream.helloFor('00000000000000000000000000000000'));
      await settle();
      expect(talker.hasListener, isFalse);
      expect(received, isEmpty);
    });

    test('a hello with the right secret registers and is answered', () async {
      hello(MicStream.helloFor(token));
      await settle();
      expect(talker.hasListener, isTrue);
      expect(String.fromCharCodes(received.single), MicStream.announcement);
    });

    test('the hello is not mistaken for an announcement', () {
      // The listener must never read its own echo as the talker's answer.
      expect(MicStream.parseAnnouncement(MicStream.helloFor(token)), isNull);
    });
  });
}

void multiListenerTests() {
  group('Several listeners', () {
    Uint8List fakeOpus(Int16List pcm) => Uint8List.fromList([7, 7, 7]);
    Uint8List frame() => Uint8List(MicStream.frameSamples * 2);
    const token = 'abcdef0123456789abcdef0123456789';

    late MicTalker talker;
    late StreamController<Uint8List> mic;
    final clients = <RawDatagramSocket>[];
    final inboxes = <List<Uint8List>>[];

    Future<int> join(InternetAddress from) async {
      final client = await RawDatagramSocket.bind(from, 0);
      final inbox = <Uint8List>[];
      client.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? d;
        while ((d = client.receive()) != null) {
          inbox.add(d!.data);
        }
      });
      client.send(
        MicStream.helloFor(token).codeUnits,
        InternetAddress.loopbackIPv4,
        talker.boundPort,
      );
      clients.add(client);
      inboxes.add(inbox);
      return clients.length - 1;
    }

    setUp(() async {
      mic = StreamController<Uint8List>();
      talker = MicTalker(
        controlPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        // Every fake phone shares 127.0.0.1, so tell them apart by port.
        listenerKey: (address, port) => '$port',
        encoder: fakeOpus,
        token: token,
      );
      await talker.start(mic.stream);
    });

    tearDown(() async {
      for (final c in clients) {
        c.close();
      }
      clients.clear();
      inboxes.clear();
      await talker.stop();
      await mic.close();
    });

    // Waits for a condition instead of a fixed delay: UDP delivery time varies
    // with machine load, and a fixed wait made this suite flaky.
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 100));

    test('two phones registered at once both receive the same audio', () async {
      // Two sockets on loopback stand in for two phones.
      await join(InternetAddress.loopbackIPv4);
      await join(InternetAddress.loopbackIPv4);
      // Wait for each phone's stream-format reply so it cannot arrive after the
      // inbox is cleared and be mistaken for audio.
      await until(
        () => talker.listenerCount == 2 && inboxes.every((i) => i.isNotEmpty),
      );
      expect(talker.listenerCount, 2);
      for (final inbox in inboxes) {
        inbox.clear();
      }

      mic.add(frame());
      await until(() => inboxes.every((i) => i.isNotEmpty));

      final why =
          "inboxes=${inboxes.map((i) => i.length).toList()} sent=${talker.packetsSent} count=${talker.listenerCount} addrs=${talker.listenerAddresses}";
      expect(inboxes[0], hasLength(1), reason: why);
      expect(inboxes[1], hasLength(1), reason: why);
      expect(inboxes[0].single, inboxes[1].single);
      expect(RtpPacketizer.payloadOf(inboxes[0].single), [7, 7, 7]);
    });

    test('a phone reconnecting from a new port replaces itself', () async {
      // Production keys phones by address, so the same address from a second
      // port is the same phone, not a second listener.
      final byAddress = MicTalker(
        controlPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        encoder: fakeOpus,
        token: token,
      );
      final feed = StreamController<Uint8List>();
      await byAddress.start(feed.stream);
      final sockets = <RawDatagramSocket>[];
      for (var i = 0; i < 2; i++) {
        final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
        s.send(
          MicStream.helloFor(token).codeUnits,
          InternetAddress.loopbackIPv4,
          byAddress.boundPort,
        );
        sockets.add(s);
      }
      await until(() => byAddress.listenerCount >= 1);
      await settle();
      expect(byAddress.listenerCount, 1);
      for (final s in sockets) {
        s.close();
      }
      await byAddress.stop();
      await feed.close();
    });

    test(
      'a sixth phone is turned away without disturbing the others',
      () async {
        for (var i = 2; i <= 6; i++) {
          await join(InternetAddress.loopbackIPv4);
        }
        await settle();
        expect(talker.listenerCount, MicTalker.maxListeners);

        final extra = await join(InternetAddress.loopbackIPv4);
        await settle();
        expect(talker.listenerCount, MicTalker.maxListeners);
        // The turned-away phone never even got the stream format back.
        expect(inboxes[extra], isEmpty);
      },
    );

    test('stopping clears every listener', () async {
      await join(InternetAddress.loopbackIPv4);
      await join(InternetAddress.loopbackIPv4);
      await settle();
      await talker.stop();
      expect(talker.listenerCount, 0);
      expect(talker.hasListener, isFalse);
    });

    test('the notification says how many phones are listening', () {
      expect(
        HomeMonitor.notificationText(hasListener: true, listeners: 3),
        'Microphone on — streaming to 3 other devices',
      );
    });
  });
}
