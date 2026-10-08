import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/home_monitor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('audio chunks scroll the level meter instead of throwing', () async {
    // Regression: the meter list was fixed-length, so the first chunk of real
    // audio threw. On the listening phone that ran before playback and left
    // it silent; on the home phone it threw on every microphone chunk.
    final monitor = HomeMonitor();
    addTearDown(monitor.dispose);

    final loud = Int16List.fromList(List.filled(320, 12000));
    monitor.processPcmForTest(loud);
    expect(monitor.levels.length, 36);
    expect(monitor.levels.last, greaterThan(0.03));

    // Later chunks keep working once the update throttle has passed.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    monitor.processPcmForTest(loud);
    expect(monitor.levels.length, 36);
  });
}
