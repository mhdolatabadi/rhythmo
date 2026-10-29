import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/data/audio_engine.dart';
import 'package:rhythmo/features/player/presentation/mini_player.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi;

const _track = Track(
    id: 'a',
    title: 'آهنگی با عنوانی بسیار بلند که در صفحه‌ی باریک جا نمی‌شود',
    artist: 'خواننده',
    contentType: 'audio/mpeg',
    sizeBytes: 1);

void main() {
  testWidgets('the mini player says it is loading on a narrow phone',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = FakeAudioEngine();
    final player = PlayerController(
        api: FakeTracksApi(), engine: engine, token: () => 't');
    addTearDown(player.dispose);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('fa'),
      supportedLocales: const [Locale('fa')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: RhythmoTheme.dark(),
      home: Scaffold(bottomNavigationBar: MiniPlayer(player: player)),
    ));

    await tester.runAsync(() => player.playFrom(const [_track], 0));
    await tester.pump();
    expect(player.status, PlayerStatus.playing);
    expect(find.text('خواننده'), findsOneWidget);
    expect(find.text('در حال بارگذاری…'), findsNothing);

    // The network stalls mid-track.
    engine.stateCtl.add(EngineState.buffering);
    await tester.pump();
    expect(player.status, PlayerStatus.buffering);
    expect(find.text('در حال بارگذاری…'), findsOneWidget);
    expect(tester.takeException(), isNull);

    engine.stateCtl.add(EngineState.ready);
    await tester.pump();
    expect(find.text('در حال بارگذاری…'), findsNothing);
    expect(find.text('خواننده'), findsOneWidget);
  });

  testWidgets('the mini player\'s play button is white, not ember',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = PlayerController(
        api: FakeTracksApi(), engine: FakeAudioEngine(), token: () => 't');
    addTearDown(player.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: RhythmoTheme.dark(),
      home: Scaffold(bottomNavigationBar: MiniPlayer(player: player)),
    ));
    await tester.runAsync(() => player.playFrom(const [_track], 0));
    await tester.pump();

    final play = tester.widget<IconButton>(find.ancestor(
        of: find.byTooltip('توقف'), matching: find.byType(IconButton)));
    final scheme = RhythmoTheme.dark().colorScheme;
    expect(play.style?.backgroundColor?.resolve({}), scheme.onSurface);
    expect(play.style?.foregroundColor?.resolve({}), scheme.surface);
  });
}
