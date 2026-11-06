import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/network/network_status.dart';
import 'package:rhythmo/core/offline/response_cache.dart';
import 'package:rhythmo/features/auth/application/auth_controller.dart';
import 'package:rhythmo/features/auth/data/auth_models.dart';
import 'package:rhythmo/features/auth/data/token_store.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/last_playback.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/core/offline/offline_outbox.dart';
import 'package:rhythmo/features/player/data/offline_songs.dart';
import 'package:rhythmo/features/player/application/favorite_tracks.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';
import 'likes_test.dart' show FakeLikesApi;

import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi;

const _track = {
  'id': 't1',
  'title': 'سرود',
  'contentType': 'audio/mpeg',
  'sizeBytes': 10,
};

void main() {
  group('NetworkStatus', () {
    test('goes offline on a failure and back online once the probe answers',
        () async {
      final scheduled = <void Function()>[];
      var reachable = false;
      final network = NetworkStatus(
        probe: () async {
          if (!reachable) throw Exception('offline');
        },
        schedule: (delay, callback) {
          scheduled.add(callback);
          return () => scheduled.remove(callback);
        },
      );
      var changes = 0;
      network.addListener(() => changes++);

      network.reportFailure();
      expect(network.online, isFalse);
      expect(scheduled, hasLength(1));

      // Still unreachable: it plans another check.
      scheduled.removeAt(0)();
      await Future<void>.delayed(Duration.zero);
      expect(network.online, isFalse);
      expect(scheduled, hasLength(1));

      reachable = true;
      scheduled.removeAt(0)();
      await Future<void>.delayed(Duration.zero);
      expect(network.online, isTrue);
      expect(scheduled, isEmpty);
      expect(changes, 2);
      network.dispose();
    });
  });

  group('ApiClient offline answers', () {
    late bool offline;
    late MemoryResponseCache cache;
    late NetworkStatus network;
    late ApiClient api;
    late List<String> requested;

    setUp(() {
      offline = false;
      requested = [];
      cache = MemoryResponseCache();
      network = NetworkStatus();
      api = ApiClient(
        Uri.parse('https://music.example.com'),
        offlineCache: cache,
        network: network,
        httpClient: MockClient((request) async {
          requested.add(request.url.path);
          if (offline) throw http.ClientException('no route to host');
          return switch (request.url.path) {
            '/api/v1/tracks' => http.Response(
                jsonEncode({
                  'tracks': [_track],
                  'storage': {'usedBytes': 10, 'limitBytes': 100},
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'}),
            '/api/v1/tracks/t1/stream' => http.Response(
                jsonEncode({
                  'url': 'https://music.example.com/a?sig=1',
                  'expiresAt': '2030-01-01T00:00:00Z',
                }),
                200),
            '/api/v1/tracks/t1/artwork' => http.Response.bytes([1, 2, 3], 200,
                headers: {'content-type': 'image/jpeg'}),
            _ => http.Response('{}', 404),
          };
        }),
      );
    });

    test('the library comes from the device when the server is unreachable',
        () async {
      final online = await api.listTracks('token');
      expect(online.tracks.single.title, 'سرود');
      expect(network.online, isTrue);

      offline = true;
      final kept = await api.listTracks('token');
      expect(kept.tracks.single.id, 't1');
      expect(kept.usedBytes, 10);
      expect(network.online, isFalse);
      network.dispose();
    });

    test('another account never sees the answers kept for this one', () async {
      await api.listTracks('token');
      offline = true;
      await expectLater(
          api.listTracks('other-token'), throwsA(isA<http.ClientException>()));
      network.dispose();
    });

    test('the token itself is never part of what is kept', () async {
      await api.listTracks('secret-token');
      expect(cache.texts.keys.single, isNot(contains('secret-token')));
      network.dispose();
    });

    test('stream links, which expire, are never kept', () async {
      await api.streamLink('token', 't1');
      expect(cache.texts, isEmpty);
      offline = true;
      await expectLater(
          api.streamLink('token', 't1'), throwsA(isA<http.ClientException>()));
      network.dispose();
    });

    test('covers seen online are shown offline', () async {
      final track = Track.fromJson(_track);
      expect(await api.trackArtwork('token', track),
          Uint8List.fromList([1, 2, 3]));
      offline = true;
      expect(await api.trackArtwork('token', track),
          Uint8List.fromList([1, 2, 3]));
      network.dispose();
    });

    test('signing out forgets everything kept', () async {
      await api.listTracks('token');
      await api.forgetOffline();
      expect(cache.texts, isEmpty);
      network.dispose();
    });
  });

  group('AuthController.revalidate', () {
    test('a session ended elsewhere while offline signs out once online',
        () async {
      final auth = _Auth();
      final tokens = MemoryTokenStore('token');
      final controller = AuthController(api: auth, tokenStore: tokens);
      await controller.restore();
      expect(controller.status, AuthStatus.signedIn);

      auth.revoked = true;
      await controller.revalidate();
      expect(controller.status, AuthStatus.signedOut);
      expect(await tokens.read(), isNull);
    });

    test('a restore that failed for lack of a connection is retried', () async {
      final auth = _Auth()..unreachable = true;
      final controller =
          AuthController(api: auth, tokenStore: MemoryTokenStore('token'));
      await controller.restore();
      expect(controller.status, AuthStatus.restoreFailed);

      auth.unreachable = false;
      await controller.revalidate();
      expect(controller.status, AuthStatus.signedIn);
    });

    test('still offline, the session is kept', () async {
      final auth = _Auth();
      final controller =
          AuthController(api: auth, tokenStore: MemoryTokenStore('token'));
      await controller.restore();
      auth.unreachable = true;
      await controller.revalidate();
      expect(controller.status, AuthStatus.signedIn);
    });
  });

  group('cached playback', () {
    test('a track kept whole on the device plays without a stream link',
        () async {
      final api = FakeTracksApi()..linkError = Exception('offline');
      final engine = FakeAudioEngine();
      final player = PlayerController(
        api: api,
        engine: engine,
        token: () => 'tok',
        isCached: (track) async => track.id == 't1',
      );
      await player.play(Track.fromJson(_track));
      expect(api.calls.where((call) => call.startsWith('stream:')), isEmpty);
      expect(engine.loads.single.$2, cachedTrackUri(Track.fromJson(_track)));
      expect(player.status, PlayerStatus.playing);
    });

    test('when the kept file fails to load, a real link is fetched', () async {
      final api = FakeTracksApi();
      final engine = FakeAudioEngine();
      var first = true;
      engine.onLoad = (_) async {
        if (first) {
          first = false;
          throw Exception('corrupt');
        }
      };
      final player = PlayerController(
        api: api,
        engine: engine,
        token: () => 'tok',
        isCached: (_) async => true,
      );
      await player.play(Track.fromJson(_track));
      expect(api.calls, contains('stream:t1'));
      expect(engine.loads.last.$2.scheme, 'https');
    });

    test('the last playback remembers which cached revision it was', () {
      const track = Track(
        id: 't1',
        title: 'A',
        contentType: 'audio/mpeg',
        sizeBytes: 10,
        embeddedTags:
            EmbeddedTags(status: EmbeddedTagStatus.written, version: 3),
      );
      final restored = LastPlayback.fromJson(
          jsonDecode(jsonEncode(const LastPlayback(track: track).toJson())));
      expect(restored!.track.embeddedTags.version, 3);
    });
  });

  group('changes made offline', () {
    const song =
        Track(id: 'b', title: 'B', contentType: 'audio/mpeg', sizeBytes: 1);
    late OfflineOutbox outbox;

    setUp(() => outbox =
        OfflineOutbox(store: MemoryResponseCache(), account: () => 'u1'));

    test('a like made offline stays and is sent once back online', () async {
      final api = FakeLikesApi()..error = http.ClientException('offline');
      final likes =
          FavoriteTracks(api: api, token: () => 'tok', outbox: outbox);

      expect(await likes.toggleTrack(song), TrackLikeResult.done);
      expect(likes.contains('b'), isTrue);
      expect(await outbox.pending(), hasLength(1));

      // A refresh from what the device kept still shows it.
      api.error = null;
      await likes.refresh();
      expect(likes.contains('b'), isTrue);

      await outbox.flush((action) => likes.sendPending(action));
      expect(api.liked.map((t) => t.id), ['b']);
      expect(await outbox.pending(), isEmpty);
    });

    test('liking then unliking offline sends only the last', () async {
      final api = FakeLikesApi()..error = http.ClientException('offline');
      final likes =
          FavoriteTracks(api: api, token: () => 'tok', outbox: outbox);
      await likes.toggleTrack(song);
      await likes.toggleTrack(song);
      final pending = await outbox.pending();
      expect(pending, hasLength(1));
      expect(pending.single['liked'], isFalse);
    });

    test('a song added to a playlist offline shows and is sent later',
        () async {
      final api = _Playlists()..offline = true;
      final playlists =
          PlaylistsController(api: api, token: () => 'tok', outbox: outbox);
      await playlists.load();

      expect(await playlists.addDeviceTrack('p1', song), AddTrackResult.added);
      final shown = await playlists.loadPlaylist('p1');
      expect(shown!.tracks.map((t) => t.id), ['a', 'b']);

      api.offline = false;
      await outbox.flush((action) => playlists.sendPending(action));
      expect(api.calls, ['replace:a,b']);
      expect(await outbox.pending(), isEmpty);
    });

    test('a new order made offline is kept and sent later', () async {
      final api = _Playlists()
        ..ids = ['a', 'b']
        ..offline = true;
      final playlists =
          PlaylistsController(api: api, token: () => 'tok', outbox: outbox);
      final arranged = await playlists.replaceTracks('p1', ['b', 'a']);
      expect(arranged!.tracks.map((t) => t.id), ['b', 'a']);

      api.offline = false;
      await outbox.flush((action) => playlists.sendPending(action));
      expect(api.calls, ['replace:b,a']);
    });

    test('a change the server refuses is dropped; unreachable ones wait',
        () async {
      await outbox.add({'kind': 'x', 'key': 'one'});
      await outbox.add({'kind': 'x', 'key': 'two'});
      var reachable = false;
      await outbox.flush((action) async {
        if (action['key'] == 'one') {
          throw const ApiException('gone', statusCode: 404);
        }
        if (!reachable) throw http.ClientException('offline');
      });
      expect((await outbox.pending()).map((a) => a['key']), ['two']);

      reachable = true;
      await outbox.flush((_) async {});
      expect(await outbox.pending(), isEmpty);
    });
  });

  group('songs kept for offline in the browser', () {
    const song =
        Track(id: 'b', title: 'B', contentType: 'audio/mpeg', sizeBytes: 1);

    test('keeping fetches a fresh link and marks the song kept', () async {
      final store = _SongStore();
      final songs = OfflineSongs(
          store: store,
          link: (track) async => Uri.parse('https://x/${track.id}'));
      await songs.load();
      expect(songs.isKept('b'), isFalse);

      expect(await songs.keep(song), isTrue);
      expect(store.kept, {'b': 'https://x/b'});
      expect(songs.isKept('b'), isTrue);

      await songs.forget(song);
      expect(songs.isKept('b'), isFalse);
      expect(store.kept, isEmpty);
    });

    test('a failed fetch leaves the song not kept', () async {
      final songs = OfflineSongs(
          store: _SongStore()..fail = true,
          link: (track) async => Uri.parse('https://x/${track.id}'));
      expect(await songs.keep(song), isFalse);
      expect(songs.isKept('b'), isFalse);
      expect(songs.isSaving('b'), isFalse);
    });
  });
}

class _SongStore implements OfflineSongStore {
  final kept = <String, String>{};
  bool fail = false;

  @override
  Future<Set<String>> keptIds() async => kept.keys.toSet();

  @override
  Future<void> keep(Track track, Uri url) async {
    if (fail) throw http.ClientException('offline');
    kept[track.id] = '$url';
  }

  @override
  Future<void> forget(Track track) async => kept.remove(track.id);
}

class _Playlists implements PlaylistsApi {
  bool offline = false;
  List<String> ids = ['a'];
  final calls = <String>[];

  Playlist _playlist() => Playlist(
        id: 'p1',
        name: 'سفر',
        trackCount: ids.length,
        tracks: [
          for (final id in ids)
            Track(id: id, title: id, contentType: 'audio/mpeg', sizeBytes: 1),
        ],
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  @override
  Future<Playlist> getPlaylist(String token, String playlistId) async {
    // Offline, ApiClient answers this read from the device.
    return _playlist();
  }

  @override
  Future<Playlist> replacePlaylistTracks(
      String token, String playlistId, List<String> trackIds) async {
    if (offline) throw http.ClientException('offline');
    calls.add('replace:${trackIds.join(',')}');
    ids = [...trackIds];
    return _playlist();
  }

  @override
  Future<List<Playlist>> listPlaylists(String token) async => [_playlist()];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Auth implements AuthApi {
  bool revoked = false;
  bool unreachable = false;

  @override
  Future<AuthUser> me(String token) async {
    if (unreachable) throw http.ClientException('offline');
    if (revoked) throw const ApiException('gone', statusCode: 401);
    return const AuthUser(id: 'u1', email: 'a@example.com');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
