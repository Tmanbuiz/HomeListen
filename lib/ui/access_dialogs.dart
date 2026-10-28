import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/cloud_connection.dart' show CloudMember;
import '../core/home_monitor.dart';
import 'design.dart';

/// Screens for who can get into this home: the connected-devices list with
/// per-phone Revoke, the authenticator setup, the secret answer, and the
/// no-link join. Kept out of the main page file so each can be read on its own.

Future<bool?> confirmAction(BuildContext context, String title, String text) =>
    showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );

String formatWhen(DateTime time) {
  final local = time.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final suffix = local.hour < 12 ? 'am' : 'pm';
  return '${local.day}/${local.month} • $hour:${local.minute.toString().padLeft(2, '0')}$suffix';
}

/// The phones paired to this home, each with its own Revoke button. Revoking
/// one leaves the others and the pairing codes alone.
class ConnectedDevices extends StatefulWidget {
  const ConnectedDevices({super.key, required this.monitor});
  final HomeMonitor monitor;
  @override
  State<ConnectedDevices> createState() => _ConnectedDevicesState();
}

class _ConnectedDevicesState extends State<ConnectedDevices> {
  List<CloudMember>? _members;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await widget.monitor.connectedDevices();
    if (!mounted) return;
    setState(() {
      _members = list;
      _loading = false;
    });
  }

  Future<void> _revoke(CloudMember member) async {
    final sure = await confirmAction(
      context,
      'Revoke ${member.label}?',
      'This phone is disconnected and can no longer listen. It can only come back with a new pairing code.',
    );
    if (sure != true) return;
    final error = await widget.monitor.revokeDevice(member.uid);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
    await _load();
  }

  Future<void> _access(CloudMember member) async {
    var role = member.role;
    var hours = 24;
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: Text('Access for ${member.label}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Only the home phone can change access.'),
                const SizedBox(height: 12),
                for (final entry in {
                  'caregiver': 'Caregiver · live audio and alerts',
                  'alerts': 'Alerts only · no live audio',
                  'guest': 'Temporary guest · live audio and alerts',
                }.entries)
                  ChoiceChip(
                    label: Text(entry.value),
                    selected: role == entry.key,
                    onSelected: (_) => change(() => role = entry.key),
                  ),
                if (role == 'guest') ...[
                  const SizedBox(height: 16),
                  const Text('Access ends after'),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final value in [1, 24, 168])
                        ChoiceChip(
                          label: Text(
                            value == 1
                                ? '1 hour'
                                : value == 24
                                ? '1 day'
                                : '7 days',
                          ),
                          selected: hours == value,
                          onSelected: (_) => change(() => hours = value),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save access'),
            ),
          ],
        ),
      ),
    );
    if (save != true) return;
    final error = await widget.monitor.setDeviceAccess(
      member.uid,
      role,
      role == 'guest' ? DateTime.now().add(Duration(hours: hours)) : null,
    );
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final members = _members;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.devices_outlined),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Connected devices',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (_loading && members == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            )
          else if (members == null)
            const Text('Could not load the list. Check your connection.')
          else if (members.isEmpty)
            const Text('No listening phones are paired yet.')
          else
            for (final member in members)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  member.listening ? Icons.headphones : Icons.smartphone,
                ),
                title: Text(member.label),
                subtitle: Text(
                  [
                    if (member.listening) 'Listening now',
                    member.role == 'alerts'
                        ? 'Alerts only'
                        : member.role == 'guest'
                        ? 'Temporary guest'
                        : 'Caregiver',
                    if (member.expiresAt != null)
                      'Ends ${formatWhen(member.expiresAt!)}',
                    if (member.joinedAt != null)
                      'Paired ${formatWhen(member.joinedAt!)}',
                  ].join(' • '),
                ),
                trailing: PopupMenuButton<String>(
                  tooltip: 'Device access',
                  onSelected: (value) =>
                      value == 'access' ? _access(member) : _revoke(member),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'access',
                      child: Text('Change access'),
                    ),
                    PopupMenuItem(value: 'revoke', child: Text('Revoke')),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// The way in without a link: the home's secret answer and a current code.
Future<void> joinWithCode(BuildContext context, HomeMonitor monitor) async {
  final answer = TextEditingController();
  final code = TextEditingController();
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Join with a code'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Each code works once. After setup or pairing another device, '
              'wait for the next code. Use automatic date and time on the authenticator phone.',
            ),
            TextField(
              controller: answer,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Secret answer'),
            ),
            TextField(
              controller: code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Authenticator code',
              ),
              onSubmitted: (_) => Navigator.pop(context, true),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Join'),
        ),
      ],
    ),
  );
  final a = answer.text;
  final c = code.text;
  answer.dispose();
  code.dispose();
  if (go != true) return;
  final ok = await monitor.pairWithCode(a, c);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(monitor.error ?? 'That answer or code is not right.'),
      ),
    );
  }
}

/// Asks for the 6-digit code an authenticator app is showing. Null if cancelled.
Future<String?> askCode(BuildContext context, String message) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Authenticator code'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(hintText: '123456'),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result == null || result.length != 6 ? null : result;
}

/// Turning the authenticator on: shows the QR code and key for the app, then
/// asks for one code from it, so protection is never enabled with a secret the
/// owner failed to save.
Future<void> setUpAuthenticator(
  BuildContext context,
  HomeMonitor monitor,
) async {
  final setup = await monitor.startAuthenticator();
  if (setup == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(monitor.error ?? 'Could not start setup.')),
      );
    }
    return;
  }
  if (!context.mounted) return;
  final controller = TextEditingController();
  String? problem;
  var busy = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Set up authenticator'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Scan this with Google Authenticator, Microsoft Authenticator or Authy. Then type the 6-digit code it shows.',
              ),
              const SizedBox(height: 12),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(data: setup.uri, size: 180),
              ),
              const SizedBox(height: 8),
              const Text(
                'Or enter this key by hand:',
                style: TextStyle(fontSize: 12),
              ),
              SelectableText(
                setup.secret,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  hintText: '123456',
                  errorText: problem,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() {
                      busy = true;
                      problem = null;
                    });
                    final error = await monitor.confirmAuthenticator(
                      controller.text,
                    );
                    if (!context.mounted) return;
                    if (error == null) {
                      Navigator.pop(context);
                    } else {
                      setState(() {
                        busy = false;
                        problem = error;
                      });
                    }
                  },
            child: const Text('Turn on'),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
  if (monitor.authenticatorOn && context.mounted) {
    await changeAnswer(context, monitor);
  }
}

/// The secret answer for joining without a link. Separate from the
/// authenticator, so it can be changed whenever wanted. Empty removes it.
Future<void> changeAnswer(BuildContext context, HomeMonitor monitor) async {
  final info = await monitor.answerInfo();
  if (info == null || !context.mounted) return;
  final question = TextEditingController(text: info.question ?? '');
  final answer = TextEditingController();
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Secret answer'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              info.hasAnswer
                  ? 'A new phone can join with this answer and a code from your authenticator app. Type a new answer to change it.'
                  : 'Pick an answer only you know. A new phone can then join with it and a code from your authenticator app, without a link.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: question,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: 'Question (a reminder, shown only here)',
              ),
            ),
            TextField(
              controller: answer,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'New secret answer'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (info.hasAnswer)
          TextButton(
            onPressed: () => Navigator.pop(context, 'remove'),
            child: const Text('Remove answer'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context, 'save'),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  final asked = question.text;
  final given = answer.text;
  question.dispose();
  answer.dispose();
  if (choice == null) return;
  final error = await monitor.setAnswer(asked, choice == 'remove' ? '' : given);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error ??
              (choice == 'remove'
                  ? 'Secret answer removed.'
                  : 'Secret answer saved.'),
        ),
      ),
    );
  }
}
