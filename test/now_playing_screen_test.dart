import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/favorite_tracks.dart';
import 'package:rhythmo/features/player/application/play_queue.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/now_playing_screen.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi;

const _tracks = [
  Track(
      id: 'a',
      title: 'یک آهنگ با عنوانی بسیار بلند که هرگز در یک خط جا نمی‌شود',
      artist: 'Artist A',
      album: 'Album',
      fileName: 'a.mp3',
      contentType: 'audio/mpeg',
      sizeBytes: 2048),
  Track(id: 'b', title: 'Second', contentType: 'audio/mpeg', sizeBytes: 1),
  Track(
      id: 'c',
      title: 'Third',
      artist: 'Artist C',
      contentType: 'audio/mpeg',
      sizeBytes: 1),
];

// Advances the finite transitions: the slide in, ink and sheets.
Future<void> advanceUi(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}

void main() {
  late PlayerController player;
  late MemoryFavoritesStore store;

  setUp(() {
    store = MemoryFavoritesStore();
    player = PlayerController(
      api: FakeTracksApi(),
      engine: FakeAudioEngine(),
      token: () => 'tok',
      favorites: FavoriteTracks(store: store),
    );
  });

  void setSize(WidgetTester tester, Size size, {double bottomInset = 0}) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(top: 24, bottom: bottomInset);
    tester.view.viewPadding = FakeViewPadding(top: 24, bottom: bottomInset);
    addTearDown(tester.view.reset);
  }

  /// A page with an "open" button, then the now-playing screen opened over
  /// it, as the mini player does.
  Future<void> open(WidgetTester tester, {bool reduceMotion = false}) async {
    await player.playFrom(_tracks, 0);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('fa'),
      supportedLocales: const [Locale('fa')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: RhythmoTheme.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
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
    await advanceUi(tester);
  }

  testWidgets('shows the track, its artist and times', (tester) async {
    await open(tester);

    expect(find.byType(NowPlayingScreen), findsOneWidget);
    expect(find.text(_tracks[0].title), findsOneWidget);
    expect(find.text('Artist A'), findsOneWidget);
    expect(find.text('۰:۰۰'), findsOneWidget);
    expect(find.text('۳:۰۰'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('transport controls drive the player', (tester) async {
    await open(tester);

    await tester.tap(find.byTooltip('توقف'));
    await advanceUi(tester);
    expect(player.status, PlayerStatus.paused);
    await tester.tap(find.byTooltip('پخش'));
    await advanceUi(tester);
    expect(player.status, PlayerStatus.playing);

    await tester.tap(find.byTooltip('بعدی'));
    await advanceUi(tester);
    expect(player.track?.id, 'b');
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('روی سرور'), findsOneWidget,
        reason: 'no artist: say where it plays from');

    await tester.tap(find.byTooltip('قبلی'));
    await advanceUi(tester);
    expect(player.track?.id, 'a');

    await tester.tap(find.byTooltip('پخش تصادفی'));
    await advanceUi(tester);
    expect(player.shuffle, isTrue);
    expect(find.byTooltip('پخش تصادفی: روشن'), findsOneWidget);

    await tester.tap(find.byTooltip('تکرار: خاموش'));
    await advanceUi(tester);
    expect(player.repeat, QueueRepeat.all);
    expect(find.byTooltip('تکرار: همه'), findsOneWidget);
  });

  testWidgets('the heart likes the track and remembers it', (tester) async {
    await open(tester);

    expect(find.byIcon(RhythmoIcons.heart), findsOneWidget);
    await tester.tap(find.byTooltip('پسندیدن'));
    await advanceUi(tester);

    expect(find.byIcon(RhythmoIcons.heartFill), findsOneWidget);
    expect(find.byTooltip('برداشتن از پسندیده‌ها'), findsOneWidget);
    expect(store.ids, {'a'});

    await tester.tap(find.byTooltip('برداشتن از پسندیده‌ها'));
    await advanceUi(tester);
    expect(store.ids, isEmpty);
  });

  testWidgets('the queue lists what plays next and plays the tapped track',
      (tester) async {
    await open(tester);

    await tester.tap(find.text('صف پخش · ۲'));
    await advanceUi(tester);

    final sheet = find.byType(QueueSheet);
    expect(sheet, findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Second')),
        findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Third')),
        findsOneWidget);

    await tester.tap(find.descendant(of: sheet, matching: find.text('Third')));
    await advanceUi(tester);

    expect(player.track?.id, 'c');
    expect(player.status, PlayerStatus.playing);
    // The sheet follows along: Third is now playing and nothing is next.
    expect(find.text('در حال پخش · Artist C'), findsOneWidget);
    expect(find.text('آهنگ دیگری در صف نیست.'), findsOneWidget);
  });

  testWidgets('the screen is still: nothing animates while it plays',
      (tester) async {
    await open(tester);
    await tester.pump(const Duration(seconds: 2));

    expect(player.status, PlayerStatus.playing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('the play button is the one white control', (tester) async {
    await open(tester);

    final play = tester.widget<IconButton>(find.ancestor(
        of: find.byTooltip('توقف'), matching: find.byType(IconButton)));
    final scheme = RhythmoTheme.dark().colorScheme;
    expect(play.style?.backgroundColor?.resolve({}), scheme.onSurface);
    expect(play.style?.foregroundColor?.resolve({}), scheme.surface);
  });

  testWidgets('«بعدی در صف» shows the next track and opens the queue',
      (tester) async {
    await open(tester);

    final next = find.byKey(const ValueKey('up-next'));
    expect(find.text('بعدی در صف'), findsOneWidget);
    expect(find.descendant(of: next, matching: find.text('Second')),
        findsOneWidget);

    await tester.tap(next);
    await advanceUi(tester);
    expect(find.byType(QueueSheet), findsOneWidget);
  });

  testWidgets('the details sheet shows the file and its size', (tester) async {
    await open(tester);

    await tester.tap(find.byTooltip('جزئیات آهنگ'));
    await advanceUi(tester);

    expect(find.text('Album'), findsOneWidget);
    expect(find.text('a.mp3'), findsOneWidget);
    expect(find.text('۲ کیلوبایت'), findsOneWidget);
  });

  testWidgets('swiping down closes; a short drag springs back', (tester) async {
    await open(tester);

    await tester.drag(find.byType(NowPlayingScreen), const Offset(0, 60));
    await advanceUi(tester);
    expect(find.byType(NowPlayingScreen), findsOneWidget);
    expect(tester.getTopLeft(find.byType(NowPlayingScreen)).dy, 0);

    await tester.fling(
        find.byType(NowPlayingScreen), const Offset(0, 400), 1500);
    await advanceUi(tester);
    expect(find.byType(NowPlayingScreen), findsNothing);
  });

  testWidgets('the close button closes', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('بستن'));
    await advanceUi(tester);
    expect(find.byType(NowPlayingScreen), findsNothing);
  });

  testWidgets('with reduced motion the screen opens without sliding',
      (tester) async {
    await player.playFrom(_tracks, 0);
    await open(tester, reduceMotion: true);
    await tester.tap(find.byTooltip('بستن'));
    // A single frame is enough: no transition runs.
    await tester.pump();
    expect(find.byType(NowPlayingScreen), findsNothing);

    await tester.tap(find.text('open'));
    await tester.pump();
    expect(tester.getTopLeft(find.byType(NowPlayingScreen)).dy, 0);
  });

  testWidgets('fits a 360 px phone with system insets and 48 px targets',
      (tester) async {
    setSize(tester, const Size(360, 640), bottomInset: 34);
    await open(tester);

    expect(tester.takeException(), isNull, reason: 'no overflow');
    final screen = tester.getRect(find.byType(NowPlayingScreen));
    for (final tooltip in [
      'بستن',
      'پسندیدن',
      'پخش تصادفی',
      'قبلی',
      'توقف',
      'بعدی',
      'تکرار: خاموش',
      'جزئیات آهنگ',
    ]) {
      final rect = tester.getRect(find.byTooltip(tooltip));
      expect(rect.width, greaterThanOrEqualTo(48), reason: tooltip);
      expect(rect.height, greaterThanOrEqualTo(48), reason: tooltip);
      expect(
          screen.contains(rect.topLeft) && rect.right <= screen.right, isTrue,
          reason: '$tooltip is on screen');
    }
    final queue = tester.getRect(find.text('صف پخش · ۲'));
    expect(queue.bottom, lessThanOrEqualTo(640 - 34),
        reason: 'the bottom row clears the gesture bar');
    final title = tester.getRect(find.text(_tracks[0].title));
    expect(title.right, lessThanOrEqualTo(360));
    expect(title.left, greaterThanOrEqualTo(0));

    // The queue sheet also fits, and its last row clears the inset.
    await tester.tap(find.text('صف پخش · ۲'));
    await advanceUi(tester);
    expect(tester.takeException(), isNull);
    expect(
        tester.getRect(find.text('Third')).bottom, lessThanOrEqualTo(640 - 34));
  });

  testWidgets('a short landscape window still fits by scrolling',
      (tester) async {
    setSize(tester, const Size(740, 360));
    await open(tester);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('توقف'), findsOneWidget);
  });

  testWidgets('desktop keeps the player in a centered column', (tester) async {
    setSize(tester, const Size(1440, 900));
    await open(tester);

    final slider = tester.getRect(find.byType(Slider));
    expect(slider.width, lessThanOrEqualTo(nowPlayingMaxWidth));
    expect(slider.center.dx, closeTo(720, 1));
  });

  test('every track tint keeps text readable', () {
    final theme = RhythmoTheme.dark().colorScheme;
    for (var i = 0; i < 500; i++) {
      final tint = trackTint(Track(
          id: 'track-$i', title: '', contentType: 'audio/mpeg', sizeBytes: 1));
      expect(contrastRatio(theme.onSurface, tint), greaterThanOrEqualTo(7));
      expect(contrastRatio(theme.onSurfaceVariant, tint),
          greaterThanOrEqualTo(4.5));
    }
    // Stable: the same track always gets the same color.
    const track =
        Track(id: 'x', title: '', contentType: 'audio/mpeg', sizeBytes: 1);
    expect(trackTint(track), trackTint(track));
  });
}
