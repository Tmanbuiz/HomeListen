import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/cloud_request.dart';
import 'package:home_listen/core/recovering_watch.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
    'terminal signaling error retries and Stop cancels recovery',
    (tester) async {
      final sources = <StreamController<int>>[];
      final values = <int>[];
      var errors = 0;
      final watch = RecoveringWatch<int>(
        () {
          final source = StreamController<int>();
          sources.add(source);
          return source.stream;
        },
        onData: values.add,
        onError: (_) => errors++,
        accept: (value) => value >= 0,
      );
      sources[0].add(1);
      await tester.pump();
      sources[0].addError(StateError('unavailable'));
      await tester.pump();
      expect(errors, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(sources, hasLength(2));
      sources[1].add(-1); // Cached/unverified data must not restore access.
      sources[1].add(2);
      await tester.pump();
      expect(values, [1, 2]);
      sources[1].addError(StateError('network changed'));
      await tester.pump();
      await watch.cancel();
      await tester.pump(const Duration(minutes: 2));
      expect(sources, hasLength(2));
      for (final source in sources) {
        unawaited(source.close());
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'repeated connection failures back off instead of spinning',
    (tester) async {
      var attempts = 0;
      final watch = RecoveringWatch<int>(
        () {
          attempts++;
          throw StateError('offline');
        },
        onData: (_) {},
        onError: (_) {},
      );
      await tester.pump(const Duration(seconds: 2));
      expect(attempts, 2);
      await tester.pump(const Duration(seconds: 3));
      expect(attempts, 2);
      await tester.pump(const Duration(seconds: 1));
      expect(attempts, 3);
      await watch.cancel();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'disconnected peer expires, recovered peer and Stop cancel deadline',
    (tester) async {
      var failures = 0;
      final deadline = PeerConnectionDeadline(() => failures++);
      deadline.connected();
      deadline.disconnected();
      await tester.pump(const Duration(seconds: 11));
      deadline.connected();
      await tester.pump(const Duration(seconds: 2));
      expect(failures, 0);
      deadline.disconnected();
      await tester.pump(const Duration(seconds: 12));
      expect(failures, 1);
      final stopped = PeerConnectionDeadline(() => failures++);
      stopped.connected();
      stopped.disconnected();
      stopped.cancel();
      await tester.pump(const Duration(seconds: 40));
      expect(failures, 1);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'response body stall times out and the next request can finish',
    () async {
      var listening = false;
      final body = StreamController<List<int>>(
        onListen: () => listening = true,
      );
      var calls = 0;
      final client = MockClient.streaming((request, stream) async {
        await stream.drain<void>();
        if (calls++ == 0) return http.StreamedResponse(body.stream, 200);
        return http.StreamedResponse(Stream.value([123, 125]), 200);
      });
      await expectLater(
        sendCloudRequest(
          client,
          'POST',
          Uri.parse('https://home.example/api/state'),
          headers: {},
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(listening, isTrue);
      final next = await sendCloudRequest(
        client,
        'POST',
        Uri.parse('https://home.example/api/state'),
        headers: {},
      );
      expect(next.body, '{}');
      await body.close();
      client.close();
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );
}
