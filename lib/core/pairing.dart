import 'dart:io';
import 'dart:math';

import '../protocols/mic_monitor.dart';

/// Everything the work phone needs to find and be admitted by the home phone,
/// carried in a QR code shown on the home phone's own screen.
///
/// Tailscale gives an app no way to list the other devices on a tailnet, so
/// something has to say where the home phone is. Scanning once is that
/// something, and it also hands over a secret: the talker ignores any hello
/// that does not carry the token. Without it, any other device on the tailnet
/// (a shared machine, a family member's phone) that guessed the port could
/// listen to the room.
class PairingInfo {
  const PairingInfo({
    required this.host,
    required this.token,
    this.port = MicStream.controlPort,
  });

  /// The home phone's Tailscale address.
  final String host;
  final String token;
  final int port;

  static const String scheme = 'homelisten';

  /// The text encoded in the QR code. It is also shown beneath it, so a phone
  /// whose camera cannot read the code can be paired by typing or pasting.
  String toCode() => Uri(
    scheme: scheme,
    host: 'pair',
    queryParameters: {'host': host, 'port': '$port', 'token': token},
  ).toString();

  /// Reads a code produced by [toCode]. Null for anything else — a QR code
  /// for some other app must not be able to point this one at a stranger.
  static PairingInfo? parse(String code) {
    final Uri uri;
    try {
      uri = Uri.parse(code.trim());
    } on FormatException {
      return null;
    }
    if (uri.scheme != scheme || uri.host != 'pair') return null;

    final host = uri.queryParameters['host'];
    final token = uri.queryParameters['token'];
    final port = int.tryParse(uri.queryParameters['port'] ?? '');
    if (host == null || token == null || port == null) return null;
    // Only a Tailscale address is acceptable. This is what stops a crafted
    // code from aiming the hello at an arbitrary host on the internet.
    if (!isTailscaleAddress(host)) return null;
    if (token.length < 16 || port < 1024 || port > 65535) return null;
    return PairingInfo(host: host, token: token, port: port);
  }

  /// 128 bits from the platform's secure generator.
  static String newToken() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Tailscale hands out addresses from 100.64.0.0/10 (carrier-grade NAT
  /// space): first octet 100, second octet 64 through 127.
  static bool isTailscaleAddress(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return false;
    final octets = parts.map(int.tryParse).toList();
    if (octets.any((o) => o == null || o < 0 || o > 255)) return false;
    return octets[0] == 100 && octets[1]! >= 64 && octets[1]! <= 127;
  }

  /// This phone's own Tailscale address, or null when Tailscale is off.
  ///
  /// Its presence is also the cue that the tunnel is up: the interface exists
  /// only while Tailscale is connected, which is what automatic connection
  /// waits for.
  static String? tailscaleAddressOf(Iterable<NetworkInterface> interfaces) {
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.type == InternetAddressType.IPv4 &&
            isTailscaleAddress(address.address)) {
          return address.address;
        }
      }
    }
    return null;
  }

  static Future<String?> ownTailscaleAddress() async {
    try {
      return tailscaleAddressOf(
        await NetworkInterface.list(type: InternetAddressType.IPv4),
      );
    } on SocketException {
      return null;
    }
  }
}
