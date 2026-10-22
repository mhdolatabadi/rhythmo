import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';

import 'player_controller_test.dart' show FakeAudioEngine;

const _shared = Track(
  id: 'song',
  title: 'Shared song',
  contentType: 'audio/mpeg',
  sizeBytes: 10,
  sharedVia: 'share-token',
);

http.Response _link() => http.Response(
  jsonEncode({
    'url': 'https://music.example.com/audio.mp3',
    'expiresAt': DateTime.utc(2030).toIso8601String(),
  }),
  200,
);

void main() {
  for (final failure in [503, 'connection', 'timeout']) {
    test(
      'shared link recovers once from $failure using recipient access',
      () async {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          if (requests.length == 1) {
            if (failure == 'connection') throw http.ClientException('lost');
            if (failure == 'timeout') throw TimeoutException('timed out');
            return http.Response('{"error":"unavailable"}', failure as int);
          }
          return _link();
        });
        final engine = FakeAudioEngine();
        final player = PlayerController(
          api: ApiClient(
            Uri.parse('https://music.example.com'),
            httpClient: client,
          ),
          engine: engine,
          token: () => 'recipient',
        );
        addTearDown(player.dispose);
        addTearDown(client.close);
        await player.play(_shared);
        expect(player.status, PlayerStatus.playing);
        expect(requests, hasLength(2));
        for (final request in requests) {
          expect(
            request.url.path,
            '/api/v1/shared-playlists/share-token/tracks/song/stream',
          );
          expect(request.headers['Authorization'], 'Bearer recipient');
        }
        expect(engine.loads, hasLength(1));
      },
    );
  }

  for (final status in [401, 403, 404, 429, 503]) {
    test(
      'persistent HTTP $status leaves loading with bounded requests',
      () async {
        var requests = 0;
        final client = MockClient((request) async {
          requests++;
          return http.Response('{"error":"unavailable"}', status);
        });
        final engine = FakeAudioEngine();
        final player = PlayerController(
          api: ApiClient(
            Uri.parse('https://music.example.com'),
            httpClient: client,
          ),
          engine: engine,
          token: () => 'recipient',
        );
        addTearDown(player.dispose);
        addTearDown(client.close);
        await player.play(_shared);
        expect(player.status, PlayerStatus.error);
        expect(requests, status >= 500 ? 2 : 1);
        expect(engine.loads, isEmpty);
      },
    );
  }

  test(
    'stop during link recovery suppresses retry and late playback',
    () async {
      final failed = Completer<void>();
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        failed.complete();
        return http.Response('{"error":"unavailable"}', 503);
      });
      final engine = FakeAudioEngine();
      final player = PlayerController(
        api: ApiClient(
          Uri.parse('https://music.example.com'),
          httpClient: client,
        ),
        engine: engine,
        token: () => 'recipient',
      );
      addTearDown(player.dispose);
      addTearDown(client.close);
      final play = player.play(_shared);
      await failed.future;
      await player.stop();
      await play;
      expect(requests, 1);
      expect(engine.loads, isEmpty);
      expect(player.status, PlayerStatus.idle);
    },
  );
}
