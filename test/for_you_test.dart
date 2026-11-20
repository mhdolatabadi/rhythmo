import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/features/for_you/application/for_you_controller.dart';
import 'package:rhythmo/features/for_you/data/for_you.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/library/presentation/home_view.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi;

Track _track(String id) =>
    Track(id: id, title: 'Track $id', contentType: 'audio/mpeg', sizeBytes: 1);

class FakeForYouApi implements ForYouApi {
  FakeForYouApi(this.lists);

  ForYou lists;
  final radioCalls = <(List<String>, List<String>)>[];
  Object? error;

  @override
  Future<ForYou> forYou(String token) async {
    if (error != null) throw error!;
    return lists;
  }

  @override
  Future<List<Track>> radio(
      String token, List<String> seedIds, List<String> excludeIds) async {
    radioCalls.add((seedIds, excludeIds));
    return [_track('r1')];
  }
}

void main() {
  test('reads the server lists', () {
    final lists = ForYou.fromJson({
      'smart': [
        {
          'key': 'most-played',
          'title': 'پرپخش‌ترین‌ها',
          'tracks': [
            {
              'id': 'a',
              'title': 'A',
              'contentType': 'audio/mpeg',
              'sizeBytes': 1
            }
          ],
        }
      ],
      'mixes': [
        {'key': 'mix-1', 'title': 'میکس روزانه ۱', 'tracks': []}
      ],
      'day': '2026-11-13',
    });
    expect(lists.smart.single.smart, isTrue);
    expect(lists.smart.single.tracks.single.id, 'a');
    expect(lists.mixes.single.smart, isFalse);
    expect(lists.all.map((l) => l.key), ['mix-1', 'most-played']);
    expect(ForYou.fromJson(const {}).isEmpty, isTrue);
  });

  test('swaps in the library copies, keeps lists on failure, clears', () async {
    final copy = Track(
        id: 'a',
        title: 'on the phone',
        contentType: 'audio/mpeg',
        sizeBytes: 1,
        sourceUri: Uri.parse('file:///a.mp3'));
    final api = FakeForYouApi(ForYou(smart: [
      ForYouList(
          key: 'most-played',
          title: 'پرپخش‌ترین‌ها',
          smart: true,
          tracks: [_track('a'), _track('b')])
    ]));
    String? token = 'tok';
    final controller =
        ForYouController(api: api, token: () => token, library: () => [copy]);
    await controller.load();
    expect(controller.lists.smart.single.tracks.first.title, 'on the phone');
    api.error = Exception('offline');
    await controller.load();
    expect(controller.lists.smart, hasLength(1));

    final radio = await controller.radio([_track('a')], [_track('a')]);
    expect(radio.single.id, 'r1');
    expect(api.radioCalls.single.$1, ['a']);
    expect(api.radioCalls.single.$2, ['a']);

    controller.clear();
    expect(controller.lists.isEmpty, isTrue);
    token = null;
    expect(await controller.radio([_track('a')], const []), isEmpty);
  });

  testWidgets('«برای تو» on «خانه» opens a read-only list at 360 px',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = PlayerController(
        api: FakeTracksApi(), engine: FakeAudioEngine(), token: () => 't');
    addTearDown(player.dispose);
    final controller = ForYouController(
      api: FakeForYouApi(ForYou(
        mixes: [
          ForYouList(
              key: 'mix-1',
              title: 'میکس روزانه ۱',
              smart: false,
              tracks: [for (var i = 0; i < 24; i++) _track('m$i')]),
        ],
        smart: [
          ForYouList(
              key: 'not-heard',
              title: 'مدتی است نشنیده‌ای',
              smart: true,
              tracks: [_track('x'), _track('y')]),
        ],
      )),
      token: () => 't',
    );
    await controller.load();
    await tester.pumpWidget(MaterialApp(
      theme: RhythmoTheme.dark(),
      home: Scaffold(
        body: HomeView(
          header: const SliverToBoxAdapter(),
          player: player,
          changes: ChangeNotifier(),
          tracks: () => [_track('lib')],
          onAddMusic: () {},
          forYou: controller,
        ),
      ),
    ));
    expect(find.text('برای تو'), findsOneWidget);
    expect(find.text('میکس روزانه ۱'), findsOneWidget);
    expect(find.text('۲۴ آهنگ'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('مدتی است نشنیده‌ای'));
    await tester.pumpAndSettle();
    expect(find.text('هوشمند'), findsOneWidget);
    expect(find.text('Track x'), findsOneWidget);
    expect(find.byKey(const ValueKey('for-you-play')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without lists «خانه» has no «برای تو»', (tester) async {
    final player = PlayerController(
        api: FakeTracksApi(), engine: FakeAudioEngine(), token: () => 't');
    addTearDown(player.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: RhythmoTheme.dark(),
      home: Scaffold(
        body: HomeView(
          header: const SliverToBoxAdapter(),
          player: player,
          changes: ChangeNotifier(),
          tracks: () => [_track('lib')],
          onAddMusic: () {},
          forYou: ForYouController(
              api: FakeForYouApi(const ForYou()), token: () => 't'),
        ),
      ),
    ));
    expect(find.text('برای تو'), findsNothing);
  });
}
