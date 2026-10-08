import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/cloud_pairing.dart';

void main() {
  test('cloud pairing round-trips with a fragment secret', () {
    final info = CloudPairing('https://home.example', 'A' * 24, 'B' * 43);
    final parsed = CloudPairing.parse(info.toCode())!;
    expect(parsed.origin, info.origin);
    expect(parsed.roomId, info.roomId);
    expect(parsed.secret, info.secret);
  });
  test(
    'cloud codes reject plaintext, credentials, and malformed invitations',
    () {
      final fragment = 'pair=${'A' * 24}.${'B' * 43}';
      for (final url in [
        'http://home.example/#$fragment',
        'https://user:pass@home.example/#$fragment',
        'https://home.example/?$fragment',
        'https://home.example/#pair=short.short',
      ]) {
        expect(CloudPairing.parse(url), isNull);
      }
    },
  );
  test('server settings accept only an HTTPS origin', () {
    expect(
      CloudPairing.serverOrigin('https://home.example/'),
      'https://home.example',
    );
    for (final url in [
      'http://home.example',
      'https://home.example/path',
      'https://user:pass@home.example',
      'https://home.example?token=secret',
    ]) {
      expect(CloudPairing.serverOrigin(url), isNull);
    }
  });
}
