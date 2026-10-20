import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';
import 'package:rhythmo/features/playlists/presentation/popular_playlists_screen.dart';
import 'package:rhythmo/features/playlists/presentation/shared_playlist_screen.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi;

const token = 'AAAAAAAAAAAAAAAAAAAAAA';

/// One playlist `p1`, owned by the signed-in user, optionally shared.
class FakePlaylistsApi implements PlaylistsApi {
  // Collaboration: the playlist's link, members and whether the user owns it.
  String? collabToken;
  List<PlaylistMember> members = [];
  bool isOwner = true;
  List<Track> tracks = [];
  List<Playlist>? userPlaylists;
  final createdNames = <String>[];
  final joined = <String>[];
  final removedMembers = <String>[];
  bool left = false;
  List<String>? replacedWith;

  String? shareToken;
  bool isPublic = false;

  /// The owner isn't verified: going public only asks an admin (#322).
  bool needsReview = false;
  bool pending = false;
  bool shareFails = false;
  final shareCalls = <bool?>[];
  final shared = <String, SharedPlaylist>{};

  Playlist get playlist => Playlist(
        id: 'p1',
        name: 'mix',
        trackCount: tracks.length,
        tracks: tracks,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        shareToken: shareToken,
        isPublic: isPublic,
        isOwner: isOwner,
        collabToken: isOwner ? collabToken : null,
        owner: 'o***@example.com',
        members: members,
      );

  @override
  Future<PlaylistShare> sharePlaylist(String t, String playlistId,
      {bool? public}) async {
    shareCalls.add(public);
    if (shareFails) throw const ApiException('500', statusCode: 500);
    if (public == true && needsReview && !isPublic) {
      pending = true;
    } else if (public != null) {
      isPublic = public;
      pending = false;
    }
    return (
      shareToken: shareToken ??= token,
      isPublic: isPublic,
      pending: pending
    );
  }

  @override
  Future<void> unsharePlaylist(String t, String playlistId) async {
    shareToken = null;
    isPublic = false;
    pending = false;
  }

  /// Who likes each shared playlist, by share token.
  final likers = <String, Set<String>>{};
  int? likeStatus;
  final likeCalls = <bool>[];

  /// Holds like requests until completed, to look at the optimistic state.
  Completer<void>? likeGate;

  @override
  Future<PlaylistLikes> setPlaylistLike(
      String t, String shareToken, bool liked) async {
    likeCalls.add(liked);
    await likeGate?.future;
    if (likeStatus != null) {
      throw ApiException('$likeStatus', statusCode: likeStatus);
    }
    final who = likers.putIfAbsent(shareToken, () => {});
    liked ? who.add('me') : who.remove('me');
    return PlaylistLikes(liked: liked, likeCount: who.length);
  }

  List<PublicPlaylist> public = [];
  bool listFails = false;

  @override
  Future<List<PublicPlaylist>> listPublicPlaylists(String? t) async {
    if (listFails) throw const ApiException('500', statusCode: 500);
    return public;
  }

  final hiddenCalls = <(String, bool)>[];
  final deletedPublic = <String>[];
  bool deleteFails = false;

  @override
  Future<void> deletePublicPlaylist(String t, String shareToken) async {
    if (deleteFails) throw const ApiException('500', statusCode: 500);
    deletedPublic.add(shareToken);
  }

  bool hideFails = false;

  @override
  Future<void> setPopularPlaylistHidden(
      String t, String shareToken, bool hidden) async {
    hiddenCalls.add((shareToken, hidden));
    if (hideFails) throw const ApiException('500', statusCode: 500);
  }

  @override
  Future<SharedPlaylist> getSharedPlaylist(String? t, String shareToken) async {
    final playlist = shared[shareToken];
    if (playlist == null) {
      throw const ApiException('404', statusCode: 404, code: 'not_found');
    }
    return playlist;
  }

  int? saveStatus;
  final saved = <String>[];

  @override
  Future<Playlist> saveSharedPlaylist(String t, String shareToken) async {
    if (saveStatus != null) {
      throw ApiException('$saveStatus', statusCode: saveStatus);
    }
    saved.add(shareToken);
    return playlist;
  }

  Playlist _playlistById(String id) {
    return (userPlaylists ?? [playlist]).firstWhere(
      (playlist) => playlist.id == id,
      orElse: () => playlist,
    );
  }

  @override
  Future<Playlist> getPlaylist(String t, String id) async => _playlistById(id);
  @override
  Future<List<Playlist>> listPlaylists(String t) async =>
      userPlaylists ?? [playlist];
  @override
  Future<Playlist> createPlaylist(String t, String name) async {
    createdNames.add(name);
    final existing = userPlaylists ?? [playlist];
    final created = Playlist(
      id: 'p${existing.length + 1}',
      name: name,
      trackCount: 0,
      tracks: const [],
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    userPlaylists = [created, ...existing];
    return created;
  }

  @override
  Future<Playlist> renamePlaylist(String t, String id, String name) async =>
      playlist;
  @override
  Future<Playlist> replacePlaylistTracks(
      String t, String id, List<String> trackIds) async {
    replacedWith = trackIds;
    final current = _playlistById(id);
    final knownTracks = {
      for (final track in [...current.tracks, ...tracks]) track.id: track,
    };
    final updated = current.withTracks([
      for (final trackId in trackIds)
        knownTracks[trackId] ??
            Track(
              id: trackId,
              title: trackId,
              contentType: 'audio/mpeg',
              sizeBytes: 1,
            ),
    ]);
    if (userPlaylists != null) {
      userPlaylists = [
        for (final playlist in userPlaylists!)
          playlist.id == id ? updated : playlist,
      ];
    } else if (id == playlist.id) {
      tracks = updated.tracks;
    }
    return updated;
  }

  @override
  Future<void> deletePlaylist(String t, String id) async {}

  int collabLinks = 0;

  @override
  Future<String> createCollabLink(String t, String playlistId) async {
    collabLinks++;
    return collabToken = '${'C' * 21}$collabLinks';
  }

  @override
  Future<void> revokeCollabLink(String t, String playlistId) async {
    collabToken = null;
  }

  @override
  Future<Playlist> joinPlaylist(String t, String collab) async {
    if (collab != collabToken) {
      throw const ApiException('404', statusCode: 404, code: 'not_found');
    }
    joined.add(collab);
    isOwner = false;
    return playlist;
  }

  @override
  Future<void> removePlaylistMember(
      String t, String playlistId, String memberId) async {
    removedMembers.add(memberId);
    members = [
      for (final m in members)
        if (m.id != memberId) m
    ];
  }

  @override
  Future<void> leavePlaylist(String t, String playlistId) async {
    left = true;
  }
}

SharedPlaylist sharedMix() => SharedPlaylist.fromJson(token, {
      'name': 'Friend mix',
      'owner': 'f***@example.com',
      'isOwner': false,
      'tracks': [
        {
          'id': 's1',
          'title': 'Their song',
          'artist': 'Someone',
          'contentType': 'audio/mpeg',
          'sizeBytes': 1,
        },
      ],
    });

PublicPlaylist listed(String name,
        {int likes = 0, bool liked = false, String shareToken = token}) =>
    PublicPlaylist(
      shareToken: shareToken,
      name: name,
      owner: 'f***@example.com',
      isOwner: false,
      trackCount: 3,
      likes: PlaylistLikes(liked: liked, likeCount: likes),
    );

void main() {
  group('share links', () {
    test('a link carries the token and can be read back', () {
      final origin = Uri.parse('https://rhythmo.example.com');
      final appLink = sharedPlaylistLink(origin, token);
      expect(
          appLink.toString(), 'https://rhythmo.example.com/app/?shared=$token');
      final publicLink = sharedPlaylistLink(origin, token, public: true);
      expect(publicLink.toString(), 'https://rhythmo.example.com/p/$token');
      for (final link in [
        appLink.toString(),
        publicLink.toString(),
        // Links shared before the app moved to /app.
        'https://rhythmo.example.com/?shared=$token',
        '  $token ',
      ]) {
        expect(shareTokenFrom(link), token, reason: link);
      }
    });

    test('anything else is not a share link', () {
      for (final input in [
        '',
        'hello',
        'https://rhythmo.example.com/?shared=short',
        'https://example.com/',
        'https://rhythmo.example.com/p/short',
        'https://rhythmo.example.com/x/$token',
      ]) {
        expect(shareTokenFrom(input), isNull, reason: input);
      }
    });
  });

  test('tracks of a shared playlist play through its link', () async {
    final tracks = FakeTracksApi();
    final player = PlayerController(
        api: tracks, engine: FakeAudioEngine(), token: () => 'tok');
    final playlist = sharedMix();

    expect(playlist.tracks.single.sharedVia, token);
    await player.playFrom(playlist.tracks, 0);

    expect(tracks.calls, contains('shared:$token:s1'));
    expect(tracks.calls.where((c) => c.startsWith('stream:')), isEmpty);
  });

  group('playlists controller', () {
    test('shares, unshares and reports unavailable links', () async {
      final api = FakePlaylistsApi();
      final controller = PlaylistsController(api: api, token: () => 'tok');

      expect(await controller.share('p1'),
          (shareToken: token, isPublic: false, pending: false));
      expect(await controller.share('p1', public: true),
          (shareToken: token, isPublic: true, pending: false));
      expect(await controller.unshare('p1'), isTrue);
      expect(api.shareToken, isNull);
      expect(() => controller.openShared(token),
          throwsA(isA<SharedPlaylistUnavailable>()));

      api.shareFails = true;
      expect(await controller.share('p1'), isNull);
    });
  });

  group('shared playlist screen', () {
    Future<(FakeTracksApi, FakePlaylistsApi)> pump(
        WidgetTester tester, String shareToken) async {
      final tracks = FakeTracksApi();
      final playlists = FakePlaylistsApi()..shared[token] = sharedMix();
      await tester.pumpWidget(MaterialApp(
        home: SharedPlaylistScreen(
          shareToken: shareToken,
          controller: PlaylistsController(api: playlists, token: () => 'tok'),
          player: PlayerController(
              api: tracks, engine: FakeAudioEngine(), token: () => 'tok'),
        ),
      ));
      await tester.pumpAndSettle();
      return (tracks, playlists);
    }

    testWidgets('shows who shared it and plays a track', (tester) async {
      final (tracks, _) = await pump(tester, token);

      expect(find.text('Friend mix'), findsOneWidget);
      expect(
          find.text('اشتراک‌گذاری‌شده توسط f***@example.com'), findsOneWidget);
      await tester.tap(find.text('Their song'));
      await tester.pumpAndSettle();
      expect(tracks.calls, contains('shared:$token:s1'));
    });

    testWidgets('a recipient saves the playlist to their account',
        (tester) async {
      final (_, playlists) = await pump(tester, token);

      await tester.tap(find.text('افزودن به حساب من'));
      await tester.pumpAndSettle();
      expect(playlists.saved, [token]);
      expect(
          find.text(
              'به فهرست‌های پخش و کتابخانه‌ات اضافه شد. این نسخه مال خودت است.'),
          findsOneWidget);
    });

    testWidgets('no room in the account is explained', (tester) async {
      final (_, playlists) = await pump(tester, token);
      playlists.saveStatus = 413;

      await tester.tap(find.text('افزودن به حساب من'));
      await tester.pumpAndSettle();
      expect(find.textContaining('فضای کافی'), findsOneWidget);
    });

    testWidgets('a revoked or wrong link says so', (tester) async {
      await pump(tester, 'BBBBBBBBBBBBBBBBBBBBBB');
      expect(
          find.text(
              'این لینک اشتباه است یا صاحبش اشتراک‌گذاری را لغو کرده است.'),
          findsOneWidget);
    });
  });

  testWidgets('the owner creates a link, then turns sharing off',
      (tester) async {
    final api = FakePlaylistsApi();
    final controller = PlaylistsController(api: api, token: () => 'tok');
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showShareSheet(context,
                playlist: api.playlist, controller: controller),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ساخت لینک اشتراک'));
    await tester.pumpAndSettle();
    // Without an API origin in tests the sheet shows the code itself.
    expect(find.text(token), findsOneWidget);
    expect(find.text('کپی لینک'), findsOneWidget);

    await tester.tap(find.text('لغو اشتراک (لینک فعلی باطل می‌شود)'));
    await tester.pumpAndSettle();
    expect(api.shareToken, isNull);
    expect(find.text('ساخت لینک اشتراک'), findsOneWidget);
  });

  testWidgets('shared playlist and share sheet fit a narrow phone',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final longName =
        'یک فهرست پخش با اسمی بسیار طولانی که نباید از صفحه بیرون بزند ' * 2;
    final playlists = FakePlaylistsApi()
      ..shared[token] = SharedPlaylist.fromJson(token, {
        'name': longName,
        'owner': 'a-very-long-owner-name***@some-very-long-domain.example.com',
        'isOwner': false,
        'tracks': [
          for (var i = 0; i < 30; i++)
            {
              'id': 's$i',
              'title': 'A very long track title number $i that must truncate',
              'artist': 'An artist with an equally long name',
              'contentType': 'audio/mpeg',
              'sizeBytes': 1,
            },
        ],
      });
    final controller = PlaylistsController(api: playlists, token: () => 'tok');
    final player = PlayerController(
        api: FakeTracksApi(), engine: FakeAudioEngine(), token: () => 'tok');
    await tester.pumpWidget(MaterialApp(
      home: SharedPlaylistScreen(
          shareToken: token, controller: controller, player: player),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('افزودن به حساب من'), findsOneWidget);
    await tester.tap(find.textContaining('number 0 '));
    await tester.pumpAndSettle();
    // The mini player is there to pause what was just started.
    expect(find.byTooltip('توقف'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showShareSheet(context,
                playlist: Playlist(
                  id: 'p1',
                  name: longName,
                  trackCount: 0,
                  tracks: const [],
                  createdAt: DateTime.utc(2026),
                  updatedAt: DateTime.utc(2026),
                  shareToken: token,
                ),
                controller: controller),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('کپی لینک'), findsOneWidget);
  });

  group('likes', () {
    test('a like shows at once and the server has the last word', () async {
      final api = FakePlaylistsApi()
        ..likers[token] = {'someone'}
        ..public = [listed('mix', likes: 1)]
        ..likeGate = Completer();
      final controller = PlaylistsController(api: api, token: () => 'tok');
      await controller.loadPopular();
      final seen = <PlaylistLikes>[];

      final pending = controller.setLike(token, controller.popular.single.likes,
          onChange: seen.add);
      expect(controller.popular.single.likes,
          const PlaylistLikes(liked: true, likeCount: 2));
      expect(controller.isLiking(token), isTrue);
      // A second tap while the first is on its way is not sent.
      expect(await controller.setLike(token, controller.popular.single.likes),
          LikeResult.failed);

      api.likeGate!.complete();
      expect(await pending, LikeResult.done);
      expect(api.likeCalls, [true]);
      expect(controller.isLiking(token), isFalse);
      expect(seen.last, const PlaylistLikes(liked: true, likeCount: 2));
    });

    test('a refused like goes back and says why', () async {
      final api = FakePlaylistsApi()
        ..public = [listed('mix', likes: 4, liked: true)];
      final controller = PlaylistsController(api: api, token: () => 'tok');
      await controller.loadPopular();

      api.likeStatus = 500;
      expect(await controller.setLike(token, controller.popular.single.likes),
          LikeResult.failed);
      expect(controller.popular.single.likes,
          const PlaylistLikes(liked: true, likeCount: 4));
      expect(api.likeCalls, [false]);

      api.likeStatus = 404;
      expect(await controller.setLike(token, controller.popular.single.likes),
          LikeResult.gone);
      expect(controller.popular.single.likes.likeCount, 4);
    });

    testWidgets('liking on the shared playlist screen', (tester) async {
      final api = FakePlaylistsApi()..shared[token] = sharedMix();
      await tester.pumpWidget(MaterialApp(
        home: SharedPlaylistScreen(
          shareToken: token,
          controller: PlaylistsController(api: api, token: () => 'tok'),
          player: PlayerController(
              api: FakeTracksApi(),
              engine: FakeAudioEngine(),
              token: () => 'tok'),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('پسندیدن · ۰'), findsOneWidget);
      expect(find.byIcon(RhythmoIcons.heart), findsOneWidget);
      await tester.tap(find.text('پسندیدن · ۰'));
      await tester.pumpAndSettle();
      expect(find.text('پسندیدی · ۱'), findsOneWidget);
      expect(find.byIcon(RhythmoIcons.heartFill), findsOneWidget);
      expect(find.bySemanticsLabel('پسندیده‌ای، ۱ پسند'), findsOneWidget);

      api.likeStatus = 503;
      await tester.tap(find.text('پسندیدی · ۱'));
      await tester.pumpAndSettle();
      expect(find.text('پسندیدی · ۱'), findsOneWidget);
      expect(find.text('پسندیدن ثبت نشد. دوباره تلاش کن.'), findsOneWidget);
    });

    testWidgets('the owner chooses link-only or public', (tester) async {
      final api = FakePlaylistsApi();
      final controller = PlaylistsController(api: api, token: () => 'tok');
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showShareSheet(context,
                  playlist: api.playlist, controller: controller),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Link-only unless the owner says otherwise.
      expect(find.textContaining('فقط کسی که لینک را دارد'), findsOneWidget);
      await tester.tap(find.text('عمومی'));
      await tester.pumpAndSettle();
      expect(api.shareCalls, isEmpty);
      await tester.tap(find.text('ساخت لینک اشتراک'));
      await tester.pumpAndSettle();
      expect(api.shareCalls, [true]);
      expect(api.isPublic, isTrue);
      expect(find.textContaining('فهرست‌های پخش محبوب'), findsOneWidget);

      await tester.tap(find.text('فقط با لینک'));
      await tester.pumpAndSettle();
      expect(api.shareCalls, [true, false]);
      expect(api.isPublic, isFalse);
      expect(api.shareToken, token);
    });

    testWidgets('an unverified owner going public waits for an admin',
        (tester) async {
      final api = FakePlaylistsApi()
        ..needsReview = true
        ..shareToken = token;
      final controller = PlaylistsController(api: api, token: () => 'tok');
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showShareSheet(context,
                  playlist: api.playlist, controller: controller),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('با تأیید مدیر است'), findsOneWidget);

      await tester.tap(find.text('عمومی'));
      await tester.pumpAndSettle();
      expect(api.shareCalls, [true]);
      expect(api.isPublic, isFalse);
      expect(find.textContaining('در انتظار تأیید مدیر'), findsOneWidget);
      expect(find.textContaining('فهرست‌های پخش محبوب'), findsNothing);

      // Going back to link-only withdraws the request.
      await tester.tap(find.text('فقط با لینک'));
      await tester.pumpAndSettle();
      expect(api.shareCalls, [true, false]);
      expect(api.pending, isFalse);
      expect(find.textContaining('در انتظار تأیید مدیر'), findsNothing);
    });

    test('ApiClient reads a pending public request', () async {
      final client = ApiClient(Uri.parse('https://api.example.com'),
          httpClient: MockClient((request) async => http.Response(
              jsonEncode({
                'shareToken': token,
                'public': false,
                'publicReview': 'pending',
              }),
              200,
              headers: {'content-type': 'application/json'})));
      expect(await client.sharePlaylist('tok', 'p1', public: true),
          (shareToken: token, isPublic: false, pending: true));
    });

    group('popular playlists screen', () {
      Future<FakePlaylistsApi> pump(
          WidgetTester tester, FakePlaylistsApi api) async {
        await tester.pumpWidget(MaterialApp(
          home: PopularPlaylistsScreen(
            controller: PlaylistsController(api: api, token: () => 'tok'),
            player: PlayerController(
                api: FakeTracksApi(),
                engine: FakeAudioEngine(),
                token: () => 'tok'),
          ),
        ));
        await tester.pumpAndSettle();
        return api;
      }

      testWidgets('lists public playlists and likes one', (tester) async {
        final api = await pump(
            tester,
            FakePlaylistsApi()
              ..public = [
                listed('loved', likes: 5),
                listed('quiet', shareToken: 'B' * 22),
              ]);

        expect(find.text('loved'), findsOneWidget);
        expect(find.text('۳ آهنگ'), findsNWidgets(2));
        // Owners are never shown, not even masked.
        expect(find.textContaining('@'), findsNothing);
        await tester.tap(find.text('۵'));
        await tester.pumpAndSettle();
        expect(api.likeCalls, [true]);
        expect(find.byIcon(RhythmoIcons.heartFill), findsOneWidget);
      });

      testWidgets('only admins can take a playlist out of the list',
          (tester) async {
        final api = await pump(
            tester, FakePlaylistsApi()..public = [listed('loved', likes: 5)]);
        expect(find.byTooltip('مدیریت loved'), findsNothing);
        expect(api.hiddenCalls, isEmpty);
      });

      testWidgets('an admin removes a playlist and can undo it',
          (tester) async {
        final api = FakePlaylistsApi()
          ..public = [
            listed('loved', likes: 5),
            listed('quiet', shareToken: 'B' * 22),
          ];
        // A narrow phone: the remove button fits beside the rank badge.
        await tester.binding.setSurfaceSize(const Size(320, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(MaterialApp(
          home: PopularPlaylistsScreen(
            controller: PlaylistsController(
                api: api, token: () => 'tok', isAdmin: () => true),
            player: PlayerController(
                api: FakeTracksApi(),
                engine: FakeAudioEngine(),
                token: () => 'tok'),
          ),
        ));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('مدیریت loved'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('حذف از محبوب‌ها'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('انصراف'));
        await tester.pumpAndSettle();
        expect(api.hiddenCalls, isEmpty);

        // The server could not save it: the playlist comes back.
        api.hideFails = true;
        await tester.tap(find.byTooltip('مدیریت loved'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('حذف از محبوب‌ها'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('حذف'));
        await tester.pumpAndSettle();
        expect(find.text('loved'), findsOneWidget);
        expect(find.text('حذف انجام نشد. دوباره تلاش کن.'), findsOneWidget);

        api.hideFails = false;
        ScaffoldMessenger.of(tester.element(find.text('quiet')))
            .removeCurrentSnackBar();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('مدیریت loved'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('حذف از محبوب‌ها'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('حذف'));
        await tester.pumpAndSettle();
        expect(find.text('loved'), findsNothing);
        expect(find.text('quiet'), findsOneWidget);
        expect(api.hiddenCalls.last, (token, true));

        await tester.tap(find.text('برگرداندن'));
        await tester.pumpAndSettle();
        expect(api.hiddenCalls.last, (token, false));
        expect(find.text('loved'), findsOneWidget);
      });

      testWidgets('an admin deletes a playlist after confirming',
          (tester) async {
        final api = FakePlaylistsApi()
          ..public = [
            listed('loved', likes: 5),
            listed('quiet', shareToken: 'B' * 22),
          ];
        await tester.binding.setSurfaceSize(const Size(320, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(MaterialApp(
          home: PopularPlaylistsScreen(
            controller: PlaylistsController(
                api: api, token: () => 'tok', isAdmin: () => true),
            player: PlayerController(
                api: FakeTracksApi(),
                engine: FakeAudioEngine(),
                token: () => 'tok'),
          ),
        ));
        await tester.pumpAndSettle();

        Future<void> askToDelete() async {
          await tester.tap(find.byTooltip('مدیریت loved'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('پاک کردن فهرست پخش'));
          await tester.pumpAndSettle();
          expect(find.textContaining('برگشت‌پذیر نیست'), findsOneWidget);
        }

        await askToDelete();
        await tester.tap(find.text('انصراف'));
        await tester.pumpAndSettle();
        expect(api.deletedPublic, isEmpty);

        api.deleteFails = true;
        await askToDelete();
        await tester.tap(find.text('پاک کردن'));
        await tester.pumpAndSettle();
        expect(find.text('loved'), findsOneWidget);
        expect(
            find.text('پاک کردن انجام نشد. دوباره تلاش کن.'), findsOneWidget);

        api.deleteFails = false;
        await askToDelete();
        await tester.tap(find.text('پاک کردن'));
        await tester.pumpAndSettle();
        expect(api.deletedPublic, [token]);
        expect(find.text('loved'), findsNothing);
        expect(find.text('quiet'), findsOneWidget);
      });

      testWidgets('a guest opens a shared link and plays it', (tester) async {
        final tracks = FakeTracksApi();
        await tester.pumpWidget(MaterialApp(
          home: PopularPlaylistsScreen(
            controller: PlaylistsController(
                api: FakePlaylistsApi()..shared[token] = sharedMix(),
                token: () => null),
            player: PlayerController(
                api: tracks, engine: FakeAudioEngine(), token: () => null),
            onSignIn: () {},
            openShareToken: token,
          ),
        ));
        await tester.pumpAndSettle();

        expect(find.text('Friend mix'), findsOneWidget);
        await tester.tap(find.text('Their song'));
        await tester.pumpAndSettle();
        expect(tracks.calls, contains('shared:$token:s1'));

        // Back on the guest home, sign-in stays on offer.
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('ورود / ثبت‌نام'), findsOneWidget);
      });

      testWidgets('says when nothing is public yet', (tester) async {
        await pump(tester, FakePlaylistsApi());
        expect(find.textContaining('هنوز فهرست پخش عمومی‌ای نیست'),
            findsOneWidget);
      });

      testWidgets('offers a retry when the list fails', (tester) async {
        final api = await pump(tester, FakePlaylistsApi()..listFails = true);
        expect(find.text('فهرست‌های پخش محبوب بارگذاری نشد.'), findsOneWidget);

        api
          ..listFails = false
          ..public = [listed('back')];
        await tester.tap(find.text('تلاش دوباره'));
        await tester.pumpAndSettle();
        expect(find.text('back'), findsOneWidget);
      });

      testWidgets('fits a narrow phone and keeps the last row reachable',
          (tester) async {
        tester.view.physicalSize = const Size(360, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final long =
            'یک فهرست پخش عمومی با اسمی بسیار طولانی که نباید بیرون بزند ' * 2;
        await pump(
            tester,
            FakePlaylistsApi()
              ..public = [
                for (var i = 0; i < 20; i++)
                  listed('$long $i', likes: 1000 + i),
              ]);

        expect(tester.takeException(), isNull);
        final like = tester.getSize(find.byType(TextButton).first);
        expect(like.width, greaterThanOrEqualTo(48));
        expect(like.height, greaterThanOrEqualTo(48));

        await tester.scrollUntilVisible(find.textContaining(' 19'), 300,
            scrollable: find.byType(Scrollable).last);
        await tester.pumpAndSettle();
        final lastRow = tester.getRect(find
            .ancestor(
                of: find.textContaining(' 19'), matching: find.byType(InkWell))
            .first);
        final screen = tester.getRect(find.byType(Scaffold));
        expect(lastRow.bottom, lessThanOrEqualTo(screen.bottom));
        expect(tester.takeException(), isNull);
      });
    });
  });
}
