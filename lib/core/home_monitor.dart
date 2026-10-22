import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocols/mic_monitor.dart';
import 'activity_event.dart';
import 'episode_recordings.dart';
import 'alert_outbox.dart';
import 'alert_inbox.dart';
import 'guardian_settings.dart';
import 'smart_home.dart';
import 'smart_home_settings.dart';
import 'alerts.dart';
import 'cloud_connection.dart';
import 'cloud_pairing.dart';
import 'pairing.dart';
import 'sound_watch.dart';

enum MonitorRole { idle, talking, listening, watching, guardian }

enum DeviceRole { home, away }

enum ConnectionMode { cloud, tailscale }

/// A local tap starts capture; auto-connect only starts playback. Both roles
/// keep a visible Android foreground service, and Stop always stays stopped.
class HomeMonitor extends ChangeNotifier {
  HomeMonitor({
    this.prefs,
    AudioRecorder? recorder,
    MethodChannel? channel,
    this.autoConnectEvery = const Duration(seconds: 5),
  }) : _recorderInstance = recorder,
       _channel = channel ?? const MethodChannel(channelName) {
    _autoConnect = prefs?.getBool('auto_connect') ?? true;
    _deviceRole = prefs?.getString('device_role') == 'home'
        ? DeviceRole.home
        : DeviceRole.away;
    _roomName = prefs?.getString('room_name') ?? 'Bedroom';
    _appearance = prefs?.getString('appearance') ?? 'system';
    _events.addAll(ActivityEvent.restore(prefs?.getString('activity')));
    soundWatch.noiseFloor = prefs?.getDouble('noise_floor') ?? 0.015;
    soundWatch.sensitivity = prefs?.getDouble('sound_threshold') ?? 0.4;
    _guardianOnly = prefs?.getBool('guardian_only') ?? false;
    _guardianSettings = GuardianSettings.restore(
      prefs?.getString('guardian_settings'),
      threshold: soundWatch.sensitivity,
    );
    _smartHomeSettings = SmartHomeSettings.restore(
      prefs?.getString('smart_home_settings'),
    );
    final savedId = prefs?.getString('smart_home_device_id') ?? '';
    _smartHomeId = RegExp(r'^[a-f0-9]{24}$').hasMatch(savedId)
        ? savedId
        : SmartHomeSettings.newDeviceId();
    _houseProfile = homeProfiles.contains(prefs?.getString('house_profile'))
        ? prefs!.getString('house_profile')!
        : 'home';
    _smartHome = SmartHomeIntegration(
      deviceId: _smartHomeId,
      health: () => smartHomeHealth,
      roomName: () => _roomName,
      onChanged: _notify,
      canSend: (category, now) =>
          category == 'test' ||
          !_guardianSettings.suppresses(
            category == 'loud_sound' ? 'loud sound' : category,
            now,
          ),
      onCommand: (command) async {
        if (_deviceRole != DeviceRole.home ||
            !_smartHomeSettings.allowControls) {
          return;
        }
        if (command == 'stop') {
          await stop();
        } else {
          await setHouseProfile(command);
        }
      },
    );
    soundWatch.rules = _guardianSettings.rules;
    _outbox.addAll(
      PendingAlert.restore(prefs?.getString('alert_outbox'), DateTime.now()),
    );
    for (var i = 0; i < _events.length; i++) {
      final event = _events[i];
      if (event.delivery == AlertDelivery.queued &&
          !_outbox.any((a) => a.id == event.id)) {
        _events[i] = event.withDelivery(AlertDelivery.expired);
      }
    }
    _pruneActivity();
    _reduceHiss = prefs?.getBool('reduce_hiss') ?? true;
    _homeShowsAlerts = prefs?.getBool('home_shows_alerts') ?? false;
    _recordingPaused = prefs?.getBool('recording_paused') ?? false;
    _autoMode = prefs?.getString('auto_mode') == 'alerts' ? 'alerts' : 'listen';
    _connectionMode = prefs?.getString('connection_mode') == 'cloud'
        ? ConnectionMode.cloud
        : ConnectionMode.tailscale;
    final selected = prefs?.getStringList('sound_categories');
    if (selected != null) {
      soundWatch.categories
        ..clear()
        ..addAll(selected);
    }
    _recordings = EpisodeRecordings(
      directory: () async {
        final path = await _channel.invokeMethod<String>('recordingsDirectory');
        if (path == null || path.isEmpty) {
          throw StateError('Recording storage unavailable');
        }
        return Directory(path);
      },
      onChanged: _notify,
      onError: (message) {
        _recordingProblem = message;
        _notify();
      },
    );
    soundWatch.onVerdict = (verdict, at) {
      if (_deviceRole == DeviceRole.home) {
        _cloud?.publishRecordingVerdict(
          verdict.category,
          at,
          verdict.categoryScore,
        );
      } else if (!cloudMode) {
        _observeRecording(verdict.category, at);
      }
    };
    soundWatch.onDetection = (detection) {
      final title = detection.title;
      // The home phone already told this phone: do not say it twice.
      final told = _remoteAlertAt[title];
      if (told != null &&
          DateTime.now().difference(told) < const Duration(seconds: 15)) {
        return;
      }
      final quiet = _guardianSettings.suppresses(
        detection.category,
        detection.at,
      );
      final queued =
          !quiet &&
          _deviceRole == DeviceRole.home &&
          cloudMode &&
          cloudServer.isNotEmpty;
      final event = _addEvent(
        ActivityKind.sound,
        title,
        category: detection.category,
        score: detection.score,
        durationMs: detection.durationMs,
        delivery: quiet
            ? AlertDelivery.quiet
            : queued
            ? AlertDelivery.queued
            : AlertDelivery.local,
      );
      if (quiet) {
        _notify();
        return;
      }
      if (_deviceRole == DeviceRole.home && event != null) {
        _smartHome.event(event, _houseProfile);
      }
      // On the home phone this is what reaches the phone you carry, even when
      // that phone is not playing any audio.
      _talker?.sendAlert(title, _roomName);
      if (queued && event != null) {
        _enqueueAlert(event);
      }
      // The home phone itself stays quiet unless asked: nobody is usually there
      // to read it, and one popping up in the room is only noise.
      if (_deviceRole != DeviceRole.home ||
          _homeShowsAlerts ||
          (isGuardian && !cloudAlertsReady)) {
        unawaited(
          _alerts.show(title, '$displayRoom • Tap to open Home Listen.'),
        );
      }
      _notify();
    };
    soundWatch.onHeard = _notify;
    soundWatch.onCalibrated = (floor) {
      prefs?.setDouble('noise_floor', floor);
      _addEvent(ActivityKind.session, 'Room calibrated');
      _notify();
    };
    soundWatch.onError = (reason) {
      _error = isGuardian
          ? 'Guardian stopped because the sound detector failed. Open Home and start again.'
          : reason;
      if (isGuardian) {
        _addEvent(ActivityKind.disconnected, 'Sound detector stopped');
        unawaited(stop());
      }
      _notify();
    };
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopRequested') await stop();
    });
  }

  static const channelName = 'com.wiantribe.home_listen/mic_service';
  final SharedPreferences? prefs;
  AudioRecorder? _recorderInstance;
  // Created on first use so building the monitor (or testing it) never needs
  // the microphone plugin.
  AudioRecorder get _recorder => _recorderInstance ??= AudioRecorder();
  final MethodChannel _channel;
  final Duration autoConnectEvery;
  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  final Battery _battery = Battery();
  final MonitorAlerts _alerts = MonitorAlerts();
  final SoundWatch soundWatch = SoundWatch();
  final PcmFramer _meterFramer = PcmFramer();
  final List<ActivityEvent> _events = [];
  final List<PendingAlert> _outbox = [];
  late final EpisodeRecordings _recordings;
  String? _recordingProblem;
  DateTime? _lastRecordingVerdict, _lastRecordingPcm;
  Timer? _recordingWatchdog;
  List<RecordingClip> get recordingClips => _recordings.clips;
  bool get recordingAudio => _recordings.recording;
  bool get bufferingRecording => _recordings.buffering;
  String? get recordingProblem => _recordingProblem;
  bool _recordingPaused = false;
  bool get _recordingOptIn =>
      !_recordingPaused &&
      soundWatch.categories.any(
        (name) => _guardianSettings.rules[name]?.recordAudio == true,
      );
  bool get recordingArmed => _deviceRole == DeviceRole.away && _recordingOptIn;
  bool get _canRecord => recordingArmed && isListening;

  Future<void> loadRecordings() async {
    if (_deviceRole != DeviceRole.away) return;
    await _recordings.initialize();
    await _recordings.prune(retentionDays: _guardianSettings.retentionDays);
  }

  Future<void> deleteRecording(RecordingClip clip) => _recordings.delete(clip);
  Future<void> clearRecordings() => _recordings.clear();
  Future<String> exportRecording(RecordingClip clip) async {
    try {
      final saved = await _channel.invokeMethod<bool>('exportRecording', {
        'path': clip.path,
        'name': clip.name,
      });
      return saved == true ? 'Audio exported.' : 'Export cancelled.';
    } catch (_) {
      return 'Could not export audio. Open Home Listen and try again.';
    }
  }

  void _observeRecording(String? category, DateTime at) {
    if (!_canRecord) return;
    _lastRecordingVerdict = DateTime.now();
    final rule = _guardianSettings.rules[category];
    _recordings.observe(
      category,
      at,
      minimumSeconds: rule?.minimumSeconds ?? 0,
      recordAudio:
          category != null &&
          soundWatch.categories.contains(category) &&
          rule?.recordAudio == true,
    );
  }

  void _feedRecording(Int16List pcm) {
    if (!_canRecord) return;
    _lastRecordingPcm = DateTime.now();
    _recordingWatchdog ??= Timer.periodic(const Duration(seconds: 1), (_) {
      final pcmAt = _lastRecordingPcm;
      final verdictAt = _lastRecordingVerdict;
      final now = DateTime.now();
      if (!_canRecord ||
          pcmAt == null ||
          now.difference(pcmAt) > const Duration(seconds: 1) ||
          (verdictAt != null &&
              now.difference(verdictAt) > const Duration(seconds: 3))) {
        _interruptRecording();
      }
    });
    final last = _lastRecordingVerdict;
    if (last != null &&
        DateTime.now().difference(last) > const Duration(seconds: 3)) {
      unawaited(_recordings.stop());
      return;
    }
    _recordings.feed(pcm);
  }

  void _interruptRecording() {
    _recordingWatchdog?.cancel();
    _recordingWatchdog = null;
    _lastRecordingPcm = null;
    _lastRecordingVerdict = null;
    unawaited(_recordings.stop());
  }

  GuardianSettings _guardianSettings = GuardianSettings();
  SmartHomeSettings _smartHomeSettings = const SmartHomeSettings();
  late final SmartHomeIntegration _smartHome;
  late final String _smartHomeId;
  String _houseProfile = 'home';
  bool _guardianOnly = false,
      _guardianConnecting = false,
      _flushingAlerts = false,
      _mergingInbox = false;
  String? _guardianCloudProblem;
  DateTime? _lastCaptureAt, _lastGuardianConnect;
  Timer? _outboxTimer;
  // Growable on purpose: the meter scrolls by dropping the oldest bar. A
  // fixed-length list threw on every audio chunk, which stopped the home
  // phone's meter and, on the listening phone, ran before playback and
  // silenced it.
  final List<double> _levels = List.filled(36, 0.03, growable: true);
  Timer? _watch, _healthTimer;
  StreamSubscription<Uint8List>? _meterSub;
  MicTalker? _talker;
  MicListener? _listener;
  MicListener? _pendingListener;
  CloudConnection? _cloud;
  ConnectionMode _connectionMode = ConnectionMode.tailscale;
  ConnectionMode get connectionMode => _connectionMode;
  bool get cloudMode => _connectionMode == ConnectionMode.cloud;
  String get cloudServer => prefs?.getString('cloud_server') ?? '';
  bool get hasPairing => cloudMode
      ? (_cloud?.paired ?? prefs?.getString('cloud_paired_room') != null)
      : _paired != null;
  String get pairedAddress =>
      cloudMode ? cloudServer : (_paired?.host ?? 'Not paired');
  String? get pairingCode =>
      cloudMode ? _cloud?.inviteCode : ownPairing?.toCode();
  int get pairedPhoneCount => (_cloud?.room?['members'] as Map?)?.length ?? 0;
  Future<void> configureConnection(ConnectionMode mode, String server) async {
    final origin = mode == ConnectionMode.cloud
        ? CloudPairing.serverOrigin(server)
        : null;
    if (mode == ConnectionMode.cloud && origin == null) {
      _error = 'Enter the HTTPS address of your Home Listen cloud server.';
      _notify();
      return;
    }
    await stop();
    if (mode != _connectionMode || (origin != null && origin != cloudServer)) {
      for (final alert in _outbox) {
        _setDelivery(alert.id, AlertDelivery.expired);
      }
      _outbox.clear();
      await _saveOutbox();
    }
    await _cloud?.close();
    _cloud = null;
    _connectionMode = mode;
    await prefs?.setString('connection_mode', mode.name);
    if (origin != null) await prefs?.setString('cloud_server', origin);
    _error = null;
    _notify();
    if (cloudMode) {
      try {
        await _cloudConnection().ensureReady();
      } catch (e) {
        _error = _readableError(e);
        _notify();
      }
    }
  }

  CloudConnection _cloudConnection() {
    if (cloudServer.isEmpty || prefs == null) {
      throw StateError(
        'Open Settings → Connection and enter your cloud server address.',
      );
    }
    final cloud = _cloud ??= CloudConnection(
      origin: cloudServer,
      prefs: prefs!,
      home: _deviceRole == DeviceRole.home,
      onPcm: _processPcm,
      onRecordingPcm: _feedRecording,
      onRecordingVerdict: (category, at, score) =>
          _observeRecording(category, at),
      onRecordingInterrupted: _interruptRecording,
      onLevel: _onCloudLevel,
      onAlert: _onRemoteAlert,
      onProblem: (reason) {
        _error = reason;
        _notify();
      },
      onChanged: _cloudChanged,
    );
    cloud.requestRecordingAudio(
      _deviceRole == DeviceRole.away && _recordingOptIn,
    );
    return cloud;
  }

  void _cloudChanged() {
    final cloud = _cloud;
    if (cloud == null || _disposed) return;
    if (_deviceRole == DeviceRole.home) {
      if (isMonitoring) _talkerChanged();
    } else {
      if (cloud.online) {
        _readStatus({
          'room': cloud.room?['roomName'],
          'battery': cloud.room?['battery'],
          'charging': cloud.room?['charging'],
        });
      } else {
        _remoteStatusAt = null;
      }
      if (isListening && (!cloud.listening || !cloud.hearing)) {
        _interruptRecording();
      }
      if (isListening && !cloud.listening) {
        _role = MonitorRole.idle;
      }
      if (!cloud.paired && (isListening || isWatching)) {
        _role = MonitorRole.idle;
        _wantListening = false;
      }
    }
    _notify();
  }

  Future<void> preparePairingCode() async {
    if (!cloudMode) return;
    try {
      final cloud = _cloudConnection()
        ..health(_roomName, _batteryLevel, _charging);
      await cloud.showInvite();
      _error = null;
    } catch (e) {
      _error = _readableError(e);
    }
    _notify();
  }

  MonitorRole _role = MonitorRole.idle;
  DeviceRole _deviceRole = DeviceRole.away;
  PairingInfo? _paired;
  String? _error, _ownToken, _tailscaleAddress, _remoteRoom;
  bool _autoConnect = true, _busy = false, _watching = false;
  bool _suppressAuto = false, _wantListening = false, _disposed = false;

  /// Whether the session being kept alive is alerts-only, so a reconnect
  /// comes back in the same mode.
  bool _wantAlertsOnly = false;

  /// Whether the home phone also shows its own alerts. Off unless switched on.
  bool _homeShowsAlerts = false;
  bool get homeShowsAlerts => _homeShowsAlerts;

  Future<void> setHomeShowsAlerts(bool value) async {
    _homeShowsAlerts = value;
    await prefs?.setBool('home_shows_alerts', value);
    if (value) {
      // Showing alerts needs the notification permission, so ask now rather
      // than at the moment of the first alert.
      _notificationsAllowed = await _alerts.requestPermission().timeout(
        const Duration(seconds: 10),
        onTimeout: () => false,
      );
    }
    _notify();
  }

  /// What automatic connection does: "listen" or "alerts".
  String _autoMode = 'listen';
  String get autoMode => _autoMode;

  /// When each alert last arrived from the home phone, by title, so this
  /// phone's own Sound Watch does not announce the same thing a second time.
  final Map<String, DateTime> _remoteAlertAt = {};
  bool _securityReady = false,
      _soundLoading = false,
      _notificationsAllowed = false;
  bool _lowBatteryReported = false;
  int _epoch = 0;
  int _historyEpoch = 0;
  int? _batteryLevel, _remoteBattery;
  bool? _charging, _remoteCharging;
  DateTime? _remoteStatusAt, _lastUiUpdate, _sessionStarted;
  String _roomName = 'Bedroom', _appearance = 'system';
  double _volume = 1;

  MonitorRole get role => _role;
  DeviceRole get deviceRole => _deviceRole;
  bool get needsSetup => prefs?.getString('device_role') == null;
  String? get error => _error;
  bool get isTalking => _role == MonitorRole.talking;
  bool get isGuardian => _role == MonitorRole.guardian;
  bool get isMonitoring => isTalking || isGuardian;
  bool get liveHomeAvailable => !(Platform.isIOS && cloudMode);
  bool get guardianOnly => _guardianOnly || !liveHomeAvailable;
  GuardianSettings get guardianSettings => _guardianSettings;
  int get queuedAlertCount => _outbox.length;
  bool get cloudAlertsReady =>
      _cloud?.sharing == true &&
      _cloud?.lastPublished != null &&
      DateTime.now().difference(_cloud!.lastPublished!) <
          const Duration(seconds: 120);
  bool get liveAvailable => !cloudMode || (_cloud?.liveAvailable ?? true);
  String get guardianConnectionStatus => !cloudMode
      ? 'Local detection · cloud alerts are not configured'
      : cloudServer.isEmpty
      ? 'Local detection · add a server for remote alerts'
      : cloudAlertsReady
      ? 'Remote alerts connected'
      : _guardianCloudProblem ?? 'Local detection · connecting remote alerts';
  String get captureHealth => !isMonitoring
      ? 'Microphone off'
      : _lastCaptureAt == null
      ? 'Waiting for microphone samples'
      : DateTime.now().difference(_lastCaptureAt!) > const Duration(seconds: 10)
      ? 'Microphone feed has paused'
      : 'Microphone samples arriving';
  String get todaySummary {
    final today = DateTime.now();
    final counts = <String, int>{};
    for (final event in events.where(
      (e) => e.kind == ActivityKind.sound && e.category != null,
    )) {
      final at = event.at.toLocal();
      if (at.year == today.year &&
          at.month == today.month &&
          at.day == today.day) {
        counts.update(event.category!, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    return counts.isEmpty
        ? 'No selected sounds logged today.'
        : counts.entries
              .map(
                (e) => '${e.value} ${soundCategoryLabel(e.key).toLowerCase()}',
              )
              .join(' · ');
  }

  static String soundCategoryLabel(String name) => switch (name) {
    'crying' => 'Crying',
    'coughing' => 'Coughing',
    'barking' => 'Dog sounds',
    'knocking' => 'Knocks and doorbells',
    'loud sound' => 'Loud sounds',
    _ => name,
  };
  bool get isListening => _role == MonitorRole.listening;

  /// Connected for alerts only: registered with the home phone, no audio.
  bool get isWatching => _role == MonitorRole.watching;
  bool get isActive => _role != MonitorRole.idle;
  bool get busy => _busy;
  bool get talkerHasListener => talkerListenerCount > 0;
  int get talkerListenerCount =>
      cloudMode ? (_cloud?.listenerCount ?? 0) : (_talker?.listenerCount ?? 0);
  int get packetsSent => _talker?.packetsSent ?? 0;
  int get talkerWatcherCount =>
      cloudMode ? (_cloud?.watcherCount ?? 0) : (_talker?.watcherCount ?? 0);
  bool get listenerIsHearing =>
      cloudMode ? (_cloud?.hearing ?? false) : (_listener?.isHearing ?? false);
  int get packetsReceived => _listener?.packetsReceived ?? 0;
  PairingInfo? get paired => _paired;
  bool get autoConnect => _autoConnect;
  String? get tailscaleAddress => _tailscaleAddress;
  bool get tailscaleUp => _tailscaleAddress != null;
  bool get searching => _busy && !isActive;
  bool get reconnecting =>
      _wantListening && !isListening && !isWatching && !_suppressAuto;
  String get roomName => _roomName;
  String get displayRoom =>
      _deviceRole == DeviceRole.away ? (_remoteRoom ?? _roomName) : _roomName;
  String get appearance => _appearance;
  double get volume => _volume;
  bool get muted => _volume == 0;
  List<double> get levels => List.unmodifiable(_levels);
  List<ActivityEvent> get events => List.unmodifiable(_events);
  int? get batteryLevel => _batteryLevel;
  SmartHomeSettings get smartHomeSettings => _smartHomeSettings;
  String get smartHomeDeviceId => _smartHomeId;
  String get smartHomeStatus => _smartHome.status;
  String? get smartHomeProblem => _smartHome.problem;
  bool get smartHomeConnected => _smartHome.connected;
  int get smartHomeQueueCount => _smartHome.queued;
  String get houseProfile => _houseProfile;
  Map<String, Object?> get smartHomeHealth {
    final now = DateTime.now();
    return {
      'monitoring': isMonitoring,
      'microphone':
          isMonitoring &&
          _lastCaptureAt != null &&
          now.difference(_lastCaptureAt!) < const Duration(seconds: 10),
      'detector':
          isMonitoring &&
          soundWatch.enabled &&
          soundWatch.ready &&
          soundWatch.lastWindowAt != null &&
          now.difference(soundWatch.lastWindowAt!) <
              const Duration(seconds: 10),
      'battery': _batteryLevel,
      'charging': _charging == true,
      'mode': isGuardian
          ? 'guardian'
          : isTalking
          ? 'live'
          : 'off',
      'profile': _houseProfile,
      'room': _roomName,
      'updated_at_ms': now.millisecondsSinceEpoch,
    };
  }

  Future<void> _connectSmartHome() async {
    try {
      await prefs?.setString('smart_home_device_id', _smartHomeId);
      final password =
          _smartHomeSettings.enabled && _deviceRole == DeviceRole.home
          ? await _secure.read(key: 'smart_home_password') ?? ''
          : '';
      await _smartHome.configure(
        _deviceRole == DeviceRole.home
            ? _smartHomeSettings
            : const SmartHomeSettings(),
        password,
      );
    } catch (_) {
      /* Optional integration never interrupts microphone monitoring. */
    }
  }

  Future<String?> configureSmartHome(
    SmartHomeSettings settings,
    String password,
  ) async {
    if (_deviceRole != DeviceRole.home) {
      return 'Set up smart home integration on the home phone.';
    }
    if (settings.enabled && settings.problem != null) return settings.problem;
    try {
      final secret = password.isEmpty
          ? await _secure.read(key: 'smart_home_password') ?? ''
          : password;
      if (settings.enabled && secret.isEmpty) {
        return 'Enter your broker password.';
      }
      if (password.isNotEmpty) {
        await _secure.write(key: 'smart_home_password', value: password);
      }
      await prefs?.setString(
        'smart_home_settings',
        jsonEncode(settings.toJson()),
      );
      _smartHomeSettings = settings;
      await prefs?.setString('smart_home_device_id', _smartHomeId);
      await _smartHome.configure(settings, secret);
      _notify();
      return _smartHome.problem;
    } catch (_) {
      return 'Smart home settings could not be saved. Try again.';
    }
  }

  Future<void> setHouseProfile(String value) async {
    if (!homeProfiles.contains(value) || _deviceRole != DeviceRole.home) return;
    _houseProfile = value;
    await prefs?.setString('house_profile', value);
    _smartHome.tick(force: true);
    _notify();
  }

  Future<String?> testSmartHome() async {
    if (!_smartHome.connected) {
      return 'Connect your broker before sending a test event.';
    }
    _smartHome.event(
      ActivityEvent(
        kind: ActivityKind.sound,
        title: 'Test alert',
        room: _roomName,
        at: DateTime.now(),
        id: SmartHomeSettings.newDeviceId(),
        category: 'test',
      ),
      _houseProfile,
    );
    await _smartHome.settle();
    return _smartHome.problem;
  }

  Future<String?> openHomeAssistant() async {
    final uri = SmartHomeSettings.assistantUri(
      _smartHomeSettings.homeAssistantUrl,
    );
    if (uri == null) {
      return 'Add your Home Assistant address in smart home settings.';
    }
    try {
      await _channel.invokeMethod<bool>('openHomeAssistant', {
        'url': uri.toString(),
      });
      return null;
    } catch (_) {
      return 'This phone could not open Home Assistant. Open its companion app.';
    }
  }

  bool? get charging => _charging;
  bool get _statusFresh =>
      _remoteStatusAt != null &&
      DateTime.now().difference(_remoteStatusAt!) < const Duration(seconds: 25);
  int? get remoteBattery => _statusFresh ? _remoteBattery : null;
  bool? get remoteCharging => _statusFresh ? _remoteCharging : null;
  DateTime? get lastAudio => _listener?.lastAudio;
  int get bufferMs => _listener?.bufferMs ?? 60;
  double get lossRate => _listener?.lossRate ?? 0;
  int get droppedPackets => _listener?.droppedPackets ?? 0;
  bool get soundLoading => _soundLoading;
  bool get soundEnabled => soundWatch.enabled;
  bool get notificationsAllowed => _notificationsAllowed;
  bool get calibrating => soundWatch.calibrating;
  Duration get sessionDuration => _sessionStarted == null
      ? Duration.zero
      : DateTime.now().difference(_sessionStarted!);
  PairingInfo? get ownPairing => _tailscaleAddress == null || _ownToken == null
      ? null
      : PairingInfo(host: _tailscaleAddress!, token: _ownToken!);

  static String notificationText({
    required bool hasListener,
    int listeners = 1,
    int watchers = 0,
  }) {
    final base = hasListener
        ? (listeners > 1
              ? 'Microphone on — streaming to $listeners other devices'
              : 'Microphone on — streaming to your other device')
        : 'Microphone on — waiting for your other device to connect';
    if (watchers == 0) return base;
    final w = watchers == 1
        ? '1 phone watching for alerts'
        : '$watchers phones watching for alerts';
    return '$base • $w';
  }

  Future<void> initialize() async {
    try {
      _ownToken =
          await _secure.read(key: 'own_token') ??
          prefs?.getString('own_token') ??
          PairingInfo.newToken();
      await _secure.write(key: 'own_token', value: _ownToken);
      final host = prefs?.getString('paired_host');
      final token =
          await _secure.read(key: 'paired_token') ??
          prefs?.getString('paired_token');
      if (host != null &&
          token != null &&
          PairingInfo.isTailscaleAddress(host)) {
        await _secure.write(key: 'paired_token', value: token);
        _paired = PairingInfo(
          host: host,
          token: token,
          port: prefs?.getInt('paired_port') ?? MicStream.controlPort,
        );
      }
      await prefs?.remove('own_token');
      await prefs?.remove('paired_token');
      _securityReady = true;
    } catch (_) {
      _error = 'Secure pairing storage could not be opened. Restart the app before pairing or sharing.';
    }
    if (_deviceRole == DeviceRole.away) unawaited(loadRecordings());
    await _refreshHealth();
    if (cloudMode && cloudServer.isNotEmpty) {
      unawaited(
        _cloudConnection().ensureReady().catchError((Object e) {
          _error = _readableError(e);
          _notify();
        }),
      );
    }
    _watch = Timer.periodic(autoConnectEvery, (_) => _watchTailscale());
    _healthTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _refreshHealth(),
    );
    _outboxTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_flushOutbox()),
    );
    unawaited(_watchTailscale());
    // Sound Watch was left switched on: bring it back. It used to start off
    // after every restart, which looked like alerts silently not working.
    if (prefs?.getBool('sound_enabled') == true) {
      unawaited(setSoundEnabled(true));
    }
    unawaited(_connectSmartHome());
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void clearError() {
    _error = null;
    _notify();
  }

  Future<void> selectDeviceRole(DeviceRole value) async {
    if (_deviceRole != value && (isActive || _busy)) await stop();
    if (_deviceRole != value) {
      await _cloud?.close();
      _cloud = null;
    }
    _deviceRole = value;
    await prefs?.setString('device_role', value.name);
    if (value == DeviceRole.away) unawaited(loadRecordings());
    unawaited(_connectSmartHome());
    _suppressAuto = false;
    _notify();
    unawaited(_watchTailscale());
  }

  Future<void> setRoomName(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    _roomName = trimmed.substring(0, math.min(32, trimmed.length));
    await prefs?.setString('room_name', _roomName);
    _smartHome.resync();
    _notify();
  }

  Future<void> setAppearance(String value) async {
    if (!['system', 'light', 'dark'].contains(value)) return;
    _appearance = value;
    await prefs?.setString('appearance', value);
    _notify();
  }

  Future<void> resetOwnToken() async {
    if (cloudMode) {
      try {
        await stop();
        await _cloudConnection().revoke();
      } catch (e) {
        _error = _readableError(e);
      }
      _notify();
      return;
    }
    if (!_securityReady) return;
    if (isTalking || _busy) await stop();
    final token = PairingInfo.newToken();
    await _secure.write(key: 'own_token', value: token);
    _ownToken = token;
    _addEvent(ActivityKind.session, 'Previous pairing codes revoked');
    _notify();
  }

  bool get authenticatorOn => _cloud?.authenticatorOn ?? false;

  /// The other way in: the home's secret answer and a current authenticator
  /// code, with no pairing link.
  Future<bool> pairWithCode(String answer, String code) async {
    try {
      if (isActive || _busy) await stop();
      _connectionMode = ConnectionMode.cloud;
      await prefs?.setString('connection_mode', 'cloud');
      await _cloudConnection().joinWithCode(answer, code);
      _suppressAuto = false;
      _error = null;
      _notify();
      return true;
    } catch (e) {
      _error = _readableError(e);
      _notify();
      return false;
    }
  }

  Future<bool> pair(String code) async {
    final invite = CloudPairing.parse(code);
    if (invite != null) {
      try {
        if (isActive || _busy) await stop();
        if (cloudServer.isEmpty) {
          await prefs?.setString('cloud_server', invite.origin);
        }
        _connectionMode = ConnectionMode.cloud;
        await prefs?.setString('connection_mode', 'cloud');
        await _cloudConnection().join(invite);
        _suppressAuto = false;
        _error = null;
        _notify();
        return true;
      } catch (e) {
        _error = _readableError(e);
        _notify();
        return false;
      }
    }
    if (cloudMode) return false;
    final info = PairingInfo.parse(code);
    if (info == null || !_securityReady) return false;
    if (isActive || _busy) await stop();
    try {
      await _secure.write(key: 'paired_token', value: info.token);
      await prefs?.setString('paired_host', info.host);
      await prefs?.setInt('paired_port', info.port);
      _paired = info;
      _remoteRoom = null;
      _remoteBattery = null;
      _remoteCharging = null;
      _remoteStatusAt = null;
      _suppressAuto = false;
      _error = null;
      _notify();
      unawaited(_watchTailscale());
      return true;
    } catch (_) {
      _error = 'Pairing could not be saved securely. Please try again.';
      _notify();
      return false;
    }
  }

  /// Authenticator setup on the home phone. Each returns null on success, or a
  /// sentence for the person on failure, so the dialog can show it in place.
  Future<({String secret, String uri})?> startAuthenticator() async {
    try {
      return await _cloudConnection().startAuthenticator();
    } catch (e) {
      _error = _readableError(e);
      _notify();
      return null;
    }
  }

  /// Phones paired to this home (home phone only). Null if it could not load.
  Future<List<CloudMember>?> connectedDevices() async {
    try {
      return await _cloudConnection().members();
    } catch (e) {
      _error = _readableError(e);
      return null;
    }
  }

  Future<String?> revokeDevice(String uid) async {
    try {
      await _cloudConnection().revokeMember(uid);
      return null;
    } catch (e) {
      return _readableError(e);
    }
  }

  Future<({String? question, bool hasAnswer})?> answerInfo() async {
    try {
      return await _cloudConnection().answerInfo();
    } catch (e) {
      _error = _readableError(e);
      _notify();
      return null;
    }
  }

  Future<String?> setAnswer(String question, String answer) async {
    try {
      await _cloudConnection().setAnswer(question, answer);
      return null;
    } catch (e) {
      return _readableError(e);
    }
  }

  Future<String?> confirmAuthenticator(String code) async {
    try {
      await _cloudConnection().confirmAuthenticator(code);
      _notify();
      return null;
    } catch (e) {
      return _readableError(e);
    }
  }

  Future<String?> disableAuthenticator(String code) async {
    try {
      await _cloudConnection().disableAuthenticator(code);
      _notify();
      return null;
    } catch (e) {
      return _readableError(e);
    }
  }

  Future<void> forgetPairing() async {
    if (cloudMode) {
      try {
        await stop();
        await _cloudConnection().forget();
        _wantListening = false;
      } catch (e) {
        _error = _readableError(e);
      }
      _notify();
      return;
    }
    if (isListening || isWatching || _busy) await stop();
    await _secure.delete(key: 'paired_token');
    await prefs?.remove('paired_host');
    await prefs?.remove('paired_port');
    _paired = null;
    _remoteStatusAt = null;
    _wantListening = false;
    _notify();
  }

  Future<void> setAutoConnect(bool value) async {
    _autoConnect = value;
    _suppressAuto = false;
    await prefs?.setBool('auto_connect', value);
    _notify();
    unawaited(_watchTailscale());
  }

  Future<void> _watchTailscale() async {
    if (_disposed || _watching) return;
    _watching = true;
    try {
      if (cloudMode) {
        final cloud = _cloud;
        if (!needsSetup &&
            _deviceRole == DeviceRole.away &&
            hasPairing &&
            cloud?.online == true &&
            (_autoConnect || _wantListening) &&
            !_suppressAuto &&
            !_busy &&
            (_role == MonitorRole.idle || (isListening && !cloud!.hearing))) {
          if (_role == MonitorRole.idle) {
            await _startCloudAway(
              alertsOnly: _wantListening
                  ? _wantAlertsOnly
                  : _autoMode == 'alerts',
              quiet: true,
            );
          }
        }
        return;
      }
      final address = await PairingInfo.ownTailscaleAddress();
      if (_disposed) return;
      if (address != _tailscaleAddress) {
        _tailscaleAddress = address;
        _notify();
      }
      if (needsSetup ||
          address == null ||
          _paired == null ||
          _deviceRole != DeviceRole.away ||
          !_securityReady ||
          !(_autoConnect || _wantListening) ||
          _suppressAuto ||
          _role != MonitorRole.idle ||
          _busy) {
        return;
      }
      await _startListening(
        _paired!,
        quiet: true,
        alertsOnly: _wantListening ? _wantAlertsOnly : _autoMode == 'alerts',
      );
    } finally {
      _watching = false;
    }
  }

  Future<void> _refreshHealth() async {
    _smartHome.tick();
    if (_disposed) return;
    await _mergeInbox();
    final before = _events.length;
    _pruneActivity();
    if (before != _events.length) await _saveActivity();
    try {
      _batteryLevel = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      _charging = state == BatteryState.charging || state == BatteryState.full;
      if (isMonitoring) _checkBattery(_batteryLevel, _charging);
    } catch (_) {
      _batteryLevel = null;
      _charging = null;
    }
    _notify();
    _cloud?.health(_roomName, _batteryLevel, _charging);
    _cloud?.detectorHealth({
      'enabled': soundWatch.enabled,
      'ready': soundWatch.ready,
      'windows': soundWatch.windowsAnalysed,
      'lastAudioMs': _lastCaptureAt?.millisecondsSinceEpoch,
    });
    if (isGuardian && !cloudAlertsReady) unawaited(_connectGuardian());
    if (isMonitoring &&
        (_lastCaptureAt ?? _sessionStarted) != null &&
        DateTime.now().difference((_lastCaptureAt ?? _sessionStarted)!) >
            const Duration(seconds: 15)) {
      _error = 'Monitoring stopped because microphone samples stopped arriving. Open Home and start again.';
      _addEvent(ActivityKind.disconnected, 'Microphone feed stopped');
      unawaited(stop());
    }
  }

  void _checkBattery(int? level, bool? charging) {
    if (level != null &&
        level <= 15 &&
        charging == false &&
        !_lowBatteryReported) {
      _lowBatteryReported = true;
      _addEvent(ActivityKind.battery, 'Home phone battery is low');
      unawaited(
        _alerts.show(
          'Home phone battery is low',
          '$displayRoom: $level% remaining.',
        ),
      );
    }
    if ((level ?? 0) > 20 || charging == true) _lowBatteryReported = false;
  }

  Future<void> startTalking() async {
    if (guardianOnly && _deviceRole == DeviceRole.home) {
      await startGuardian();
      return;
    }
    if (cloudMode) {
      await _startCloudHome();
      return;
    }
    if (isActive || _busy || !_securityReady) return;
    if (!(Platform.isAndroid || Platform.isIOS)) {
      _error = 'Sharing needs an Android or iOS phone.';
      _notify();
      return;
    }
    _busy = true;
    _error = null;
    final epoch = ++_epoch;
    _notify();
    try {
      final address = await PairingInfo.ownTailscaleAddress();
      if (address == null) {
        throw StateError('Connect Tailscale on this phone before sharing.');
      }
      _tailscaleAddress = address;
      if (!await _recorder.hasPermission()) {
        throw StateError(
          'Allow microphone access in this phone’s settings to share sound.',
        );
      }
      if (epoch != _epoch) return;
      if (Platform.isAndroid) {
        final shown = await _channel.invokeMethod<bool>('start', {
          'text': notificationText(hasListener: false),
        });
        if (shown != true) {
          throw StateError(
            'Allow Home Listen notifications before sharing the microphone.',
          );
        }
      }
      if (epoch != _epoch) {
        await _teardownTalker();
        return;
      }
      final pcm = (await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: MicStream.sampleRate,
          numChannels: MicStream.channels,
          autoGain: false,
          echoCancel: false,
          noiseSuppress: false,
        ),
      )).asBroadcastStream();
      if (epoch != _epoch) {
        await _teardownTalker();
        return;
      }
      _meterFramer.reset();
      _meterSub = pcm.listen((chunk) {
        for (final frame in _meterFramer.add(chunk)) {
          _processPcm(frame);
        }
      }, onError: (_) {});
      final talker =
          MicTalker(
              bindAddress: InternetAddress(_tailscaleAddress!),
              token: _ownToken,
              statusProvider: () => {
                'room': _roomName,
                'battery': _batteryLevel,
                'charging': _charging,
                'version': 1,
              },
            )
            ..onChanged = _talkerChanged
            ..onFailure = (reason) {
              _error = reason;
              unawaited(stop());
            };
      _talker = talker;
      await talker.start(pcm);
      if (epoch != _epoch || _disposed) {
        await _teardownTalker();
        return;
      }
      _role = MonitorRole.talking;
      unawaited(_ensureSoundWatch());
      _sessionStarted = DateTime.now();
      _addEvent(ActivityKind.session, 'Microphone sharing started');
    } catch (e) {
      await _teardownTalker();
      _error = _readableError(e);
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> _startCloudHome() async {
    if (isActive || _busy || _disposed) return;
    if (!Platform.isAndroid) {
      _error = 'Live home sharing needs Android. On an iPhone, use Guardian.';
      _notify();
      return;
    }
    _busy = true;
    _error = null;
    final epoch = ++_epoch;
    _notify();
    try {
      final cloud = _cloudConnection()
        ..health(_roomName, _batteryLevel, _charging);
      await cloud.ensureReady();
      if (!await _recorder.hasPermission()) {
        throw StateError('Allow microphone access to share sound.');
      }
      if (epoch != _epoch) return;
      final shown = await _channel.invokeMethod<bool>('start', {
        'text': notificationText(hasListener: false),
      });
      if (shown != true) {
        throw StateError(
          'Allow visible Home Listen notifications before sharing.',
        );
      }
      if (epoch != _epoch) return;
      await cloud.startHome();
      if (epoch != _epoch || _disposed) {
        await cloud.stopHome();
        return;
      }
      _role = MonitorRole.talking;
      _sessionStarted = DateTime.now();
      unawaited(_ensureSoundWatch());
      _addEvent(ActivityKind.session, 'Cloud microphone sharing started');
      _talkerChanged();
    } catch (e) {
      await _cloud?.stopHome();
      await _teardownTalker();
      if (epoch == _epoch) _error = _readableError(e);
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> setGuardianOnly(bool value) async {
    if (value == _guardianOnly) return;
    // Changing capture modes stops first; the next start always needs a local tap.
    if (isActive || _busy) await stop();
    _guardianOnly = value;
    await prefs?.setBool('guardian_only', value);
    _notify();
  }

  Future<void> startGuardian() async {
    if (isActive || _busy || _disposed || _deviceRole != DeviceRole.home) {
      return;
    }
    if (!(Platform.isAndroid || Platform.isIOS)) {
      _error = 'Guardian monitoring needs an Android phone or an iPhone.';
      _notify();
      return;
    }
    _busy = true;
    _error = null;
    final epoch = ++_epoch;
    _notify();
    try {
      if (!await _recorder.hasPermission()) {
        throw StateError('Allow microphone access to start Guardian.');
      }
      await setSoundEnabled(true);
      if (!soundWatch.ready || !soundWatch.enabled) {
        throw StateError(
          'The local sound detector must load before Guardian starts.',
        );
      }
      if (epoch != _epoch || _disposed) return;
      await _showGuardianNotice();
      if (epoch != _epoch || _disposed) return;
      final pcm = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          autoGain: false,
          echoCancel: false,
          noiseSuppress: false,
        ),
      );
      if (epoch != _epoch || _disposed) {
        await _teardownTalker();
        return;
      }
      _meterFramer.reset();
      _role = MonitorRole.guardian;
      _sessionStarted = DateTime.now();
      _lastCaptureAt = null;
      _meterSub = pcm.listen(
        (chunk) {
          for (final frame in _meterFramer.add(chunk)) {
            _processPcm(frame);
          }
        },
        onError: (Object _) {
          if (epoch != _epoch || _disposed) return;
          _error = 'Guardian stopped because its microphone feed failed. Start again from Home.';
          unawaited(stop());
        },
        onDone: () {
          if (epoch == _epoch && !_disposed && isGuardian) {
            _error = 'Guardian microphone feed ended. Start again from Home.';
            unawaited(stop());
          }
        },
      );
      _addEvent(ActivityKind.session, 'Guardian started · live listening off');
      unawaited(_connectGuardian(force: true));
    } catch (e) {
      await _teardownTalker();
      if (epoch == _epoch) _error = _readableError(e);
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Android shows a persistent microphone notification with a Stop action.
  /// An iPhone has none: iOS shows its own recording indicator while the
  /// microphone is open, and Stop stays on the Home screen.
  Future<void> _showGuardianNotice() async {
    if (!Platform.isAndroid) return;
    final shown = await _channel.invokeMethod<bool>('start', {
      'text': 'Guardian on — local sound detection • live listening off',
    });
    if (shown != true) {
      throw StateError(
        'Allow visible Home Listen notifications before starting Guardian.',
      );
    }
  }

  Future<void> _connectGuardian({bool force = false}) async {
    if (!isGuardian ||
        !cloudMode ||
        cloudServer.isEmpty ||
        _guardianConnecting ||
        _disposed) {
      return;
    }
    final now = DateTime.now();
    if (!force &&
        _lastGuardianConnect != null &&
        now.difference(_lastGuardianConnect!) < const Duration(seconds: 30)) {
      return;
    }
    _lastGuardianConnect = now;
    _guardianConnecting = true;
    final epoch = _epoch;
    try {
      final cloud = _cloudConnection()
        ..health(_roomName, _batteryLevel, _charging);
      if (!cloud.sharing) {
        await cloud.startGuardian();
      } else {
        await cloud.refreshHome();
      }
      if (epoch != _epoch || !isGuardian || _disposed) return;
      _guardianCloudProblem = null;
      unawaited(_flushOutbox());
    } catch (e) {
      if (epoch == _epoch && isGuardian) {
        _guardianCloudProblem =
            'Local detection continues · ${_readableError(e)}';
      }
    } finally {
      _guardianConnecting = false;
      _notify();
    }
  }

  Future<void> _saveGuardianSettings() async {
    await prefs?.setString('guardian_settings', _guardianSettings.encode());
  }

  Future<void> setQuietHours({bool? enabled, int? start, int? end}) async {
    _guardianSettings = _guardianSettings.copyWith(
      quietEnabled: enabled,
      quietStart: start,
      quietEnd: end,
    );
    await _saveGuardianSettings();
    _notify();
  }

  Future<void> setSoundRule(String category, SoundRule rule) async {
    if (!guardianCategories.contains(category)) return;
    final enableRecording =
        rule.recordAudio &&
        _guardianSettings.rules[category]?.recordAudio != true;
    _guardianSettings = _guardianSettings.copyWith(
      rules: {..._guardianSettings.rules, category: rule},
    );
    soundWatch.rules = _guardianSettings.rules;
    soundWatch.reset();
    if (enableRecording) {
      _recordingPaused = false;
      await prefs?.setBool('recording_paused', false);
    }
    await _recordings.stop();
    _lastRecordingVerdict = null;
    _cloud?.requestRecordingAudio(
      _deviceRole == DeviceRole.away && _recordingOptIn,
    );
    if (_recordingOptIn && _deviceRole == DeviceRole.away && !cloudMode) {
      await setSoundEnabled(true);
    }
    await _saveGuardianSettings();
    _notify();
  }

  Future<void> setRetentionDays(int days) async {
    _guardianSettings = _guardianSettings.copyWith(retentionDays: days);
    _pruneActivity();
    if (_deviceRole == DeviceRole.away) {
      await _recordings.prune(retentionDays: days);
    }
    await _saveGuardianSettings();
    await _saveActivity();
    _notify();
  }

  void _pruneActivity() {
    final cutoff = DateTime.now().subtract(
      Duration(days: _guardianSettings.retentionDays),
    );
    _events.removeWhere((e) => e.at.isBefore(cutoff));
    if (_events.length > 500) _events.removeRange(500, _events.length);
  }

  Future<void> _saveActivity() async {
    await prefs?.setString(
      'activity',
      jsonEncode(_events.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> _saveOutbox() async {
    await prefs?.setString(
      'alert_outbox',
      jsonEncode(_outbox.map((a) => a.toJson()).toList()),
    );
  }

  Future<void> _mergeInbox() async {
    final preferences = prefs;
    if (preferences == null || _mergingInbox) return;
    _mergingInbox = true;
    final epoch = _historyEpoch;
    try {
      final incoming = await AlertInbox.pending(preferences);
      if (_disposed || epoch != _historyEpoch) return;
      for (final event in incoming) {
        if (!_events.any((e) => e.id == event.id)) _events.add(event);
      }
      _events.sort((a, b) => b.at.compareTo(a.at));
      _pruneActivity();
      if (incoming.isNotEmpty) await _saveActivity();
      // Remove only the keys read above; another notification may have arrived.
      for (final event in incoming) {
        await preferences.remove('${AlertInbox.prefix}${event.id}');
      }
    } finally {
      _mergingInbox = false;
    }
  }

  String exportActivity() => jsonEncode({
    'schemaVersion': 2,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'events': events.map((e) => e.toJson()).toList(),
  });

  Future<String> exportEventFile() async {
    try {
      final saved = await _channel.invokeMethod<bool>('exportActivity', {
        'content': exportActivity(),
      });
      return saved == true
          ? 'Event history saved. No audio was included.'
          : 'Export cancelled.';
    } catch (_) {
      return 'Could not save event history. Try another location.';
    }
  }

  Future<String?> openSpeechSession() async {
    if (isMonitoring || _busy) await stop();
    try {
      await _channel.invokeMethod<bool>('openSpeechSession');
      return null;
    } catch (_) {
      return 'Could not open Oralyvo. Open oralyvo.app in your browser.';
    }
  }

  void _setDelivery(String id, AlertDelivery delivery) {
    final index = _events.indexWhere((e) => e.id == id);
    if (index < 0) return;
    _events[index] = _events[index].withDelivery(delivery);
    unawaited(_saveActivity());
    _notify();
  }

  void _enqueueAlert(ActivityEvent event) {
    if (event.id == null) return;
    if (_outbox.length >= 50) {
      final removed = _outbox.removeAt(0);
      _setDelivery(removed.id, AlertDelivery.expired);
    }
    _outbox.add(
      PendingAlert(
        id: event.id!,
        title: event.title,
        at: event.at,
        roomId: _cloud?.roomId,
        origin: cloudServer,
      ),
    );
    unawaited(_saveOutbox());
    unawaited(_flushOutbox());
  }

  Future<void> retryAlerts() async {
    if (isGuardian) await _connectGuardian(force: true);
    await _flushOutbox(force: true);
  }

  Future<void> _flushOutbox({bool force = false}) async {
    if (_disposed || _flushingAlerts) return;
    _flushingAlerts = true;
    try {
      final now = DateTime.now();
      for (final alert in _outbox.toList()) {
        if (alert.expired(now)) {
          _outbox.remove(alert);
          _setDelivery(alert.id, AlertDelivery.expired);
        }
      }
      final cloud = _cloud;
      if (!isMonitoring || !cloudMode || cloud?.sharing != true) return;
      // Send sequentially so the server's event grouping limit can settle.
      for (final alert in _outbox.toList()) {
        if (_disposed || !isMonitoring || !cloud!.sharing) break;
        if (!_outbox.contains(alert)) continue;
        if (!force && !alert.due(DateTime.now())) continue;
        final event = _events.where((e) => e.id == alert.id).firstOrNull;
        // Re-check the clock on every retry. An offline alert must not wake
        // someone after quiet hours begin; explicit test alerts still work.
        if (alert.title != 'Test alert' &&
            _guardianSettings.suppresses(
              event?.category ?? '',
              DateTime.now(),
            )) {
          continue;
        }
        if ((alert.roomId != null && alert.roomId != cloud.roomId) ||
            (alert.origin != null && alert.origin != cloudServer)) {
          _outbox.remove(alert);
          _setDelivery(alert.id, AlertDelivery.expired);
          continue;
        }
        try {
          final result = await cloud.sendAlertDetailed(
            alert.title,
            eventId: alert.id,
          );
          if (!_outbox.contains(alert)) continue;
          _outbox.remove(alert);
          if (result.retryable) {
            _outbox.add(alert.retry(DateTime.now()));
          } else {
            _setDelivery(
              alert.id,
              result.expired
                  ? AlertDelivery.expired
                  : result.sent > 0
                  ? AlertDelivery.submitted
                  : result.registered == 0
                  ? AlertDelivery.noRecipients
                  : AlertDelivery.failed,
            );
          }
        } catch (_) {
          if (_outbox.remove(alert)) _outbox.add(alert.retry(DateTime.now()));
        }
        await _saveOutbox();
      }
    } finally {
      await _saveOutbox();
      _flushingAlerts = false;
      _notify();
    }
  }

  Future<String?> setDeviceAccess(
    String uid,
    String role,
    DateTime? expiresAt,
  ) async {
    try {
      await _cloudConnection().setMemberAccess(uid, role, expiresAt);
      return null;
    } catch (e) {
      return _readableError(e);
    }
  }

  Future<void> _startCloudAway({
    required bool alertsOnly,
    bool quiet = false,
  }) async {
    if (_busy || isActive || _disposed || !hasPairing) return;
    _busy = true;
    final epoch = ++_epoch;
    if (!quiet) _error = null;
    _suppressAuto = false;
    _wantListening = true;
    _wantAlertsOnly = alertsOnly;
    _notify();
    try {
      final cloud = _cloudConnection();
      await cloud.ensureReady();
      final onlyAlerts = alertsOnly || !cloud.liveAvailable;
      _wantAlertsOnly = onlyAlerts;
      if (onlyAlerts) {
        _notificationsAllowed = await _alerts.requestPermission();
        await cloud.enableAlerts();
      } else {
        if (Platform.isAndroid) {
          final shown = await _channel.invokeMethod<bool>('startPlayback', {
            'text': 'Listening to $displayRoom — tap to open or stop',
          });
          if (shown != true) {
            throw StateError(
              'Allow notifications to keep listening with the screen locked.',
            );
          }
        }
        if (epoch != _epoch) return;
        await cloud.startAway(_volume);
        _notificationsAllowed = await _alerts.requestPermission();
        await cloud.enableAlerts();
      }
      if (epoch != _epoch || _disposed) {
        await cloud.stopAway();
        return;
      }
      _role = onlyAlerts ? MonitorRole.watching : MonitorRole.listening;
      _sessionStarted = DateTime.now();
      _error = null;
      _addEvent(
        ActivityKind.connected,
        onlyAlerts
            ? 'Cloud sound alerts enabled'
            : 'Connecting to live home audio',
      );
    } catch (e) {
      await _cloud?.stopAway(disableAlerts: false);
      if (Platform.isAndroid) {
        try {
          await _channel.invokeMethod<void>('stop');
        } catch (_) {}
      }
      if (!quiet && epoch == _epoch) _error = _readableError(e);
    } finally {
      _busy = false;
      _notify();
    }
  }

  void _talkerChanged() {
    if (Platform.isAndroid && (_talker != null || _cloud?.sharing == true)) {
      unawaited(
        _channel
            .invokeMethod<void>('update', {
              'text': isGuardian
                  ? 'Guardian on — local sound detection • live listening off'
                  : notificationText(
                      hasListener: talkerHasListener,
                      listeners: talkerListenerCount,
                      watchers: talkerWatcherCount,
                    ),
            })
            .catchError((_) {}),
      );
    }
    _notify();
  }

  Future<void> _teardownTalker() async {
    final talker = _talker;
    _talker = null;
    await _meterSub?.cancel();
    _meterSub = null;
    try {
      await _recorderInstance?.stop();
    } catch (_) {}
    await talker?.stop();
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<void>('stop');
      } catch (_) {}
    }
  }

  Future<void> startListening() async {
    if (cloudMode) {
      await _startCloudAway(alertsOnly: false);
      return;
    }
    if (_paired == null || _busy || isActive) return;
    _suppressAuto = false;
    _wantListening = true;
    _wantAlertsOnly = false;
    await _startListening(_paired!, quiet: false);
  }

  /// Connects for alerts only: no audio is sent to this phone and nothing
  /// plays. It costs a small message every ten seconds instead of fifty audio
  /// packets a second, and the home phone's Sound Watch does the listening.
  Future<void> startWatching() async {
    if (cloudMode) {
      await _startCloudAway(alertsOnly: true);
      return;
    }
    if (_paired == null || _busy || isActive) return;
    _suppressAuto = false;
    _wantListening = true;
    _wantAlertsOnly = true;
    await _startListening(_paired!, quiet: false, alertsOnly: true);
  }

  /// Moves a connected phone between listening and alerts-only without
  /// letting go of the connection's background notification.
  ///
  /// The home phone sees the same address register again with the other mode,
  /// which replaces the earlier registration: audio stops or starts on its own,
  /// and the phone is never counted twice. Nothing here touches the automatic
  /// setting, so a manual switch is not undone five seconds later.
  Future<void> switchMode({required bool alertsOnly}) async {
    if (cloudMode) {
      await stop();
      await _startCloudAway(alertsOnly: alertsOnly);
      return;
    }
    final paired = _paired;
    if (paired == null || _busy || _disposed) return;
    if (!(isListening || isWatching) || alertsOnly == isWatching) return;

    _busy = true;
    _notify();
    final old = _listener;
    _listener = null;
    _role = MonitorRole.idle;
    _interruptRecording();
    _remoteStatusAt = null;
    soundWatch.reset();
    try {
      await old?.stop();
    } finally {
      _busy = false;
    }
    _suppressAuto = false;
    _wantListening = true;
    _wantAlertsOnly = alertsOnly;
    await _startListening(paired, quiet: false, alertsOnly: alertsOnly);
  }

  /// Sends a harmless test alert so the alert path can be checked without
  /// having to make a real noise. Returns a sentence saying what happened.
  ///
  /// On the home phone it goes to every connected phone, over the same path a
  /// real alert takes. On any phone it also posts a local notification, which
  /// proves that notifications are allowed there.
  Future<String> sendTestAlert() async {
    if (cloudMode && cloudServer.isNotEmpty && _deviceRole == DeviceRole.home) {
      if (!isMonitoring) {
        return 'Start Guardian or sharing before sending a test alert.';
      }
      final event = _addEvent(
        ActivityKind.sound,
        'Test alert',
        delivery: AlertDelivery.queued,
      );
      if (event != null) _enqueueAlert(event);
      _notify();
      return 'Test alert saved. Activity shows whether the push provider accepted it or a retry is waiting.';
    }
    if (_deviceRole == DeviceRole.home && !_homeShowsAlerts && !isGuardian) {
      // Nothing is shown here; the test goes only to connected phones.
      final sent = _talker?.sendAlert('Test alert', _roomName) ?? 0;
      _addEvent(ActivityKind.sound, 'Test alert sent');
      _notify();
      if (!isTalking) {
        return 'Sharing is off, so nothing was sent. Start sharing first.';
      }
      if (sent == 0) {
        return 'No other phone is connected to this one right now, so '
            'nothing was sent.';
      }
      return 'Sent to $sent connected phone${sent == 1 ? '' : 's'}. Check '
          'that it appeared there. Nothing is shown on this phone.';
    }
    _notificationsAllowed = await _alerts.requestPermission();
    if (!_notificationsAllowed) {
      _notify();
      return 'Notifications are blocked for Home Listen on this phone, so no '
          'alert can appear here. Allow them in the phone settings.';
    }
    unawaited(
      _alerts.show('Test alert', '$displayRoom • This is only a test.'),
    );
    _addEvent(ActivityKind.sound, 'Test alert');
    if (_deviceRole == DeviceRole.home) {
      if (isGuardian) {
        _notify();
        return 'A local test notification was shown. Configure a cloud server and pair another phone to test remote Guardian alerts.';
      }
      final sent = _talker?.sendAlert('Test alert', _roomName) ?? 0;
      _notify();
      if (!isTalking) {
        return 'Shown on this phone. Sharing is off, so nothing was sent to '
            'your other phone.';
      }
      if (sent == 0) {
        return 'Shown on this phone, but no other phone is connected to it '
            'right now, so nothing was sent.';
      }
      return 'Shown on this phone and sent to $sent connected '
          'phone${sent == 1 ? '' : 's'}. Check that it appeared there.';
    }
    _notify();
    return 'A test notification was shown on this phone, so alerts can '
        'appear here. To test the link from home, send one from the home phone.';
  }

  Future<void> setAutoMode(String mode) async {
    _autoMode = mode == 'alerts' ? 'alerts' : 'listen';
    await prefs?.setString('auto_mode', _autoMode);
    _notify();
  }

  /// An alert from the home phone's Sound Watch, shown as a notification and
  /// kept in the activity list. The text is all that was sent; no audio.
  void _onRemoteAlert(Map<String, dynamic> alert) {
    final title = alert['title'];
    if (title is! String || title.isEmpty || title.length > 80) return;
    final room = alert['room'] is String && (alert['room'] as String).isNotEmpty
        ? (alert['room'] as String)
        : displayRoom;
    _remoteAlertAt[title] = DateTime.now();
    final id = alert['id'] is String ? alert['id'] as String : null;
    if (id != null && _events.any((e) => e.id == id)) return;
    _addEvent(
      ActivityKind.sound,
      title,
      id: id,
      room: room,
      category: alert['kind'] is String ? alert['kind'] : null,
      delivery: AlertDelivery.received,
    );
    unawaited(_alerts.show(title, '$room • Tap to open Home Listen.'));
    _notify();
  }

  Future<void> _startListening(
    PairingInfo paired, {
    required bool quiet,
    bool alertsOnly = false,
  }) async {
    if (_disposed || _busy || isActive) return;
    _busy = true;
    final epoch = ++_epoch;
    if (!quiet) _error = null;
    _notify();
    final listener = MicListener()
      ..volume = _volume
      ..reduceHiss = _reduceHiss
      ..onChanged = _notify
      ..onPcm = _processPcm
      ..onAlert = _onRemoteAlert
      ..onStatus = _readStatus
      ..onFailure = (reason) {
        _error = reason;
        _notify();
      };
    _pendingListener = listener;
    try {
      // Alerts arrive as notifications, so this phone must be allowed to show
      // them. Listening with sound does not otherwise need the permission.
      if (alertsOnly) {
        _notificationsAllowed = await _alerts.requestPermission();
      }
      if (Platform.isAndroid) {
        final shown = await _channel.invokeMethod<bool>('startPlayback', {
          'text': alertsOnly
              ? 'Connecting to your home phone for alerts — tap to open or stop'
              : 'Connecting to your home phone — tap to open or stop',
        });
        if (shown != true) {
          throw StateError(
            'Allow notifications to keep listening with the screen locked.',
          );
        }
      }
      if (epoch != _epoch) {
        await _teardownTalker();
        return;
      }
      await listener.start(
        paired.host,
        port: paired.port,
        token: paired.token,
        alertsOnly: alertsOnly,
      );
      if (epoch != _epoch || _disposed) {
        await listener.stop();
        return;
      }
      _listener = listener;
      listener.onStalled = () => unawaited(_recoverListener(listener));
      _role = alertsOnly ? MonitorRole.watching : MonitorRole.listening;
      if (!alertsOnly) unawaited(_ensureSoundWatch());
      _wantListening = true;
      _wantAlertsOnly = alertsOnly;
      _sessionStarted = DateTime.now();
      _error = null;
      _addEvent(
        ActivityKind.connected,
        alertsOnly
            ? 'Watching for alerts from home phone'
            : 'Connected to home phone',
      );
      if (Platform.isAndroid) {
        unawaited(
          _channel
              .invokeMethod<void>('update', {
                'text': alertsOnly
                    ? 'Watching for alerts from $displayRoom — tap to open or stop'
                    : 'Listening to $displayRoom — tap to open or stop',
              })
              .catchError((_) {}),
        );
      }
    } catch (e) {
      await listener.stop();
      if (Platform.isAndroid) {
        try {
          if (_wantListening && epoch == _epoch && !_disposed) {
            await _channel.invokeMethod<void>('update', {
              'text': 'Reconnecting to your home phone — tap to open or stop',
            });
          } else {
            await _channel.invokeMethod<void>('stop');
          }
        } catch (_) {}
      }
      if (!quiet && epoch == _epoch && !_disposed) _error = _readableError(e);
    } finally {
      if (_pendingListener == listener) _pendingListener = null;
      _busy = false;
      _notify();
    }
  }

  Future<void> _recoverListener(MicListener listener) async {
    if (_listener != listener || _disposed) return;
    _listener = null;
    _role = MonitorRole.idle;
    _interruptRecording();
    _remoteStatusAt = null;
    soundWatch.reset();
    await listener.stop();
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<void>('update', {
          'text': 'Connection lost — reconnecting to your home phone',
        });
      } catch (_) {}
    }
    _addEvent(
      ActivityKind.disconnected,
      'Audio connection lost — reconnecting',
    );
    unawaited(
      _alerts.show(
        'Home Listen connection lost',
        '$displayRoom: reconnecting to the home phone.',
      ),
    );
    _notify();
    unawaited(_watchTailscale());
  }

  void _readStatus(Map<String, dynamic> status) {
    final battery = status['battery'];
    _remoteBattery = battery is int && battery >= 0 && battery <= 100
        ? battery
        : null;
    _remoteCharging = status['charging'] is bool ? status['charging'] : null;
    if (status['room'] is String) {
      final name = status['room'] as String;
      _remoteRoom = name.substring(0, math.min(32, name.length));
    }
    _remoteStatusAt = DateTime.now();
    _checkBattery(_remoteBattery, _remoteCharging);
    _notify();
  }

  /// Exposed so a test can drive the level meter without a microphone.
  @visibleForTesting
  void processPcmForTest(Int16List pcm) => _processPcm(pcm);

  void _processPcm(Int16List pcm) {
    if (_disposed) return;
    _lastCaptureAt = DateTime.now();
    if (_deviceRole == DeviceRole.away && !cloudMode) _feedRecording(pcm);
    soundWatch.feed(pcm);
    var sum = 0.0;
    for (final v in pcm) {
      sum += (v / 32768.0) * (v / 32768.0);
    }
    final rms = math.sqrt(sum / math.max(1, pcm.length));
    final now = DateTime.now();
    if (_lastUiUpdate == null ||
        now.difference(_lastUiUpdate!) > const Duration(milliseconds: 100)) {
      _levels.removeAt(0);
      _levels.add((rms * 8).clamp(0.03, 1));
      _lastUiUpdate = now;
      _notify();
    }
  }

  /// Draws the listening phone's sound wave from the loudness WebRTC reports.
  /// The square root makes a quiet room visible and a loud one not all
  /// clipped at the top.
  void _onCloudLevel(double level) {
    if (_disposed) return;
    _levels.removeAt(0);
    _levels.add((math.sqrt(level.clamp(0.0, 1.0)) * 1.4).clamp(0.03, 1.0));
    _notify();
  }

  bool _reduceHiss = true;
  bool get reduceHiss => _reduceHiss;

  Future<void> setReduceHiss(bool value) async {
    _reduceHiss = value;
    _listener?.reduceHiss = value;
    await prefs?.setBool('reduce_hiss', value);
    _notify();
  }

  void setVolume(double value) {
    _volume = value.clamp(0, 1);
    _listener?.volume = _volume;
    _cloud?.setVolume(_volume);
    _notify();
  }

  /// Sound Watch is a setting the user left on; make it true in practice.
  /// Called when a session starts, because restoring it at launch can lose a
  /// race with the app starting up.
  Future<void> _ensureSoundWatch() async {
    if (_disposed || _soundLoading) return;
    if (prefs?.getBool('sound_enabled') != true &&
        !_recordingOptIn &&
        _deviceRole != DeviceRole.home) {
      return;
    }
    if (soundWatch.enabled && soundWatch.ready) return;
    debugPrint('sound watch: restoring after session start');
    await setSoundEnabled(true);
  }

  Future<void> setSoundEnabled(bool value) async {
    if (_soundLoading) return;
    if (!value) {
      _recordingPaused = true;
      await prefs?.setBool('recording_paused', true);
      _interruptRecording();
      _cloud?.requestRecordingAudio(false);
      if (isGuardian) await stop();
      soundWatch.enabled = false;
      soundWatch.reset();
      await prefs?.setBool('sound_enabled', false);
      _notify();
      return;
    }
    _soundLoading = true;
    _notify();
    try {
      debugPrint('sound watch: loading the detector');
      await soundWatch.initialize();
      if (_disposed) return;
      soundWatch.enabled = true;
      _recordingPaused = false;
      await prefs?.setBool('recording_paused', false);
      _cloud?.requestRecordingAudio(
        _deviceRole == DeviceRole.away && _recordingOptIn,
      );
      await prefs?.setBool('sound_enabled', true);
      debugPrint('sound watch: enabled, ready=${soundWatch.ready}');
      _notify();
      _notificationsAllowed = await _alerts.requestPermission().timeout(
        const Duration(seconds: 10),
        onTimeout: () => false,
      );
      if (_disposed) return;
      if (!_notificationsAllowed) _error = 'Sound Watch is active in the app. Enable notifications in phone settings for alerts outside this screen.';
    } catch (e) {
      debugPrint('sound watch: failed to load: $e');
      _error = 'Sound Watch could not load on this device. Live listening is available.';
    } finally {
      _soundLoading = false;
      _notify();
    }
  }

  Future<void> setSoundThreshold(double value) async {
    soundWatch.sensitivity = value.clamp(0.2, 0.85);
    await prefs?.setDouble('sound_threshold', soundWatch.sensitivity);
    _guardianSettings = _guardianSettings.copyWith(
      rules: {
        for (final e in _guardianSettings.rules.entries)
          e.key: e.value.copyWith(threshold: soundWatch.sensitivity),
      },
    );
    soundWatch.rules = _guardianSettings.rules;
    await _saveGuardianSettings();
    _notify();
  }

  Future<void> toggleSoundCategory(String name, bool selected) async {
    if (selected) {
      soundWatch.categories.add(name);
    } else {
      soundWatch.categories.remove(name);
    }
    soundWatch.reset();
    await _recordings.stop();
    _lastRecordingVerdict = null;
    _cloud?.requestRecordingAudio(
      _deviceRole == DeviceRole.away && _recordingOptIn,
    );
    await prefs?.setStringList(
      'sound_categories',
      soundWatch.categories.toList(),
    );
    _notify();
  }

  void calibrateRoom() {
    if (isActive) {
      soundWatch.calibrate();
      _notify();
    }
  }

  ActivityEvent? _addEvent(
    ActivityKind kind,
    String title, {
    String? id,
    String? category,
    double? score,
    int? durationMs,
    AlertDelivery delivery = AlertDelivery.local,
    String? room,
  }) {
    if (_disposed) return null;
    final event = ActivityEvent(
      kind: kind,
      title: title,
      room: room ?? displayRoom,
      at: DateTime.now(),
      id: id ?? PairingInfo.newToken().substring(0, 24),
      category: category,
      modelScore: score,
      modelVersion: score == null ? null : 'yamnet-audioset-v1',
      durationMs: durationMs,
      delivery: delivery,
    );
    _events.insert(0, event);
    _pruneActivity();
    prefs?.setString(
      'activity',
      jsonEncode(_events.map((e) => e.toJson()).toList()),
    );
    return event;
  }

  Future<void> clearActivity() async {
    _historyEpoch++;
    _smartHome.clearPending();
    _events.clear();
    _outbox.clear();
    await _saveOutbox();
    if (prefs != null) await AlertInbox.clear(prefs!);
    await prefs?.remove('activity');
    _notify();
  }

  String _readableError(Object e) => e
      .toString()
      .replaceFirst('Bad state: ', '')
      .replaceFirst('Exception: ', '');
  Future<void> stop() async {
    final active = isActive;
    _role = MonitorRole.idle;
    _suppressAuto = true;
    _wantListening = false;
    _epoch++;
    _recordingWatchdog?.cancel();
    _recordingWatchdog = null;
    _lastRecordingPcm = null;
    final closingRecordings = _recordings.stop();
    _lastRecordingVerdict = null;
    _smartHome.clearPending();
    _suppressAuto = true;
    _wantListening = false;
    _role = MonitorRole.idle;
    await _cloud?.stopHome();
    await _cloud?.stopAway();
    await _teardownTalker();
    final listener = _listener;
    final pendingListener = _pendingListener;
    _listener = null;
    _pendingListener = null;
    await listener?.stop();
    if (pendingListener != listener) await pendingListener?.stop();
    await closingRecordings;
    _role = MonitorRole.idle;
    _interruptRecording();
    _remoteStatusAt = null;
    _sessionStarted = null;
    _lastCaptureAt = null;
    soundWatch.reset();
    _levels.fillRange(0, _levels.length, 0.03);
    if (active) _addEvent(ActivityKind.session, 'Monitoring stopped');
    _smartHome.tick(force: true);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _watch?.cancel();
    _healthTimer?.cancel();
    _outboxTimer?.cancel();
    _recordingWatchdog?.cancel();
    _channel.setMethodCallHandler(null);
    unawaited(stop().whenComplete(() => _recorderInstance?.dispose()));
    unawaited(soundWatch.dispose());
    unawaited(_cloud?.close());
    unawaited(_smartHome.dispose());
    super.dispose();
  }
}
