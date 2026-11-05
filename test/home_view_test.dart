import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/library/presentation/home_view.dart';
import 'package:rhythmo/features/library/presentation/rhythmo_dock.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi;

Track _track(String id, {DateTime? addedAt}) => Track(
    id: id,
    title: 'Track $id',
    contentType: 'audio/mpeg',
    sizeBytes: 1,
    addedAt: addedAt);

void main() {
  test('the greeting follows the hour', () {
    expect(homeGreeting(DateTime(2026, 1, 1, 8)), 'صبح بخیر');
    expect(homeGreeting(DateTime(2026, 1, 1, 13)), 'روز بخیر');
    expect(homeGreeting(DateTime(2026, 1, 1, 18)), 'عصر بخیر');
    expect(homeGreeting(DateTime(2026, 1, 1, 23)), 'شب بخیر');
    expect(homeGreeting(DateTime(2026, 1, 1, 2)), 'شب بخیر');
  });

  test('the shelf puts the newest first and undated tracks last', () {
    final shelf = newestTracks([
      _track('old', addedAt: DateTime(2026, 1, 1)),
      _track('undated'),
      _track('new', addedAt: DateTime(2026, 10, 1)),
    ]);
    expect(shelf.map((t) => t.id), ['new', 'old', 'undated']);
    expect(newestTracks([for (var i = 0; i < 20; i++) _track('$i')]),
        hasLength(homeShelfLength));
  });

  group('home', () {
    late PlayerController player;

    setUp(() => player = PlayerController(
        api: FakeTracksApi(), engine: FakeAudioEngine(), token: () => 't'));
    tearDown(() => player.dispose());

    Future<void> pump(WidgetTester tester, List<Track> tracks,
        {VoidCallback? onAddMusic,
        VoidCallback? onPopular,
        VoidCallback? onStore,
        VoidCallback? onIdentify}) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: RhythmoTheme.dark(),
        home: Scaffold(
          body: HomeView(
            header: const SliverToBoxAdapter(),
            player: player,
            changes: ChangeNotifier(),
            tracks: () => tracks,
            onAddMusic: onAddMusic ?? () {},
            onPopular: onPopular,
            onStore: onStore,
            onIdentify: onIdentify,
            now: () => DateTime(2026, 10, 29, 22),
          ),
        ),
      ));
    }

    testWidgets('an empty library offers to add music', (tester) async {
      var asked = false;
      await pump(tester, const [], onAddMusic: () => asked = true);

      expect(find.text('شب بخیر'), findsOneWidget);
      await tester.tap(find.text('افزودن موسیقی'));
      expect(asked, isTrue);
    });

    testWidgets('discovery is three small chips right under the greeting',
        (tester) async {
      final opened = <String>[];
      await pump(tester, [_track('a')],
          onPopular: () => opened.add('popular'),
          onStore: () => opened.add('store'),
          onIdentify: () => opened.add('identify'));

      final greeting = tester.getRect(find.text('شب بخیر'));
      final shelf = tester.getRect(find.text('Track a'));
      for (final label in ['محبوب‌ها', 'گنجینه', 'این آهنگ چیه؟']) {
        final chip = tester.getRect(find.ancestor(
            of: find.text(label), matching: find.byType(InkWell)));
        // Between the greeting and the music, and a full touch target
        // without being a big card.
        expect(chip.top, greaterThan(greeting.bottom));
        expect(chip.bottom, lessThan(shelf.top));
        expect(chip.height, inInclusiveRange(48, 56));
        await tester.tap(find.text(label));
      }
      expect(opened, ['popular', 'store', 'identify']);
      expect(find.text('کشف'), findsNothing);
    });

    testWidgets('a shelf cover plays, then the resume card follows along',
        (tester) async {
      await pump(tester, [_track('a'), _track('b')]);
      expect(find.text('ادامه بده'), findsNothing);

      await tester.runAsync(() async {
        await tester.tap(find.text('Track b'));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      expect(player.track?.id, 'b');
      final card = find.byKey(const ValueKey('home-resume'));
      expect(
          find.descendant(of: card, matching: find.text('Track b')), findsOne);
      final play = tester.widget<IconButton>(
          find.descendant(of: card, matching: find.byType(IconButton)));
      expect(play.style?.backgroundColor?.resolve({}),
          RhythmoTheme.dark().colorScheme.onSurface);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets(
      'the dock is four named icons across a 360 px phone, with no account '
      '(#444)', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = PlayerController(
        api: FakeTracksApi(), engine: FakeAudioEngine(), token: () => 't');
    addTearDown(player.dispose);
    DockDestination? picked;
    await tester.pumpWidget(MaterialApp(
      theme: RhythmoTheme.dark(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          bottomNavigationBar: RhythmoDock(
            player: player,
            selected: DockDestination.home,
            onSelect: (d) => picked = d,
          ),
        ),
      ),
    ));

    // Icons only: the names are for tooltips and screen readers.
    for (final label in ['خانه', 'جست‌وجو', 'پسندیده‌ها', 'موسیقی من']) {
      expect(find.text(label), findsNothing);
      final size = tester.getSize(find.byTooltip(label));
      expect(size.width, greaterThanOrEqualTo(48), reason: label);
      expect(size.height, greaterThanOrEqualTo(48), reason: label);
    }
    // The account opens from the header avatar, not the dock.
    expect(find.byTooltip('حساب'), findsNothing);
    await tester.tap(find.byTooltip('پسندیده‌ها'));
    expect(picked, DockDestination.liked);
    await tester.tap(find.byTooltip('جست‌وجو'));
    expect(picked, DockDestination.search);
    expect(
        tester.getSemantics(find.byTooltip('خانه')),
        matchesSemantics(
            label: 'خانه',
            isButton: true,
            isSelected: true,
            hasSelectedState: true,
            hasTapAction: true));
    // Spread across the whole width, in reading order.
    expect(tester.getCenter(find.byTooltip('خانه')).dx, greaterThan(270));
    expect(tester.getCenter(find.byTooltip('موسیقی من')).dx, lessThan(90));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the dock stays together in the middle of a wide window',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = PlayerController(
        api: FakeTracksApi(), engine: FakeAudioEngine(), token: () => 't');
    addTearDown(player.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: RhythmoTheme.dark(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          bottomNavigationBar: RhythmoDock(
            player: player,
            selected: DockDestination.home,
            onSelect: (_) {},
          ),
        ),
      ),
    ));

    final first = tester.getRect(find.byTooltip('خانه'));
    final last = tester.getRect(find.byTooltip('موسیقی من'));
    final middle = (first.center.dx + last.center.dx) / 2;
    expect((middle - 700).abs(), lessThan(1));
    // Capped at the 520 px row, not spread to the window's edges.
    expect(first.center.dx - last.center.dx, lessThanOrEqualTo(dockNavWidth));
  });
}
