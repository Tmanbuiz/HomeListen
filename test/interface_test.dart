import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/main.dart';
import 'package:home_listen/core/home_monitor.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const recordingChannel = MethodChannel(HomeMonitor.channelName);
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recordingChannel, (call) async {
          if (call.method == 'recordingsDirectory') {
            throw PlatformException(code: 'recordings_test_unavailable');
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recordingChannel, null);
  });
  testWidgets('Guardian controls fit a small home phone with enlarged text', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'device_role': 'home',
      'connection_mode': 'tailscale',
    });
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(HomeListenApp(prefs: prefs));
    expect(find.text('Share this room'), findsWidgets);
    expect(find.text('Guard this room'), findsNothing);
    await tester.tap(find.text('Guardian').first);
    await tester.pumpAndSettle();
    expect(find.text('Guard this room'), findsOneWidget);
    expect(prefs.getBool('guardian_only'), isTrue);
    expect(tester.takeException(), isNull);
    for (final label in ['Activity', 'Settings']) {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.scrollUntilVisible(find.text('Guardian rules'), 250);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  testWidgets(
    'setup and all navigation tabs fit a small phone with enlarged text',
    (tester) async {
      SharedPreferences.setMockInitialValues({'connection_mode': 'cloud'});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(HomeListenApp(prefs: prefs));
      expect(find.text('A little closer to home.'), findsOneWidget);
      await tester.tap(find.text('I’ll listen on this phone'));
      await tester.pumpAndSettle();
      expect(find.text('Your home'), findsOneWidget);
      expect(tester.takeException(), isNull);
      for (final label in ['Activity', 'Devices', 'Settings']) {
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(label),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('Configure connection'));
      await tester.pumpAndSettle();
      expect(find.text('Home Listen server'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
