import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/playback_settings.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/now_playing_screen.dart';
import 'package:rhythmo/features/player/presentation/playback_controls.dart';
import 'package:rhythmo/features/settings/application/cache_controller.dart';
import 'package:rhythmo/features/settings/presentation/settings_screen.dart';
import 'package:rhythmo/features/settings/presentation/queue_settings_section.dart';

import 'cache_controller_test.dart' show FakeAudioCache;
import 'now_playing_screen_test.dart' show advanceUi;
import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi;

const _tracks = [
  Track(
      id: 'a',
      title: 'یک آهنگ با عنوانی بسیار بلند که هرگز در یک خط جا نمی‌شود',
      artist: 'Artist A',
      contentType: 'audio/mpeg',
      sizeBytes: 2048),
  Track(id: 'b', title: 'Second', contentType: 'audio/mpeg', sizeBytes: 1),
  Track(id: 'c', title: 'Third', contentType: 'audio/mpeg', sizeBytes: 1),
];

Widget _app(Widget home) => MaterialApp(
      locale: const Locale('fa'),
      supportedLocales: const [Locale('fa')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: RhythmoTheme.dark(),
      home: home,
    );

void main() {
  // The real Persian font, so the narrow-screen checks measure real text
  // instead of the test font's wide placeholder glyphs.
  setUpAll(() async {
    final vazirmatn = FontLoader('Vazirmatn')
      ..addFont(rootBundle.load('assets/fonts/Vazirmatn-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Vazirmatn-Medium.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Vazirmatn-Bold.ttf'));
    await vazirmatn.load();
  });

  late FakeAudioEngine engine;
  late PlayerController player;
  late DateTime clock;

  setUp(() {
    clock = DateTime(2026, 10, 6, 23);
    engine = FakeAudioEngine();
    player = PlayerController(
      api: FakeTracksApi(),
      engine: engine,
      token: () => 'tok',
      settingsStore: MemoryPlaybackSettingsStore(),
      now: () => clock,
    );
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
    addTearDown(tester.view.reset);
  }

  void expectTarget(WidgetTester tester, Finder finder, String reason) {
    final rect = tester.getRect(finder);
    expect(rect.width, greaterThanOrEqualTo(48), reason: reason);
    expect(rect.height, greaterThanOrEqualTo(48), reason: reason);
    expect(rect.left, greaterThanOrEqualTo(0), reason: reason);
    expect(rect.right, lessThanOrEqualTo(360), reason: reason);
    expect(rect.bottom, lessThanOrEqualTo(640 - 34), reason: reason);
  }

  Future<void> openPlayer(WidgetTester tester) async {
    await player.playFrom(_tracks, 0);
    await tester.pumpWidget(_app(Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => openNowPlaying(context, player),
            child: const Text('open'),
          ),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await advanceUi(tester);
  }

  test('speeds and timer choices read in Persian', () {
    expect(formatSpeed(1), '۱×');
    expect(formatSpeed(0.75), '۰٫۷۵×');
    expect(formatSpeed(1.5), '۱٫۵×');
    expect(formatSpeed(2), '۲×');
    expect(formatSleepChoice(15), '۱۵ دقیقه');
    expect(formatSleepChoice(60), '۱ ساعت');
  });

  group('on a 360 px phone', () {
    testWidgets('the sleep timer and speed controls fit with 48 px targets',
        (tester) async {
      phone(tester);
      await openPlayer(tester);
      player.setSleepTimer(const Duration(minutes: 45));
      await player.setSpeed(1.75);
      await tester.pump();

      expect(tester.takeException(), isNull, reason: 'no overflow');
      expectTarget(tester, find.byTooltip('زمان‌سنج خواب: توقف تا ۴۵:۰۰'),
          'sleep timer');
      expectTarget(tester, find.byTooltip('سرعت پخش'), 'speed');
      expectTarget(tester, find.byTooltip('جزئیات آهنگ'), 'details');
      expect(find.text('۱٫۷۵×'), findsOneWidget);
      final queueLabel =
          tester.renderObject<RenderParagraph>(find.text('صف پخش (۲)'));
      expect(queueLabel.didExceedMaxLines, isFalse,
          reason: 'the queue label is not cut off');
      final status = tester.getRect(find.byKey(const ValueKey('sleep-status')));
      expect(status.left, greaterThanOrEqualTo(0));
      expect(status.right, lessThanOrEqualTo(360));
      expect(find.text('توقف تا ۴۵:۰۰'), findsOneWidget);

      // The countdown moves on while the screen is open.
      clock = clock.add(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('توقف تا ۴۳:۵۹'), findsOneWidget);
      player.cancelSleepTimer();
      await tester.pump();
      expect(find.byKey(const ValueKey('sleep-status')), findsNothing);
      expect(find.byTooltip('زمان‌سنج خواب'), findsOneWidget);
    });

    testWidgets('the sleep timer sheet sets, shows and cancels a timer',
        (tester) async {
      phone(tester);
      await openPlayer(tester);

      await tester.tap(find.byTooltip('زمان‌سنج خواب'));
      await advanceUi(tester);
      expect(tester.takeException(), isNull);
      for (final label in [
        '۱۵ دقیقه',
        '۳۰ دقیقه',
        '۴۵ دقیقه',
        '۱ ساعت',
        'پایان همین آهنگ',
      ]) {
        final tile = find.ancestor(
            of: find.text(label), matching: find.byType(ListTile));
        expectTarget(tester, tile, label);
      }
      expect(find.text('لغو زمان‌سنج'), findsNothing);

      await tester.tap(find.text('۳۰ دقیقه'));
      await advanceUi(tester);
      expect(player.sleepRemaining, const Duration(minutes: 30));
      expect(find.text('توقف تا ۳۰:۰۰'), findsOneWidget);

      await tester.tap(find.byTooltip('زمان‌سنج خواب: توقف تا ۳۰:۰۰'));
      await advanceUi(tester);
      await tester.tap(find.text('پایان همین آهنگ'));
      await advanceUi(tester);
      expect(player.sleepsAtTrackEnd, isTrue);
      expect(find.text('توقف در پایان آهنگ'), findsOneWidget);

      await tester.tap(find.byTooltip('زمان‌سنج خواب: توقف در پایان آهنگ'));
      await advanceUi(tester);
      final cancel = find.ancestor(
          of: find.text('لغو زمان‌سنج'), matching: find.byType(ListTile));
      expectTarget(tester, cancel, 'cancel');
      await tester.tap(cancel);
      await advanceUi(tester);
      expect(player.sleepTimerActive, isFalse);
    });

    testWidgets('the speed sheet changes the speed', (tester) async {
      phone(tester);
      await openPlayer(tester);

      await tester.tap(find.byTooltip('سرعت پخش'));
      await advanceUi(tester);
      expect(tester.takeException(), isNull);
      for (final speed in playbackSpeeds) {
        final chip = find.widgetWithText(ChoiceChip, formatSpeed(speed));
        expectTarget(tester, chip, formatSpeed(speed));
      }

      await tester.tap(find.widgetWithText(ChoiceChip, '۱٫۵×'));
      await advanceUi(tester);
      expect(player.speed, 1.5);
      expect(engine.speed, 1.5);
      final chip =
          tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '۱٫۵×'));
      expect(chip.selected, isTrue);
    });

    testWidgets('queue controls update persisted preferences on a narrow phone',
        (tester) async {
      phone(tester);
      await tester.pumpWidget(_app(Scaffold(
        body: SafeArea(child: QueueSettingsSection(player: player)),
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('با انتخاب یک آهنگ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('فقط همان آهنگ پخش شود'));
      await tester.pumpAndSettle();
      expect(player.playOnlySelected, isTrue);
      expect(find.text('فقط همان آهنگ پخش شود'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(player.preventDuplicates, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('settings speed and sleep timer update the real player',
        (tester) async {
      phone(tester);
      await tester.pumpWidget(_app(SettingsScreen(
        cache: CacheController(cache: FakeAudioCache(), playing: () => null),
        player: player,
        siteUri: (_) => null,
      )));
      await tester.pumpAndSettle();
      final speed = find.byKey(const ValueKey('playback-speed-slider'));
      expectTarget(tester, speed, 'speed slider');
      expect(Directionality.of(tester.element(speed)), TextDirection.ltr);
      await tester.drag(speed, const Offset(400, 0));
      await tester.pumpAndSettle();
      expect(player.speed, playbackSpeeds.last);
      expect(engine.speed, playbackSpeeds.last);
      await tester.tap(find.text('زمان‌سنج خواب'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('۱۵ دقیقه'));
      await tester.pumpAndSettle();
      expect(player.sleepTimerActive, isTrue);
      expect(find.textContaining('توقف تا'), findsOneWidget);
      expect(tester.takeException(), isNull);
      player.cancelSleepTimer();
    });

    testWidgets('settings offer crossfade where the platform supports it',
        (tester) async {
      phone(tester);
      await tester.pumpWidget(_app(SettingsScreen(
        cache: CacheController(cache: FakeAudioCache(), playing: () => null),
        player: player,
        siteUri: (_) => null,
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('هم‌پوشانی آهنگ‌ها'), findsOneWidget);
      expect(find.text('خاموش'), findsWidgets, reason: 'off by default');

      final slider = find.byType(Slider).last;
      expectTarget(tester, slider, 'crossfade slider');
      // Slide all the way to the end: eight seconds.
      await tester.drag(slider, const Offset(400, 0));
      await tester.pumpAndSettle();
      expect(player.crossfade, maxCrossfade);
      expect(engine.crossfade, maxCrossfade);
      expect(find.text('۸ ثانیه'), findsWidgets);
    });

    testWidgets('settings hide crossfade where it cannot work reliably',
        (tester) async {
      phone(tester);
      engine.crossfadeSupported = false;
      await tester.pumpWidget(_app(SettingsScreen(
        cache: CacheController(cache: FakeAudioCache(), playing: () => null),
        player: player,
        siteUri: (_) => null,
      )));
      await tester.pumpAndSettle();
      expect(find.text('هم‌پوشانی آهنگ‌ها'), findsNothing);
      expect(find.byType(Slider), findsOneWidget,
          reason: 'speed stays available');
    });
  });
}
