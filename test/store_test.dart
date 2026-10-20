import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/format_size.dart';
import 'package:rhythmo/features/history/application/recently_played_controller.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/lyrics/application/lyrics_controller.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/mini_player.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/presentation/popular_playlists_screen.dart';
import 'package:rhythmo/features/store/application/store_controller.dart';
import 'package:rhythmo/features/store/data/store_catalog.dart';
import 'package:rhythmo/features/store/presentation/store_screen.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'playlist_sharing_test.dart' show FakePlaylistsApi;
import 'upload_controller_test.dart' show FakeTracksApi;

Track song(int i, {String? title, String? artist}) => Track(
      id: 'entry-$i',
      title: title ?? 'Song $i',
      artist: artist ?? 'Artist ${i % 3}',
      contentType: 'audio/mpeg',
      sizeBytes: 3 * 1024 * 1024,
      fromStore: true,
    );

/// A store of [songs], served [pageSize] at a time, that records calls.
class FakeStoreApi implements StoreApi {
  FakeStoreApi({List<Track>? songs, this.pageSize = 50})
      : songs = songs ?? [for (var i = 0; i < 5; i++) song(i)];

  List<Track> songs;
  final int pageSize;
  final calls = <String>[];
  Object? error;
  String? saveError;
  String? reportError;
  Completer<void>? gate;

  @override
  Future<StorePage<Track>> storeTracks(String? token,
      {String query = '',
      String? artist,
      String? album,
      int offset = 0}) async {
    calls.add('tracks:$token:$query:$artist:$album:$offset');
    await gate?.future;
    if (error != null) throw error!;
    final matching = songs
        .where((s) =>
            (query.isEmpty || s.title.contains(query)) &&
            (artist == null || s.artist == artist))
        .toList();
    final page = matching.skip(offset).take(pageSize).toList();
    return StorePage(page, hasMore: offset + page.length < matching.length);
  }

  /// What the carousels rank; empty means nothing has a score yet.
  List<Track> ranked = [];

  @override
  Future<StorePage<Track>> storeRanked(String? token, StoreRanking ranking,
      {int offset = 0}) async {
    calls.add('ranked:${ranking.wire}:$offset');
    if (error != null) throw error!;
    final list =
        ranking == StoreRanking.popular ? ranked : ranked.reversed.toList();
    return StorePage(list.skip(offset).toList(), hasMore: false);
  }

  @override
  Future<Track> storeTrack(String? token, String id) async {
    calls.add('track:$id');
    final found = songs.where((s) => s.id == id);
    if (found.isEmpty) {
      throw const ApiException('gone', statusCode: 404, code: 'not_found');
    }
    return found.first;
  }

  @override
  Future<StorePage<StoreArtist>> storeArtists(String? token,
      {String query = '', int offset = 0}) async {
    calls.add('artists:$query:$offset');
    return const StorePage([StoreArtist(name: 'Artist 0', trackCount: 2)],
        hasMore: false);
  }

  @override
  Future<StorePage<StoreAlbum>> storeAlbums(String? token,
      {String query = '', String? artist, int offset = 0}) async {
    calls.add('albums:$query:$offset');
    return const StorePage(
        [StoreAlbum(name: 'Seasons', artist: 'Artist 1', trackCount: 1)],
        hasMore: false);
  }

  @override
  Future<Track> saveStoreTrack(String token, String id) async {
    calls.add('save:$token:$id');
    if (saveError != null) {
      throw ApiException('no', statusCode: 409, code: saveError);
    }
    return Track(
        id: 'copy-$id', title: 'copy', contentType: 'audio/mpeg', sizeBytes: 1);
  }

  @override
  Future<void> reportStoreTrack(
      String token, String id, StoreReportReason reason,
      {String? details}) async {
    calls.add('report:$token:$id:${reason.wire}:$details');
    if (reportError != null) {
      throw ApiException('no', statusCode: 429, code: reportError);
    }
  }
}

void main() {
  group('StoreController', () {
    test('pages songs and drops a response a reload overtook', () async {
      final api = FakeStoreApi(
          songs: [for (var i = 0; i < 5; i++) song(i)], pageSize: 2);
      final store = StoreController(api: api, token: () => null);
      await store.songs.ensureLoaded();
      expect(store.songs.items.map((s) => s.id), ['entry-0', 'entry-1']);
      expect(store.songs.hasMore, isTrue);
      await store.songs.loadMore();
      await store.songs.loadMore();
      expect(store.songs.items, hasLength(5));
      expect(store.songs.hasMore, isFalse);
      // Visitors browse without a token.
      expect(api.calls.first, 'tracks:null::null:null:0');

      api.gate = Completer<void>();
      final slow = store.songs.refresh();
      api.gate = null;
      await store.search('Song 4');
      expect(store.songs.items.single.id, 'entry-4');
      // The earlier reload answers last and is ignored.
      await slow.timeout(Duration.zero, onTimeout: () {});
      expect(store.songs.items.single.id, 'entry-4');
    });

    test('search reloads only the listings already shown', () async {
      final api = FakeStoreApi();
      final store = StoreController(api: api, token: () => 'tok');
      await store.songs.ensureLoaded();
      api.calls.clear();
      await store.search('  Song 2 ');
      expect(store.query, 'Song 2');
      expect(api.calls, ['tracks:tok:Song 2:null:null:0']);
      await store.search('Song 2');
      expect(api.calls, hasLength(1), reason: 'the same search again');
      await store.artists.ensureLoaded();
      expect(api.calls.last, 'artists:Song 2:0');
    });

    test('typing searches once it rests', () {
      final api = FakeStoreApi();
      final store = StoreController(api: api, token: () => null);
      store.songs.ensureLoaded();
      api.calls.clear();
      store.searchSoon('S');
      store.searchSoon('So');
      expect(api.calls, isEmpty);
      return Future<void>.delayed(StoreController.searchDelay * 2, () {
        expect(api.calls, ['tracks:null:So:null:null:0']);
      });
    });

    test('a failed page can be retried', () async {
      final api = FakeStoreApi(pageSize: 2);
      final store = StoreController(api: api, token: () => null);
      await store.songs.ensureLoaded();
      api.error = Exception('offline');
      await store.songs.loadMore();
      expect(store.songs.moreFailed, isTrue);
      expect(store.songs.items, hasLength(2));
      api.error = null;
      await store.songs.loadMore();
      expect(store.songs.items, hasLength(4));
      api.error = Exception('offline');
      await store.songs.refresh();
      expect(store.songs.status, StoreStatus.error);
    });

    test('saving and reporting need an account and say how it went', () async {
      String? token;
      final api = FakeStoreApi();
      var reloaded = 0;
      final store = StoreController(
          api: api, token: () => token, onSaved: () async => reloaded++);
      expect(await store.save(song(1)), StoreSaveResult.failed);
      expect(await store.report(song(1), StoreReportReason.copyright),
          StoreReportResult.failed);
      expect(api.calls, isEmpty);

      token = 'tok';
      expect(await store.save(song(1)), StoreSaveResult.saved);
      expect(reloaded, 1);
      for (final (code, result) in [
        ('already_yours', StoreSaveResult.alreadyYours),
        ('quota_exceeded', StoreSaveResult.noSpace),
        ('uploads_disabled', StoreSaveResult.uploadsDisabled),
        ('not_found', StoreSaveResult.gone),
        ('internal_error', StoreSaveResult.failed),
      ]) {
        api.saveError = code;
        expect(await store.save(song(1)), result, reason: code);
      }
      expect(
          await store.report(song(2), StoreReportReason.wrongInfo,
              details: 'title'),
          StoreReportResult.sent);
      expect(api.calls, contains('report:tok:entry-2:wrong_info:title'));
      api.reportError = 'rate_limited';
      expect(await store.report(song(2), StoreReportReason.other),
          StoreReportResult.tooMany);
    });

    test('a song that left the store is null', () async {
      final store = StoreController(api: FakeStoreApi(), token: () => null);
      expect((await store.song('entry-1'))?.title, 'Song 1');
      expect(await store.song('gone'), isNull);
    });
  });

  test('store songs play, without an account, through the store', () async {
    final tracks = FakeTracksApi();
    final engine = FakeAudioEngine();
    final player =
        PlayerController(api: tracks, engine: engine, token: () => null);
    await player.playFrom([song(1), song(2)], 0);
    expect(tracks.calls, contains('store:entry-1'));
    expect(player.track?.id, 'entry-1');
    expect(song(1).playsWithoutAccount, isTrue);
    expect(
        const Track(id: 'x', title: 'x', contentType: 'a', sizeBytes: 1)
            .playsWithoutAccount,
        isFalse);
    // A store song keeps where it came from when its metadata is refreshed.
    expect(
        const Track(id: 'entry-1', title: 'new', contentType: 'a', sizeBytes: 1)
            .keepingContextOf(song(1))
            .fromStore,
        isTrue);
  });

  test('store songs have no lyrics or history yet', () async {
    final lyrics = LyricsController(api: _NoLyrics(), token: () => 'tok');
    expect(lyrics.unavailable(song(1)), LyricsUnavailable.store);
    final history = _RecordingHistory();
    final recent = RecentlyPlayedController(api: history, token: () => 'tok');
    await recent.record(song(1));
    expect(history.recorded, isEmpty);
    expect(recent.tracks, isEmpty);
  });

  group('ApiClient', () {
    final base = Uri.parse('https://music.example.com');
    test('lists, saves and reports store songs', () async {
      http.Response json(Object body, int status) =>
          http.Response.bytes(utf8.encode(jsonEncode(body)), status,
              headers: {'content-type': 'application/json; charset=utf-8'});
      final sent = <http.Request>[];
      final client = ApiClient(base, httpClient: MockClient((request) async {
        sent.add(request);
        final path = request.url.path;
        if (path.endsWith('/report')) return http.Response('', 204);
        if (path.endsWith('/save')) {
          return json({
            'id': 'mine',
            'title': 'باران',
            'contentType': 'audio/mpeg',
            'sizeBytes': 9,
          }, 201);
        }
        if (path.endsWith('/stream')) {
          return json({
            'url': 'https://music.example.com/a?sig',
            'expiresAt': '2030-01-01T00:00:00Z',
          }, 200);
        }
        if (path == '/api/v1/store/artists') {
          return json({
            'artists': [
              {'name': 'AC/DC', 'trackCount': 2}
            ],
            'hasMore': false,
          }, 200);
        }
        return json({
          'tracks': [
            {
              'id': 'e1',
              'title': 'باران',
              'artist': 'AC/DC',
              'contentType': 'audio/flac',
              'sizeBytes': 31876000,
              'replayGain': {'trackGainDb': -6.5},
            }
          ],
          'hasMore': true,
        }, 200);
      }));
      final page =
          await client.storeTracks(null, query: ' باران ', artist: 'AC/DC');
      expect(page.hasMore, isTrue);
      final found = page.items.single;
      expect(found.fromStore, isTrue);
      expect(found.replayGain?.trackGainDb, -6.5);
      expect(sent.last.headers.containsKey('Authorization'), isFalse);
      expect(sent.last.url.queryParameters, {'q': 'باران', 'artist': 'AC/DC'});

      await client.storeTracks('tok', offset: 50);
      expect(sent.last.url.query, 'offset=50');
      expect(sent.last.headers['Authorization'], 'Bearer tok');

      final artists = await client.storeArtists(null);
      expect(artists.items.single.name, 'AC/DC');
      expect(sent.last.url.query, isEmpty);

      final link = await client.storeStreamLink(null, 'e/1');
      expect(link.url.toString(), 'https://music.example.com/a?sig');
      expect(sent.last.url.path, '/api/v1/store/tracks/e%2F1/stream');

      final saved = await client.saveStoreTrack('tok', 'e1');
      expect(saved.fromStore, isFalse);
      expect(sent.last.method, 'POST');

      await client.reportStoreTrack('tok', 'e1', StoreReportReason.copyright,
          details: '  mine  ');
      expect(jsonDecode(sent.last.body),
          {'reason': 'copyright', 'details': 'mine'});
      await client.reportStoreTrack('tok', 'e1', StoreReportReason.other,
          details: ' ');
      expect(jsonDecode(sent.last.body), {'reason': 'other'});
    });
  });

  group('StoreScreen', () {
    final listScrollable = find
        .descendant(
            of: find.byType(ListView), matching: find.byType(Scrollable))
        .first;
    Finder row(String title) =>
        find.descendant(of: find.byType(ListTile), matching: find.text(title));
    Finder button(String label) => find
        .ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton))
        .first;
    late FakeStoreApi api;
    late StoreController store;
    late PlayerController player;
    late FakeTracksApi tracks;
    String? token;

    setUp(() {
      token = null;
      tracks = FakeTracksApi();
      player = PlayerController(
          api: tracks, engine: FakeAudioEngine(), token: () => token);
    });

    Future<void> pump(WidgetTester tester,
        {Size size = const Size(360, 640),
        List<Track>? songs,
        int pageSize = 50,
        String? openSongId,
        VoidCallback? onSignIn}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(bottom: 34);
      addTearDown(tester.view.reset);
      api = FakeStoreApi(songs: songs, pageSize: pageSize);
      store = StoreController(api: api, token: () => token);
      addTearDown(store.dispose);
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('fa'),
        supportedLocales: const [Locale('fa')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: RhythmoTheme.dark(),
        home: StoreScreen(
          controller: store,
          player: player,
          onSignIn: onSignIn,
          openSongId: openSongId,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('fits a narrow phone and keeps the last row clear',
        (tester) async {
      final long = 'یک آهنگ با نامی بسیار طولانی که نباید از ردیف بیرون بزند';
      await pump(tester, songs: [
        for (var i = 0; i < 20; i++)
          song(i, title: '$long $i', artist: 'خواننده‌ای با نام بسیار بلند $i'),
      ]);
      expect(tester.takeException(), isNull);
      expect(find.text('استور'), findsOneWidget);
      for (final tab in ['آهنگ‌ها', 'خواننده‌ها', 'آلبوم‌ها']) {
        expect(tester.getSize(find.text(tab)).height, lessThan(48));
        expect(
            tester
                .getSize(find.ancestor(
                    of: find.text(tab), matching: find.byType(Tab)))
                .height,
            greaterThanOrEqualTo(RhythmoSpace.target));
      }
      final menu = tester.getSize(find.byTooltip('گزینه‌های آهنگ').first);
      expect(menu.width, greaterThanOrEqualTo(RhythmoSpace.target));
      expect(menu.height, greaterThanOrEqualTo(RhythmoSpace.target));
      // The artist is the row's only secondary detail; the size is not.
      expect(find.text('خواننده‌ای با نام بسیار بلند 0'), findsOneWidget);
      expect(find.textContaining(formatSize(3 * 1024 * 1024)), findsNothing);

      await player.play(song(0, title: '$long 0'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.textContaining('$long 19'), 300,
          scrollable: listScrollable);
      await tester.pumpAndSettle();
      final lastRow = tester.getRect(find
          .ancestor(of: find.text('$long 19'), matching: find.byType(ListTile))
          .first);
      final miniPlayer = tester.getRect(find.byType(MiniPlayer));
      expect(lastRow.bottom, lessThanOrEqualTo(miniPlayer.top));
      expect(tester.takeException(), isNull);
    });

    testWidgets('centres its content on a wide screen', (tester) async {
      await pump(tester, size: const Size(1440, 900));
      final row = tester.getRect(find.ancestor(
          of: find.text('Song 0'), matching: find.byType(ListTile)));
      // A song's actions stay near its title: the list is a narrow column.
      expect(row.width, lessThanOrEqualTo(storeContentWidth));
      expect((row.left - (1440 - row.right)).abs(), lessThan(2));
      // The search lines up with the list.
      final search = tester.getRect(find.byType(TextField));
      expect(search.width, lessThanOrEqualTo(storeContentWidth));
      expect((search.left - (1440 - search.right)).abs(), lessThan(2));
      // The tabs sit together at the start (the right, in RTL), not spread
      // across the column.
      final songsTab = tester.getRect(find.text('آهنگ‌ها'));
      final albumsTab = tester.getRect(find.text('آلبوم‌ها'));
      expect(songsTab.right, greaterThan(albumsTab.right));
      expect(
          songsTab.right - albumsTab.left, lessThan(storeContentWidth * 0.75));
    });

    for (final size in [const Size(360, 640), const Size(1440, 900)]) {
      testWidgets('shows artists and albums as cards at ${size.width}',
          (tester) async {
        await pump(tester, size: size);
        await tester.tap(find.text('خواننده‌ها'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final card = tester.getRect(find
            .ancestor(of: find.text('Artist 0'), matching: find.byType(InkWell))
            .first);
        // At least two cards fit side by side, each a 48 px target or more.
        expect(card.width, lessThanOrEqualTo(storeContentWidth / 2));
        expect(card.width, greaterThanOrEqualTo(RhythmoSpace.target));
        expect(card.height, greaterThan(card.width));
        expect(find.bySemanticsLabel('Artist 0، ۲ آهنگ'), findsOneWidget);

        await tester.tap(find.text('آلبوم‌ها'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Seasons'), findsOneWidget);
      });
    }

    testWidgets('plays a song without an account and loads more on scroll',
        (tester) async {
      await pump(tester,
          songs: [for (var i = 0; i < 30; i++) song(i)], pageSize: 20);
      await tester.tap(find.text('Song 1'));
      await tester.pumpAndSettle();
      expect(player.track?.id, 'entry-1');
      expect(tracks.calls, contains('store:entry-1'));

      await tester.scrollUntilVisible(find.text('Song 29'), 400,
          scrollable: listScrollable);
      await tester.pumpAndSettle();
      expect(api.calls.where((c) => c.startsWith('tracks:')),
          ['tracks:null::null:null:0', 'tracks:null::null:null:20']);
    });

    testWidgets('searches as you type and says when nothing matched',
        (tester) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'Song 3');
      await tester.pump(StoreController.searchDelay);
      await tester.pumpAndSettle();
      expect(row('Song 3'), findsOneWidget);
      expect(row('Song 2'), findsNothing);
      await tester.enterText(find.byType(TextField), 'nothing like it');
      await tester.pump(StoreController.searchDelay);
      await tester.pumpAndSettle();
      expect(find.text('آهنگی پیدا نشد'), findsOneWidget);
      await tester.tap(find.byTooltip('پاک کردن جستجو'));
      await tester.pumpAndSettle();
      expect(find.text('Song 2'), findsOneWidget);
    });

    testWidgets('browses artists and albums into their songs', (tester) async {
      await pump(tester);
      await tester.tap(find.text('خواننده‌ها'));
      await tester.pumpAndSettle();
      expect(find.text('Artist 0'), findsOneWidget);
      await tester.tap(find.text('Artist 0'));
      await tester.pumpAndSettle();
      expect(api.calls.last, 'tracks:null::Artist 0:null:0');
      expect(find.text('Song 0'), findsOneWidget);
      expect(find.text('Song 1'), findsNothing);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('آلبوم‌ها'));
      await tester.pumpAndSettle();
      expect(find.text('Artist 1 · ۱ آهنگ'), findsOneWidget);
    });

    testWidgets('a guest is asked to sign in to add or report', (tester) async {
      var signIns = 0;
      await pump(tester, onSignIn: () => signIns++);
      await tester.tap(find.byTooltip('گزینه‌های آهنگ').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('افزودن به کتابخانه‌ی من'));
      await tester.pumpAndSettle();
      expect(
          find.text('برای افزودن به کتابخانه وارد حسابت شو.'), findsOneWidget);
      await tester.tap(find.text('ورود'));
      expect(signIns, 1);
      await tester.tap(find.byTooltip('گزینه‌های آهنگ').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('گزارش تخلف'));
      await tester.pumpAndSettle();
      expect(find.text('برای گزارش تخلف وارد حسابت شو.'), findsOneWidget);
      expect(
          api.calls.where(
              (c) => !c.startsWith('tracks:') && !c.startsWith('ranked:')),
          isEmpty);
    });

    testWidgets('a listener adds a song and reports one', (tester) async {
      token = 'tok';
      await pump(tester);
      await tester.tap(find.byTooltip('گزینه‌های آهنگ').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('افزودن به کتابخانه‌ی من'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('save:tok:entry-0'));
      expect(find.textContaining('به کتابخانه‌ات اضافه شد'), findsOneWidget);

      await tester.tap(find.byTooltip('گزینه‌های آهنگ').at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('گزارش تخلف'));
      await tester.pumpAndSettle();
      final sheet = find
          .descendant(
              of: find.byType(BottomSheet), matching: find.byType(Scrollable))
          .first;
      await tester.scrollUntilVisible(find.text('فرستادن گزارش'), 200,
          scrollable: sheet);
      final send = button('فرستادن گزارش');
      expect(tester.widget<ButtonStyleButton>(send).onPressed, isNull,
          reason: 'a reason must be picked first');
      await tester.scrollUntilVisible(find.text('نقض حق نشر'), -200,
          scrollable: sheet);
      await tester.tap(find.text('نقض حق نشر'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'توضیح (اختیاری)'), 'اثر من است');
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(api.calls, contains('report:tok:entry-1:copyright:اثر من است'));
      expect(find.textContaining('گزارشت فرستاده شد'), findsOneWidget);
    });

    testWidgets('a report sheet fits a narrow phone', (tester) async {
      token = 'tok';
      await pump(tester, size: const Size(360, 560));
      await tester.tap(find.byTooltip('گزینه‌های آهنگ').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('گزارش تخلف'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final reason in StoreReportReason.values) {
        final tile = find.ancestor(
            of: find.text(reason.label), matching: find.byType(ListTile));
        expect(tester.getSize(tile).height,
            greaterThanOrEqualTo(RhythmoSpace.target));
      }
    });

    testWidgets('opens the song a store page linked to', (tester) async {
      await pump(tester, openSongId: 'entry-2');
      expect(find.text('Song 2'), findsWidgets);
      await tester.tap(button('پخش'));
      await tester.pumpAndSettle();
      expect(player.track?.id, 'entry-2');
    });

    testWidgets('says when the linked song left the store', (tester) async {
      await pump(tester, openSongId: 'gone');
      expect(find.text('این آهنگ دیگر در استور نیست.'), findsOneWidget);
    });

    testWidgets('an unreachable store offers a retry', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      api = FakeStoreApi()..error = Exception('offline');
      store = StoreController(api: api, token: () => null);
      addTearDown(store.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: RhythmoTheme.dark(),
        home: StoreScreen(controller: store, player: player),
      ));
      await tester.pumpAndSettle();
      expect(find.text('استور بارگذاری نشد'), findsOneWidget);
      api.error = null;
      await tester.tap(find.text('تلاش دوباره'));
      await tester.pumpAndSettle();
      expect(find.text('Song 0'), findsOneWidget);
    });
  });

  group('the store is one tap away', () {
    Widget app(Widget home) => MaterialApp(
          locale: const Locale('fa'),
          supportedLocales: const [Locale('fa')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: RhythmoTheme.dark(),
          home: home,
        );

    testWidgets('from the guest home', (tester) async {
      final player = PlayerController(
          api: FakeTracksApi(), engine: FakeAudioEngine(), token: () => null);
      final store = StoreController(api: FakeStoreApi(), token: () => null);
      addTearDown(store.dispose);
      await tester.pumpWidget(app(PopularPlaylistsScreen(
        controller:
            PlaylistsController(api: FakePlaylistsApi(), token: () => null),
        player: player,
        onSignIn: () {},
        store: store,
      )));
      await tester.pumpAndSettle();
      final entry = find.byTooltip('استور');
      expect(tester.getSize(entry).height, greaterThanOrEqualTo(48));
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byType(StoreScreen), findsOneWidget);
      expect(find.text('Song 0'), findsOneWidget);
    });
  });
}

class _NoLyrics implements LyricsApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _RecordingHistory implements HistoryApi {
  final recorded = <String>[];

  @override
  Future<void> recordPlay(String token, String trackId,
      {String? playlistId}) async {
    recorded.add(trackId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
