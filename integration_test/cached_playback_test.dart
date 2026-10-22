import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/data/audio_cache_io.dart';

// A fresh cloud track goes through just_audio's loopback HTTP cache proxy.
// A mock engine cannot detect Android blocking that proxy (#403).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android plays an uncached track through the real cache proxy', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('rhythmo-audio-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final player = AudioPlayer();
      final bytes = _wav();
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      try {
        final track = Track(
          id: 'shared-uncached',
          title: 'Shared audio',
          contentType: 'audio/wav',
          sizeBytes: bytes.length,
          sharedVia: 'AAAAAAAAAAAAAAAAAAAAAA',
        );
        final cache = FileAudioCache(() async => directory);
        final source = await cache.sourceFor(
          track,
          Uri.parse('http://127.0.0.1:${server.port}/track.wav'),
        );
        // ignore: experimental_member_use
        expect(source, isA<LockCachingAudioSource>());
        await player
            .setAudioSource(source)
            .timeout(const Duration(seconds: 15));
        final progressed = player.positionStream.firstWhere(
          (position) => position >= const Duration(milliseconds: 200),
        );
        // play() completes when playback ends; attach its error handler now.
        final finished = player.play();
        await Future.wait([
          progressed.timeout(const Duration(seconds: 10)),
          finished.timeout(const Duration(seconds: 10)),
        ]);
        expect(requests, greaterThan(0));
      } finally {
        await player.dispose();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    });
  });
}

// Three seconds of PCM WAV, generated locally so CI needs no media service.
Uint8List _wav() {
  const sampleRate = 8000;
  const dataLength = sampleRate * 3 * 2;
  final bytes = Uint8List(44 + dataLength);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  text(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, dataLength, Endian.little);
  return bytes;
}
