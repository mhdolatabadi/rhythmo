import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';
import 'package:rhythmo/features/playlists/presentation/playlists_screen.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'playlist_sharing_test.dart' show FakePlaylistsApi;
import 'upload_controller_test.dart' show FakeTracksApi;

class FakeGoalsApi extends FakePlaylistsApi implements PlaylistGoalsApi {
  final goals = <String, int?>{};
  final occasionCalls = <String>[];
  bool fail = false;

  @override
  Future<void> setPlaylistGoal(String token, String id, int? goal) async {
    if (fail) throw Exception('offline');
    goals[id] = goal;
  }

  @override
  Future<void> setPlaylistOccasion(
      String token, String id, String occasion) async {
    if (fail) throw Exception('offline');
    occasionCalls.add(occasion);
  }
}

Playlist _playlist(String id, {String occasion = '', int? goal}) => Playlist(
      id: id,
      name: 'list $id',
      trackCount: 3,
      tracks: const [],
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      occasion: occasion,
      goal: goal,
    );

void main() {
  test('reads goals, occasions and shares from the server', () {
    final playlist = Playlist.fromJson({
      'id': 'p',
      'name': 'trip',
      'trackCount': 4,
      'createdAt': '2026-01-01T00:00:00Z',
      'updatedAt': '2026-01-01T00:00:00Z',
      'goal': 30,
      'occasion': 'سفر',
      'contributors': 3,
      'viewerContribution': 2,
    });
    expect(playlist.goal, 30);
    expect(playlist.occasion, 'سفر');
    expect(playlist.contributors, 3);
    expect(playlist.viewerContribution, 2);
    expect(playlist.withTracks(const []).goal, 30);
    expect(playlist.withGoal(clearGoal: true).goal, isNull);
  });

  test('a goal shows at once and goes back when the server says no', () async {
    final api = FakeGoalsApi()..userPlaylists = [_playlist('p1')];
    final controller = PlaylistsController(api: api, token: () => 'tok');
    await controller.load();
    expect(controller.supportsGoals, isTrue);

    expect(await controller.setGoal('p1', 20), isTrue);
    expect(controller.playlists.single.goal, 20);
    expect(api.goals['p1'], 20);

    api.fail = true;
    expect(await controller.setGoal('p1', null), isFalse);
    expect(controller.playlists.single.goal, 20, reason: 'undone');
    expect(await controller.setOccasion('p1', 'x'), isFalse);
    expect(controller.playlists.single.occasion, '');

    api.fail = false;
    expect(await controller.setOccasion('p1', '  سفر   شمال '), isTrue);
    expect(api.occasionCalls.single, 'سفر شمال');
    expect(controller.occasions, ['سفر شمال']);
  });

  test('without server support nothing is offered', () {
    final controller =
        PlaylistsController(api: FakePlaylistsApi(), token: () => 'tok');
    expect(controller.supportsGoals, isFalse);
  });

  testWidgets('goal progress counts songs and people without ranking',
      (tester) async {
    tester.view.physicalSize = const Size(360, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<void> show(Playlist playlist) => tester.pumpWidget(MaterialApp(
          theme: RhythmoTheme.dark(),
          home: Scaffold(body: PlaylistGoalProgress(playlist: playlist)),
        ));
    final shared = Playlist.fromJson({
      'id': 'p',
      'name': 'trip',
      'trackCount': 3,
      'createdAt': '2026-01-01T00:00:00Z',
      'updatedAt': '2026-01-01T00:00:00Z',
      'isOwner': false,
      'goal': 10,
      'contributors': 2,
      'viewerContribution': 1,
    });
    await show(shared);
    expect(find.text('۳ از ۱۰ آهنگ · ۲ نفر · سهم تو ۱'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('goal-progress')));
    expect(bar.value, closeTo(0.3, 0.001));
    expect(tester.takeException(), isNull);

    await show(_playlist('p', goal: 2));
    expect(find.text('هدف رسید: ۳ آهنگ'), findsOneWidget);
    await show(_playlist('p'));
    expect(find.byKey(const ValueKey('goal-progress')), findsNothing);
  });

  testWidgets('occasion collections filter the playlists, once there are any',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FakeGoalsApi()
      ..userPlaylists = [
        _playlist('a', occasion: 'سفر'),
        _playlist('b', occasion: 'ورزش'),
        _playlist('c'),
      ];
    final controller = PlaylistsController(api: api, token: () => 'tok');
    final player = PlayerController(
        api: FakeTracksApi(), engine: FakeAudioEngine(), token: () => 'tok');
    addTearDown(player.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: RhythmoTheme.dark(),
      home: PlaylistsScreen(
          controller: controller, libraryTracks: const [], player: player),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('occasion-filters')), findsOneWidget);
    expect(find.text('list c'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'سفر'));
    await tester.pumpAndSettle();
    expect(find.text('list a'), findsOneWidget);
    expect(find.text('list b'), findsNothing);
    expect(find.text('list c'), findsNothing);
    expect(tester.takeException(), isNull);

    // Nobody filed anything: no filters at all.
    api.userPlaylists = [_playlist('c')];
    await controller.load();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('occasion-filters')), findsNothing);
  });
}
