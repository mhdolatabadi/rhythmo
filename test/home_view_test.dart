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
        {VoidCallback? onAddMusic}) async {
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

  testWidgets('the dock selects, searches and fits a 360 px phone',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = PlayerController(
        api: FakeTracksApi(), engine: FakeAudioEngine(), token: () => 't');
    addTearDown(player.dispose);
    DockDestination? picked;
    await tester.pumpWidget(MaterialApp(
      theme: RhythmoTheme.dark(),
      home: Scaffold(
        bottomNavigationBar: RhythmoDock(
          player: player,
          selected: DockDestination.home,
          onSelect: (d) => picked = d,
        ),
      ),
    ));

    expect(find.text('خانه'), findsOneWidget);
    expect(find.text('موسیقی من'), findsNothing);
    // Liked songs are a tab of «موسیقی من», not a second way in.
    expect(find.byTooltip('پسندیده‌ها'), findsNothing);
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
    expect(tester.takeException(), isNull);
  });

  testWidgets('the dock is one pill centred on a wide window', (tester) async {
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
    final last = tester.getRect(find.byTooltip('حساب'));
    final middle = (first.right + last.left) / 2;
    expect((middle - 700).abs(), lessThan(1));
    // Not stretched to the 520 px cap: the items sit together.
    expect(first.right - last.left, lessThan(400));
  });
}
