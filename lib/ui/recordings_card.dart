import 'dart:async';

import 'package:flutter/material.dart';

import '../core/episode_recordings.dart';
import '../core/home_monitor.dart';
import 'design.dart';

/// Clips belong to the receiving device, never to the remote home phone.
class RecordingsCard extends StatefulWidget {
  const RecordingsCard({super.key, required this.monitor});

  final HomeMonitor monitor;

  @override
  State<RecordingsCard> createState() => _RecordingsCardState();
}

class _RecordingsCardState extends State<RecordingsCard> {
  bool _loading = true;
  bool _busy = false;
  bool _showAll = false;
  String? _loadProblem;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant RecordingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.monitor != widget.monitor) {
      _loading = true;
      _loadProblem = null;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final monitor = widget.monitor;
    try {
      await monitor.loadRecordings();
    } catch (_) {
      if (mounted && identical(monitor, widget.monitor)) {
        _loadProblem = 'The recording list could not be opened. Try again.';
      }
    } finally {
      if (mounted && identical(monitor, widget.monitor)) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The recording action could not be completed.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ) ??
      false;

  String _duration(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  String _time(BuildContext context, DateTime at) {
    final local = at.toLocal();
    return '${MaterialLocalizations.of(context).formatMediumDate(local)} · '
        '${TimeOfDay.fromDateTime(local).format(context)}';
  }

  Widget _clip(BuildContext context, RecordingClip clip) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(clip.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
          '${HomeMonitor.soundCategoryLabel(clip.category)} · '
          '${_duration(clip.durationMs)} · ${_time(context, clip.startedAt)}',
          style: const TextStyle(fontSize: 12),
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => _action(() async {
                      final message = await widget.monitor.exportRecording(
                        clip,
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(message)));
                    }),
              icon: const Icon(Icons.ios_share_outlined),
              label: const Text('Save / share audio'),
            ),
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      final agreed = await _confirm(
                        'Delete this recording?',
                        'Delete ${clip.name} from this device? Copies already exported will remain.',
                      );
                      if (agreed && mounted) {
                        await _action(
                          () => widget.monitor.deleteRecording(clip),
                        );
                      }
                    },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete'),
            ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.monitor,
    builder: (context, _) {
      final monitor = widget.monitor;
      final clips = monitor.recordingClips;
      final problem = _loadProblem ?? monitor.recordingProblem;
      return SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Receiving-device recordings',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            const Text(
              'Tick “Record this alert on this phone” in sound rules, then keep live listening connected. Audio is saved only on this receiving device, never uploaded to HomeListen or saved on the home phone.',
            ),
            if (monitor.recordingAudio || monitor.bufferingRecording) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    monitor.recordingAudio
                        ? Icons.fiber_manual_record
                        : Icons.hourglass_top,
                    size: 18,
                    color: monitor.recordingAudio
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      monitor.recordingAudio
                          ? 'Recording the detected sound. The clip appears here when the episode ends.'
                          : 'Buffering an opted-in sound until it reaches the alert duration. Short episodes are discarded.',
                    ),
                  ),
                ],
              ),
            ],
            if (!monitor.recordingAudio && !monitor.bufferingRecording) ...[
              const SizedBox(height: 10),
              Text(monitor.recordingStatus),
            ],
            if (problem != null) ...[
              const SizedBox(height: 10),
              Text(
                problem,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              TextButton(
                onPressed: _loading || _busy
                    ? null
                    : () {
                        setState(() {
                          _loading = true;
                          _loadProblem = null;
                        });
                        unawaited(_load());
                      },
                child: const Text('Refresh recordings'),
              ),
            ],
            const SizedBox(height: 10),
            if (_loading)
              const LinearProgressIndicator()
            else if (clips.isEmpty)
              const Text('No saved audio clips yet.')
            else ...[
              for (final clip in _showAll ? clips : clips.take(10))
                _clip(context, clip),
              if (clips.length > 10)
                TextButton(
                  onPressed: () => setState(() => _showAll = !_showAll),
                  child: Text(
                    _showAll
                        ? 'Show fewer'
                        : 'Show all ${clips.length} recordings',
                  ),
                ),
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        final agreed = await _confirm(
                          'Delete all recordings?',
                          'Delete all audio clips and discard the current recording buffer on this device? Copies already exported will remain.',
                        );
                        if (agreed && mounted) {
                          await _action(widget.monitor.clearRecordings);
                        }
                      },
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Delete all recordings'),
              ),
            ],
            const Divider(height: 24),
            Text(
              'Kept for ${monitor.guardianSettings.retentionDays} days, up to 100 clips or 200 MB. Long episodes split into 10-minute clips. Use Save / share audio to export a WAV file for playback in another app.',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      );
    },
  );
}
