import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/away_room_invite.dart';

Future<void> showAwayRoomInviteDialog(
  BuildContext context, {
  required AwayRoomInviteController controller,
  required Future<bool> Function(String) shareLink,
}) async {
  try {
    await showDialog<void>(
      context: context,
      builder: (_) =>
          AwayRoomInviteDialog(controller: controller, shareLink: shareLink),
    );
  } finally {
    controller.dispose();
  }
}

/// A scrollable dialog keeps QR, expiry and actions reachable with large text.
class AwayRoomInviteDialog extends StatefulWidget {
  const AwayRoomInviteDialog({
    super.key,
    required this.controller,
    required this.shareLink,
    this.copyLink,
  });

  final AwayRoomInviteController controller;
  final Future<bool> Function(String) shareLink;
  final Future<void> Function(String)? copyLink;

  @override
  State<AwayRoomInviteDialog> createState() => _AwayRoomInviteDialogState();
}

class _AwayRoomInviteDialogState extends State<AwayRoomInviteDialog> {
  String? _feedback;
  bool _sharing = false, _copying = false, _closing = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    if (widget.controller.invalidated) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
    }
  }

  void _changed() {
    if (!mounted) return;
    if (widget.controller.invalidated && !_closing) {
      _closing = true;
      _feedback = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).pop();
        }
      });
    }
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  Future<void> _generate() async {
    setState(() => _feedback = null);
    await widget.controller.generate();
  }

  Future<void> _copy() async {
    final controller = widget.controller;
    if (_copying || !controller.validate()) return;
    final invite = controller.invite;
    if (invite == null) return;
    setState(() {
      _copying = true;
      _feedback = null;
    });
    String feedback;
    try {
      if (widget.copyLink != null) {
        await widget.copyLink!(invite.code);
      } else {
        await Clipboard.setData(ClipboardData(text: invite.code));
      }
      feedback = 'Pairing link copied.';
    } catch (_) {
      feedback = 'Could not copy the link. Scan the QR code instead.';
    }
    if (!mounted) return;
    final current =
        controller.validate() && identical(controller.invite, invite);
    setState(() {
      _copying = false;
      _feedback = current ? feedback : null;
    });
  }

  Future<void> _share() async {
    final controller = widget.controller;
    if (_sharing || !controller.validate()) return;
    final invite = controller.invite;
    if (invite == null) return;
    setState(() {
      _sharing = true;
      _feedback = null;
    });
    String? feedback;
    try {
      await widget.shareLink(invite.code);
    } catch (_) {
      feedback = 'Sharing is unavailable. Copy the link or scan the QR code.';
    }
    if (!mounted) return;
    final current =
        controller.validate() && identical(controller.invite, invite);
    setState(() {
      _sharing = false;
      _feedback = current ? feedback : null;
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller;
    final invite = state.invite;
    final working = state.generating || _sharing || _copying;
    final localExpiry = invite?.expiresAt.toLocal();
    final expiryText = localExpiry == null
        ? null
        : MaterialLocalizations.of(context).formatTimeOfDay(
            TimeOfDay.fromDateTime(localExpiry),
            alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
          );
    return AlertDialog(
      title: const Text('Invite another phone'),
      content: SizedBox(
        width: 280,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Room: ${state.room.name}',
                key: const ValueKey('away-invite-room'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              if (state.invalidated)
                const Text('Room access changed. Open the selected room again.')
              else ...[
                if (invite != null) ...[
                  LayoutBuilder(
                    builder: (context, constraints) => Center(
                      child: Container(
                        color: Colors.white,
                        padding: const EdgeInsets.all(12),
                        child: QrImageView(
                          key: const ValueKey('away-invite-qr'),
                          data: invite.code,
                          size: (constraints.maxWidth - 24)
                              .clamp(0, 200)
                              .toDouble(),
                          semanticsLabel: 'Pairing code for ${state.room.name}',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Expires at $expiryText · one use',
                    key: const ValueKey('away-invite-expiry'),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'On the other phone, scan in Devices or open the shared link.',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const ValueKey('copy-away-invite'),
                    onPressed: working ? null : _copy,
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy link'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('share-away-invite'),
                    onPressed: working ? null : _share,
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Share link'),
                  ),
                ] else if (state.expired) ...[
                  const Text(
                    'This code expired. Create a new code to invite another phone.',
                  ),
                  const SizedBox(height: 12),
                ],
                if (state.error != null) ...[
                  Text(
                    state.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_feedback != null) ...[
                  Text(_feedback!, key: const ValueKey('away-invite-feedback')),
                  const SizedBox(height: 12),
                ],
                const Text(
                  'Keep this code private. It lets one phone join this room within 10 minutes. Creating a new code replaces your previous unused code for this room. Logging this phone out cancels its unused code.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const ValueKey('generate-away-invite'),
                  onPressed: working ? null : _generate,
                  icon: state.generating
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.qr_code_2),
                  label: Text(
                    state.generating
                        ? 'Creating code…'
                        : invite == null
                        ? 'Create pairing code'
                        : 'Create new code',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
