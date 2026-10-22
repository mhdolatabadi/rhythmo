import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/data/audio_cache.dart';
import 'package:rhythmo/features/player/data/audio_cache_io.dart';
import 'package:rhythmo/features/player/data/audio_engine.dart';

// Exercise the actual API client, shared context, controller, cache and
// Android decoder. A fake engine cannot detect proxy or decoder failures.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final corruptCache in [false, true]) {
    testWidgets(
      'recipient plays a shared track with ${corruptCache ? 'corrupt' : 'empty'} cache',
      (tester) async {
        await tester.runAsync(() async {
          final harness = await _Harness.create();
          try {
            final playlist = await harness.api.getSharedPlaylist(
              'recipient',
              _share,
            );
            expect(playlist.isOwner, isFalse);
            final track = playlist.tracks.first;
            expect(track.sharedVia, _share);
            if (corruptCache) {
              await File('${harness.directory.path}/${cacheFileName(track)}')
                  .writeAsBytes(Uint8List(track.sizeBytes));
            }
            final progressed = harness.engine.position.firstWhere(
              (position) => position >= const Duration(milliseconds: 200),
            );
            await harness.player
                .play(track)
                .timeout(const Duration(seconds: 20));
            await progressed.timeout(const Duration(seconds: 10));
            expect(harness.player.status, PlayerStatus.playing);
            expect(harness.streamRequests, 1);
            expect(harness.mediaRequests, contains('/audio/first.wav'));
            expect(harness.privateLibraryRequests, 0);
          } finally {
            await harness.close();
          }
        });
      },
    );
  }

  for (final stop in [false, true]) {
    testWidgets(
      'a slow cache lookup cannot undo ${stop ? 'stop' : 'a newer selection'}',
      (tester) async {
        await tester.runAsync(() async {
          final gate = _DelayedCache();
          final harness = await _Harness.create(cache: gate);
          try {
            final playlist = await harness.api.getSharedPlaylist(
              'recipient',
              _share,
            );
            final first = harness.player.play(playlist.tracks.first);
            await gate.entered.future.timeout(const Duration(seconds: 10));
            if (stop) {
              await harness.player.stop();
            } else {
              final progressed = harness.engine.position.firstWhere(
                (position) => position >= const Duration(milliseconds: 200),
              );
              await harness.player
                  .play(playlist.tracks.last)
                  .timeout(const Duration(seconds: 15));
              await progressed.timeout(const Duration(seconds: 10));
            }
            gate.release.complete();
            await first.timeout(const Duration(seconds: 10));
            expect(harness.mediaRequests, isNot(contains('/audio/first.wav')));
            expect(harness.player.track?.id, stop ? null : 'second');
            expect(
              harness.player.status,
              stop ? PlayerStatus.idle : PlayerStatus.playing,
            );
          } finally {
            if (!gate.release.isCompleted) gate.release.complete();
            await harness.close();
          }
        });
      },
    );
  }
}

const _share = 'AAAAAAAAAAAAAAAAAAAAAA';

class _Harness {
  _Harness(this.directory, this.server, AudioCache cache) {
    api = ApiClient(
      Uri.parse('http://127.0.0.1:${server.port}'),
      httpClient: client,
    );
    engine = JustAudioEngine(cache: cache, supportsCrossfade: false);
    player = PlayerController(
      api: api,
      engine: engine,
      token: () => 'recipient',
    );
    server.listen(_handle);
  }

  static Future<_Harness> create({AudioCache? cache}) async {
    final directory = await Directory.systemTemp.createTemp('rhythmo-audio-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _Harness(
      directory,
      server,
      cache ?? FileAudioCache(() async => directory),
    );
  }

  final Directory directory;
  final HttpServer server;
  final client = http.Client();
  final bytes = _wav();
  late final ApiClient api;
  late final JustAudioEngine engine;
  late final PlayerController player;
  var streamRequests = 0;
  var privateLibraryRequests = 0;
  final mediaRequests = <String>[];

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (path.startsWith('/audio/')) {
      mediaRequests.add(path);
      request.response.headers.contentType = ContentType('audio', 'wav');
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
    } else if (request.headers.value('Authorization') != 'Bearer recipient') {
      request.response.statusCode = HttpStatus.unauthorized;
    } else if (path == '/api/v1/shared-playlists/$_share') {
      _json(request, {
        'name': 'Shared playlist',
        'owner': 'o***@example.com',
        'isOwner': false,
        'public': false,
        'tracks': [
          for (final id in ['first', 'second'])
            {
              'id': id,
              'title': id,
              'contentType': 'audio/wav',
              'sizeBytes': bytes.length,
            },
        ],
      });
    } else if (path.startsWith('/api/v1/shared-playlists/$_share/tracks/') &&
        path.endsWith('/stream')) {
      streamRequests++;
      final id = request.uri.pathSegments[5];
      _json(request, {
        'url': 'http://127.0.0.1:${server.port}/audio/$id.wav',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
      });
    } else {
      privateLibraryRequests++;
      request.response.statusCode = HttpStatus.forbidden;
    }
    await request.response.close();
  }

  void _json(HttpRequest request, Map<String, Object> value) {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(value));
  }

  Future<void> close() async {
    // stop() cancels any active decoder/download before deleting temp files.
    await player.stop();
    player.dispose();
    client.close();
    await server.close(force: true);
    // Controller.dispose() delegates asynchronous engine disposal. Wait for
    // the engine's streams to close before removing its cache directory.
    await engine.position.drain<void>();
    await directory.delete(recursive: true);
  }
}

class _DelayedCache implements AudioCache {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<AudioSource> sourceFor(Track track, Uri url) async {
    if (track.id == 'first') {
      entered.complete();
      await release.future;
    }
    return AudioSource.uri(url, tag: track.id);
  }

  @override
  bool get isManaged => false;
  @override
  Future<int> sizeBytes() async => 0;
  @override
  Future<void> clear({String? keep}) async {}
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
