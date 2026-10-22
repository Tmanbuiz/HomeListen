import 'dart:typed_data';

/// Receiver-only recording transport inside an already authorized live peer.
const alertAudioChannel = 'homelisten-alert-audio-v1';

class AlertAudioPacket {
  AlertAudioPacket(this.sequence, this.clock, this.pcm);
  final int sequence, clock;
  final Int16List pcm;

  static Uint8List encode(int sequence, int clock, Uint8List pcm) {
    final bytes = Uint8List(12 + pcm.length);
    bytes.setRange(0, 4, [72, 76, 65, 49]);
    final data = ByteData.sublistView(bytes);
    data.setUint32(4, sequence & 0xffffffff, Endian.little);
    data.setUint32(8, clock & 0xffffffff, Endian.little);
    bytes.setRange(12, bytes.length, pcm);
    return bytes;
  }

  static AlertAudioPacket? decode(Uint8List bytes) {
    if (bytes.length < 14 ||
        bytes.length > 6412 ||
        bytes.length.isOdd ||
        bytes[0] != 72 ||
        bytes[1] != 76 ||
        bytes[2] != 65 ||
        bytes[3] != 49) {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    return AlertAudioPacket(
      data.getUint32(4, Endian.little),
      data.getUint32(8, Endian.little),
      Int16List.fromList(
        List.generate(
          (bytes.length - 12) ~/ 2,
          (i) => data.getInt16(12 + i * 2, Endian.little),
        ),
      ),
    );
  }
}
