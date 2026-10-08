import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/cloud_connection.dart';

void main() {
  group('Capture anchor track id', () {
    const id = 'c53a56e1-7243-46ef-a9af-b20135af816a';
    final sdp = [
      'v=0',
      'm=audio 9 UDP/TLS/RTP/SAVPF 111',
      'a=msid:stream1 $id',
      'a=ssrc:123 msid:stream1 $id',
      'a=ssrc:123 label:$id',
    ].join('\r\n');

    test('the anchor copy gets a different id everywhere it appears', () {
      final out = CloudConnection.renameAnchorTracks(sdp, [id]);
      expect(out.contains('$id-anchor'), isTrue);
      // Every occurrence was renamed, and none is left with the original id
      // on its own: the plugin would then find the real microphone track.
      expect(RegExp(id).allMatches(out).length, 3);
      expect(RegExp('$id-anchor').allMatches(out).length, 3);
      expect(out.replaceAll('$id-anchor', ''), isNot(contains(id)));
    });

    test('other lines and an empty list are left alone', () {
      expect(CloudConnection.renameAnchorTracks(sdp, const []), sdp);
      final out = CloudConnection.renameAnchorTracks(sdp, [id]);
      expect(out.split('\r\n').first, 'v=0');
      expect(out.split('\r\n')[1], contains('m=audio'));
    });
  });
}
