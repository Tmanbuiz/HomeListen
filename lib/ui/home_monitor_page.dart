import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/activity_event.dart';
import '../core/home_monitor.dart';
import '../core/pairing.dart';
import '../core/cloud_pairing.dart';
import '../protocols/mic_monitor.dart';
import 'design.dart';

class HomeMonitorPage extends StatefulWidget {
  const HomeMonitorPage({super.key});
  @override
  State<HomeMonitorPage> createState() => _HomeMonitorPageState();
}

class _HomeMonitorPageState extends State<HomeMonitorPage> {
  int _tab = 0;
  @override
  Widget build(BuildContext context) {
    final monitor = context.watch<HomeMonitor>();
    final color = Theme.of(context).colorScheme;
    if (monitor.needsSetup) return _Setup(monitor: monitor);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const HomeListenMark(size: 30),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Home Listen',
                    maxLines: 1,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    monitor.deviceRole == DeviceRole.home
                        ? 'Home phone'
                        : 'Listening phone',
                    style: TextStyle(fontSize: 11, color: color.primary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
              children: [
                if (monitor.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: SurfaceCard(
                      borderColor: color.error,
                      padding: 14,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, color: color.error),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              monitor.error!,
                              style: TextStyle(color: color.error),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Dismiss',
                            onPressed: monitor.clearError,
                            icon: const Icon(Icons.close, size: 18),
                          ),
                        ],
                      ),
                    ),
                  ),
                switch (_tab) {
                  0 => _Dashboard(
                    monitor: monitor,
                    onActivity: () => setState(() => _tab = 1),
                  ),
                  1 => _Activity(monitor: monitor),
                  2 => _Devices(monitor: monitor),
                  _ => _Settings(monitor: monitor),
                },
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.graphic_eq),
            label: 'Activity',
          ),
          NavigationDestination(
            icon: Icon(Icons.devices_outlined),
            label: 'Devices',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class _Setup extends StatelessWidget {
  const _Setup({required this.monitor});
  final HomeMonitor monitor;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(28),
            children: [
              const Center(child: HomeListenMark(size: 110, tile: true)),
              const SizedBox(height: 28),
              Text(
                'A little closer to home.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Text(
                'Share sound from a phone at home with the phone you carry. Start by choosing this phone’s role.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: () => monitor.selectDeviceRole(DeviceRole.home),
                icon: const Icon(Icons.home_outlined),
                label: const Text('This phone stays at home'),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () => monitor.selectDeviceRole(DeviceRole.away),
                icon: const Icon(Icons.headphones_outlined),
                label: const Text('I’ll listen on this phone'),
              ),
              const SizedBox(height: 28),
              const Text(
                'Choose Cloud or Tailscale in Settings, then pair with a QR code. Microphone sharing starts only when you turn it on at home.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Dashboard extends StatelessWidget {
  const _Dashboard({required this.monitor, required this.onActivity});
  final HomeMonitor monitor;
  final VoidCallback onActivity;
  @override
  Widget build(BuildContext context) {
    final home = monitor.deviceRole == DeviceRole.home;
    final scheme = Theme.of(context).colorScheme;
    final on = home
        ? monitor.isTalking
        : monitor.isListening || monitor.isWatching;
    final state = home
        ? (on ? 'Microphone ON' : 'Microphone off')
        : (monitor.listenerIsHearing
              ? 'Audio arriving now'
              : monitor.isWatching
              ? 'Watching for alerts'
              : monitor.isListening
              ? 'Connected • waiting for audio'
              : monitor.reconnecting
              ? 'Reconnecting to home'
              : monitor.searching
              ? 'Looking for your home phone'
              : !monitor.hasPairing
              ? 'Pair your home phone'
              : 'Ready to listen');
    final stateColor = home && on
        ? scheme.error
        : monitor.listenerIsHearing
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(
          home ? 'Share this room' : 'Your home',
          home
              ? 'Your microphone, under your control.'
              : 'Hear what’s happening in your room.',
        ),
        const SizedBox(height: 22),
        SurfaceCard(
          padding: 16,
          child: Row(
            children: [
              Icon(Icons.bed_outlined, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  monitor.displayRoom,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (home)
                IconButton(
                  tooltip: 'Rename room',
                  onPressed: () => _rename(context, monitor),
                  icon: const Icon(Icons.edit_outlined, size: 20),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: stateColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                state,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: stateColor,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          home
              ? (on
                    ? monitor.talkerHasListener
                          ? (monitor.talkerListenerCount > 1
                                ? 'Sharing with ${monitor.talkerListenerCount} listening phones'
                                : 'Sharing with your paired listening phone')
                          : monitor.talkerWatcherCount > 0
                          ? 'Watching for alerts: ${monitor.talkerWatcherCount} phone${monitor.talkerWatcherCount == 1 ? '' : 's'} • nobody is listening yet'
                          : 'Waiting for your listening phone to connect'
                    : 'Turn on sharing when this phone is in the room.')
              : (monitor.remoteBattery == null
                    ? 'Home phone status appears after connection.'
                    : 'Home phone: ${_batteryText(monitor.remoteBattery, monitor.remoteCharging)}'),
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 22),
        if (home)
          Center(
            child: Container(
              width: 148,
              height: 148,
              margin: const EdgeInsets.only(bottom: 24),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (on ? scheme.error : scheme.primary).withValues(
                  alpha: .07,
                ),
                border: Border.all(
                  color: (on ? scheme.error : scheme.primary).withValues(
                    alpha: .5,
                  ),
                  width: 2,
                ),
              ),
              child: Icon(
                on ? Icons.mic : Icons.mic_off_outlined,
                size: 60,
                color: on ? scheme.error : scheme.primary,
              ),
            ),
          )
        else
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Sound activity',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                SoundWave(
                  levels: monitor.levels,
                  active: monitor.listenerIsHearing,
                ),
                Text(
                  monitor.listenerIsHearing
                      ? 'Live sound from your home phone'
                      : monitor.isWatching
                      ? 'Alerts only — no audio is playing'
                      : 'No live audio',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        if (!home) const SizedBox(height: 18),
        if (!home && !monitor.hasPairing)
          FilledButton.icon(
            onPressed: monitor.busy ? null : () => _scan(context, monitor),
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan home phone’s code'),
          )
        else
          FilledButton.icon(
            style: home && on
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            onPressed: monitor.busy
                ? null
                : on
                ? monitor.stop
                : home
                ? monitor.startTalking
                : monitor.startListening,
            icon: monitor.busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    on
                        ? Icons.stop_rounded
                        : home
                        ? Icons.mic
                        : Icons.headphones,
                  ),
            label: Text(
              monitor.busy
                  ? home
                        ? 'Starting sharing…'
                        : 'Connecting…'
                  : on
                  ? home
                        ? 'Turn microphone off'
                        : monitor.isWatching
                        ? 'Stop watching'
                        : 'Stop listening'
                  : home
                  ? 'Share this room'
                  : 'Listen to home',
            ),
          ),
        if (!home && monitor.hasPairing && !on && !monitor.busy)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: monitor.startWatching,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Alerts only — no sound'),
            ),
          ),
        if (!home && monitor.hasPairing && on)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.headphones),
                  label: Text('Listen'),
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.notifications_active_outlined),
                  label: Text('Alerts only'),
                ),
              ],
              selected: {monitor.isWatching},
              onSelectionChanged: monitor.busy
                  ? null
                  : (selection) =>
                        monitor.switchMode(alertsOnly: selection.first),
            ),
          ),
        if (monitor.busy || monitor.reconnecting)
          TextButton(
            onPressed: monitor.stop,
            child: const Text('Cancel connection'),
          ),
        const SizedBox(height: 12),
        if (home)
          OutlinedButton.icon(
            onPressed: () => _showPairingCode(context, monitor),
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Pair another phone'),
          )
        else
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _volumeSheet(context, monitor),
                  icon: Icon(
                    monitor.muted
                        ? Icons.volume_off_outlined
                        : Icons.volume_up_outlined,
                  ),
                  label: const Text('Volume'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _connectionSheet(context, monitor),
                  icon: const Icon(Icons.wifi),
                  label: const Text('Connection'),
                ),
              ),
            ],
          ),
        const SizedBox(height: 24),
        _WatchCard(monitor: monitor, onActivity: onActivity),
        const SizedBox(height: 18),
        SurfaceCard(
          padding: 16,
          child: Column(
            children: [
              _Detail(
                Icons.battery_charging_full,
                'This phone’s battery',
                _batteryText(monitor.batteryLevel, monitor.charging),
              ),
              const Divider(height: 26),
              _Detail(
                Icons.vpn_lock_outlined,
                monitor.cloudMode ? 'Cloud server' : 'Tailscale',
                monitor.cloudMode
                    ? (monitor.cloudServer.isEmpty
                          ? 'Add in Settings'
                          : monitor.cloudServer)
                    : (monitor.tailscaleUp
                          ? 'Address detected'
                          : 'Not detected'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 15, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Live audio only. Nothing recorded.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _WatchCard extends StatelessWidget {
  const _WatchCard({required this.monitor, required this.onActivity});
  final HomeMonitor monitor;
  final VoidCallback onActivity;
  @override
  Widget build(BuildContext context) => SurfaceCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Sound Watch',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Sound alerts'),
          subtitle: Text(
            monitor.soundLoading
                ? 'Loading sound detector…'
                : monitor.soundEnabled
                ? monitor.isActive
                      ? 'Watching the live audio on this phone'
                      : 'Ready for your next monitoring session'
                : 'Choose sounds to get your attention',
          ),
          value: monitor.soundEnabled,
          onChanged: monitor.soundLoading ? null : monitor.setSoundEnabled,
        ),
        const Divider(height: 16),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.graphic_eq),
          title: const Text('Recent activity'),
          subtitle: Text(
            monitor.events.isEmpty
                ? 'Your activity will appear here'
                : monitor.events.first.title,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: onActivity,
        ),
      ],
    ),
  );
}

class _Activity extends StatelessWidget {
  const _Activity({required this.monitor});
  final HomeMonitor monitor;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _Heading('Activity', 'Sound events and monitoring updates.'),
      const SizedBox(height: 24),
      if (monitor.events.isEmpty)
        const SurfaceCard(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Column(
              children: [
                Icon(Icons.graphic_eq, size: 44),
                SizedBox(height: 16),
                Text(
                  'No activity yet',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 8),
                Text(
                  'Start sharing or listening to see updates here.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        )
      else
        ...monitor.events.map(
          (event) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SurfaceCard(
              padding: 16,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(switch (event.kind) {
                    ActivityKind.sound => Icons.notifications_active_outlined,
                    ActivityKind.battery => Icons.battery_alert_outlined,
                    ActivityKind.disconnected => Icons.wifi_off_outlined,
                    ActivityKind.connected => Icons.wifi,
                    _ => Icons.mic_none,
                  }, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          event.title,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${event.room} • ${_time(event.at)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      const SizedBox(height: 8),
      const Text(
        'Only event details are saved on this phone. Sound detections are estimates; tap Home to listen and check.',
        style: TextStyle(fontSize: 12),
      ),
      if (monitor.events.isNotEmpty)
        TextButton(
          onPressed: () async {
            if (await _confirm(
                  context,
                  'Clear activity?',
                  'This removes saved event details from this phone.',
                ) ==
                true) {
              await monitor.clearActivity();
            }
          },
          child: const Text('Clear activity'),
        ),
    ],
  );
}

class _Devices extends StatelessWidget {
  const _Devices({required this.monitor});
  final HomeMonitor monitor;
  @override
  Widget build(BuildContext context) {
    final home = monitor.deviceRole == DeviceRole.home;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Heading('Devices', 'Connect the two phones you use.'),
        const SizedBox(height: 24),
        // A listening phone shows the phone it listens to. Its own battery and
        // role are not what anyone opens this page to check.
        if (!home && monitor.hasPairing)
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Detail(Icons.home_outlined, 'Home phone', monitor.displayRoom),
                const Divider(height: 30),
                _Detail(
                  Icons.battery_std,
                  'Home phone battery',
                  monitor.isListening
                      ? _batteryText(
                          monitor.remoteBattery,
                          monitor.remoteCharging,
                        )
                      : 'Shown while connected',
                ),
                const Divider(height: 30),
                _Detail(
                  Icons.graphic_eq,
                  'Connection',
                  monitor.isListening
                      ? (monitor.listenerIsHearing
                            ? 'Connected • hearing audio'
                            : 'Connected • no audio yet')
                      : (monitor.reconnecting || monitor.searching
                            ? 'Looking for the home phone…'
                            : 'Not connected'),
                ),
                const Divider(height: 30),
                _Detail(Icons.lan_outlined, 'Address', monitor.pairedAddress),
              ],
            ),
          )
        else
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Detail(
                  Icons.smartphone,
                  'This phone',
                  home ? 'At home' : 'Listening phone',
                ),
                const Divider(height: 30),
                _Detail(
                  Icons.battery_std,
                  'Battery',
                  _batteryText(monitor.batteryLevel, monitor.charging),
                ),
                const SizedBox(height: 16),
                Text(
                  home
                      ? 'Name this room so you can recognize it on your other phone.'
                      : 'Use your cloud pairing link, or connect Tailscale on both phones for private network mode.',
                ),
                if (home)
                  TextButton.icon(
                    onPressed: () => _rename(context, monitor),
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(monitor.roomName),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 18),
        if (home) ...[
          FilledButton.icon(
            onPressed: () => _showPairingCode(context, monitor),
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Show pairing code'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              if (await _confirm(
                    context,
                    'Reset pairing code?',
                    'Sharing will stop and previously paired phones will need to scan the new code.',
                  ) ==
                  true) {
                await monitor.resetOwnToken();
              }
            },
            icon: const Icon(Icons.link_off),
            label: const Text('Revoke previous pairing codes'),
          ),
        ] else ...[
          if (monitor.hasPairing)
            SurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Connect automatically'),
                    subtitle: const Text(
                      'When this app is running and your home phone is sharing.',
                    ),
                    value: monitor.autoConnect,
                    onChanged: monitor.setAutoConnect,
                  ),
                  if (monitor.autoConnect)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: 'listen',
                            icon: Icon(Icons.headphones),
                            label: Text('Listen'),
                          ),
                          ButtonSegment(
                            value: 'alerts',
                            icon: Icon(Icons.notifications_active_outlined),
                            label: Text('Alerts only'),
                          ),
                        ],
                        selected: {monitor.autoMode},
                        onSelectionChanged: (s) => monitor.setAutoMode(s.first),
                      ),
                    ),
                  TextButton(
                    onPressed: () async {
                      if (await _confirm(
                            context,
                            'Forget home phone?',
                            'You will need to scan its pairing code again to listen.',
                          ) ==
                          true) {
                        await monitor.forgetPairing();
                      }
                    },
                    child: const Text('Forget this home phone'),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: monitor.busy ? null : () => _scan(context, monitor),
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(
              !monitor.hasPairing
                  ? 'Scan pairing code'
                  : 'Pair a different home phone',
            ),
          ),
          TextButton(
            onPressed: () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              if (context.mounted) {
                await _accept(context, monitor, data?.text ?? '');
              }
            },
            child: const Text('Paste a pairing code'),
          ),
        ],
        const SizedBox(height: 24),
        const Text(
          'Pairing codes contain a secret. Share the code only with the person who should listen. Up to ${MicTalker.maxListeners} phones can listen at the same time; resetting the code disconnects them all.',
        ),
      ],
    );
  }
}

class _Settings extends StatelessWidget {
  const _Settings({required this.monitor});
  final HomeMonitor monitor;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _Heading('Settings', 'Make Home Listen work for you.'),
      const SizedBox(height: 24),
      SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Connection',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              monitor.cloudMode
                  ? 'Cloud · Android home, Android or iPhone listener'
                  : 'Tailscale · private network',
            ),
            if (monitor.cloudMode)
              Text(
                monitor.cloudServer.isEmpty
                    ? 'Add your deployed server address to get started.'
                    : monitor.cloudServer,
              ),
            TextButton.icon(
              onPressed: () => _configureCloud(context, monitor),
              icon: const Icon(Icons.settings_ethernet),
              label: const Text('Configure connection'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Appearance',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              children: ['system', 'light', 'dark']
                  .map(
                    (mode) => ChoiceChip(
                      label: Text(mode[0].toUpperCase() + mode.substring(1)),
                      selected: monitor.appearance == mode,
                      onSelected: (_) => monitor.setAppearance(mode),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 24),
            const Text(
              'This phone’s role',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: DeviceRole.values
                  .map(
                    (role) => ChoiceChip(
                      label: Text(
                        role == DeviceRole.home
                            ? 'Home phone'
                            : 'Listening phone',
                      ),
                      selected: monitor.deviceRole == role,
                      onSelected: (_) async {
                        if (role == monitor.deviceRole) return;
                        if (monitor.isActive &&
                            await _confirm(
                                  context,
                                  'Switch phone role?',
                                  'The current monitoring session will stop.',
                                ) !=
                                true) {
                          return;
                        }
                        await monitor.selectDeviceRole(role);
                      },
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      SurfaceCard(
        child: SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Reduce background hiss'),
          subtitle: const Text(
            'Turns down the steady hiss every phone microphone makes in a quiet room. Voices and sounds still come through at full volume.',
          ),
          value: monitor.reduceHiss,
          onChanged: monitor.setReduceHiss,
        ),
      ),
      const SizedBox(height: 18),
      SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Sound Watch',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enable sound alerts'),
              value: monitor.soundEnabled,
              onChanged: monitor.soundLoading ? null : monitor.setSoundEnabled,
            ),
            if (monitor.soundEnabled)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  !monitor.isActive
                      ? 'Starts when sharing or listening begins.'
                      : monitor.isWatching
                      ? 'Alerts-only: the home phone does the listening, so '
                            'this phone has nothing to analyse. Sound alerts '
                            'must be on at the home phone.'
                      : monitor.soundWatch.lastHeard == null
                      ? monitor.soundWatch.status
                      : '${monitor.soundWatch.status}\nHearing now: '
                            '${monitor.soundWatch.lastHeard} '
                            '(${(monitor.soundWatch.lastHeardScore * 100).round()}%)',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (monitor.deviceRole == DeviceRole.home)
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Also show alerts on this phone'),
                subtitle: const Text(
                  'Off by default. Alerts are sent to your other phone only.',
                ),
                value: monitor.homeShowsAlerts,
                onChanged: monitor.setHomeShowsAlerts,
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: OutlinedButton.icon(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final result = await monitor.sendTestAlert();
                  messenger.showSnackBar(SnackBar(content: Text(result)));
                },
                icon: const Icon(Icons.notifications_active_outlined),
                label: const Text('Send test alert'),
              ),
            ),
            const Text('Sounds to watch'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: ['crying', 'barking', 'knocking', 'loud sound']
                  .map(
                    (name) => FilterChip(
                      label: Text(name[0].toUpperCase() + name.substring(1)),
                      selected: monitor.soundWatch.categories.contains(name),
                      onSelected: (value) =>
                          monitor.toggleSoundCategory(name, value),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 18),
            const Text(
              'Alert sensitivity',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            Slider(
              value: .85 - monitor.soundWatch.sensitivity + .2,
              min: .2,
              max: .85,
              divisions: 13,
              label: monitor.soundWatch.sensitivity < .4
                  ? 'More sensitive'
                  : monitor.soundWatch.sensitivity > .65
                  ? 'Less sensitive'
                  : 'Balanced',
              onChanged: (value) => monitor.setSoundThreshold(.85 - value + .2),
            ),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(child: Text('Fewer alerts')),
                SizedBox(width: 12),
                Expanded(
                  child: Text('More sensitive', textAlign: TextAlign.end),
                ),
              ],
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: !monitor.isActive || monitor.calibrating
                  ? null
                  : monitor.calibrateRoom,
              icon: const Icon(Icons.tune),
              label: Text(
                monitor.calibrating
                    ? 'Listening to the room…'
                    : 'Calibrate normal room sound',
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Calibrate while the room is quiet. It takes about 8 seconds and tunes loud-sound alerts for normal background noise.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            const Text(
              'Alerts run on this phone while sharing or listening. Closing the app from recents keeps a running session going; use Turn off to stop it. Sound recognition may miss or misclassify events.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Connection & privacy',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            const Text(
              'Cloud audio uses encrypted WebRTC; Tailscale mode uses your private network. Sound detection runs locally. Sharing starts from a tap at home. No audio recordings are saved.',
            ),
            const SizedBox(height: 14),
            const Text(
              'Keep the home phone charging. On Samsung, add Home Listen to “Never auto sleeping apps”. Add Tailscale too when using private network mode.',
            ),
            TextButton.icon(
              onPressed: () => _connectionSheet(context, monitor),
              icon: const Icon(Icons.network_check),
              label: const Text('Connection details'),
            ),
            TextButton.icon(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Home Listen',
                applicationVersion: '1.2.5',
              ),
              icon: const Icon(Icons.description_outlined),
              label: const Text('Open-source licenses'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      const Center(
        child: Text(
          'Home Listen 1.2.5 • WianTribe',
          style: TextStyle(fontSize: 12),
        ),
      ),
    ],
  );
}

class _Heading extends StatelessWidget {
  const _Heading(this.title, this.subtitle);
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: Theme.of(context).textTheme.headlineMedium
            ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -.6),
      ),
      const SizedBox(height: 8),
      Text(
        subtitle,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ],
  );
}

class _Detail extends StatelessWidget {
  const _Detail(this.icon, this.label, this.value);
  final IconData icon;
  final String label, value;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(
        icon,
        size: 21,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: 10),
      Expanded(child: Text(label)),
      const SizedBox(width: 10),
      Flexible(
        child: Text(
          value,
          textAlign: TextAlign.end,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    ],
  );
}

String _batteryText(int? level, bool? charging) => level == null
    ? 'Unavailable'
    : '$level%${charging == true
          ? ' • Charging'
          : charging == false
          ? ' • On battery'
          : ''}';
String _time(DateTime time) {
  final local = time.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final suffix = local.hour < 12 ? 'am' : 'pm';
  return '${local.day}/${local.month} • $hour:${local.minute.toString().padLeft(2, '0')}$suffix';
}

Future<bool?> _confirm(BuildContext context, String title, String text) =>
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
Future<void> _rename(BuildContext context, HomeMonitor monitor) async {
  final controller = TextEditingController(text: monitor.roomName);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Name this room'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 32,
        decoration: const InputDecoration(hintText: 'Bedroom'),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (result != null) await monitor.setRoomName(result);
  controller.dispose();
}

Future<void> _scan(BuildContext context, HomeMonitor monitor) async {
  final code = await Navigator.of(context)
      .push<String>(MaterialPageRoute(builder: (_) => const _ScanPage()));
  if (code != null && context.mounted) await _accept(context, monitor, code);
}

Future<void> _accept(
  BuildContext context,
  HomeMonitor monitor,
  String code,
) async {
  final ok = await monitor.pair(code);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'That code could not be paired. Use the code shown on your home phone.',
        ),
      ),
    );
  }
}

Future<void> _volumeSheet(
  BuildContext context,
  HomeMonitor monitor,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  useSafeArea: true,
  builder: (_) => ChangeNotifierProvider<HomeMonitor>.value(
    value: monitor,
    child: Consumer<HomeMonitor>(
      builder: (context, state, _) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Listening volume',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            Slider(
              value: state.volume,
              onChanged: state.setVolume,
              divisions: 20,
              label: '${(state.volume * 100).round()}%',
            ),
            TextButton.icon(
              onPressed: () => state.setVolume(state.muted ? 1 : 0),
              icon: Icon(state.muted ? Icons.volume_up : Icons.volume_off),
              label: Text(state.muted ? 'Unmute' : 'Mute audio'),
            ),
            const Text(
              'Muting playback keeps Sound Watch and connection checks active.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  ),
);
Future<void> _connectionSheet(
  BuildContext context,
  HomeMonitor monitor,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  useSafeArea: true,
  isScrollControlled: true,
  builder: (_) => ChangeNotifierProvider<HomeMonitor>.value(
    value: monitor,
    child: Consumer<HomeMonitor>(
      builder: (context, state, _) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Connection details',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 20),
            _Detail(
              Icons.vpn_lock,
              state.cloudMode ? 'Cloud server' : 'This phone’s VPN address',
              state.cloudMode
                  ? state.cloudServer
                  : (state.tailscaleAddress ?? 'Not detected'),
            ),
            const SizedBox(height: 14),
            _Detail(
              Icons.home_outlined,
              'Home phone',
              state.hasPairing ? state.pairedAddress : 'Not paired',
            ),
            const SizedBox(height: 14),
            _Detail(
              Icons.graphic_eq,
              'Audio',
              state.listenerIsHearing
                  ? 'Arriving'
                  : state.isTalking
                  ? 'Microphone active'
                  : 'Not arriving',
            ),
            if (state.isListening && !state.cloudMode) ...[
              const SizedBox(height: 14),
              _Detail(
                Icons.timer_outlined,
                'Audio buffer',
                '${state.bufferMs} ms',
              ),
              const SizedBox(height: 14),
              _Detail(
                Icons.network_check,
                'Missing frames',
                '${(state.lossRate * 100).toStringAsFixed(1)}%',
              ),
              const SizedBox(height: 14),
              _Detail(
                Icons.schedule,
                'Last packet',
                state.lastAudio == null
                    ? 'Waiting'
                    : '${DateTime.now().difference(state.lastAudio!).inSeconds} seconds ago',
              ),
            ],
            const SizedBox(height: 20),
            const Text(
              'If audio stops, check internet and sharing at home. For Tailscale mode, check the VPN on both phones. Stop listening cancels recovery.',
            ),
          ],
        ),
      ),
    ),
  ),
);
Future<void> _showPairingCode(BuildContext context, HomeMonitor monitor) async {
  await monitor.preparePairingCode();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => ChangeNotifierProvider<HomeMonitor>.value(
      value: monitor,
      child: Consumer<HomeMonitor>(
        builder: (context, state, _) => AlertDialog(
          title: const Text('Pair your listening phone'),
          content: SingleChildScrollView(
            child: state.pairingCode == null
                ? const Text(
                    'Set your cloud server in Settings, or connect Tailscale for private network mode. Check the app message if code creation failed.',
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        color: Colors.white,
                        padding: const EdgeInsets.all(12),
                        child: QrImageView(data: state.pairingCode!, size: 200),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'On Android, scan in Devices. On iPhone, open this link in Safari. Cloud invitations expire in 10 minutes; pairing is saved after joining.',
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: state.pairingCode!),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Pairing code copied'),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy code instead'),
                      ),
                      const Text(
                        'This code grants access while sharing is on. Keep it private.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    ),
  );
}

const _muted = Color(0xFF738A90);

Future<void> _configureCloud(BuildContext context, HomeMonitor monitor) async {
  final controller = TextEditingController(text: monitor.cloudServer);
  var mode = monitor.connectionMode;
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Connection'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<ConnectionMode>(
                segments: const [
                  ButtonSegment(
                    value: ConnectionMode.cloud,
                    label: Text('Cloud'),
                  ),
                  ButtonSegment(
                    value: ConnectionMode.tailscale,
                    label: Text('Tailscale'),
                  ),
                ],
                selected: {mode},
                onSelectionChanged: (values) =>
                    setState(() => mode = values.first),
              ),
              const SizedBox(height: 18),
              if (mode == ConnectionMode.cloud) ...[
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Home Listen server',
                    hintText: 'https://homelisten.your-name.workers.dev',
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Use the address from your cloud deployment. Pairing and alerts need Firebase configured there.',
                ),
              ] else
                const Text(
                  'Connect Tailscale on both phones, then pair using the home phone’s QR code.',
                ),
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
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  if (saved == true) await monitor.configureConnection(mode, controller.text);
  controller.dispose();
}

/// A plain camera view that returns the first Home Listen code it sees.
class _ScanPage extends StatefulWidget {
  const _ScanPage();

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      // Ignore codes meant for anything else rather than closing on them.
      if (value != null &&
          (PairingInfo.parse(value) != null ||
              CloudPairing.parse(value) != null)) {
        _done = true;
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan pairing code')),
      body: Column(
        children: [
          Expanded(child: MobileScanner(onDetect: _onDetect)),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Point the camera at the code on your home phone '
              '(Home Listen → Show pairing code). The camera is only on while '
              'this screen is open.',
              style: TextStyle(color: _muted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
