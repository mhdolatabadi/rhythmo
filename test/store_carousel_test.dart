import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/likes/presentation/liked_songs_screen.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/presentation/playlists_screen.dart';
import 'package:rhythmo/features/store/application/store_controller.dart';
import 'package:rhythmo/features/store/data/store_catalog.dart';
import 'package:rhythmo/features/store/presentation/store_carousel.dart';
import 'package:rhythmo/features/store/presentation/store_screen.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'playlist_sharing_test.dart' show FakePlaylistsApi;
import 'store_test.dart' show FakeStoreApi;
import 'upload_controller_test.dart' show FakeTracksApi;

Widget _app(Widget home) => MaterialApp(
      locale: const Locale('fa'),
      supportedLocales: const [Locale('fa')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: RhythmoTheme.dark(),
      home: home,
    );

void main() {
  late FakeStoreApi api;
  late StoreController store;
  late PlayerController player;
  late FakeTracksApi tracks;

  void setUpStore(WidgetTester tester, {Size size = const Size(360, 640)}) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.reset);
    api = FakeStoreApi();
    store = StoreController(api: api, token: () => null);
    addTearDown(store.dispose);
    tracks = FakeTracksApi();
    player = PlayerController(
        api: tracks, engine: FakeAudioEngine(), token: () => null);
  }

  final long = 'یک آهنگ محبوب با نامی بسیار طولانی که در کارت جا نمی‌شود';
  List<Track> ranked() => [
        for (var i = 0; i < 8; i++)
          Track(
            id: 'hit-$i',
            title: '$long $i',
            artist: 'خواننده‌ای با نام بلند $i',
            contentType: 'audio/mpeg',
            sizeBytes: 1,
            fromStore: true,
            likeCount: 100 - i,
          ),
      ];

  testWidgets('a new store opens without empty shelves', (tester) async {
    setUpStore(tester);
    await tester
        .pumpWidget(_app(StoreScreen(controller: store, player: player)));
    await tester.pumpAndSettle();
    expect(api.calls, containsAll(['ranked:popular:0', 'ranked:trending:0']));
    for (final ranking in StoreRanking.values) {
      expect(find.text(ranking.label), findsNothing);
    }
    expect(find.text('Song 0'), findsOneWidget);
  });

  testWidgets('popular and trending carousels fit a narrow phone and play',
      (tester) async {
    setUpStore(tester);
    api.ranked = ranked();
    await tester
        .pumpWidget(_app(StoreScreen(controller: store, player: player)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'long titles fit');
    for (final ranking in StoreRanking.values) {
      expect(find.text(ranking.label), findsOneWidget);
    }
    expect(find.text('همه‌ی آهنگ‌ها'), findsOneWidget);
    // Trending comes first; the first card is the trending order's first.
    final trending = find.byType(StoreCarousel).first;
    final firstCard =
        find.descendant(of: trending, matching: find.byType(InkWell)).first;
    final card = tester.getRect(firstCard);
    expect(card.width, storeCarouselCardWidth);
    expect(card.height, greaterThanOrEqualTo(RhythmoSpace.target));
    expect(card.right, lessThanOrEqualTo(360 - RhythmoSpace.lg + 0.5),
        reason: 'the first card sits in the RTL gutter');
    expect(find.bySemanticsLabel(RegExp('$long 7، .*، ۹۳ پسند')), findsWidgets);

    await tester.tap(firstCard);
    await tester.pumpAndSettle();
    expect(player.track?.id, 'hit-7');
    expect(tracks.calls, contains('store:hit-7'));

    // Searching hides the shelves.
    await tester.enterText(find.byType(TextField), 'Song');
    await tester.pump(StoreController.searchDelay);
    await tester.pumpAndSettle();
    expect(find.byType(StoreCarousel), findsNothing);
  });

  testWidgets('the shelves scroll sideways on a wide screen too',
      (tester) async {
    setUpStore(tester, size: const Size(1280, 800));
    api.ranked = ranked();
    await tester
        .pumpWidget(_app(StoreScreen(controller: store, player: player)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final shelf = tester.getRect(find.byType(StoreCarousel).first);
    expect(shelf.width, lessThanOrEqualTo(RhythmoSpace.pageWidth));
  });

  testWidgets('the playlists tab has only personal content and icon actions',
      (tester) async {
    setUpStore(tester);
    api.ranked = ranked();
    await tester.pumpWidget(_app(Scaffold(
      body: PlaylistsView(
        controller:
            PlaylistsController(api: FakePlaylistsApi(), token: () => 'tok'),
        libraryTracks: const [],
        player: player,
      ),
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(StoreRanking.trending.label), findsNothing);
    expect(find.text(StoreRanking.popular.label), findsNothing);
    expect(find.byType(StoreCarousel), findsNothing);
    expect(find.byType(LikedSongsEntry), findsNothing);
    expect(api.calls, isEmpty);
    expect(find.text('فهرست پخش جدید'), findsNothing);
    final create = find.byTooltip('فهرست پخش جدید');
    expect(create, findsOneWidget);
    final rect = tester.getRect(create);
    expect(rect.width, greaterThanOrEqualTo(48));
    expect(rect.height, greaterThanOrEqualTo(48));
    expect(rect.left, greaterThanOrEqualTo(16));
    expect(rect.right, lessThanOrEqualTo(344));
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('فهرست پخش جدید'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('the client asks the server for each ranking', () async {
    final sent = <Uri>[];
    final client = ApiClient(Uri.parse('https://api.example'),
        httpClient: MockClient((request) async {
      sent.add(request.url);
      return http.Response(
          jsonEncode({
            'tracks': [
              {
                'id': 'e1',
                'title': 'hit',
                'contentType': 'audio/mpeg',
                'sizeBytes': 1,
                'likeCount': 5,
              }
            ],
            'hasMore': false,
          }),
          200);
    }));
    final popular = await client.storeRanked(null, StoreRanking.popular);
    expect(sent.last.path, '/api/v1/store/popular');
    expect(sent.last.query, 'limit=20');
    expect(popular.items.single.fromStore, isTrue);
    expect(popular.items.single.likeCount, 5);
    await client.storeRanked('tok', StoreRanking.trending, offset: 20);
    expect(sent.last.path, '/api/v1/store/trending');
    expect(sent.last.queryParameters, {'limit': '20', 'offset': '20'});
  });
}
