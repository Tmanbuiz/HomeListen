import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/home_monitor.dart';
import 'package:home_listen/ui/smart_home_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('smart home setup fits a small phone with enlarged text', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'device_role': 'home'});
    final monitor = HomeMonitor(prefs: await SharedPreferences.getInstance());
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(MaterialApp(home: SmartHomePage(monitor: monitor)));
    expect(find.text('Home Assistant & Matter'), findsOneWidget);
    expect(tester.takeException(), isNull);
    for (final label in [
      'Broker password',
      'Save connection',
      'House mode',
      'Matter devices',
      'Open Home Assistant',
    ]) {
      await tester.scrollUntilVisible(
        find.text(label),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: label);
    }
    await tester.tap(find.text('Open Home Assistant'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    monitor.dispose();
    await tester.pump();
  });
}
