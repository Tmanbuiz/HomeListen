import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_pairing.dart';

@pragma('vm:entry-point')
Future<void> homeListenBackgroundMessage(RemoteMessage message) async {
  // FCM displays the notification payload. No microphone or audio starts here.
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('cloud_firebase_config');
  if (Firebase.apps.isEmpty && raw != null) {
    await Firebase.initializeApp(options: _options(jsonDecode(raw)));
  }
}

FirebaseOptions _options(Map<String, dynamic> config) => FirebaseOptions(
  apiKey: config['apiKey'] as String,
  appId: config['androidAppId'] as String,
  messagingSenderId: config['messagingSenderId'] as String,
  projectId: config['projectId'] as String,
);

/// Firebase carries authenticated signaling and notifications. Audio is WebRTC.
/// Only startHome() opens the microphone, after the caller shows its service.
class CloudConnection {
  CloudConnection({
    required this.origin,
    required this.prefs,
    required this.home,
    required this.onChanged,
    required this.onProblem,
    required this.onPcm,
    required this.onAlert,
  });
  final String origin;
  final SharedPreferences prefs;
  final bool home;
  final void Function() onChanged;
  final void Function(String) onProblem;
  final void Function(Int16List) onPcm;
  final void Function(Map<String, dynamic>) onAlert;
  static const _pcm = EventChannel('com.wiantribe.home_listen/webrtc_pcm');
  static const _native = MethodChannel('com.wiantribe.home_listen/mic_service');
  final http.Client _client = http.Client();
  FirebaseAuth? _auth;
  FirebaseFirestore? _db;
  Future<void>? _ready;
  Future<void> _stateTail = Future<void>.value();
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _roomSub;
  StreamSubscription<dynamic>? _pcmSub;
  StreamSubscription<RemoteMessage>? _messages;
  StreamSubscription<String>? _tokens;
  MediaStream? _stream;
  RTCPeerConnection? _anchorSender, _anchorReceiver;
  Timer? _heartbeat, _lease;
  final Map<String, _CloudPeer> _peers = {};
  final Map<String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>
  _offers = {};
  final Set<String> _accepting = {};
  _CloudPeer? _away;
  Map<String, dynamic>? room;
  String? roomId;
  bool sharing = false, alertsEnabled = false, hearing = false, _closed = false;
  int _epoch = 0;
  String? inviteCode;
  DateTime? inviteExpires;
  int? _battery;
  bool? _charging;
  String _name = 'Bedroom';
  double _volume = 1;
  int get listenerCount => _peers.values.where((p) => p.connected).length;
  bool get listening => _away != null;
  int get watcherCount => (room?['watchers'] as Map?)?.length ?? 0;
  bool get paired => roomId != null && !home;
  bool get online =>
      room?['sharing'] == true &&
      DateTime.now().millisecondsSinceEpoch -
              ((room?['lastSeenMs'] as num?)?.toInt() ?? 0) <
          120000;

  Future<void> ensureReady() =>
      _ready ??= _initialize().catchError((Object error) {
        _ready = null;
        throw error;
      });
  Future<void> _initialize() async {
    if (!Platform.isAndroid) {
      throw StateError(
        'Cloud mode uses the Android app or the iPhone Home Screen web app. Choose Tailscale for native iOS.',
      );
    }
    final response = await _client
        .get(Uri.parse('$origin/api/config'))
        .timeout(const Duration(seconds: 15));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw StateError(data['error'] ?? 'The cloud server is not ready.');
    }
    final config = Map<String, dynamic>.from(data['firebase'] as Map);
    if ((config['androidAppId'] as String? ?? '').isEmpty) {
      throw StateError('Add the Android Firebase app ID to the cloud server.');
    }
    if (Firebase.apps.isNotEmpty &&
        Firebase.app().options.projectId != config['projectId']) {
      throw StateError(
        'Restart Home Listen after changing to a different Firebase project.',
      );
    }
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: _options(config));
    }
    if (_closed) return;
    await prefs.setString('cloud_firebase_config', jsonEncode(config));
    // Persist public client options for Android's background FCM receiver.
    if (Platform.isAndroid) {
      await _native.invokeMethod<void>('configureFirebase', config);
    }
    _auth = FirebaseAuth.instance;
    _db = FirebaseFirestore.instance;
    if (_auth!.currentUser == null) await _auth!.signInAnonymously();
    if (_closed) return;
    FirebaseMessaging.onBackgroundMessage(homeListenBackgroundMessage);
    _messages = FirebaseMessaging.onMessage.listen((message) {
      if (message.data['roomId'] == roomId &&
          DateTime.now().millisecondsSinceEpoch -
                  (int.tryParse(message.data['sentAt'] ?? '') ?? 0) <
              120000) {
        onAlert(Map<String, dynamic>.from(message.data));
      }
    });
    roomId = prefs.getString(home ? 'cloud_home_room' : 'cloud_paired_room');
    alertsEnabled =
        !home &&
        roomId != null &&
        prefs.getBool('cloud_alerts_enabled') == true;
    if (roomId != null) _watchRoom();
    _lease = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!home && !online && _away != null) {
        unawaited(stopAway(disableAlerts: false));
        onProblem('The home phone went offline or stopped sharing.');
      }
    });
    _tokens = FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      if (alertsEnabled && roomId != null) {
        unawaited(
          api('/rooms/$roomId/device', {
            'kind': 'fcm',
            'token': token,
          }).then<void>((_) {}, onError: (Object _) {}),
        );
      }
    });
  }

  Future<Map<String, dynamic>> api(
    String path, [
    Map<String, dynamic>? data,
    String method = 'POST',
  ]) async {
    await ensureReady();
    if (_closed) throw StateError('This connection was closed.');
    final token = await _auth!.currentUser!.getIdToken();
    final request = http.Request(method, Uri.parse('$origin/api$path'))
      ..headers.addAll({
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      });
    if (data != null) request.body = jsonEncode(data);
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 15)),
    );
    final result = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      throw StateError(result['error'] ?? 'Cloud connection failed.');
    }
    return result;
  }

  Future<void> createHome() async {
    final result = await api('/rooms', {'roomName': _name});
    roomId = result['roomId'] as String;
    await prefs.setString('cloud_home_room', roomId!);
    room = Map<String, dynamic>.from(result['room'] as Map);
    _watchRoom();
  }

  Future<String> showInvite() async {
    await ensureReady();
    if (roomId == null) await createHome();
    final result = await api('/rooms/$roomId/invite', {});
    inviteExpires = DateTime.parse(result['expiresAt'] as String);
    inviteCode = CloudPairing(
      origin,
      roomId!,
      result['secret'] as String,
    ).toCode();
    return inviteCode!;
  }

  Future<void> join(CloudPairing invite) async {
    if (invite.origin != origin) {
      throw StateError('Use a pairing link from your configured cloud server.');
    }
    final result = await api('/rooms/${invite.roomId}/join', {
      'secret': invite.secret,
    });
    roomId = invite.roomId;
    room = Map<String, dynamic>.from(result['room'] as Map);
    await prefs.setString('cloud_paired_room', roomId!);
    _watchRoom();
  }

  void _watchRoom() {
    unawaited(_roomSub?.cancel());
    _roomSub = _db!.doc('rooms/$roomId').snapshots().listen((snapshot) {
      final data = snapshot.data();
      final uid = _auth!.currentUser!.uid;
      if (data == null || (!home && (data['members'] as Map?)?[uid] != true)) {
        unawaited(_revoked());
        return;
      }
      room = data;
      if (home && sharing) {
        final active = Map<String, dynamic>.from(
          data['activeSessions'] as Map? ?? {},
        );
        final ids = active.values.whereType<String>().toSet();
        for (final id in _offers.keys.toList()) {
          if (!ids.contains(id)) {
            unawaited(_offers.remove(id)?.cancel());
            unawaited(_peers.remove(id)?.close());
          }
        }
        for (final id in ids) {
          if (_offers.containsKey(id)) continue;
          _offers[id] = _db!
              .doc('rooms/$roomId/sessions/$id')
              .snapshots()
              .listen(
                (s) => unawaited(_accept(id, s.data())),
                onError: (Object _) => _dropHomePeer(id),
              );
        }
      }
      final active = data['activeSessions'] as Map? ?? {};
      if (!home && _away != null && active[uid] != _away!.id) {
        unawaited(stopAway(disableAlerts: false));
        onProblem('This listening connection was replaced or revoked.');
      }
      onChanged();
    }, onError: (Object _) => unawaited(_revoked()));
  }

  Future<void> _revoked() async {
    await stopAway(disableAlerts: false);
    if (!home) {
      roomId = null;
      room = null;
      alertsEnabled = false;
      await prefs.remove('cloud_paired_room');
      await prefs.setBool('cloud_alerts_enabled', false);
    }
    onProblem('Cloud pairing was removed or the server rules need setup.');
    onChanged();
  }

  void health(String name, int? battery, bool? charging) {
    _name = name;
    _battery = battery;
    _charging = charging;
  }

  Future<void> _publish(bool value) {
    if (!home || roomId == null) return Future<void>.value();
    final next = _stateTail.then((_) async {
      await api('/rooms/$roomId/state', {
        'sharing': value,
        'roomName': _name,
        'battery': _battery,
        'charging': _charging,
      });
    });
    _stateTail = next.catchError((Object _) {});
    return next;
  }

  Future<void> startHome() async {
    if (!Platform.isAndroid) {
      throw StateError(
        'Use an Android phone at home. An iPhone can listen with the web app.',
      );
    }
    final epoch = ++_epoch;
    await ensureReady();
    if (roomId == null) await createHome();
    if (epoch != _epoch || _closed) return;
    await WebRTC.initialize(
      options: {
        'bypassVoiceProcessing': true,
        'androidUseHardwareAudioProcessing': false,
        'audioSampleRate': 16000,
        'audioOutputSampleRate': 48000,
      },
    );
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': false,
        'noiseSuppression': false,
        'autoGainControl': false,
        'channelCount': 1,
        'sampleRate': 16000,
      },
      'video': false,
    });
    if (epoch != _epoch || _closed) {
      await _disposeStream(stream);
      return;
    }
    _stream = stream;
    // Observe the existing WebRTC capture; never open a second recorder.
    final ready = Completer<void>();
    _pcmSub = _pcm
        .receiveBroadcastStream({'trackId': stream.getAudioTracks().first.id})
        .listen(
          (event) {
            if (event is Uint8List) {
              if (!ready.isCompleted) ready.complete();
              final data = ByteData.sublistView(event);
              onPcm(
                Int16List.fromList(
                  List.generate(
                    event.length ~/ 2,
                    (i) => data.getInt16(i * 2, Endian.little),
                  ),
                ),
              );
            }
          },
          onError: (Object error) {
            if (!ready.isCompleted) {
              ready.completeError(error);
            } else {
              onProblem('The sound detector lost its microphone feed.');
            }
          },
        );
    await _startCaptureAnchor(stream, epoch);
    await ready.future.timeout(const Duration(seconds: 5));
    if (epoch != _epoch || _closed) {
      await stopHome();
      return;
    }
    sharing = true;
    await _publish(true);
    _watchRoom();
    _heartbeat = Timer.periodic(const Duration(seconds: 60), (_) {
      if (sharing) {
        unawaited(
          _publish(true).catchError((Object _) {
            onProblem(
              'Home phone cloud connection lost. Check internet; sharing remains visible here.',
            );
          }),
        );
      }
    });
    onChanged();
  }

  /// Appends "-anchor" to every occurrence of each track id in [sdp].
  @visibleForTesting
  static String renameAnchorTracks(String sdp, Iterable<String> ids) {
    var out = sdp;
    for (final id in ids) {
      out = out.replaceAll(id, '$id-anchor');
    }
    return out;
  }

  Future<void> _startCaptureAnchor(MediaStream stream, int epoch) async {
    // Native WebRTC can suspend capture without a sending audio channel.
    // This muted, local-only peer pair holds that channel for alerts-only use.
    // Both peers share the same existing AudioTrack and audio device module.
    final sender = await createPeerConnection({'iceServers': []});
    if (epoch != _epoch || _closed) {
      await sender.close();
      await sender.dispose();
      return;
    }
    _anchorSender = sender;
    final receiver = await createPeerConnection({'iceServers': []});
    if (epoch != _epoch || _closed) {
      await receiver.close();
      await receiver.dispose();
      return;
    }
    _anchorReceiver = receiver;
    final toSender = <RTCIceCandidate>[], toReceiver = <RTCIceCandidate>[];
    Future<void> route(
      RTCPeerConnection target,
      List<RTCIceCandidate> pending,
      RTCIceCandidate candidate,
    ) async {
      if (epoch != _epoch ||
          _closed ||
          candidate.candidate?.isNotEmpty != true) {
        return;
      }
      try {
        if (await target.getRemoteDescription() == null) {
          pending.add(candidate);
        } else {
          await target.addCandidate(candidate);
        }
      } catch (_) {}
    }

    sender.onIceCandidate = (c) => unawaited(route(receiver, toReceiver, c));
    receiver.onIceCandidate = (c) => unawaited(route(sender, toSender, c));
    receiver.onTrack = (event) {
      event.track.enabled = false;
      unawaited(Helper.setVolume(0, event.track));
    };
    for (final track in stream.getAudioTracks()) {
      await sender.addTrack(track, stream);
    }
    final offer = await sender.createOffer();
    await sender.setLocalDescription(offer);
    // The plugin finds a track by id and looks at LOCAL tracks first. The
    // anchor's receiver would see the microphone track's own id, so the
    // enabled = false and volume 0 above landed on the real microphone track
    // and every viewer heard silence while capture itself kept running. Give
    // the anchor's copy a different id so those calls only silence its own
    // playback.
    await receiver.setRemoteDescription(
      RTCSessionDescription(
        renameAnchorTracks(offer.sdp ?? '', [
          for (final t in stream.getAudioTracks())
            if (t.id != null) t.id!,
        ]),
        offer.type,
      ),
    );
    for (final c in toReceiver) {
      await receiver.addCandidate(c);
    }
    toReceiver.clear();
    final answer = await receiver.createAnswer();
    await receiver.setLocalDescription(answer);
    await sender.setRemoteDescription(answer);
    for (final c in toSender) {
      await sender.addCandidate(c);
    }
    toSender.clear();
  }

  Future<void> _accept(String id, Map<String, dynamic>? data) async {
    if (!sharing || _stream == null || data == null) return;
    if (data['ended'] == true) {
      _dropHomePeer(id);
      return;
    }
    if (data['offer'] == null ||
        _peers.containsKey(id) ||
        _accepting.contains(id)) {
      return;
    }
    if (data['generation'] != room?['generation'] ||
        !(data['expiresAt'] as Timestamp).toDate().isAfter(DateTime.now())) {
      return;
    }
    _accepting.add(id);
    final epoch = _epoch;
    _CloudPeer? peer;
    try {
      final ice = await api('/rooms/$roomId/ice', {});
      if (!sharing || epoch != _epoch) return;
      peer = await _CloudPeer.create(
        _db!,
        roomId!,
        id,
        data,
        'home',
        ice['iceServers'],
        onChanged: onChanged,
        onFailure: () => _dropHomePeer(id),
      );
      if (!sharing || epoch != _epoch || !_offers.containsKey(id)) {
        await peer.close();
        return;
      }
      _peers[id] = peer;
      for (final track in _stream!.getAudioTracks()) {
        await peer.pc.addTrack(track, _stream!);
      }
      await peer.pc.setRemoteDescription(
        RTCSessionDescription(data['offer'] as String, 'offer'),
      );
      await peer.flush();
      final answer = await peer.pc.createAnswer();
      await peer.pc.setLocalDescription(answer);
      if (!sharing || epoch != _epoch) return;
      await _db!.doc('rooms/$roomId/sessions/$id').update({
        'answer': answer.sdp,
      });
      peer.renewIce = () => _refreshPeer(peer!);
    } catch (_) {
      await peer?.close();
      _peers.remove(id);
    } finally {
      _accepting.remove(id);
      onChanged();
    }
  }

  void _dropHomePeer(String id) {
    unawaited(_peers.remove(id)?.close());
    onChanged();
  }

  Future<void> _refreshPeer(_CloudPeer peer) async {
    final ice = await api('/rooms/$roomId/ice', {});
    if (!peer.closed) {
      await peer.pc.setConfiguration({'iceServers': ice['iceServers']});
    }
  }

  Future<void> startAway(double volume) async {
    _volume = volume;
    final epoch = ++_epoch;
    await ensureReady();
    if (roomId == null) throw StateError('Pair your home phone first.');
    // Left alone, WebRTC plays a call as a phone call: the communication
    // stream, with the call volume curve and voice filtering, which sounds thin
    // and quiet through the loudspeaker. A web page plays the same stream as
    // ordinary media, which is why the web listener sounded better. A room
    // monitor is not a phone call, so play it as media. This has to be set
    // before the first connection is created, because the audio track's usage
    // is fixed when the audio device is created.
    if (Platform.isAndroid) {
      try {
        await WebRTC.initialize(
          options: {
            'androidAudioConfiguration': AndroidAudioConfiguration.media
                .toMap(),
            'audioOutputSampleRate': 48000,
          },
        );
      } catch (_) {
        // Fall back to the default route rather than refuse to listen.
      }
    }
    final data = await api('/rooms/$roomId/sessions', {});
    final ice = await api('/rooms/$roomId/ice', {});
    if (epoch != _epoch || _closed) return;
    _CloudPeer? peer;
    peer = await _CloudPeer.create(
      _db!,
      roomId!,
      data['sessionId'] as String,
      {
        'expiresAt': Timestamp.fromDate(
          DateTime.parse(data['expiresAt'] as String),
        ),
      },
      'away',
      ice['iceServers'],
      onChanged: () {
        hearing = peer?.connected ?? false;
        onChanged();
      },
      onFailure: () {
        unawaited(stopAway(disableAlerts: false));
        onProblem(
          'Audio connection lost. Reconnecting while listening is enabled.',
        );
      },
    );
    if (epoch != _epoch || _closed) {
      await peer.close();
      return;
    }
    _away = peer;
    peer.pc.onTrack = (event) {
      event.track.enabled = true;
      event.track.enabled = _volume > 0;
      unawaited(Helper.setVolume(_volume, event.track));
      // WebRTC puts a call into communication mode, and Android then sends it
      // to a connected Bluetooth headset (at call volume) or to the quiet
      // earpiece. Nothing here chose an output, so a listener could hear
      // nothing at all. Use the phone speaker, as a room monitor should.
      unawaited(_useSpeaker());
      peer!.remoteTrack = event.track;
    };
    await peer.pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    final offer = await peer.pc.createOffer();
    await peer.pc.setLocalDescription(offer);
    if (epoch != _epoch || _closed) {
      await peer.close();
      return;
    }
    await _db!.doc('rooms/$roomId/sessions/${peer.id}').update({
      'offer': offer.sdp,
    });
    peer.renewIce = () => _refreshPeer(peer!);
    onChanged();
  }

  /// Plays the incoming audio through the phone's loudspeaker.
  Future<void> _useSpeaker() async {
    try {
      await Helper.setSpeakerphoneOn(true);
    } catch (_) {
      // Not every platform exposes routing; the default route still plays.
    }
  }

  Future<void> enableAlerts() async {
    await ensureReady();
    if (!Platform.isAndroid) {
      throw StateError('For free iPhone alerts, use the Home Screen web app.');
    }
    if (roomId == null) throw StateError('Pair the home phone first.');
    final permission = await FirebaseMessaging.instance.requestPermission();
    if (permission.authorizationStatus == AuthorizationStatus.denied) {
      throw StateError('Allow notifications in phone settings.');
    }
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null) {
      throw StateError(
        'Google Play services could not register notifications.',
      );
    }
    await api('/rooms/$roomId/device', {'kind': 'fcm', 'token': token});
    alertsEnabled = true;
    await prefs.setBool('cloud_alerts_enabled', true);
    onChanged();
  }

  Future<void> disableAlerts() async {
    if (roomId != null && alertsEnabled) {
      await api('/rooms/$roomId/device', null, 'DELETE');
    }
    alertsEnabled = false;
    await prefs.setBool('cloud_alerts_enabled', false);
    onChanged();
  }

  Future<int> sendAlert(String title) async {
    final kind = title.toLowerCase().contains('cry')
        ? 'crying'
        : title.toLowerCase().contains('bark')
        ? 'barking'
        : title.toLowerCase().contains('knock')
        ? 'knocking'
        : title.toLowerCase().contains('test')
        ? 'test'
        : 'loud';
    if (!sharing) return 0;
    final result = await api('/rooms/$roomId/alerts', {
      'kind': kind,
      'id': _db!.collection('eventIds').doc().id,
    });
    return result['sent'] as int? ?? 0;
  }

  Future<void> revoke() async {
    await api('/rooms/$roomId/revoke', {});
    inviteCode = null;
    inviteExpires = null;
    onChanged();
  }

  Future<void> forget() async {
    if (roomId != null) await api('/rooms/$roomId/leave', {});
    await stopAway(disableAlerts: false);
    await _roomSub?.cancel();
    _roomSub = null;
    roomId = null;
    room = null;
    alertsEnabled = false;
    await prefs.remove('cloud_paired_room');
    await prefs.setBool('cloud_alerts_enabled', false);
    onChanged();
  }

  void setVolume(double value) {
    _volume = value;
    final track = _away?.remoteTrack;
    if (track != null) {
      track.enabled = value > 0;
      unawaited(Helper.setVolume(value, track));
    }
  }

  Future<void> stopAway({bool disableAlerts = true}) async {
    _epoch++;
    final peer = _away;
    _away = null;
    hearing = false;
    await peer?.close();
    if (disableAlerts && alertsEnabled) {
      try {
        await this.disableAlerts();
      } catch (_) {
        onProblem(
          'Audio stopped. Alerts could not be disabled while offline; disable them when internet returns.',
        );
      }
    }
    onChanged();
  }

  Future<void> stopHome() async {
    if (!home) return;
    _epoch++;
    sharing = false;
    _heartbeat?.cancel();
    _heartbeat = null;
    for (final sub in _offers.values) {
      await sub.cancel();
    }
    _offers.clear();
    for (final peer in _peers.values.toList()) {
      await peer.close();
    }
    _peers.clear();
    for (final pc in [_anchorSender, _anchorReceiver]) {
      if (pc != null) {
        pc.onIceCandidate = null;
        pc.onTrack = null;
        await pc.close();
        await pc.dispose();
      }
    }
    _anchorSender = null;
    _anchorReceiver = null;
    await _pcmSub?.cancel();
    _pcmSub = null;
    final stream = _stream;
    _stream = null;
    if (stream != null) await _disposeStream(stream);
    unawaited(_publish(false).catchError((Object _) {}));
    onChanged();
  }

  Future<void> _disposeStream(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }

  Future<void> close() async {
    await stopHome();
    await stopAway(disableAlerts: false);
    _closed = true;
    await _roomSub?.cancel();
    await _messages?.cancel();
    await _tokens?.cancel();
    _lease?.cancel();
    _client.close();
  }
}

class _CloudPeer {
  _CloudPeer(
    this.db,
    this.path,
    this.id,
    this.pc,
    this.side,
    this.expires,
    this.onChanged,
    this.onFailure,
  );
  final FirebaseFirestore db;
  final String path, id, side;
  final RTCPeerConnection pc;
  final Timestamp expires;
  final void Function() onChanged, onFailure;
  final List<RTCIceCandidate> _pending = [];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _candidates;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _session;
  MediaStreamTrack? remoteTrack;
  Timer? _timeout, _expiry, _refresh;
  Future<void> Function()? renewIce;
  bool connected = false, closed = false, _answerBusy = false;
  static Future<_CloudPeer> create(
    FirebaseFirestore db,
    String room,
    String id,
    Map<String, dynamic> data,
    String side,
    dynamic ice, {
    required void Function() onChanged,
    required void Function() onFailure,
  }) async {
    final pc = await createPeerConnection({'iceServers': ice});
    final peer = _CloudPeer(
      db,
      'rooms/$room/sessions/$id',
      id,
      pc,
      side,
      data['expiresAt'] as Timestamp,
      onChanged,
      onFailure,
    );
    pc.onIceCandidate = (candidate) {
      if (!peer.closed && (candidate.candidate?.isNotEmpty ?? false)) {
        unawaited(
          db
              .collection('${peer.path}/candidates')
              .add({
                'candidate': candidate.candidate,
                'sdpMid': candidate.sdpMid,
                'sdpMLineIndex': candidate.sdpMLineIndex,
                'side': side,
                'expiresAt': peer.expires,
              })
              .then<void>(
                (_) {},
                onError: (Object _) {
                  if (!peer.closed) onFailure();
                },
              ),
        );
      }
    };
    pc.onConnectionState = (state) {
      if (peer.closed) return;
      peer.connected =
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
      if (peer.connected) peer._timeout?.cancel();
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        onFailure();
      }
      onChanged();
    };
    peer._candidates = db
        .collection('${peer.path}/candidates')
        .snapshots()
        .listen(
          (snapshot) async {
            try {
              for (final change in snapshot.docChanges) {
                if (peer.closed ||
                    change.type != DocumentChangeType.added ||
                    change.doc.data()?['side'] == side) {
                  continue;
                }
                final value = change.doc.data()!;
                final candidate = RTCIceCandidate(
                  value['candidate'] as String,
                  value['sdpMid'] as String?,
                  value['sdpMLineIndex'] as int?,
                );
                if (await pc.getRemoteDescription() == null) {
                  peer._pending.add(candidate);
                } else if (!peer.closed) {
                  await pc.addCandidate(candidate);
                }
              }
            } catch (_) {
              if (!peer.closed) onFailure();
            }
          },
          onError: (Object _) {
            if (!peer.closed) onFailure();
          },
        );
    peer._session = db
        .doc(peer.path)
        .snapshots()
        .listen(
          (snapshot) async {
            if (peer.closed) return;
            final value = snapshot.data();
            if (value == null || value['ended'] == true) {
              onFailure();
              return;
            }
            if (side != 'away' || value['answer'] == null || peer._answerBusy) {
              return;
            }
            peer._answerBusy = true;
            try {
              if (await pc.getRemoteDescription() == null) {
                await pc.setRemoteDescription(
                  RTCSessionDescription(value['answer'] as String, 'answer'),
                );
                await peer.flush();
              }
            } catch (_) {
              if (!peer.closed) onFailure();
            } finally {
              peer._answerBusy = false;
            }
          },
          onError: (Object _) {
            if (!peer.closed) onFailure();
          },
        );
    peer._timeout = Timer(const Duration(seconds: 35), () {
      if (!peer.connected && !peer.closed) onFailure();
    });
    peer._expiry = Timer(peer.expires.toDate().difference(DateTime.now()), () {
      if (!peer.closed) onFailure();
    });
    peer._refresh = Timer.periodic(const Duration(minutes: 25), (_) {
      final refresh = peer.renewIce;
      if (refresh != null && !peer.closed) {
        unawaited(
          refresh().catchError((Object _) {
            if (!peer.closed) onFailure();
          }),
        );
      }
    });
    return peer;
  }

  Future<void> flush() async {
    for (final candidate in _pending.toList()) {
      if (!closed) await pc.addCandidate(candidate);
    }
    _pending.clear();
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    connected = false;
    _timeout?.cancel();
    _expiry?.cancel();
    _refresh?.cancel();
    await _session?.cancel();
    await _candidates?.cancel();
    pc.onTrack = null;
    pc.onIceCandidate = null;
    pc.onConnectionState = null;
    await pc.close();
    await pc.dispose();
    try {
      await db.doc(path).update({'ended': true});
    } catch (_) {}
  }
}
