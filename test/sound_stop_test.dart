import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/activity_event.dart';
import 'package:home_listen/core/home_monitor.dart';
import 'package:home_listen/core/sound_watch.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Stop rejects late detector results and PCM before teardown finishes',
    () async {
      SharedPreferences.setMockInitialValues({'device_role': 'home'});
      final prefs = await SharedPreferences.getInstance();
      final monitor = HomeMonitor(prefs: prefs);
      addTearDown(monitor.dispose);
      monitor.soundWatch.enabled = true;
      monitor.soundWatch.feed(Int16List(320));
      expect(monitor.soundWatch.framesFed, 1);

      final stopping = monitor.stop();
      expect(monitor.soundWatch.framesFed, 0);
      final at = DateTime.now();
      monitor.processPcmForTest(Int16List(320));
      monitor.soundWatch.onVerdict?.call(
        const SoundVerdict('crying', 'Baby cry, infant cry', .8, .8),
        at,
      );
      monitor.soundWatch.onDetection?.call(
        SoundDetection('crying', at, .8, 30000),
      );

      expect(monitor.soundWatch.framesFed, 0);
      expect(
        monitor.events.where((e) => e.kind == ActivityKind.sound),
        isEmpty,
      );
      expect(monitor.queuedAlertCount, 0);
      await stopping;
    },
  );
}
