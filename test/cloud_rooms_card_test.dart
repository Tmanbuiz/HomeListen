import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/saved_rooms.dart';
import 'package:home_listen/ui/home_monitor_page.dart';

void main() {
  testWidgets(
    'Home recording control requires live audio and allows stopping after audio loss',
    (tester) async {
      var starts = 0, stops = 0;
      Future<void> show({required bool recording, required bool live}) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: DeviceRecordingControl(
                  recording: recording,
                  canRecord: live,
                  onStart: () async {
                    starts++;
                  },
                  onStop: () async {
                    stops++;
                  },
                ),
              ),
            ),
          );
      await show(recording: false, live: false);
      final button = find.byKey(const ValueKey('home-record-to-device'));
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      await show(recording: false, live: true);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(starts, 1);
      await show(recording: true, live: false);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(stops, 1);
    },
  );

  testWidgets(
    'Home recording control blocks double taps and shows storage errors',
    (tester) async {
      final pending = Completer<void>();
      var starts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DeviceRecordingControl(
              recording: false,
              canRecord: true,
              onStart: () {
                starts++;
                return pending.future;
              },
              onStop: () async {},
            ),
          ),
        ),
      );
      final button = find.byKey(const ValueKey('home-record-to-device'));
      await tester.tap(button);
      await tester.pump();
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      expect(starts, 1);
      pending.completeError(StateError('Storage unavailable'));
      await tester.pumpAndSettle();
      expect(
        find.text('The recording action could not be completed.'),
        findsOneWidget,
      );
    },
  );

  List<SavedCloudRoom> rooms() => [
    SavedCloudRoom(
      roomId: 'bedroom',
      origin: 'https://home.example',
      name: 'Bedroom',
    ),
    SavedCloudRoom(
      roomId: 'kitchen',
      origin: 'https://home.example',
      name: 'Kitchen',
    ),
  ];

  testWidgets('choosing another room only invokes the selection action', (
    tester,
  ) async {
    var selected = 'bedroom';
    final choices = <String>[];
    final logouts = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) => CloudRoomsCard(
                rooms: rooms(),
                selectedRoomId: selected,
                connectedCount: 2,
                statusForRoom: (_) => 'Live connected',
                onSelected: (id) async {
                  choices.add(id);
                  setState(() => selected = id);
                },
                onLogout: (id) async => logouts.add(id),
                onAdd: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('select-cloud-room-kitchen')));
    await tester.pumpAndSettle();
    expect(choices, ['kitchen']);
    expect(logouts, isEmpty);
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('select-cloud-room-kitchen')),
          )
          .selected,
      isTrue,
    );
    expect(find.text('2 saved rooms · 2 live connections'), findsOneWidget);
    expect(
      find.textContaining('Optional recordings use the selected room only.'),
      findsOneWidget,
    );
  });

  testWidgets('logout confirms this phone and names only its target room', (
    tester,
  ) async {
    final logouts = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CloudRoomsCard(
              rooms: rooms(),
              selectedRoomId: 'bedroom',
              connectedCount: 2,
              statusForRoom: (_) => 'Live connected',
              onSelected: (_) async {},
              onLogout: (id) async => logouts.add(id),
              onAdd: () {},
            ),
          ),
        ),
      ),
    );
    final logout = find.byKey(const ValueKey('logout-cloud-room-bedroom'));
    await tester.tap(logout);
    await tester.pumpAndSettle();
    expect(find.text('Log out of Bedroom?'), findsOneWidget);
    expect(
      find.textContaining(
        'Your other saved rooms and every other device stay connected.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(logouts, isEmpty);
    await tester.tap(logout);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(logouts, ['bedroom']);
    expect(find.text('Kitchen'), findsOneWidget);
  });

  testWidgets('room names fit a small screen and Add room remains available', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    var additions = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CloudRoomsCard(
              rooms: [
                SavedCloudRoom(
                  roomId: 'long',
                  origin: 'https://home.example',
                  name: 'Upstairs bedroom near the family living area',
                ),
              ],
              selectedRoomId: 'long',
              connectedCount: 0,
              statusForRoom: (_) =>
                  'Home offline · reconnecting when available',
              onSelected: (_) async {},
              onLogout: (_) async {},
              onAdd: () => additions++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final add = find.byKey(const ValueKey('add-cloud-room'));
    await tester.ensureVisible(add);
    await tester.tap(add);
    expect(additions, 1);
  });
}
