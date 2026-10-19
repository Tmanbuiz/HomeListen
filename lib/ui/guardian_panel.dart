import 'package:flutter/material.dart';

import '../core/guardian_settings.dart';
import '../core/home_monitor.dart';
import 'design.dart';

class GuardianOverview extends StatelessWidget {
  const GuardianOverview({super.key, required this.monitor});
  final HomeMonitor monitor;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, color: scheme.primary),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Guardian',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              if (monitor.guardianSettings.quietAt(DateTime.now()))
                const Chip(label: Text('Quiet hours')),
            ],
          ),
          const SizedBox(height: 12),
          Text(monitor.todaySummary),
          const SizedBox(height: 12),
          Text(monitor.captureHealth),
          if (monitor.isMonitoring)
            Text(
              monitor.soundWatch.status,
              style: const TextStyle(fontSize: 12),
            ),
          const SizedBox(height: 8),
          Text(
            monitor.guardianConnectionStatus,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          if (monitor.queuedAlertCount > 0) ...[
            const SizedBox(height: 10),
            Text(
              '${monitor.queuedAlertCount} alert(s) waiting to send. Retries end after 15 minutes.',
            ),
            TextButton.icon(
              onPressed: monitor.isMonitoring ? monitor.retryAlerts : null,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry remote alerts'),
            ),
          ],
          const SizedBox(height: 10),
          const Text(
            'Events stay on this phone. Guardian detects selected sounds locally; live audio stays off in Guardian mode.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class HomeModeSelector extends StatelessWidget {
  const HomeModeSelector({super.key, required this.monitor});
  final HomeMonitor monitor;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          ChoiceChip(
            label: const Text('Guardian'),
            selected: monitor.guardianOnly,
            onSelected: monitor.busy
                ? null
                : (_) => monitor.setGuardianOnly(true),
          ),
          ChoiceChip(
            label: const Text('Live + Guardian'),
            selected: !monitor.guardianOnly,
            onSelected: monitor.busy || !monitor.liveHomeAvailable
                ? null
                : (_) => monitor.setGuardianOnly(false),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        monitor.guardianOnly
            ? 'Local sound alerts. Paired phones cannot request live audio.'
            : 'Allow your paired phones to listen while the microphone is on.',
      ),
      const SizedBox(height: 8),
      const Text(
        'Changing mode stops monitoring. Tap Start again on this phone.',
        style: TextStyle(fontSize: 12),
      ),
    ],
  );
}

class GuardianSettingsCard extends StatelessWidget {
  const GuardianSettingsCard({super.key, required this.monitor});
  final HomeMonitor monitor;
  String _clock(BuildContext context, int minute) =>
      TimeOfDay(hour: minute ~/ 60, minute: minute % 60).format(context);
  Future<void> _time(BuildContext context, bool start) async {
    final minute = start
        ? monitor.guardianSettings.quietStart
        : monitor.guardianSettings.quietEnd;
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
    );
    if (selected == null) return;
    await monitor.setQuietHours(
      start: start ? selected.hour * 60 + selected.minute : null,
      end: start ? null : selected.hour * 60 + selected.minute,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = monitor.guardianSettings;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Guardian rules',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          const Text(
            'Tune each sound for this room. Higher scores make alerts more selective; scores are not probabilities.',
          ),
          const SizedBox(height: 12),
          for (final name in guardianCategories)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text(HomeMonitor.soundCategoryLabel(name)),
              subtitle: Text(
                'Hold ${settings.rules[name]!.minimumSeconds}s · repeat after ${settings.rules[name]!.cooldownSeconds}s',
              ),
              children: [
                Text(
                  name == 'loud sound'
                      ? 'Loudness threshold'
                      : 'Minimum model score',
                ),
                Slider(
                  value: settings.rules[name]!.threshold,
                  min: .2,
                  max: .9,
                  divisions: 14,
                  label: settings.rules[name]!.threshold.toStringAsFixed(2),
                  onChanged: (value) => monitor.setSoundRule(
                    name,
                    settings.rules[name]!.copyWith(threshold: value),
                  ),
                ),
                const Text('Minimum duration'),
                Slider(
                  value: settings.rules[name]!.minimumSeconds.toDouble(),
                  min: 0,
                  max: 10,
                  divisions: 10,
                  label: '${settings.rules[name]!.minimumSeconds}s',
                  onChanged: (value) => monitor.setSoundRule(
                    name,
                    settings.rules[name]!.copyWith(
                      minimumSeconds: value.round(),
                    ),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final seconds in [15, 30, 60, 300])
                      ChoiceChip(
                        label: Text(
                          seconds < 60
                              ? '${seconds}s cooldown'
                              : '${seconds ~/ 60}min cooldown',
                        ),
                        selected:
                            settings.rules[name]!.cooldownSeconds == seconds,
                        onSelected: (_) => monitor.setSoundRule(
                          name,
                          settings.rules[name]!.copyWith(
                            cooldownSeconds: seconds,
                          ),
                        ),
                      ),
                  ],
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allow during quiet hours'),
                  value: settings.rules[name]!.duringQuietHours,
                  onChanged: (value) => monitor.setSoundRule(
                    name,
                    settings.rules[name]!.copyWith(duringQuietHours: value),
                  ),
                ),
              ],
            ),
          const Divider(height: 28),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Quiet hours'),
            subtitle: const Text(
              'Pause outgoing sound alerts. Events are still saved; selected sounds can bypass this.',
            ),
            value: settings.quietEnabled,
            onChanged: (value) => monitor.setQuietHours(enabled: value),
          ),
          if (settings.quietEnabled)
            Wrap(
              spacing: 12,
              children: [
                OutlinedButton(
                  onPressed: () => _time(context, true),
                  child: Text('From ${_clock(context, settings.quietStart)}'),
                ),
                OutlinedButton(
                  onPressed: () => _time(context, false),
                  child: Text('Until ${_clock(context, settings.quietEnd)}'),
                ),
              ],
            ),
          const SizedBox(height: 10),
          const Text(
            'Uses this home phone’s local time. Matching start and end times mean no quiet interval.',
            style: TextStyle(fontSize: 12),
          ),
          const Divider(height: 28),
          const Text('Keep event history for'),
          Wrap(
            spacing: 8,
            children: [
              for (final days in [1, 7, 30])
                ChoiceChip(
                  label: Text('$days day${days == 1 ? '' : 's'}'),
                  selected: settings.retentionDays == days,
                  onSelected: (_) => monitor.setRetentionDays(days),
                ),
            ],
          ),
          const Text(
            'At most 500 events are kept. Clearing history also clears waiting alerts.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class SpeechSessionsCard extends StatelessWidget {
  const SpeechSessionsCard({super.key, required this.monitor});
  final HomeMonitor monitor;
  @override
  Widget build(BuildContext context) => SurfaceCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Oralyvo speech sessions',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        const Text(
          'Open Oralyvo in your browser for a separate transcription or translation session. Sign in there and choose its provider settings.',
        ),
        const SizedBox(height: 8),
        const Text(
          'HomeListen does not send Guardian audio to Oralyvo. Provider costs and limits remain those of your Oralyvo account.',
          style: TextStyle(fontSize: 12),
        ),
        TextButton.icon(
          onPressed: monitor.busy
              ? null
              : () async {
                  if (monitor.isMonitoring) {
                    final agreed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text(
                          'Stop monitoring for a speech session?',
                        ),
                        content: const Text(
                          'Monitoring on this phone will stop before Oralyvo opens. Restart monitoring from Home afterward.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Stop and open'),
                          ),
                        ],
                      ),
                    );
                    if (agreed != true) return;
                  }
                  final error = await monitor.openSpeechSession();
                  if (error != null && context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(error)));
                  }
                },
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open Oralyvo'),
        ),
      ],
    ),
  );
}
