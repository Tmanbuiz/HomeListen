import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/recording_subscription.dart';

void main() {
  testWidgets('missed subscribe is retried and acknowledgement stops retries', (
    tester,
  ) async {
    final sent = <String>[];
    final subscription = RecordingSubscription(
      send: (message) async {
        sent.add(message);
      },
      isOpen: () => true,
    );
    subscription.request(true);
    expect(sent, ['subscribe']);
    await tester.pump(const Duration(seconds: 1));
    expect(sent, ['subscribe', 'subscribe']);
    subscription.acknowledge();
    await tester.pump(const Duration(seconds: 10));
    expect(sent.length, 2);
    expect(subscription.ready, isTrue);
    subscription.request(false);
    subscription.acknowledge();
    expect(subscription.ready, isFalse);
    expect(sent.last, 'unsubscribe');
    subscription.close();
  });
  testWidgets('closed channel waits for open and retries are bounded', (
    tester,
  ) async {
    var open = false;
    final sent = <String>[];
    final subscription = RecordingSubscription(
      send: (message) async {
        sent.add(message);
      },
      isOpen: () => open,
    );
    subscription.request(true);
    expect(sent, isEmpty);
    open = true;
    subscription.opened();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(sent.length, 5);
    expect(subscription.exhausted, isTrue);
    subscription.request(true);
    subscription.close();
    await tester.pump(const Duration(seconds: 10));
    expect(sent.length, 6);
  });
}
