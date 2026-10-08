/// A short-lived invitation; the secret is carried in a URL fragment.
class CloudPairing {
  const CloudPairing(this.origin, this.roomId, this.secret);
  final String origin, roomId, secret;
  static String? serverOrigin(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      return null;
    }
    return uri.origin;
  }

  static CloudPairing? parse(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final parts = Uri.splitQueryString(uri.fragment)['pair']?.split('.');
    if (parts == null ||
        parts.length != 2 ||
        !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(parts[0]) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(parts[1])) {
      return null;
    }
    return CloudPairing(uri.origin, parts[0], parts[1]);
  }

  String toCode() => '$origin/#pair=$roomId.$secret';
}
