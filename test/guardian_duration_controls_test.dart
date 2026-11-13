import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/guardian_settings.dart';
import 'package:home_listen/core/home_monitor.dart';
import 'package:home_listen/ui/guardian_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(HomeMonitor.channelName);

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'recordingsDirectory') {
            throw PlatformException(code: 'recordings_test_unavailable');
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<HomeMonitor> mount(
    WidgetTester tester,
    Map<String, Object> values,
  ) async {
    SharedPreferences.setMockInitialValues(values);
    final prefs = await SharedPreferences.getInstance();
    final monitor = HomeMonitor(prefs: prefs);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: monitor,
              builder: (context, _) => GuardianSettingsCard(monitor: monitor),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      monitor.dispose();
      await tester.pump();
    });
    return monitor;
  }

  Map<String, Object> oldCough() => {
    'device_role': 'home',
    'guardian_settings': jsonEncode({
      'version': 2,
      'rules': {
        'coughing': {'minimumSeconds': 8, 'recordAudio': true},
      },
    }),
  };

  testWidgets('old cough timing can be corrected before expanding its rules', (
    tester,
  ) async {
    final monitor = await mount(tester, oldCough());
    expect(find.text('Review cough alert timing'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('use-two-cough-alerts')));
    await tester.pumpAndSettle();
    final cough = monitor.guardianSettings.rules['coughing']!;
    expect(cough.minimumSeconds, 0);
    expect(cough.recordingMinimumSeconds, 8);
    expect(cough.recordAudio, isTrue);
    expect(cough.durationNeedsReview, isFalse);
    expect(find.text('Review cough alert timing'), findsNothing);
    final saved = GuardianSettings.restore(
      monitor.prefs!.getString('guardian_settings'),
    );
    expect(saved.rules['coughing']!.durationNeedsReview, isFalse);
  });

  testWidgets('an intentional eight-second cough rule can be confirmed', (
    tester,
  ) async {
    final monitor = await mount(tester, oldCough());
    await tester.tap(find.byKey(const ValueKey('keep-cough-duration')));
    await tester.pumpAndSettle();
    expect(monitor.guardianSettings.rules['coughing']!.minimumSeconds, 8);
    expect(find.text('Review cough alert timing'), findsNothing);
    expect(
      GuardianSettings.restore(monitor.prefs!.getString('guardian_settings'))
          .rules['coughing']!
          .durationNeedsReview,
      isFalse,
    );
  });

  testWidgets(
    'receiver duration controls change recordings without alert rules',
    (tester) async {
      final monitor = await mount(tester, {'device_role': 'away'});
      await tester.tap(find.text('Coughing'));
      await tester.pumpAndSettle();
      final tile = find.ancestor(
        of: find.text('Coughing'),
        matching: find.byType(ExpansionTile),
      );
      final duration = find.descendant(
        of: tile,
        matching: find.widgetWithText(ChoiceChip, '15s'),
      );
      await tester.ensureVisible(duration);
      await tester.tap(duration);
      await tester.pumpAndSettle();
      final cough = monitor.guardianSettings.rules['coughing']!;
      expect(cough.minimumSeconds, 0);
      expect(cough.recordingMinimumSeconds, 15);
      expect(cough.recordAudio, isFalse);
    },
  );
}
