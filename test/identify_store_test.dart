import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/identify/application/identify_controller.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/store/application/store_controller.dart';
import 'package:rhythmo/features/store/presentation/store_screen.dart';

import 'identify_test.dart' show FakeIdentifyApi, FakeRecorder;
import 'player_controller_test.dart' show FakeAudioEngine;
import 'store_test.dart' show FakeStoreApi, song;
import 'upload_controller_test.dart' show FakeTracksApi;

final _storeMatch = SongMatch(
  track: song(7, title: 'باران', artist: 'محسن'),
  confidence: 0.9,
  source: SongMatchSource.store,
);

void main() {
  test('without a token the client asks the store and reads its match',
      () async {
    final sent = <http.Request>[];
    final client = ApiClient(Uri.parse('https://api.example'),
        httpClient: MockClient((request) async {
      sent.add(request);
      if (request.url.path.endsWith('/save')) {
        return http.Response(
            jsonEncode({
              'id': 'copy',
              'title': 'x',
              'contentType': 'audio/mpeg',
              'sizeBytes': 1
            }),
            201);
      }
      return http.Response(
          jsonEncode({
            'status': 'found',
            'confidence': 0.9,
            'source': 'store',
            'storeTrack': {
              'id': 'entry-7',
              'title': 'x',
              'contentType': 'audio/flac',
              'sizeBytes': 9,
            },
          }),
          200);
    }));
    final match = await client.identifySong(null, utf8.encode('RIFF'));
    expect(sent.single.headers.containsKey('Authorization'), isFalse);
    expect(match!.source, SongMatchSource.store);
    expect(match.track.fromStore, isTrue);
    expect(match.track.id, 'entry-7');
    expect(match.canSave, isTrue);
    await client.saveIdentifiedSong('tok', match);
    expect(sent.last.url.path, '/api/v1/store/tracks/entry-7/save');
    expect(sent.last.headers['Authorization'], 'Bearer tok');
  });

  test('a guest identifies against the store but cannot add', () async {
    final api = FakeIdentifyApi()..answer = _storeMatch;
    final recorder = FakeRecorder();
    final controller =
        IdentifyController(api: api, recorder: recorder, token: () => null);
    expect(controller.signedIn, isFalse);
    final done = controller.listen();
    await pumpEventQueue();
    recorder.finish();
    await done;
    expect(api.tokens.single, isNull);
    expect(controller.phase, IdentifyPhase.found);
    expect(await controller.save(), isNull);
    expect(api.saved, isEmpty);
  });

  testWidgets('a guest finds a store song from the store on a narrow phone',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.reset);
    final api = FakeIdentifyApi()..answer = _storeMatch;
    final recorder = FakeRecorder();
    final identify =
        IdentifyController(api: api, recorder: recorder, token: () => null);
    final tracks = FakeTracksApi();
    final player = PlayerController(
        api: tracks, engine: FakeAudioEngine(), token: () => null);
    final store = StoreController(api: FakeStoreApi(), token: () => null);
    addTearDown(store.dispose);
    var signIns = 0;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('fa'),
      supportedLocales: const [Locale('fa')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: RhythmoTheme.dark(),
      home: StoreScreen(
        controller: store,
        player: player,
        identify: identify,
        onSignIn: () => signIns++,
      ),
    ));
    await tester.pumpAndSettle();
    final entry = find.byTooltip('این آهنگ چیه؟');
    expect(tester.getSize(entry).height, greaterThanOrEqualTo(48));
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.textContaining('با آهنگ‌های گنجینه ریتمو مقایسه می‌کند'),
        findsOneWidget);
    await tester.tap(find.text('گوش بده'));
    await tester.pump();
    recorder.finish();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('باران'), findsOneWidget);
    expect(find.textContaining('در گنجینه ریتمو'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('افزودن به کتابخانه'), 100);
    await tester.tap(find.text('افزودن به کتابخانه'));
    await tester.pumpAndSettle();
    expect(find.text('برای افزودن به کتابخانه وارد حسابت شو.'), findsOneWidget);
    expect(api.saved, isEmpty);
    await tester.tap(find.text('ورود'));
    expect(signIns, 1);

    await tester.scrollUntilVisible(find.text('پخش'), -100);
    await tester.tap(find.text('پخش'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(player.track?.id, 'entry-7');
    expect(tracks.calls, contains('store:entry-7'));
  });

  testWidgets('a guest who finds nothing is told only the store is searched',
      (tester) async {
    final recorder = FakeRecorder();
    final identify = IdentifyController(
        api: FakeIdentifyApi(), recorder: recorder, token: () => null);
    final player = PlayerController(
        api: FakeTracksApi(), engine: FakeAudioEngine(), token: () => null);
    final store = StoreController(api: FakeStoreApi(), token: () => null);
    addTearDown(store.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: RhythmoTheme.dark(),
      home: StoreScreen(controller: store, player: player, identify: identify),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('این آهنگ چیه؟'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('گوش بده'));
    await tester.pump();
    recorder.finish();
    await tester.pumpAndSettle();
    expect(find.textContaining('فقط آهنگ‌های گنجینه ریتمو شناخته می‌شوند'),
        findsOneWidget);
  });
}
