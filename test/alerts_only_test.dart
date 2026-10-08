import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/home_monitor.dart';
import 'package:home_listen/protocols/mic_monitor.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const token = 'abcdef0123456789abcdef0123456789';
  Uint8List fakeOpus(Int16List pcm) => Uint8List.fromList([1, 2, 3]);
  Uint8List frame() => Uint8List(MicStream.frameSamples * 2);

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 150 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  group('Alerts-only registration', () {
    late MicTalker talker;
    late StreamController<Uint8List> mic;
    final sockets = <RawDatagramSocket>[];

    setUp(() async {
      mic = StreamController<Uint8List>();
      talker = MicTalker(
        controlPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        encoder: fakeOpus,
        token: token,
        // Every fake phone shares 127.0.0.1, so tell them apart by port.
        listenerKey: (address, port) => '$port',
      );
      await talker.start(mic.stream);
    });

    tearDown(() async {
      for (final s in sockets) {
        s.close();
      }
      sockets.clear();
      await talker.stop();
      await mic.close();
    });

    Future<List<Uint8List>> join(String hello) async {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final inbox = <Uint8List>[];
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? d;
        while ((d = socket.receive()) != null) {
          inbox.add(d!.data);
        }
      });
      socket.send(
        hello.codeUnits,
        InternetAddress.loopbackIPv4,
        talker.boundPort,
      );
      sockets.add(socket);
      return inbox;
    }

    test('an alerts-only phone is a watcher, not a listener', () async {
      await join(MicStream.helloFor(token, alertsOnly: true));
      await until(() => talker.watcherCount == 1);
      expect(talker.watcherCount, 1);
      expect(talker.listenerCount, 0);
      expect(talker.hasListener, isFalse);
    });

    test('it receives no audio, and nothing is encoded for it', () async {
      final inbox = await join(MicStream.helloFor(token, alertsOnly: true));
      await until(() => talker.watcherCount == 1 && inbox.isNotEmpty);
      inbox.clear();

      mic.add(frame());
      mic.add(frame());
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(inbox, isEmpty);
      expect(talker.packetsSent, 0);
    });

    test('a listener next to a watcher still gets audio', () async {
      final watcher = await join(MicStream.helloFor(token, alertsOnly: true));
      final listener = await join(MicStream.helloFor(token));
      await until(() => talker.watcherCount == 1 && talker.listenerCount == 1);
      await until(() => watcher.isNotEmpty && listener.isNotEmpty);
      watcher.clear();
      listener.clear();

      mic.add(frame());
      await until(() => listener.isNotEmpty);

      expect(listener, hasLength(1));
      expect(watcher, isEmpty);
    });

    test('an alerts hello with the wrong secret is ignored', () async {
      final inbox = await join(
        MicStream.helloFor(
          '00000000000000000000000000000000',
          alertsOnly: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(talker.watcherCount, 0);
      expect(inbox, isEmpty);
    });

    test('an alert goes to watchers and listeners, as text only', () async {
      final watcher = await join(MicStream.helloFor(token, alertsOnly: true));
      final listener = await join(MicStream.helloFor(token));
      await until(() => watcher.isNotEmpty && listener.isNotEmpty);
      watcher.clear();
      listener.clear();

      talker.sendAlert('Possible barking', 'Bedroom');
      await until(() => watcher.length >= 2 && listener.length >= 2);

      // Sent twice, in case one datagram is lost.
      for (final inbox in [watcher, listener]) {
        expect(inbox, hasLength(2));
        final text = utf8.decode(inbox.first);
        expect(text, startsWith(MicStream.alertTag));
        final data = jsonDecode(text.substring(MicStream.alertTag.length));
        expect(data['title'], 'Possible barking');
        expect(data['room'], 'Bedroom');
        expect(inbox[0], inbox[1]);
      }
    });

    test('switching from listening to alerts only edits the same phone', () async {
      // Same socket, so the same source port: a second hello with another mode
      // must update that phone rather than add a second one.
      final socket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      sockets.add(socket);
      void hello(String text) => socket.send(
        text.codeUnits,
        InternetAddress.loopbackIPv4,
        talker.boundPort,
      );
      hello(MicStream.helloFor(token));
      await until(() => talker.listenerCount == 1);
      hello(MicStream.helloFor(token, alertsOnly: true));
      await until(() => talker.watcherCount == 1);
      expect(talker.listenerCount, 0);
      expect(talker.watcherCount, 1);
    });
  });

  group('Alerts-only listener, end to end', () {
    test(
      'shows an alert once although it is sent twice, and no audio',
      () async {
        final mic = StreamController<Uint8List>();
        final talker = MicTalker(
          controlPort: 0,
          bindAddress: InternetAddress.loopbackIPv4,
          encoder: fakeOpus,
          token: token,
        );
        await talker.start(mic.stream);
        final listener = MicListener();
        final alerts = <Map<String, dynamic>>[];
        listener.onAlert = alerts.add;
        addTearDown(() async {
          await listener.stop();
          await talker.stop();
          await mic.close();
        });

        await listener.start(
          '127.0.0.1',
          port: talker.boundPort,
          token: token,
          alertsOnly: true,
        );
        expect(listener.alertsOnly, isTrue);
        expect(listener.isRunning, isTrue);
        expect(listener.isInContact, isTrue);
        await until(() => talker.watcherCount == 1);

        talker.sendAlert('Possible knocking', 'Bedroom');
        await until(() => alerts.isNotEmpty);
        // Wait out the repeat the talker sends half a second later.
        await Future<void>.delayed(const Duration(milliseconds: 800));

        expect(alerts, hasLength(1));
        expect(alerts.single['title'], 'Possible knocking');

        mic.add(frame());
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(listener.packetsReceived, 0);
      },
    );

    test('a talker that never answers makes start fail clearly', () async {
      final listener = MicListener();
      // Nothing listens on this port.
      await expectLater(
        listener.start('127.0.0.1', port: 1, token: token, alertsOnly: true),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('Switching modes from the receiving phone', () {
    test('a phone that reconnects in the other mode replaces itself', () async {
      // The app switches by closing its connection and registering again from
      // a new port in the other mode. Phones are told apart by address, so
      // the home phone must see one phone change mode, not a second phone.
      final mic = StreamController<Uint8List>();
      final talker = MicTalker(
        controlPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        encoder: fakeOpus,
        token: token,
      );
      await talker.start(mic.stream);
      addTearDown(() async {
        await talker.stop();
        await mic.close();
      });

      final first = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      first.send(
        MicStream.helloFor(token).codeUnits,
        InternetAddress.loopbackIPv4,
        talker.boundPort,
      );
      await until(() => talker.listenerCount == 1);
      first.close();

      final second = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(second.close);
      second.send(
        MicStream.helloFor(token, alertsOnly: true).codeUnits,
        InternetAddress.loopbackIPv4,
        talker.boundPort,
      );
      await until(() => talker.watcherCount == 1);

      expect(talker.listenerCount, 0);
      expect(talker.watcherCount, 1);
    });

    test('and back again', () async {
      final mic = StreamController<Uint8List>();
      final talker = MicTalker(
        controlPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        encoder: fakeOpus,
        token: token,
      );
      await talker.start(mic.stream);
      addTearDown(() async {
        await talker.stop();
        await mic.close();
      });

      Future<void> register(String hello) async {
        final socket = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        socket.send(
          hello.codeUnits,
          InternetAddress.loopbackIPv4,
          talker.boundPort,
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        socket.close();
      }

      await register(MicStream.helloFor(token, alertsOnly: true));
      expect(talker.watcherCount, 1);
      await register(MicStream.helloFor(token));
      expect(talker.listenerCount, 1);
      expect(talker.watcherCount, 0);
    });
  });

  group('Alerts-only wording and settings', () {
    test('the notification mentions phones watching for alerts', () {
      expect(
        HomeMonitor.notificationText(hasListener: false, watchers: 1),
        'Microphone on — waiting for your other device to connect • '
        '1 phone watching for alerts',
      );
      expect(
        HomeMonitor.notificationText(
          hasListener: true,
          listeners: 2,
          watchers: 3,
        ),
        'Microphone on — streaming to 2 other devices • '
        '3 phones watching for alerts',
      );
      expect(
        HomeMonitor.notificationText(hasListener: true),
        'Microphone on — streaming to your other device',
      );
    });

    test(
      'the home phone does not show its own alerts unless switched on',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final monitor = HomeMonitor(prefs: prefs);
        expect(monitor.homeShowsAlerts, isFalse);

        // The setting is remembered across launches. (Turning it on also asks
        // for notification permission, which needs a real phone, so the stored
        // value is set directly here.)
        await prefs.setBool('home_shows_alerts', true);
        expect(HomeMonitor(prefs: prefs).homeShowsAlerts, isTrue);
        await prefs.remove('home_shows_alerts');
        expect(HomeMonitor(prefs: prefs).homeShowsAlerts, isFalse);
      },
    );

    test(
      'the automatic mode is remembered and defaults to listening',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final first = HomeMonitor(prefs: prefs);
        expect(first.autoMode, 'listen');
        await first.setAutoMode('alerts');
        expect(first.autoMode, 'alerts');

        final second = HomeMonitor(prefs: prefs);
        expect(second.autoMode, 'alerts');
        await second.setAutoMode('anything else');
        expect(second.autoMode, 'listen');
      },
    );
  });
}
