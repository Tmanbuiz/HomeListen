import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:home_listen/core/guardian_settings.dart';
import 'package:home_listen/core/home_monitor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('turning sound off keeps recording paused after a restart', () async {
    final settings = GuardianSettings(
      rules: {'crying': const SoundRule(minimumSeconds: 30, recordAudio: true)},
    );
    SharedPreferences.setMockInitialValues({
      'device_role': 'away',
      'connection_mode': 'cloud',
      'guardian_settings': settings.encode(),
    });
    final prefs = await SharedPreferences.getInstance();
    final first = HomeMonitor(prefs: prefs);
    expect(first.recordingArmed, isTrue);
    await first.setSoundEnabled(false);
    expect(first.recordingArmed, isFalse);
    first.dispose();

    final restarted = HomeMonitor(prefs: prefs);
    expect(restarted.recordingArmed, isFalse);
    await restarted.setSoundRule(
      'crying',
      restarted.guardianSettings.rules['crying']!.copyWith(minimumSeconds: 60),
    );
    expect(restarted.recordingArmed, isFalse);
    await restarted.setSoundRule(
      'crying',
      restarted.guardianSettings.rules['crying']!.copyWith(recordAudio: false),
    );
    await restarted.setSoundRule(
      'crying',
      restarted.guardianSettings.rules['crying']!.copyWith(recordAudio: true),
    );
    expect(restarted.recordingArmed, isTrue);
    restarted.dispose();
  });
}
