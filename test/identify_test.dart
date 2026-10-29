import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/auth/data/token_store.dart';
import 'package:rhythmo/features/identify/application/identify_controller.dart';
import 'package:rhythmo/features/identify/data/snippet_recorder.dart';
import 'package:rhythmo/features/identify/presentation/identify_screen.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/favorite_tracks.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/main.dart';

import 'cache_controller_test.dart' show FakeAudioCache;
import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi, FakeUploader;
import 'widget_test.dart' show FakeAuthApi, FakePicker;

final _wav = Uint8List.fromList(utf8.encode('RIFF....WAVE'));

/// A microphone the test drives: [finish] ends the recording.
class FakeRecorder implements SnippetRecorder {
  bool supported = true;
  bool allowed = true;
  int permissionRequests = 0;
  Completer<Uint8List>? _recording;
  void Function(double)? _onLevel;

  void level(double value) => _onLevel?.call(value);
  void finish() => _recording?.complete(_wav);

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return allowed;
  }

  @override
  Future<Uint8List> record(Duration length,
      {void Function(double level)? onLevel}) {
    _onLevel = onLevel;
    return (_recording = Completer<Uint8List>()).future;
  }

  @override
  Future<void> cancel() async {
    final recording = _recording;
    if (recording != null && !recording.isCompleted) {
      recording.completeError(const RecordingCancelled());
    }
  }
}

class FakeIdentifyApi implements IdentifyApi {
  SongMatch? answer;
  Object? error;
  Completer<void>? gate;
  final snippets = <Uint8List>[];
  final saved = <SongMatch>[];
  final tokens = <String?>[];

  @override
  Future<SongMatch?> identifySong(String? token, Uint8List wav) async {
    tokens.add(token);
    snippets.add(wav);
    await gate?.future;
    if (error != null) throw error!;
    return answer;
  }

  @override
  Future<Track> saveIdentifiedSong(String token, SongMatch match) async {
    if (error != null) throw error!;
    saved.add(match);
    return match.track;
  }
}

const _publicSong = SongMatch(
  track: Track(
    id: 'song',
    title: 'یک آهنگ با عنوانی بسیار بلند که در یک خط جا نمی‌شود و ادامه دارد',
    artist: 'هنرمند',
    contentType: 'audio/mpeg',
    sizeBytes: 1,
    sharedVia: 'share-token',
    addedBy: 'b***@example.com',
  ),
  confidence: 0.82,
  source: SongMatchSource.public,
);

void main() {
  test('the client posts the snippet as audio and reads the match', () async {
    late http.Request sent;
    final client = ApiClient(Uri.parse('https://api.example'),
        httpClient: MockClient((request) async {
      sent = request;
      if (request.url.path == '/api/v1/identify/save') {
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
            'source': 'playlist',
            'playlistId': 'pl',
            'track': {
              'id': 't',
              'title': 'x',
              'contentType': 'audio/mpeg',
              'sizeBytes': 1,
              'addedBy': 'b***@x',
            },
          }),
          200);
    }));
    final match = await client.identifySong('tok', _wav);
    expect(sent.headers['Content-Type'], 'audio/wav');
    expect(sent.headers['Authorization'], 'Bearer tok');
    expect(sent.bodyBytes, _wav);
    expect(match!.track.viaPlaylist, 'pl');
    expect(match.source, SongMatchSource.playlist);
    expect(match.canSave, isTrue);

    await client.saveIdentifiedSong('tok', match);
    expect(jsonDecode(sent.body), {'trackId': 't', 'playlistId': 'pl'});
    await client.saveIdentifiedSong('tok', _publicSong);
    expect(jsonDecode(sent.body),
        {'trackId': 'song', 'shareToken': 'share-token'});

    final notFound = ApiClient(Uri.parse('https://api.example'),
        httpClient: MockClient((_) async =>
            http.Response(jsonEncode({'status': 'not_found'}), 200)));
    expect(await notFound.identifySong('tok', _wav), isNull);
    final tooShort = ApiClient(Uri.parse('https://api.example'),
        httpClient: MockClient((_) async =>
            http.Response(jsonEncode({'error': 'snippet_too_short'}), 422)));
    expect(
        () => tooShort.identifySong('tok', _wav),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'snippet_too_short')));
  });

  group('controller', () {
    late FakeRecorder recorder;
    late FakeIdentifyApi api;
    late IdentifyController controller;
    var reloads = 0;

    setUp(() {
      recorder = FakeRecorder();
      api = FakeIdentifyApi();
      reloads = 0;
      controller = IdentifyController(
        api: api,
        recorder: recorder,
        token: () => 'tok',
        onSaved: () async => reloads++,
      );
    });

    test('listens, then finds the song and adds it to the library', () async {
      api.answer = _publicSong;
      final done = controller.listen();
      await pumpEventQueue();
      expect(controller.phase, IdentifyPhase.listening);
      recorder.level(0.7);
      expect(controller.level, 0.7);
      recorder.finish();
      await done;
      expect(api.snippets.single, _wav);
      expect(controller.phase, IdentifyPhase.found);
      expect(await controller.save(), isNotNull);
      expect(controller.saved, isTrue);
      expect(reloads, 1);
    });

    test('no microphone, or no permission, is said plainly', () async {
      recorder.supported = false;
      await controller.listen();
      expect(controller.phase, IdentifyPhase.unsupported);
      expect(recorder.permissionRequests, 0);

      recorder
        ..supported = true
        ..allowed = false;
      await controller.listen();
      expect(controller.phase, IdentifyPhase.permissionDenied);
      expect(api.snippets, isEmpty);
    });

    test('nothing found, server refusals and cancelling', () async {
      var done = controller.listen();
      await pumpEventQueue();
      recorder.finish();
      await done;
      expect(controller.phase, IdentifyPhase.notFound);

      api.error = const ApiException('x', code: 'snippet_too_short');
      done = controller.listen();
      await pumpEventQueue();
      recorder.finish();
      await done;
      expect(controller.phase, IdentifyPhase.failed);
      expect(controller.error, contains('صدای کافی'));

      done = controller.listen();
      await pumpEventQueue();
      await controller.cancel();
      await done;
      expect(controller.phase, IdentifyPhase.ready);
      expect(api.snippets, hasLength(2),
          reason: 'a cancelled snippet is not sent');
    });

    test('a full library is reported when saving', () async {
      api.answer = _publicSong;
      final done = controller.listen();
      await pumpEventQueue();
      recorder.finish();
      await done;
      api.error = const ApiException('x', code: 'quota_exceeded');
      expect(await controller.save(), isNull);
      expect(controller.error, 'فضای کافی در حساب شما نیست.');
      expect(controller.saved, isFalse);
    });
  });

  group('screen at 360 px', () {
    late FakeRecorder recorder;
    late FakeIdentifyApi api;
    late IdentifyController controller;
    late PlayerController player;

    const bottomInset = 34.0;

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: bottomInset);
      tester.view.viewPadding =
          const FakeViewPadding(top: 24, bottom: bottomInset);
      addTearDown(tester.view.reset);
      recorder = FakeRecorder();
      api = FakeIdentifyApi();
      controller =
          IdentifyController(api: api, recorder: recorder, token: () => 'tok');
      player = PlayerController(
        api: FakeTracksApi(),
        engine: FakeAudioEngine(),
        token: () => 'tok',
        favorites: FavoriteTracks(store: MemoryFavoritesStore()),
      );
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('fa'),
        supportedLocales: const [Locale('fa')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: RhythmoTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => openIdentify(context, controller, player),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    void expectFits(WidgetTester tester, Finder finder, {String? reason}) {
      final rect = tester.getRect(finder);
      expect(rect.left, greaterThanOrEqualTo(0), reason: reason);
      expect(rect.right, lessThanOrEqualTo(360), reason: reason);
      expect(rect.bottom, lessThanOrEqualTo(640 - bottomInset), reason: reason);
      expect(rect.height, greaterThanOrEqualTo(48), reason: reason);
    }

    testWidgets('explains first, then listens and searches', (tester) async {
      await open(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('آهنگی که پخش می‌شود را بشناسید'), findsOneWidget);
      expect(find.textContaining('صدای ضبط‌شده بعد از جستجو پاک می‌شود'),
          findsOneWidget);
      expect(recorder.permissionRequests, 0,
          reason: 'the microphone is asked for only after the explanation');
      expectFits(tester, find.widgetWithText(FilledButton, 'گوش بده'));

      final gate = api.gate = Completer<void>();
      await tester.tap(find.widgetWithText(FilledButton, 'گوش بده'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('در حال گوش دادن…'), findsOneWidget);
      expectFits(tester, find.widgetWithText(OutlinedButton, 'لغو'));
      recorder.level(1);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);

      recorder.finish();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('در حال جستجو…'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('پیدا نشد'), findsOneWidget);
      expectFits(tester, find.widgetWithText(FilledButton, 'دوباره گوش بده'));
    });

    testWidgets('shows the song, plays it and adds it to the library',
        (tester) async {
      await open(tester);
      api.answer = _publicSong;
      await tester.tap(find.widgetWithText(FilledButton, 'گوش بده'));
      await tester.pump();
      recorder.finish();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'a long title fits');
      expect(find.text(_publicSong.track.title), findsOneWidget);
      expect(find.text('هنرمند'), findsOneWidget);
      expect(find.text('در یک فهرست پخش عمومی · اطمینان ۸۲٪'), findsOneWidget);
      expectFits(tester, find.widgetWithText(FilledButton, 'پخش'));

      // The last action stays clear of the gesture bar, scrolled to if need be.
      await tester.scrollUntilVisible(find.text('آهنگ دیگر'), 100);
      expectFits(tester, find.widgetWithText(TextButton, 'آهنگ دیگر'));

      await tester.scrollUntilVisible(find.text('افزودن به موسیقی من'), -100);
      await tester.tap(find.text('افزودن به موسیقی من'));
      await tester.pumpAndSettle();
      expect(api.saved.single.track.id, 'song');
      expect(find.text('در «موسیقی من»'), findsOneWidget);
      expect(find.text('به «موسیقی من» اضافه شد.'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('پخش'), -100);
      await tester.tap(find.widgetWithText(FilledButton, 'پخش'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(player.track?.id, 'song');
      expect(player.track?.sharedVia, 'share-token',
          reason: 'it plays through the public playlist it was found in');
    });

    testWidgets('a song of your own has nothing to add', (tester) async {
      await open(tester);
      api.answer = const SongMatch(
        track:
            Track(id: 'mine', title: 'مال من', contentType: 'a', sizeBytes: 1),
        confidence: 0.5,
        source: SongMatchSource.library,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'گوش بده'));
      await tester.pump();
      recorder.finish();
      await tester.pumpAndSettle();
      expect(find.text('مال من'), findsOneWidget);
      expect(find.text('افزودن به موسیقی من'), findsNothing);
    });

    testWidgets('a refused microphone explains how to allow it',
        (tester) async {
      await open(tester);
      recorder.allowed = false;
      await tester.tap(find.widgetWithText(FilledButton, 'گوش بده'));
      await tester.pumpAndSettle();
      expect(find.text('دسترسی به میکروفون داده نشد'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expectFits(tester, find.widgetWithText(FilledButton, 'دوباره گوش بده'));
    });
  });

  testWidgets('the library offers «این آهنگ چیه؟» on a narrow phone',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recorder = FakeRecorder();
    await tester.pumpWidget(RhythmoApp(
      healthCheck: () async {},
      authApi: FakeAuthApi(),
      tokenStore: MemoryTokenStore('valid-token'),
      tracksApi: FakeTracksApi(),
      audioEngine: FakeAudioEngine(),
      audioCache: FakeAudioCache(),
      uploader: FakeUploader(),
      picker: FakePicker(null),
      identifyApi: FakeIdentifyApi(),
      snippetRecorder: recorder,
    ));
    await tester.pumpAndSettle();
    final action = tester.getRect(find.byTooltip('این آهنگ چیه؟'));
    expect(action.width, greaterThanOrEqualTo(48));
    expect(action.left, greaterThanOrEqualTo(0));
    expect(action.right, lessThanOrEqualTo(360));
    await tester.tap(find.byTooltip('این آهنگ چیه؟'));
    await tester.pumpAndSettle();
    expect(find.byType(IdentifyScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
