import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/library/presentation/rhythmo_dock.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/features/auth/data/token_store.dart';
import 'package:rhythmo/features/history/application/recently_played_controller.dart';
import 'package:rhythmo/features/library/data/local_audio_library.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/library/presentation/library_screen.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/mini_player.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';
import 'package:rhythmo/main.dart';

import 'cache_controller_test.dart' show FakeAudioCache;
import 'library_sync_controller_test.dart'
    show FakeTrackDownloader, FakeUploadSource;
import 'local_audio_controller_test.dart' show FakeLocalAudioLibrary;
import 'player_controller_test.dart' show FakeAudioEngine;
import 'playlist_sharing_test.dart' show FakePlaylistsApi;
import 'recently_played_test.dart' show FakeHistoryApi;
import 'upload_controller_test.dart' show FakeTracksApi, FakeUploader;
import 'widget_test.dart' show FakeAuthApi, FakePicker;

const _longPersian =
    'یک عنوان بسیار بسیار طولانی فارسی برای آزمودن کوتاه‌شدن در صفحهٔ باریک';
const _longLatin =
    'An extremely long Latin title that must truncate gracefully on phones';

Track _cloud(String id, String title, {String? artist}) => Track(
      id: id,
      title: title,
      artist: artist,
      contentType: 'audio/mpeg',
      sizeBytes: 1000,
      fileName: '$id.mp3',
    );

/// Someone else's track, played through collaborative playlist p1.
const _memberTrack = Track(
  id: 'm1',
  title: 'آهنگ هم‌گروه',
  contentType: 'audio/mpeg',
  sizeBytes: 10,
  addedBy: 'b***@example.com',
  viaPlaylist: 'p1',
);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpApp(
  WidgetTester tester, {
  required FakeTracksApi tracks,
  required FakeHistoryApi history,
  FakePlaylistsApi? playlists,
  FakeAudioEngine? engine,
}) async {
  await tester.pumpWidget(RhythmoApp(
    healthCheck: () async {},
    authApi: FakeAuthApi(),
    tokenStore: MemoryTokenStore('valid-token'),
    tracksApi: tracks,
    playlistsApi: playlists,
    historyApi: history,
    audioEngine: engine ?? FakeAudioEngine(),
    audioCache: FakeAudioCache(),
    uploader: FakeUploader(),
    picker: FakePicker(null),
    localAudioLibrary: FakeLocalAudioLibrary(
        const LocalAudioResult(LocalAudioStatus.loaded, [])),
    localAudioUpload: FakeUploadSource(),
    trackDownloader: FakeTrackDownloader(),
  ));
  await tester.pumpAndSettle();
}

final _searchField = find.descendant(
    of: find.byType(LibrarySearchScreen), matching: find.byType(TextField));

Finder _row(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(ListTile));

void _expectTouchTarget(WidgetTester tester, Finder finder) {
  final size = tester.getSize(finder);
  expect(size.width, greaterThanOrEqualTo(48), reason: '$finder width');
  expect(size.height, greaterThanOrEqualTo(48), reason: '$finder height');
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  group('recently played', () {
    testWidgets(
        'on a 360 px phone the compact library truncates long titles, '
        'keep 48 px targets and stay clear of the mini player', (tester) async {
      _phone(tester);
      final library = [
        _cloud('a', _longPersian, artist: 'خواننده‌ای با نامی بسیار طولانی'),
        _cloud('b', _longLatin, artist: 'Someone With A Long Name'),
        for (var i = 0; i < 10; i++) _cloud('c$i', 'آهنگ $i'),
      ];
      final history = FakeHistoryApi()
        ..history = [
          _memberTrack,
          library[0],
          library[1],
          for (var i = 0; i < 10; i++) library[2 + i],
        ];
      await _pumpApp(tester, tracks: FakeTracksApi(library), history: history);

      expect(find.text('اخیراً پخش‌شده'), findsNothing);
      expect(tester.takeException(), isNull);
      // Search lives behind the dock's bubble, not above the list.
      expect(find.byType(SearchBar), findsNothing);
      _expectTouchTarget(tester, find.byTooltip('جست‌وجو'));
      final dock = tester.getRect(find.byType(RhythmoDock));
      final search = tester.getRect(find.byTooltip('جست‌وجو'));
      expect(dock.contains(search.center), isTrue);
      expect(tester.getSize(_row(_longPersian)).height, lessThanOrEqualTo(72));
      _expectTouchTarget(tester, _row(_longPersian));

      // Library tracks keep their actions.
      expect(
          find.descendant(
              of: _row(_longPersian), matching: find.byTooltip('اقدامات آهنگ')),
          findsOneWidget);
      // Long titles stay on one line inside the row.
      final title = tester.getRect(find.text(_longPersian));
      expect(title.left, greaterThanOrEqualTo(0));
      expect(title.right, lessThanOrEqualTo(360));

      // Starting a track shows the compact mini player.
      await tester.tap(find.text(_longPersian));
      await tester.pumpAndSettle();
      expect(find.byTooltip('توقف'), findsOneWidget);
      final progress = find.descendant(
          of: find.byType(MiniPlayer),
          matching: find.byType(LinearProgressIndicator));
      expect(progress, findsOneWidget);
      expect(Directionality.of(tester.element(progress)), TextDirection.ltr);

      for (var i = 0; i < 8; i++) {
        await tester.drag(
            find.byType(CustomScrollView).last, const Offset(0, -400));
        await tester.pumpAndSettle();
      }
      final lastRow = tester.getRect(_row('آهنگ 9'));
      final miniPlayerTop = tester.getTopLeft(find.byTooltip('توقف')).dy - 16;
      expect(lastRow.bottom, lessThan(miniPlayerTop));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a real listen records history without adding a home shelf',
        (tester) async {
      _phone(tester);
      final history = FakeHistoryApi();
      final engine = FakeAudioEngine();
      final tracks = FakeTracksApi([_cloud('a', 'Alpha'), _cloud('b', 'Beta')]);
      await _pumpApp(tester, tracks: tracks, history: history, engine: engine);
      // Nothing played yet: no shelf at all.
      expect(find.text('اخیراً پخش‌شده'), findsNothing);

      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      for (var ms = 250; ms <= 10000; ms += 250) {
        engine.positionCtl.add(Duration(milliseconds: ms));
      }
      await tester.pumpAndSettle();
      // Ten seconds is not a listen yet.
      expect(history.recorded, isEmpty);
      for (var ms = 10250; ms <= 31000; ms += 250) {
        engine.positionCtl.add(Duration(milliseconds: ms));
      }
      await tester.pumpAndSettle();
      expect(history.recorded, [('b', null)]);
      expect(find.text('اخیراً پخش‌شده'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    group('screen states at 360 px', () {
      late FakeHistoryApi api;
      late RecentlyPlayedController recent;
      late PlayerController player;

      setUp(() {
        api = _GatedHistoryApi();
        recent = RecentlyPlayedController(api: api, token: () => 'tok');
        player = PlayerController(
            api: FakeTracksApi(),
            engine: FakeAudioEngine(),
            token: () => 'tok');
      });

      Future<void> pumpScreen(WidgetTester tester) async {
        _phone(tester);
        await tester.pumpWidget(MaterialApp(
          theme: RhythmoTheme.dark(),
          locale: const Locale('fa'),
          supportedLocales: const [Locale('fa')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: RecentlyPlayedScreen(
            recent: recent,
            changes: recent,
            tracks: () => recent.tracks,
            player: player,
            list: (tracks) => ListView(children: [
              for (final t in tracks) ListTile(title: Text(t.title)),
            ]),
          ),
        ));
      }

      testWidgets('loading', (tester) async {
        final gate = (api as _GatedHistoryApi).gate = Completer<void>();
        unawaited(recent.load());
        await pumpScreen(tester);
        await tester.pump();
        expect(find.bySemanticsLabel('در حال دریافت تاریخچه'), findsOneWidget);
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.text('هنوز آهنگی پخش نشده'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('error, then retry', (tester) async {
        api.error = Exception('offline');
        await recent.load();
        await pumpScreen(tester);
        await tester.pumpAndSettle();
        expect(find.text('تاریخچه دریافت نشد'), findsOneWidget);
        _expectTouchTarget(
            tester, find.widgetWithText(FilledButton, 'تلاش دوباره'));
        expect(tester.takeException(), isNull);

        api
          ..error = null
          ..history = [_cloud('a', _longLatin)];
        await tester.tap(find.widgetWithText(FilledButton, 'تلاش دوباره'));
        await tester.pumpAndSettle();
        expect(find.text(_longLatin), findsOneWidget);
      });

      testWidgets('empty', (tester) async {
        await recent.load();
        await pumpScreen(tester);
        await tester.pumpAndSettle();
        expect(find.text('هنوز آهنگی پخش نشده'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  });

  group('unified search', () {
    late FakePlaylistsApi playlists;
    late FakeHistoryApi history;

    setUp(() {
      history = FakeHistoryApi();
      playlists = _GatedPlaylistsApi()
        ..userPlaylists = [
          Playlist(
            id: 'p1',
            name: 'كلاسيك $_longPersian',
            trackCount: 3,
            tracks: const [],
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        ]
        ..public = [
          const PublicPlaylist(
            shareToken: 'pub1',
            name: 'کلاسیک‌های محبوب',
            owner: 'z***@example.com',
            isOwner: false,
            trackCount: 9,
            likes: PlaylistLikes(liked: false, likeCount: 12),
          ),
          const PublicPlaylist(
            shareToken: 'mine',
            name: 'کلاسیک خودم',
            owner: 'me',
            isOwner: true,
            trackCount: 1,
            likes: PlaylistLikes(liked: false, likeCount: 0),
          ),
        ];
    });

    Future<void> openSearch(WidgetTester tester) async {
      await _pumpApp(tester,
          tracks: FakeTracksApi([
            _cloud('a', 'موسيقي كلاسيك $_longPersian', artist: 'Bach'),
            _cloud('b', 'Clair de lune', artist: 'Debussy'),
            for (var i = 0; i < 12; i++)
              _cloud('k$i', 'کلاسیک شمارهٔ $i', artist: 'Various'),
          ]),
          history: history,
          playlists: playlists);
      _expectTouchTarget(tester, find.byTooltip('جست‌وجو'));
      await tester.tap(find.byTooltip('جست‌وجو'));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'groups tracks, own and popular playlists, tolerant of Arabic forms '
        'and ZWNJ, on a 360 px phone', (tester) async {
      _phone(tester);
      await openSearch(tester);
      expect(find.text('در همهٔ موسیقی‌ات بگرد'), findsOneWidget);

      // «کلاسیک» with Persian letters finds «كلاسيك» spelled the Arabic way,
      // and «کلاسیکهای» without ZWNJ the popular «کلاسیک‌های».
      await tester.enterText(_searchField, 'کلاسیک طولانی');
      await tester.pumpAndSettle();
      expect(find.text('آهنگ‌ها'), findsOneWidget);
      expect(find.text('فهرست‌های پخش من'), findsOneWidget);
      expect(find.text('موسيقي كلاسيك $_longPersian'), findsOneWidget);
      expect(find.text('كلاسيك $_longPersian'), findsOneWidget);
      // Long titles end in an ellipsis inside the 360 px screen.
      for (final title in [
        'موسيقي كلاسيك $_longPersian',
        'كلاسيك $_longPersian',
      ]) {
        final rect = tester.getRect(find.text(title));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(360));
      }
      expect(tester.takeException(), isNull);

      await tester.enterText(_searchField, 'کلاسیکهای');
      await tester.pumpAndSettle();
      expect(find.text('فهرست‌های پخش محبوب'), findsOneWidget);
      expect(find.text('کلاسیک‌های محبوب'), findsOneWidget);
      // The user's own public playlist isn't listed twice.
      expect(find.text('کلاسیک خودم'), findsNothing);

      // Artist and filename count too, ignoring case.
      await tester.enterText(_searchField, 'DEBUSSY');
      await tester.pumpAndSettle();
      expect(find.text('Clair de lune'), findsOneWidget);
      await tester.enterText(_searchField, 'k11.mp3');
      await tester.pumpAndSettle();
      expect(find.text('کلاسیک شمارهٔ 11'), findsOneWidget);

      // Playing a result shows the mini player; the last result stays
      // above it.
      await tester.enterText(_searchField, 'کلاسیک');
      await tester.pumpAndSettle();
      await tester.tap(find.text('کلاسیک شمارهٔ 0'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 8; i++) {
        await tester.drag(
            find.byType(CustomScrollView).last, const Offset(0, -400));
        await tester.pumpAndSettle();
      }
      final last = tester.getRect(_row('کلاسیک‌های محبوب'));
      final miniPlayerTop = tester.getTopLeft(find.byTooltip('توقف')).dy - 16;
      expect(last.bottom, lessThan(miniPlayerTop));
      expect(last.height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);

      // Nothing found offers to clear the search.
      await tester.enterText(_searchField, 'zzzz');
      await tester.pumpAndSettle();
      expect(find.text('نتیجه‌ای پیدا نشد'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'پاک کردن جست‌وجو'));
      await tester.pumpAndSettle();
      // The search that led to a played track is remembered; «zzzz» found
      // nothing and is not.
      expect(find.text('جست‌وجوهای اخیر'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'کلاسیک'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'zzzz'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('popular playlists loading, then failing, with a retry',
        (tester) async {
      _phone(tester);
      final gated = playlists as _GatedPlaylistsApi;
      gated.gate = Completer<void>();
      await _pumpApp(tester,
          tracks: FakeTracksApi([_cloud('a', 'Alpha')]),
          history: history,
          playlists: playlists);
      await tester.tap(find.byTooltip('جست‌وجو'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(_searchField, 'alpha');
      await tester.pump();
      final alpha = find.descendant(
          of: find.byType(LibrarySearchScreen), matching: find.text('Alpha'));
      expect(alpha, findsOneWidget);
      expect(find.bySemanticsLabel('در حال دریافت'), findsOneWidget);

      playlists.listFails = true;
      gated.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('فهرست‌های محبوب دریافت نشد.'), findsOneWidget);
      _expectTouchTarget(
          tester, find.widgetWithText(TextButton, 'تلاش دوباره'));
      expect(tester.takeException(), isNull);

      playlists
        ..listFails = false
        ..public = [];
      await tester.tap(find.widgetWithText(TextButton, 'تلاش دوباره'));
      await tester.pumpAndSettle();
      expect(find.text('فهرست‌های محبوب دریافت نشد.'), findsNothing);
      expect(alpha, findsOneWidget);
    });
  });
}

class _GatedHistoryApi extends FakeHistoryApi {
  Completer<void>? gate;

  @override
  Future<List<Track>> listHistory(String token, {int? limit}) async {
    await gate?.future;
    return super.listHistory(token, limit: limit);
  }
}

class _GatedPlaylistsApi extends FakePlaylistsApi {
  Completer<void>? gate;

  @override
  Future<List<PublicPlaylist>> listPublicPlaylists(String? t) async {
    await gate?.future;
    return super.listPublicPlaylists(t);
  }
}
