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
import 'alerts.dart';
import 'cloud_connection.dart';
import 'cloud_pairing.dart';
import 'pairing.dart';
import 'sound_watch.dart';

enum MonitorRole { idle, talking, listening, watching }

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
    _reduceHiss = prefs?.getBool('reduce_hiss') ?? true;
    _homeShowsAlerts = prefs?.getBool('home_shows_alerts') ?? false;
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
    soundWatch.onEvent = (title) {
      // The home phone already told this phone: do not say it twice.
      final told = _remoteAlertAt[title];
      if (told != null &&
          DateTime.now().difference(told) < const Duration(seconds: 15)) {
        return;
      }
      _addEvent(ActivityKind.sound, title);
      // On the home phone this is what reaches the phone you carry, even when
      // that phone is not playing any audio.
      _talker?.sendAlert(title, _roomName);
      if (_cloud?.sharing == true) {
        unawaited(
          _cloud!
              .sendAlert(title)
              .then<void>(
                (_) {},
                onError: (Object e) {
                  _error = 'Sound heard, but its cloud alert could not be sent. Check internet.';
                  _notify();
                },
              ),
        );
      }
      // The home phone itself stays quiet unless asked: nobody is usually there
      // to read it, and one popping up in the room is only noise.
      if (_deviceRole != DeviceRole.home || _homeShowsAlerts) {
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
      _error = reason;
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
    return _cloud ??= CloudConnection(
      origin: cloudServer,
      prefs: prefs!,
      home: _deviceRole == DeviceRole.home,
      onPcm: _processPcm,
      onLevel: _onCloudLevel,
      onAlert: _onRemoteAlert,
      onProblem: (reason) {
        _error = reason;
        _notify();
      },
      onChanged: _cloudChanged,
    );
  }

  void _cloudChanged() {
    final cloud = _cloud;
    if (cloud == null || _disposed) return;
    if (_deviceRole == DeviceRole.home) {
      if (isTalking) _talkerChanged();
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
    unawaited(_watchTailscale());
    // Sound Watch was left switched on: bring it back. It used to start off
    // after every restart, which looked like alerts silently not working.
    if (prefs?.getBool('sound_enabled') == true) {
      unawaited(setSoundEnabled(true));
    }
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
    _suppressAuto = false;
    _notify();
    unawaited(_watchTailscale());
  }

  Future<void> setRoomName(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    _roomName = trimmed.substring(0, math.min(32, trimmed.length));
    await prefs?.setString('room_name', _roomName);
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
    if (_disposed) return;
    try {
      _batteryLevel = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      _charging = state == BatteryState.charging || state == BatteryState.full;
      if (isTalking) _checkBattery(_batteryLevel, _charging);
    } catch (_) {
      _batteryLevel = null;
      _charging = null;
    }
    _notify();
    _cloud?.health(_roomName, _batteryLevel, _charging);
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
      _error = 'Use Android as the home phone. iPhone can listen through the web app.';
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
      if (alertsOnly) {
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
      _role = alertsOnly ? MonitorRole.watching : MonitorRole.listening;
      _sessionStarted = DateTime.now();
      _error = null;
      _addEvent(
        ActivityKind.connected,
        alertsOnly
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
              'text': notificationText(
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
    if (cloudMode && _deviceRole == DeviceRole.home) {
      if (!isTalking) return 'Start sharing before sending a cloud test alert.';
      try {
        final sent = await _cloudConnection().sendAlert('Test alert');
        return 'Sent to $sent phone(s). Enable alerts on a paired listening phone if none arrived.';
      } catch (e) {
        return _readableError(e);
      }
    }
    if (_deviceRole == DeviceRole.home && !_homeShowsAlerts) {
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
    _addEvent(ActivityKind.sound, title);
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
    if (prefs?.getBool('sound_enabled') != true) return;
    if (soundWatch.enabled && soundWatch.ready) return;
    debugPrint('sound watch: restoring after session start');
    await setSoundEnabled(true);
  }

  Future<void> setSoundEnabled(bool value) async {
    if (_soundLoading) return;
    if (!value) {
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
    _notify();
  }

  Future<void> toggleSoundCategory(String name, bool selected) async {
    if (selected) {
      soundWatch.categories.add(name);
    } else {
      soundWatch.categories.remove(name);
    }
    soundWatch.reset();
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

  void _addEvent(ActivityKind kind, String title) {
    if (_disposed) return;
    _events.insert(
      0,
      ActivityEvent(
        kind: kind,
        title: title,
        room: displayRoom,
        at: DateTime.now(),
      ),
    );
    if (_events.length > 100) _events.removeRange(100, _events.length);
    prefs?.setString(
      'activity',
      jsonEncode(_events.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> clearActivity() async {
    _events.clear();
    await prefs?.remove('activity');
    _notify();
  }

  String _readableError(Object e) => e
      .toString()
      .replaceFirst('Bad state: ', '')
      .replaceFirst('Exception: ', '');
  Future<void> stop() async {
    _epoch++;
    _suppressAuto = true;
    _wantListening = false;
    final active = isActive;
    await _cloud?.stopHome();
    await _cloud?.stopAway();
    await _teardownTalker();
    final listener = _listener;
    final pendingListener = _pendingListener;
    _listener = null;
    _pendingListener = null;
    await listener?.stop();
    if (pendingListener != listener) await pendingListener?.stop();
    _role = MonitorRole.idle;
    _remoteStatusAt = null;
    _sessionStarted = null;
    soundWatch.reset();
    _levels.fillRange(0, _levels.length, 0.03);
    if (active) _addEvent(ActivityKind.session, 'Monitoring stopped');
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _watch?.cancel();
    _healthTimer?.cancel();
    _channel.setMethodCallHandler(null);
    unawaited(stop().whenComplete(() => _recorderInstance?.dispose()));
    unawaited(soundWatch.dispose());
    unawaited(_cloud?.close());
    super.dispose();
  }
}
