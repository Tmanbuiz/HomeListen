import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:home_listen/core/episode_recordings.dart';
import 'package:home_listen/core/guardian_settings.dart';
import 'package:home_listen/core/home_monitor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'restoring a thirty-day setting preserves older recordings on first load',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'home_recording_retention_',
      );
      final old = DateTime.now().subtract(const Duration(days: 10));
      final writer = EpisodeRecordings(
        directory: () async => root,
        clock: () => old,
      );
      writer.feed(Int16List(16000));
      writer.observe('crying', old, minimumSeconds: 0, recordAudio: true);
      await writer.drain();
      await writer.stop();
      final clip = writer.clips.single;

      const channel = MethodChannel(HomeMonitor.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async =>
                call.method == 'recordingsDirectory' ? root.path : null,
          );
      SharedPreferences.setMockInitialValues({
        'device_role': 'away',
        'guardian_settings': GuardianSettings(retentionDays: 30).encode(),
      });
      final monitor = HomeMonitor(prefs: await SharedPreferences.getInstance());
      try {
        await monitor.loadRecordings();
        expect(monitor.recordingClips, hasLength(1));
        expect(await File(clip.path).exists(), isTrue);
        await monitor.setRetentionDays(1);
        expect(monitor.recordingClips, isEmpty);
        expect(await File(clip.path).exists(), isFalse);
      } finally {
        monitor.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await root.delete(recursive: true);
      }
    },
  );
}
