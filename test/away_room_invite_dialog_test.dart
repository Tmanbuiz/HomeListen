import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/away_room_invite.dart';
import 'package:home_listen/core/cloud_pairing.dart';
import 'package:home_listen/ui/away_room_invite_dialog.dart';
import 'package:qr_flutter/qr_flutter.dart';

const bedroom = AwayInviteRoom(
  origin: 'https://home.example',
  roomId: 'AAAAAAAAAAAAAAAAAAAAAAAA',
  name: 'Bedroom',
  generation: 4,
);
final now = DateTime.utc(2026, 11, 16, 12);

AwayRoomInvite inviteFor(AwayInviteRoom room, {Duration? lifetime}) =>
    AwayRoomInvite(
      room: room,
      code: CloudPairing(room.origin, room.roomId, 'B' * 43).toCode(),
      expiresAt: now.add(lifetime ?? const Duration(minutes: 10)),
      issuerEpoch: 'membership-first',
    );

Future<void> openDialog(
  WidgetTester tester,
  AwayRoomInviteController controller, {
  Future<void> Function(String)? copy,
  Future<bool> Function(String)? share,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AwayRoomInviteDialog(
                controller: controller,
                copyLink: copy,
                shareLink: share ?? (_) async => true,
              ),
            ),
            child: const Text('Open invite'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open invite'));
  await tester.pumpAndSettle();
}

Future<void> generateCode(WidgetTester tester) async {
  final generate = find.byKey(const ValueKey('generate-away-invite'));
  await tester.ensureVisible(generate);
  await tester.tap(generate);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an invalidated target is closed before any code can be shown', (
    tester,
  ) async {
    var requests = 0;
    final controller = AwayRoomInviteController(
      room: bedroom,
      clock: () => now,
      isCurrent: () => true,
      generate: () async {
        requests++;
        return inviteFor(bedroom);
      },
    )..invalidate();
    addTearDown(controller.dispose);
    await openDialog(tester, controller);
    expect(find.byType(AwayRoomInviteDialog), findsNothing);
    expect(find.byType(QrImageView), findsNothing);
    expect(requests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'QR generation is explicit and copy/share use the captured room link',
    (tester) async {
      var requests = 0;
      final copies = <String>[], shares = <String>[];
      final controller = AwayRoomInviteController(
        room: bedroom,
        clock: () => now,
        isCurrent: () => true,
        generate: () async {
          requests++;
          return inviteFor(bedroom);
        },
      );
      addTearDown(controller.dispose);
      await openDialog(
        tester,
        controller,
        copy: (link) async => copies.add(link),
        share: (link) async {
          shares.add(link);
          return true;
        },
      );
      expect(requests, 0);
      expect(find.text('Room: Bedroom'), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);
      await generateCode(tester);
      expect(requests, 1);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(
        CloudPairing.parse(controller.invite!.code)!.roomId,
        bedroom.roomId,
      );
      expect(find.byKey(const ValueKey('away-invite-expiry')), findsOneWidget);
      final copy = find.byKey(const ValueKey('copy-away-invite'));
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(copies, [controller.invite!.code]);
      expect(find.text('Pairing link copied.'), findsOneWidget);
      final share = find.byKey(const ValueKey('share-away-invite'));
      await tester.ensureVisible(share);
      await tester.tap(share);
      await tester.pumpAndSettle();
      expect(shares, copies);
      expect(requests, 1);
      expect(find.byType(QrImageView), findsOneWidget);
    },
  );

  testWidgets('unavailable OS share preserves QR and copy fallback', (
    tester,
  ) async {
    final copies = <String>[];
    final controller = AwayRoomInviteController(
      room: bedroom,
      clock: () => now,
      isCurrent: () => true,
      generate: () async => inviteFor(bedroom),
    );
    addTearDown(controller.dispose);
    await openDialog(
      tester,
      controller,
      copy: (link) async => copies.add(link),
      share: (_) async => throw MissingPluginException(),
    );
    await generateCode(tester);
    final share = find.byKey(const ValueKey('share-away-invite'));
    await tester.ensureVisible(share);
    await tester.tap(share);
    await tester.pumpAndSettle();
    expect(
      find.text('Sharing is unavailable. Copy the link or scan the QR code.'),
      findsOneWidget,
    );
    expect(find.byType(QrImageView), findsOneWidget);
    final copy = find.byKey(const ValueKey('copy-away-invite'));
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(copies, [controller.invite!.code]);
  });

  testWidgets(
    'expiry clears QR and sharing actions without automatic renewal',
    (tester) async {
      var requests = 0;
      final controller = AwayRoomInviteController(
        room: bedroom,
        clock: () => now,
        isCurrent: () => true,
        generate: () async {
          requests++;
          return inviteFor(bedroom, lifetime: const Duration(seconds: 2));
        },
      );
      addTearDown(controller.dispose);
      await openDialog(tester, controller);
      await generateCode(tester);
      expect(find.byType(QrImageView), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(controller.invite, isNull);
      expect(find.byType(QrImageView), findsNothing);
      expect(find.byKey(const ValueKey('copy-away-invite')), findsNothing);
      expect(find.byKey(const ValueKey('share-away-invite')), findsNothing);
      expect(find.textContaining('This code expired.'), findsOneWidget);
      expect(requests, 1);
    },
  );

  testWidgets(
    'selection/access changes close the dialog and discard a late response',
    (tester) async {
      var current = true;
      final pending = Completer<AwayRoomInvite>();
      final controller = AwayRoomInviteController(
        room: bedroom,
        clock: () => now,
        isCurrent: () => current,
        generate: () => pending.future,
      );
      addTearDown(controller.dispose);
      await openDialog(tester, controller);
      final generate = find.byKey(const ValueKey('generate-away-invite'));
      await tester.ensureVisible(generate);
      await tester.tap(generate);
      await tester.pump();
      expect(controller.generating, isTrue);
      current = false;
      controller.validate();
      await tester.pumpAndSettle();
      expect(find.byType(AwayRoomInviteDialog), findsNothing);
      pending.complete(inviteFor(bedroom));
      await tester.pumpAndSettle();
      expect(controller.invite, isNull);
      expect(find.byType(QrImageView), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dialog is scrollable on a small screen with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    const room = AwayInviteRoom(
      origin: 'https://home.example',
      roomId: 'AAAAAAAAAAAAAAAAAAAAAAAA',
      name: 'Upstairs bedroom near the family living area',
      generation: 4,
    );
    final controller = AwayRoomInviteController(
      room: room,
      clock: () => now,
      isCurrent: () => true,
      generate: () async => inviteFor(room),
    );
    addTearDown(controller.dispose);
    await openDialog(tester, controller, copy: (_) async {});
    await generateCode(tester);
    expect(tester.takeException(), isNull);
    for (final key in [
      'copy-away-invite',
      'share-away-invite',
      'generate-away-invite',
    ]) {
      final button = find.byKey(ValueKey(key));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(AwayRoomInviteDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
