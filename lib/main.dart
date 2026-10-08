import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/home_monitor.dart';
import 'ui/home_monitor_page.dart';
import 'ui/design.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('assets/models/LICENSE.txt');
    yield LicenseEntryWithLineBreaks(const ['YAMNet'], license);
  });
  final prefs = await SharedPreferences.getInstance();
  if (!prefs.containsKey('connection_mode')) {
    await prefs.setString('connection_mode', 'cloud');
  }
  final monitor = HomeMonitor(prefs: prefs);
  await monitor.initialize();
  runApp(HomeListenApp(prefs: prefs, monitor: monitor));
}

/// Home Listen: cloud WebRTC audio, with an optional Tailscale fallback.
///
/// System, light, and dark themes with the wiaTribe teal accent.
class HomeListenApp extends StatelessWidget {
  const HomeListenApp({super.key, required this.prefs, this.monitor});

  final SharedPreferences prefs;
  final HomeMonitor? monitor;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      // Lives for the whole app so the monitor survives leaving its page.
      create: (_) => monitor ?? HomeMonitor(prefs: prefs),
      child: Consumer<HomeMonitor>(
        builder: (context, state, _) => MaterialApp(
          title: 'Home Listen',
          debugShowCheckedModeBanner: false,
          theme: HomeListenTheme.theme(Brightness.light),
          darkTheme: HomeListenTheme.theme(Brightness.dark),
          themeMode: switch (state.appearance) {
            'light' => ThemeMode.light,
            'dark' => ThemeMode.dark,
            _ => ThemeMode.system,
          },
          home: const HomeMonitorPage(),
        ),
      ),
    );
  }
}
