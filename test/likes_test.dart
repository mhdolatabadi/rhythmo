import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhythmo/app/app_preferences.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/features/auth/data/token_store.dart';
import 'package:rhythmo/features/library/application/track_sort.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/likes/data/likes.dart';
import 'package:rhythmo/features/likes/presentation/liked_songs_screen.dart';
import 'package:rhythmo/features/player/application/favorite_tracks.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/mini_player.dart';
import 'package:rhythmo/features/store/application/store_controller.dart';
import 'package:rhythmo/features/store/presentation/store_screen.dart';
import 'package:rhythmo/main.dart';

import 'cache_controller_test.dart' show FakeAudioCache;
import 'player_controller_test.dart' show FakeAudioEngine;
import 'store_test.dart' show FakeStoreApi, song;
import 'upload_controller_test.dart' show FakeTracksApi, FakeUploader;
import 'widget_test.dart' show FakeAuthApi, FakePicker;

Track own(String id,
        {String? title,
        bool published = false,
        int likes = 0,
        bool liked = false,
        String? publishReview}) =>
    Track(
      id: id,
      title: title ?? 'Track $id',
      artist: 'Artist',
      contentType: 'audio/mpeg',
      sizeBytes: 2 * 1024 * 1024,
      published: published,
      publishReview: publishReview,
      likeCount: likes,
      liked: liked,
    );

/// Server likes in memory; it records calls and can be made to fail.
class FakeLikesApi implements LikesApi {
  FakeLikesApi({List<Track>? liked}) : liked = [...?liked];

  final List<Track> liked;
  final calls = <String>[];
  Object? error;
  final missing = <String>{};
  final published = <String, bool>{};

  @override
  Future<LikeState> setLike(String token, Track track, bool like) async {
    calls.add(
        '${like ? 'like' : 'unlike'}:${track.fromStore ? 'store:' : ''}${track.id}');
    if (error != null) throw error!;
    if (missing.contains(track.id)) {
      throw const ApiException('404', statusCode: 404, code: 'not_found');
    }
    liked.removeWhere((t) => t.id == track.id);
    if (like) liked.insert(0, track);
    return LikeState(count: like ? 1 : 0, liked: like);
  }

  @override
  Future<List<LikedSong>> likedSongs(String token) async {
    calls.add('list');
    return [
      for (final track in liked)
        LikedSong(track: track, likedAt: DateTime(2026)),
    ];
  }

  @override
  Future<PublishState> setPublished(
      String token, String trackId, bool publish) async {
    calls.add('${publish ? 'publish' : 'unpublish'}:$trackId');
    if (publish && needsReview) return PublishState.pending;
    published[trackId] = publish;
    return publish ? PublishState.published : PublishState.private;
  }

  /// The owner isn't verified: publishing only asks an admin (#322).
  bool needsReview = false;
}

Widget _app(Widget home) => MaterialApp(
      locale: const Locale('fa'),
      supportedLocales: const [Locale('fa')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: RhythmoTheme.dark(),
      home: home,
    );

void _narrow(WidgetTester tester, {Size size = const Size(360, 640)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(bottom: 34);
  tester.view.viewPadding = const FakeViewPadding(bottom: 34);
  addTearDown(tester.view.reset);
}

void main() {
  group('FavoriteTracks', () {
    test('loads server likes and moves device likes of cloud tracks there',
        () async {
      final api = FakeLikesApi(liked: [song(1)]);
      api.missing.add('shared-track');
      final store =
          MemoryFavoritesStore({'cloud-1', 'device:abc', 'shared-track'});
      final favorites =
          FavoriteTracks(store: store, api: api, token: () => 'tok');
      await favorites.load();
      expect(api.calls,
          containsAll(['like:cloud-1', 'like:shared-track', 'list']));
      expect(api.calls, isNot(contains('like:device:abc')));
      // Moved likes leave the device; the rest stay.
      expect(store.ids, {'device:abc', 'shared-track'});
      for (final id in ['cloud-1', 'device:abc', 'shared-track', 'entry-1']) {
        expect(favorites.contains(id), isTrue, reason: id);
      }
      expect(favorites.songs.map((t) => t.id), ['cloud-1', 'entry-1']);
    });

    test('a like flips at once and flips back when the server says no',
        () async {
      final api = FakeLikesApi();
      final favorites = FavoriteTracks(api: api, token: () => 'tok');
      final track = own('t1', likes: 4);
      final pending = favorites.toggleTrack(track);
      expect(favorites.contains('t1'), isTrue);
      expect(favorites.countFor(track), 5);
      expect(await pending, TrackLikeResult.done);
      expect(api.calls, ['like:t1']);

      api.error = Exception('offline');
      expect(await favorites.toggleTrack(track), TrackLikeResult.failed);
      expect(favorites.contains('t1'), isTrue, reason: 'the unlike was undone');
      expect(favorites.songs.single.id, 't1');
    });

    test(
        'a guest likes device music locally but needs an account for the store',
        () async {
      final api = FakeLikesApi();
      final favorites = FavoriteTracks(api: api, token: () => null);
      expect(
          await favorites.toggleTrack(song(2)), TrackLikeResult.needsAccount);
      expect(favorites.contains('entry-2'), isFalse);
      final device = Track(
          id: 'device:1',
          title: 'on the phone',
          contentType: 'audio/mpeg',
          sizeBytes: 1,
          sourceUri: Uri.parse('content://media/1'));
      expect(await favorites.toggleTrack(device), TrackLikeResult.done);
      expect(favorites.contains('device:1'), isTrue);
      expect(api.calls, isEmpty);
    });

    test('a liked count already counting the listener is not counted twice',
        () async {
      final favorites = FavoriteTracks(
          api: FakeLikesApi(liked: [own('t1')]), token: () => 'tok');
      await favorites.load();
      expect(favorites.countFor(own('t1', likes: 3, liked: true)), 3);
      await favorites.toggleTrack(own('t1', likes: 3, liked: true));
      expect(favorites.countFor(own('t1', likes: 3, liked: true)), 2);
    });

    test('«پسندیده‌ها» puts server likes first, in like order', () async {
      final favorites = FavoriteTracks(
          store: MemoryFavoritesStore({'device:9'}),
          api: FakeLikesApi(liked: [song(5), own('t1')]),
          token: () => 'tok');
      await favorites.load();
      final library = [
        own('t1', title: 'library copy'),
        own('t2'),
        Track(
            id: 'device:9',
            title: 'phone',
            contentType: 'audio/mpeg',
            sizeBytes: 1,
            sourceUri: Uri.parse('content://9')),
      ];
      final liked = favorites.likedFrom(library);
      expect(liked.map((t) => t.id), ['entry-5', 't1', 'device:9']);
      expect(liked[1].title, 'library copy');
      favorites.clearAccount();
      expect(favorites.likedFrom(library).map((t) => t.id), ['device:9']);
    });
  });

  test('ApiClient likes, lists likes and publishes', () async {
    final sent = <http.Request>[];
    final client = ApiClient(Uri.parse('https://api.example'),
        httpClient: MockClient((request) async {
      sent.add(request);
      final path = request.url.path;
      final body = switch (path) {
        '/api/v1/likes' => {
            'songs': [
              {
                'source': 'store',
                'likedAt': '2026-10-15T12:00:00Z',
                'storeTrack': {
                  'id': 'e1',
                  'title': 's',
                  'contentType': 'audio/mpeg',
                  'sizeBytes': 1,
                  'likeCount': 3,
                  'liked': true,
                },
              },
              {
                'source': 'library',
                'likedAt': '2026-10-14T12:00:00Z',
                'track': {
                  'id': 't1',
                  'title': 'mine',
                  'contentType': 'audio/mpeg',
                  'sizeBytes': 1,
                  'published': true,
                  'likeCount': 2,
                },
              },
            ],
            'hasMore': request.url.queryParameters['offset'] == '0',
          },
        _ when path.endsWith('t2/published') => {
            'published': false,
            'review': 'pending'
          },
        _ when path.endsWith('/published') => {
            'published': request.method == 'PUT'
          },
        _ => {'liked': request.method == 'PUT', 'likeCount': 7},
      };
      return http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    final state = await client.setLike('tok', song(1), true);
    expect(sent.last.method, 'PUT');
    expect(sent.last.url.path, '/api/v1/store/tracks/entry-1/like');
    expect(state.count, 7);
    await client.setLike('tok', own('t/1'), false);
    expect(sent.last.method, 'DELETE');
    expect(sent.last.url.path, '/api/v1/tracks/t%2F1/like');

    final liked = await client.likedSongs('tok');
    expect(liked, hasLength(4), reason: 'two pages');
    expect(liked.first.track.fromStore, isTrue);
    expect(liked.first.track.likeCount, 3);
    expect(liked[1].track.published, isTrue);
    expect(
        sent
            .where((r) => r.url.path == '/api/v1/likes')
            .map((r) => r.url.query),
        ['limit=100&offset=0', 'limit=100&offset=2']);

    expect(
        await client.setPublished('tok', 't1', true), PublishState.published);
    expect(sent.last.method, 'PUT');
    expect(sent.last.url.path, '/api/v1/tracks/t1/published');
    expect(await client.setPublished('tok', 't1', false), PublishState.private);
    expect(await client.setPublished('tok', 't2', true), PublishState.pending);
  });

  test('my published tracks sort by likes', () {
    final tracks = [
      own('a', likes: 1),
      own('b', likes: 9, published: true),
      own('c', likes: 4, published: true),
      own('d', likes: 9),
    ];
    expect(sortTracks(tracks, TrackSort.mostLiked).map((t) => t.id),
        ['b', 'd', 'c', 'a']);
    expect(
        sortTracks(tracks, TrackSort.published).map((t) => t.id), ['b', 'c']);
  });

  group('screens', () {
    testWidgets('«پسندیده‌ها» plays, shuffles and unlikes on a narrow phone',
        (tester) async {
      _narrow(tester);
      final api = FakeLikesApi(liked: [
        for (var i = 0; i < 20; i++)
          song(i, title: 'یک آهنگ پسندیده با نامی بسیار طولانی $i'),
      ]);
      final favorites = FavoriteTracks(api: api, token: () => 'tok');
      await favorites.load();
      final tracks = FakeTracksApi();
      final player = PlayerController(
          api: tracks,
          engine: FakeAudioEngine(),
          token: () => 'tok',
          favorites: favorites);
      await tester.pumpWidget(
          _app(LikedSongsScreen(player: player, libraryTracks: const [])));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('۲۰ آهنگ'), findsOneWidget);
      final heart = find.byTooltip('نپسندیدن').first;
      expect(tester.getSize(heart).height,
          greaterThanOrEqualTo(RhythmoSpace.target));

      await tester.tap(find.text('پخش همه'));
      await tester.pumpAndSettle();
      expect(player.track?.id, 'entry-0');
      await tester.tap(find.text('پخش تصادفی'));
      await tester.pumpAndSettle();
      expect(player.shuffle, isTrue);

      await tester.tap(heart);
      await tester.pumpAndSettle();
      expect(api.calls, contains('unlike:store:entry-0'));
      expect(find.text('۱۹ آهنگ'), findsOneWidget);

      await tester.scrollUntilVisible(find.textContaining('طولانی 19'), 300,
          scrollable: find.byType(Scrollable).last);
      await tester.pumpAndSettle();
      final lastRow = tester.getRect(find
          .ancestor(
              of: find.textContaining('طولانی 19'),
              matching: find.byType(ListTile))
          .first);
      expect(lastRow.bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(MiniPlayer)).top));
    });

    testWidgets('an empty «پسندیده‌ها» says how to fill it', (tester) async {
      final player = PlayerController(
          api: FakeTracksApi(), engine: FakeAudioEngine(), token: () => 'tok');
      await tester.pumpWidget(
          _app(LikedSongsScreen(player: player, libraryTracks: const [])));
      await tester.pumpAndSettle();
      expect(find.text('هنوز آهنگی را نپسندیده‌ای'), findsOneWidget);
    });

    testWidgets('store rows show likes and a guest is asked to sign in',
        (tester) async {
      _narrow(tester);
      String? token;
      final likes = FakeLikesApi();
      final favorites = FavoriteTracks(api: likes, token: () => token);
      final player = PlayerController(
          api: FakeTracksApi(),
          engine: FakeAudioEngine(),
          token: () => token,
          favorites: favorites);
      final storeApi = FakeStoreApi(songs: [
        Track(
            id: 'entry-1',
            title: 'Song 1',
            artist: 'Artist',
            contentType: 'audio/mpeg',
            sizeBytes: 1,
            fromStore: true,
            likeCount: 12),
        song(2),
      ]);
      final store = StoreController(api: storeApi, token: () => token);
      addTearDown(store.dispose);
      var signIns = 0;
      await tester.pumpWidget(_app(StoreScreen(
          controller: store, player: player, onSignIn: () => signIns++)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final counted = find.bySemanticsLabel('پسندیدن، ۱۲ پسند');
      expect(counted, findsOneWidget);
      expect(tester.getSize(find.byType(TextButton).first).height,
          greaterThanOrEqualTo(RhythmoSpace.target));

      await tester.tap(counted);
      await tester.pumpAndSettle();
      expect(find.text('برای پسندیدن وارد حسابت شو.'), findsOneWidget);
      await tester.tap(find.text('ورود'));
      expect(signIns, 1);
      expect(likes.calls, isEmpty);

      token = 'tok';
      await tester.tap(find.bySemanticsLabel('پسندیدن، ۱۲ پسند'));
      await tester.pumpAndSettle();
      expect(likes.calls, ['like:store:entry-1']);
      expect(find.bySemanticsLabel('نپسندیدن، ۱۳ پسند'), findsOneWidget);
    });
  });

  group('library', () {
    Future<void> pumpLibrary(
        WidgetTester tester, FakeTracksApi tracks, FakeLikesApi likes,
        {Set<LibraryTab> hidden = const {LibraryTab.favorites}}) async {
      _narrow(tester, size: const Size(360, 740));
      await tester.pumpWidget(RhythmoApp(
        healthCheck: () async {},
        appPreferencesStore: MemoryAppPreferencesStore()
          ..value = AppPreferences(hidden: hidden),
        authApi: FakeAuthApi(),
        tokenStore: MemoryTokenStore('valid-token'),
        tracksApi: tracks,
        likesApi: likes,
        audioEngine: FakeAudioEngine(),
        audioCache: FakeAudioCache(),
        uploader: FakeUploader(),
        picker: FakePicker(null),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('rows show published and like counts, and the menu publishes',
        (tester) async {
      final tracks = FakeTracksApi([
        own('t1', title: 'منتشرشده و محبوب', published: true, likes: 12),
        own('t2', title: 'خصوصی'),
      ]);
      final likes = FakeLikesApi();
      await pumpLibrary(tester, tracks, likes);
      expect(tester.takeException(), isNull);
      expect(
          find.bySemanticsLabel(RegExp('منتشرشده، ۱۲ پسند')), findsOneWidget);

      await tester.tap(find.byTooltip('اقدامات آهنگ').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('انتشار در استور'));
      await tester.pumpAndSettle();
      expect(likes.calls, contains('publish:t2'));
      expect(find.textContaining('در استور منتشر شد'), findsOneWidget);

      await tester.tap(find.byTooltip('اقدامات آهنگ').first);
      await tester.pumpAndSettle();
      expect(find.text('لغو انتشار در استور'), findsOneWidget);
      await tester.tap(find.text('پسندیدن'));
      await tester.pumpAndSettle();
      expect(likes.calls, contains('like:t1'));
      expect(find.bySemanticsLabel(RegExp('منتشرشده، پسندیده‌ای، ۱۳ پسند')),
          findsOneWidget);
    });

    testWidgets('an unverified owner asks an admin to publish', (tester) async {
      final tracks = FakeTracksApi([
        own('t1', title: 'در انتظار', publishReview: 'pending'),
        own('t2', title: 'خصوصی'),
      ]);
      final likes = FakeLikesApi()..needsReview = true;
      await pumpLibrary(tester, tracks, likes);
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel(RegExp('در انتظار تأیید مدیر')),
          findsOneWidget);

      await tester.tap(find.byTooltip('اقدامات آهنگ').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('انتشار در استور'));
      await tester.pumpAndSettle();
      expect(likes.calls, contains('publish:t2'));
      expect(find.textContaining('برای مدیر فرستاده شد'), findsOneWidget);

      // A pending request is withdrawn from the same menu.
      await tester.tap(find.byTooltip('اقدامات آهنگ').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('لغو درخواست انتشار'));
      await tester.pumpAndSettle();
      expect(likes.calls, contains('unpublish:t1'));
    });

    testWidgets('the «پسندیده‌ها» tab lists server likes', (tester) async {
      final tracks =
          FakeTracksApi([own('t1', title: 'mine'), own('t2', title: 'other')]);
      final likes = FakeLikesApi(
          liked: [song(3, title: 'from the store'), own('t1', title: 'mine')]);
      await pumpLibrary(tester, tracks, likes, hidden: const {});
      await tester.tap(find.widgetWithText(Tab, 'پسندیده‌ها'));
      await tester.pumpAndSettle();
      expect(find.text('from the store'), findsOneWidget);
      expect(find.text('mine'), findsOneWidget);
      expect(find.text('other'), findsNothing);
    });
  });
}
