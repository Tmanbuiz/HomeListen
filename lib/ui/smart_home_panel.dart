import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/home_monitor.dart';
import '../core/smart_home_settings.dart';
import 'design.dart';

class SmartHomeCard extends StatelessWidget {
  const SmartHomeCard({super.key, required this.monitor});
  final HomeMonitor monitor;
  @override
  Widget build(BuildContext context) => SurfaceCard(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [Icon(Icons.hub_outlined), SizedBox(width: 10),
        Expanded(child: Text('Smart home', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)))]),
      const SizedBox(height: 12),
      const Text('Let Home Assistant respond to selected sounds with lights, notifications and household routines.'),
      const SizedBox(height: 10),
      Text(monitor.smartHomeStatus),
      if (monitor.smartHomeProblem != null) ...[
        const SizedBox(height: 8), Text(monitor.smartHomeProblem!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SmartHomePage(monitor: monitor))),
        icon: const Icon(Icons.settings_outlined), label: const Text('Home Assistant & Matter'),
      ),
    ]),
  );
}

class SmartHomePage extends StatefulWidget {
  const SmartHomePage({super.key, required this.monitor});
  final HomeMonitor monitor;
  @override
  State<SmartHomePage> createState() => _SmartHomePageState();
}

class _SmartHomePageState extends State<SmartHomePage> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _host, _port, _username, _url, _prefix;
  final _password = TextEditingController();
  late bool _enabled, _tls, _controls;
  bool _saving = false;
  String? _feedback;
  @override
  void initState() {
    super.initState();
    final settings = widget.monitor.smartHomeSettings;
    _enabled = settings.enabled; _tls = settings.tls; _controls = settings.allowControls;
    _host = TextEditingController(text: settings.host);
    _port = TextEditingController(text: '${settings.port}');
    _username = TextEditingController(text: settings.username);
    _url = TextEditingController(text: settings.homeAssistantUrl);
    _prefix = TextEditingController(text: settings.discoveryPrefix);
  }
  @override
  void dispose() {
    for (final controller in [_host, _port, _username, _password, _url, _prefix]) { controller.dispose(); }
    super.dispose();
  }
  SmartHomeSettings get _settings => SmartHomeSettings(
    enabled: _enabled, host: _host.text.trim(), port: int.tryParse(_port.text) ?? 0,
    tls: _tls, username: _username.text.trim(), discoveryPrefix: _prefix.text.trim(),
    homeAssistantUrl: _url.text.trim(), allowControls: _controls,
  );
  Future<void> _save() async {
    if (_saving) return;
    if (_enabled && _settings.problem != null) { setState(() => _feedback = _settings.problem); return; }
    setState(() { _saving = true; _feedback = null; });
    final problem = await widget.monitor.configureSmartHome(_settings, _password.text);
    if (!mounted) return;
    _password.clear();
    setState(() { _saving = false; _feedback = problem ?? (_enabled ? 'Settings saved. Check your Home Assistant devices.' : 'Integration switched off.'); });
  }
  Future<void> _test() async {
    if (_saving) return;
    setState(() => _saving = true);
    final problem = await widget.monitor.testSmartHome();
    if (mounted) setState(() { _saving = false; _feedback = problem ?? 'Test event sent. Choose test in your Home Assistant sound response automation.'; });
  }
  Future<void> _openAssistant() async {
    final problem = await widget.monitor.openHomeAssistant();
    if (mounted && problem != null) setState(() => _feedback = problem);
  }
  Widget _field(TextEditingController controller, String label, {String? hint, bool password = false, bool number = false}) =>
    Padding(padding: const EdgeInsets.only(top: 14), child: TextFormField(
      controller: controller, obscureText: password, autocorrect: false, enableSuggestions: !password,
      enabled: !_saving, keyboardType: number ? TextInputType.number : TextInputType.text,
      inputFormatters: number ? [FilteringTextInputFormatter.digitsOnly] : null,
      decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
    ));
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Home Assistant & Matter')),
    body: SafeArea(child: AnimatedBuilder(animation: widget.monitor, builder: (context, _) => Align(
      alignment: Alignment.topCenter, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(padding: const EdgeInsets.all(20), children: [
          SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.monitor.smartHomeStatus, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            const Text('Your phone detects sound locally. Mosquitto carries sound events and health information to your Home Assistant hub. Audio is not sent through this connection.'),
            if (widget.monitor.smartHomeQueueCount > 0) Padding(padding: const EdgeInsets.only(top: 10),
              child: Text('${widget.monitor.smartHomeQueueCount} fresh events waiting')),
            if (_feedback != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_feedback!)),
          ])),
          const SizedBox(height: 18),
          SurfaceCard(child: Form(key: _form, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SwitchListTile.adaptive(contentPadding: EdgeInsets.zero, title: const Text('Connect this home phone'),
              value: _enabled, onChanged: _saving ? null : (value) => setState(() => _enabled = value)),
            const Text('Use the Mosquitto address and account from your Home Assistant setup.'),
            _field(_host, 'Broker address', hint: '192.168.1.20 or broker.example.com'),
            _field(_port, 'Broker port', number: true),
            SwitchListTile.adaptive(contentPadding: EdgeInsets.zero, title: const Text('Use TLS encryption'),
              subtitle: const Text('Public addresses require TLS. Your certificate must be trusted by this phone.'),
              value: _tls, onChanged: _saving ? null : (value) => setState(() {
                _tls = value;
                if (_port.text == '1883' || _port.text == '8883') _port.text = value ? '8883' : '1883';
              })),
            _field(_username, 'Broker username'),
            _field(_password, 'Broker password', password: true, hint: 'Leave empty to keep the saved password'),
            _field(_url, 'Home Assistant address (optional)', hint: 'http://homeassistant.local:8123'),
            SwitchListTile.adaptive(contentPadding: EdgeInsets.zero, title: const Text('Allow household controls'),
              subtitle: const Text('Home Assistant may stop monitoring and set Home, Away or Night. Microphone capture still starts only from a tap on this phone.'),
              value: _controls, onChanged: _saving ? null : (value) => setState(() => _controls = value)),
            ExpansionTile(tilePadding: EdgeInsets.zero, title: const Text('Advanced setup'), children: [
              _field(_prefix, 'Home Assistant discovery prefix'),
              const SizedBox(height: 10), const Text('Device identifier'),
              SelectableText(widget.monitor.smartHomeDeviceId),
              TextButton.icon(onPressed: () => Clipboard.setData(ClipboardData(text: widget.monitor.smartHomeDeviceId)),
                icon: const Icon(Icons.copy), label: const Text('Copy device identifier')),
            ]),
            const SizedBox(height: 16),
            FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Connecting…' : 'Save connection')),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: _saving || !widget.monitor.smartHomeConnected ? null : _test,
              icon: const Icon(Icons.notifications_active_outlined), label: const Text('Send test event')),
          ]))),
          const SizedBox(height: 18),
          SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('House mode', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('Use this context in your Home Assistant sound responses. Changing it does not start the microphone.'),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: homeProfiles.map((profile) => ChoiceChip(
              label: Text('${profile[0].toUpperCase()}${profile.substring(1)}'), selected: widget.monitor.houseProfile == profile,
              onSelected: (_) => widget.monitor.setHouseProfile(profile),
            )).toList()),
          ])),
          const SizedBox(height: 18),
          SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Matter devices', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            const Text('Pair supported Matter lights, plugs and sensors in the Home Assistant companion app. Home Assistant can then use Home Listen sound events in their automations.'),
            const SizedBox(height: 10),
            const Text('Try a gentle hallway light for possible crying at night, or a notification for knocking while you are away. Our sound-response and monitor-health blueprints are in the setup guide.'),
            const SizedBox(height: 10),
            const Text('An always-on Home Assistant hub is required. Matter-over-Thread devices also need a Thread border router.'),
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: _openAssistant, icon: const Icon(Icons.open_in_new), label: const Text('Open Home Assistant')),
          ])),
        ]),
      ),
    ))),
  );
}
