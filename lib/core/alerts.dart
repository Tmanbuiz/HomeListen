import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class MonitorAlerts {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<bool> requestPermission() async {
    if (!_initialized) {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_home_listen'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestSoundPermission: false,
            requestBadgePermission: false,
          ),
        ),
      );
      _initialized = true;
    }
    if (Platform.isAndroid) {
      await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(const AndroidNotificationChannel(
            'sound_watch', 'Sound Watch',
            description: 'Sound events from your paired home phone.',
            importance: Importance.high,
          ));
      return await _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false;
    }
    if (Platform.isIOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, sound: true, badge: false) ??
          false;
    }
    return false;
  }

  Future<void> show(String title, String body) async {
    if (!_initialized) return;
    await _plugin.show(
      81,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'sound_watch',
          'Sound Watch',
          channelDescription:
              'Sound events and connection alerts while monitoring is active.',
          importance: Importance.high,
          priority: Priority.high,
          icon: 'ic_stat_home_listen',
        ),
        iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
      ),
    );
  }
}
