import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/lyrics/application/lyrics_controller.dart';
import 'package:rhythmo/features/lyrics/data/lyrics.dart';
import 'package:rhythmo/features/lyrics/presentation/lyrics_sheet.dart';
import 'package:rhythmo/features/player/application/favorite_tracks.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/now_playing_screen.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi;

const _song = Track(
  id: 'song',
  title: 'آهنگ',
  artist: 'هنرمند',
  contentType: 'audio/mpeg',
  sizeBytes: 1,
);

const _synced = '''[ar:someone]
[00:01.00]خط اول
[00:05.00]Second line in English
[00:09.00]
[00:12.50][00:20.00]خط تکراری
[00:15.00]خط چهارم
[00:30.00]آخرین خط آهنگ''';

/// Lyrics answers by track id; counts requests.
class FakeLyricsApi implements LyricsApi, TranscriptionApi {
  FakeLyricsApi(this.answers);

  final Map<String, Object> answers;
  final requests = <String>[];
  final chosen = <int>[];

  Map<String, dynamic>? extractionAnswer;
  int extractionStarts = 0;
  @override
  Future<Map<String, dynamic>> transcription(String token, String trackId,
      {bool start = false}) async {
    if (extractionAnswer == null) {
      throw const ApiException('disabled', code: 'transcription_disabled');
    }
    if (start) {
      extractionStarts++;
      extractionAnswer = {'state': 'queued'};
    }
    return extractionAnswer!;
  }

  @override
  Future<TrackLyrics> trackLyrics(String? token, Track track,
      {Duration? duration}) async {
    requests.add(track.id);
    final answer = answers[track.id];
    if (answer is Exception) throw answer;
    return answer as TrackLyrics? ??
        const TrackLyrics(status: LyricsStatus.notFound);
  }

  @override
  Future<List<LyricsMatch>> lyricsCandidates(String token, String trackId,
          {String query = ''}) async =>
      [
        const LyricsMatch(
            id: 7,
            trackName: 'آهنگ',
            artistName: 'هنرمند',
            duration: Duration(minutes: 3, seconds: 5),
            synced: true),
      ];

  @override
  Future<TrackLyrics> chooseLyrics(
      String token, String trackId, int lrclibId) async {
    chosen.add(lrclibId);
    return const TrackLyrics(
        status: LyricsStatus.found, plain: 'متن انتخاب‌شده', canChoose: true);
  }
}

Future<void> _advance(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}

void main() {
  group('parseLrc', () {
    test('reads timed lines, repeats and pauses, skipping metadata', () {
      final lines = parseLrc(_synced);
      expect(lines.map((l) => l.text), [
        'خط اول',
        'Second line in English',
        '',
        'خط تکراری',
        'خط چهارم',
        'خط تکراری',
        'آخرین خط آهنگ',
      ]);
      expect(lines[3].time, const Duration(seconds: 12, milliseconds: 500));
      expect(lines[5].time, const Duration(seconds: 20));
    });

    test('accepts one, two or three fraction digits', () {
      final lines = parseLrc('[01:02.5]a\n[01:02.05]b\n[01:02.005]c\n[1:2]d');
      expect(lines.map((l) => l.time.inMilliseconds),
          [62000, 62005, 62050, 62500]);
    });

    test('the active line is the last one started', () {
      final lines = parseLrc(_synced);
      expect(activeLyricLine(lines, Duration.zero), -1);
      expect(activeLyricLine(lines, const Duration(seconds: 1)), 0);
      expect(activeLyricLine(lines, const Duration(seconds: 13)), 3);
      expect(activeLyricLine(lines, const Duration(minutes: 9)), 6);
    });

    test('Persian reads right to left, English left to right', () {
      expect(lyricDirection('خط اول'), TextDirection.rtl);
      expect(lyricDirection('  Hello دنیا'), TextDirection.ltr);
      expect(lyricDirection('۱۲۳ سلام'), TextDirection.rtl);
    });
  });

  test('the client asks the route the track is played through', () async {
    final paths = <String>[];
    final client = ApiClient(Uri.parse('https://api.example'),
        httpClient: MockClient((request) async {
      paths.add(request.url.toString());
      return http.Response(
          jsonEncode({
            'status': 'found',
            'synced': '[00:01.00]a',
            'plain': 'a',
            'match': {'id': 1, 'trackName': 'x', 'artistName': 'y'},
            'canChoose': true,
          }),
          200);
    }));
    final lyrics = await client.trackLyrics('tok', _song,
        duration: const Duration(seconds: 200));
    expect(lyrics.isSynced, isTrue);
    expect(lyrics.canChoose, isTrue);
    await client.trackLyrics(
        null,
        Track.fromJson(
            {'id': 't', 'title': 'x', 'contentType': 'a', 'sizeBytes': 1},
            sharedVia: 'share'));
    await client.trackLyrics(
        'tok',
        Track.fromJson({
          'id': 't',
          'title': 'x',
          'contentType': 'a',
          'sizeBytes': 1,
          'addedBy': 'b***@x'
        }, viaPlaylist: 'pl'));
    expect(paths, [
      'https://api.example/api/v1/tracks/song/lyrics?durationMs=200000',
      'https://api.example/api/v1/shared-playlists/share/tracks/t/lyrics',
      'https://api.example/api/v1/playlists/pl/tracks/t/lyrics',
    ]);
  });

  test('the controller keeps answers and knows what it cannot load', () async {
    final api = FakeLyricsApi({
      'song': const TrackLyrics(status: LyricsStatus.found, plain: 'x'),
    });
    String? token = 'tok';
    final controller = LyricsController(api: api, token: () => token);
    await controller.load(_song);
    await controller.load(_song);
    expect(api.requests, ['song'], reason: 'the second load is from memory');

    const device =
        Track(id: 'device:1', title: 'x', contentType: 'a', sizeBytes: 1);
    expect(controller.unavailable(device), LyricsUnavailable.deviceOnly);
    token = null;
    expect(controller.unavailable(_song), LyricsUnavailable.signedOut);
  });

  group('lyrics view at 360 px', () {
    late FakeAudioEngine engine;
    late PlayerController player;
    late FakeLyricsApi api;

    Future<void> open(WidgetTester tester, Map<String, Object> answers,
        {Track track = _song, Map<String, dynamic>? extraction}) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
      addTearDown(tester.view.reset);
      api = FakeLyricsApi(answers)..extractionAnswer = extraction;
      engine = FakeAudioEngine();
      player = PlayerController(
        api: FakeTracksApi(),
        engine: engine,
        token: () => 'tok',
        favorites: FavoriteTracks(store: MemoryFavoritesStore()),
        lyrics: LyricsController(api: api, token: () => 'tok'),
      );
      await player.playFrom([track], 0);
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('fa'),
        supportedLocales: const [Locale('fa')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: RhythmoTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => openNowPlaying(context, player),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await _advance(tester);
      final button = tester.getRect(find.byTooltip('متن آهنگ'));
      expect(button.width, greaterThanOrEqualTo(48));
      expect(button.height, greaterThanOrEqualTo(48));
      expect(button.right, lessThanOrEqualTo(360));
      expect(button.bottom, lessThanOrEqualTo(640 - 34));
      await tester.tap(find.byTooltip('متن آهنگ'));
      await _advance(tester);
      expect(tester.takeException(), isNull, reason: 'no overflow');
    }

    /// The bottom of what is visible: above the gesture bar.
    const visibleBottom = 640.0 - 34;

    testWidgets('synced lyrics light up with the music; a tap seeks',
        (tester) async {
      await open(tester, {
        'song': TrackLyrics(
          status: LyricsStatus.found,
          lines: parseLrc(_synced),
          match: const LyricsMatch(
              id: 1, trackName: 'آهنگ', artistName: 'هنرمند', synced: true),
        ),
      });
      expect(find.text('متن آهنگ'), findsOneWidget);
      expect(find.byKey(const ValueKey('synced-lyrics')), findsOneWidget);
      expect(find.text('متن دیگر'), findsNothing,
          reason: 'only the owner may pick another match');

      FontWeight? weight(String text) => tester
          .widget<AnimatedDefaultTextStyle>(find
              .ancestor(
                  of: find.text(text),
                  matching: find.byType(AnimatedDefaultTextStyle))
              .first)
          .style
          .fontWeight;

      engine.positionCtl.add(const Duration(seconds: 6));
      await _advance(tester);
      expect(weight('Second line in English'), FontWeight.w700);
      expect(weight('خط اول'), FontWeight.w500);
      final english = tester.widget<Text>(find.text('Second line in English'));
      expect(english.textDirection, TextDirection.ltr);
      expect(tester.widget<Text>(find.text('خط اول')).textDirection,
          TextDirection.rtl);

      // The playing line is scrolled into view, clear of the gesture bar.
      engine.positionCtl.add(const Duration(seconds: 31));
      await _advance(tester);
      final last = tester.getRect(find.text('آخرین خط آهنگ'));
      expect(last.top, greaterThanOrEqualTo(0));
      expect(last.bottom, lessThanOrEqualTo(visibleBottom));

      await tester.tap(find.text('خط چهارم'));
      await _advance(tester);
      expect(engine.calls, contains('seek:15'));
      expect(weight('خط چهارم'), FontWeight.w700);
      final line = tester.getRect(find.text('خط چهارم'));
      expect(line.width, lessThanOrEqualTo(360));
    });

    testWidgets('plain lyrics scroll to their last line and source',
        (tester) async {
      final text = [for (var i = 1; i <= 40; i++) 'بیت شماره $i'].join('\n');
      await open(tester, {
        'song': TrackLyrics(
          status: LyricsStatus.found,
          plain: text,
          canChoose: true,
          match:
              const LyricsMatch(id: 1, trackName: 'آهنگ', artistName: 'هنرمند'),
        ),
      });
      expect(find.byKey(const ValueKey('plain-lyrics')), findsOneWidget);
      await tester.dragUntilVisible(find.textContaining('متن از LRCLIB'),
          find.byKey(const ValueKey('plain-lyrics')), const Offset(0, -300));
      await tester.drag(
          find.byKey(const ValueKey('plain-lyrics')), const Offset(0, -2000));
      await _advance(tester);
      expect(tester.getRect(find.text('بیت شماره 40')).bottom,
          lessThanOrEqualTo(visibleBottom));
      expect(tester.getRect(find.textContaining('متن از LRCLIB')).bottom,
          lessThanOrEqualTo(visibleBottom),
          reason: 'nothing covers the end of the lyrics');
    });

    testWidgets('owner queues transcription and sees timed Persian result',
        (tester) async {
      await open(tester, {
        'song':
            const TrackLyrics(status: LyricsStatus.notFound, canChoose: true),
      }, extraction: {
        'state': 'idle'
      });
      final button = find.text('استخراج متن از صدا');
      expect(
          tester
              .getRect(find.ancestor(
                  of: button, matching: find.byType(FilledButton)))
              .height,
          greaterThanOrEqualTo(48));
      await tester.tap(button);
      await _advance(tester);
      expect(api.extractionStarts, 1);
      expect(find.text('در صف استخراج متن'), findsOneWidget);
      api.extractionAnswer = {
        'state': 'done',
        'plain': 'یا حسین',
        'synced': '[00:01.00]یا حسین'
      };
      await tester.pump(const Duration(seconds: 15));
      await _advance(tester);
      expect(find.text('یا حسین'), findsOneWidget);
      expect(
          find.text(
              'متن استخراج‌شده از صدا؛ ممکن است نیاز به اصلاح داشته باشد.'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('failed extraction offers retry without losing existing text',
        (tester) async {
      await open(tester, {
        'song':
            const TrackLyrics(status: LyricsStatus.found, plain: 'متن قبلی'),
      }, extraction: {
        'state': 'failed'
      });
      expect(find.text('تلاش دوباره برای استخراج از صدا'), findsOneWidget);
      expect(find.text('متن قبلی'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('not found says so, and the owner can search and pick',
        (tester) async {
      await open(tester, {
        'song':
            const TrackLyrics(status: LyricsStatus.notFound, canChoose: true),
      });
      expect(find.text('متنی پیدا نشد'), findsOneWidget);
      await tester.tap(find.text('جستجوی متن'));
      await _advance(tester);
      expect(tester.takeException(), isNull);
      final tile = tester.getRect(find.ancestor(
          of: find.text('هنرمند · ۳:۰۵'), matching: find.byType(ListTile)));
      expect(tile.height, greaterThanOrEqualTo(48));
      await tester.tap(find.text('هنرمند · ۳:۰۵'));
      await _advance(tester);
      expect(api.chosen, [7]);
      expect(find.text('متن انتخاب‌شده'), findsOneWidget);
    });

    testWidgets('a failure offers to try again', (tester) async {
      await open(tester, {
        'song': const ApiException('down',
            statusCode: 503, code: 'lyrics_unavailable'),
      });
      expect(find.text('سرویس متن آهنگ الان پاسخ نمی‌دهد'), findsOneWidget);
      api.answers['song'] =
          const TrackLyrics(status: LyricsStatus.instrumental);
      await tester.tap(find.text('تلاش دوباره'));
      await _advance(tester);
      expect(find.text('این آهنگ بی‌کلام است'), findsOneWidget);
    });

    testWidgets('music only on this device has no lyrics to ask for',
        (tester) async {
      await open(tester, {},
          track: Track(
            id: 'device:1',
            title: 'روی گوشی',
            contentType: 'audio/mpeg',
            sizeBytes: 1,
            sourceUri: Uri.parse('content://media/1'),
          ));
      expect(find.text('متن این آهنگ در دسترس نیست'), findsOneWidget);
      expect(api.requests, isEmpty);
    });
  });
}
