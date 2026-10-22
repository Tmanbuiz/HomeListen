import 'dart:convert';
import 'dart:io';
import 'dart:math';

const homeListenVersion = '2.2.0';
const homeProfiles = ['home', 'away', 'night'];

/// Credentials are stored separately in Android's encrypted storage.
class SmartHomeSettings {
  const SmartHomeSettings({
    this.enabled = false,
    this.host = '',
    this.port = 8883,
    this.tls = true,
    this.username = '',
    this.discoveryPrefix = 'homeassistant',
    this.homeAssistantUrl = '',
    this.allowControls = false,
  });
  final bool enabled, tls, allowControls;
  final String host, username, discoveryPrefix, homeAssistantUrl;
  final int port;

  String? get problem {
    if (host.isEmpty ||
        host.length > 253 ||
        RegExp(r'[\s/#?@]').hasMatch(host) ||
        host.contains('://')) {
      return 'Enter a broker hostname or IP address, without a URL or path.';
    }
    if (port < 1 || port > 65535) {
      return 'Broker port must be between 1 and 65535.';
    }
    if (username.isEmpty ||
        username.length > 128 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(username)) {
      return 'Enter your broker username.';
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(discoveryPrefix)) {
      return 'Use letters, numbers, underscores or hyphens for the discovery prefix.';
    }
    if (!tls && !isPrivateHost(host)) {
      return 'Use TLS for this broker. Plain connections are limited to private LAN addresses or .local names.';
    }
    if (homeAssistantUrl.isNotEmpty && assistantUri(homeAssistantUrl) == null) {
      return 'Enter an HTTPS Home Assistant address, or HTTP on your private home network.';
    }
    return null;
  }

  static bool isPrivateHost(String value) {
    if (RegExp(
      r'^[a-zA-Z0-9][a-zA-Z0-9.-]*\.local$',
      caseSensitive: false,
    ).hasMatch(value)) {
      return true;
    }
    final address = InternetAddress.tryParse(value);
    if (address == null) return false;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return bytes[0] == 10 ||
          bytes[0] == 127 ||
          (bytes[0] == 192 && bytes[1] == 168) ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31);
    }
    return address.isLoopback || (bytes[0] & 0xfe) == 0xfc;
  }

  static Uri? assistantUri(String value) {
    if (value.length > 2048) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' && isPrivateHost(uri.host)))) {
      return null;
    }
    return uri;
  }

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'host': host,
    'port': port,
    'tls': tls,
    'username': username,
    'discoveryPrefix': discoveryPrefix,
    'homeAssistantUrl': homeAssistantUrl,
    'allowControls': allowControls,
  };
  static SmartHomeSettings restore(String? raw) {
    try {
      final data = jsonDecode(raw ?? '{}');
      if (data is! Map) return const SmartHomeSettings();
      final settings = SmartHomeSettings(
        enabled: data['enabled'] == true,
        host: data['host'] is String ? data['host'] : '',
        port: data['port'] is int ? data['port'] : 8883,
        tls: data['tls'] != false,
        username: data['username'] is String ? data['username'] : '',
        discoveryPrefix: data['discoveryPrefix'] is String
            ? data['discoveryPrefix']
            : 'homeassistant',
        homeAssistantUrl: data['homeAssistantUrl'] is String
            ? data['homeAssistantUrl']
            : '',
        allowControls: data['allowControls'] == true,
      );
      return settings.enabled && settings.problem != null
          ? const SmartHomeSettings()
          : settings;
    } on FormatException {
      return const SmartHomeSettings();
    }
  }

  static String newDeviceId() {
    final random = Random.secure();
    return List.generate(
      12,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

class SmartHomeTopics {
  SmartHomeTopics(this.id, this.prefix) {
    if (!RegExp(r'^[a-f0-9]{24}$').hasMatch(id)) {
      throw ArgumentError('Invalid device identifier.');
    }
  }
  final String id, prefix;
  String get base => 'homelisten/$id';
  String get availability => '$base/availability';
  String get state => '$base/state';
  String get events => '$base/events';
  String get command => '$base/command';
  String get profileSet => '$base/profile/set';
  String discovery(String component, String name) =>
      '$prefix/$component/hl_${id}_$name/config';

  Map<String, Map<String, Object>> discoveryMessages(
    String room,
    bool controls,
  ) {
    final device = <String, Object>{
      'identifiers': ['homelisten_$id'],
      'name': '$room · Home Listen',
      'manufacturer': 'WianTribe',
      'model': 'Android sound monitor',
      'sw_version': homeListenVersion,
    };
    Map<String, Object> entity(String name, String key) => {
      'name': name,
      'unique_id': 'hl_${id}_$key',
      'device': device,
      'availability_topic': availability,
      'payload_available': 'online',
      'payload_not_available': 'offline',
      'state_topic': state,
      'value_template': '{{ value_json.$key }}',
      'qos': 1,
    };
    final result = <String, Map<String, Object>>{};
    for (final entry in {
      'monitoring': 'Monitoring',
      'microphone': 'Microphone samples',
      'detector': 'Sound detector',
      'charging': 'Charging',
    }.entries) {
      result[discovery('binary_sensor', entry.key)] = {
        ...entity(entry.value, entry.key),
        'payload_on': 'true',
        'payload_off': 'false',
        'value_template':
            "{{ 'true' if value_json.${entry.key} else 'false' }}",
        'expire_after': 45,
      };
    }
    result[discovery('sensor', 'battery')] = {
      ...entity('Battery', 'battery'),
      'device_class': 'battery',
      'unit_of_measurement': '%',
      'state_class': 'measurement',
      'expire_after': 45,
    };
    result[discovery('sensor', 'mode')] = {
      ...entity('Monitoring mode', 'mode'),
      'expire_after': 45,
    };
    result[discovery('sensor', 'profile')] = {
      ...entity('House mode', 'profile'),
      'expire_after': 45,
    };
    result[discovery('event', 'sound')] = {
      ...entity('Sound event', 'sound'),
      'state_topic': events,
      'event_types': [
        'crying',
        'coughing',
        'barking',
        'knocking',
        'loud_sound',
        'test',
      ],
      'value_template': '{{ value_json | tojson }}',
    };
    if (controls) {
      result[discovery('select', 'profile_control')] = {
        ...entity('Set house mode', 'profile'),
        'unique_id': 'hl_${id}_profile_control',
        'command_topic': profileSet,
        'options': homeProfiles,
      };
      final stop = entity('Stop monitoring', 'stop')
        ..remove('state_topic')
        ..remove('value_template');
      result[discovery('button', 'stop')] = {
        ...stop,
        'command_topic': command,
        'payload_press': 'stop',
      };
    }
    return result;
  }

  /// Retained commands and all microphone-start commands are rejected.
  String? parseCommand(
    String topic,
    String payload,
    bool retained,
    bool controls,
  ) {
    if (!controls || retained || payload.length > 64) return null;
    if (topic == command && payload == 'stop') return 'stop';
    if (topic == profileSet && homeProfiles.contains(payload)) return payload;
    return null;
  }
}
