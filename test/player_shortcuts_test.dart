import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/playback_settings.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/mini_player.dart';
import 'package:rhythmo/features/player/presentation/player_shortcuts.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi;

const _tracks = [
  Track(id: 'a', title: 'A', contentType: 'audio/mpeg', sizeBytes: 1),
  Track(id: 'b', title: 'B', contentType: 'audio/mpeg', sizeBytes: 1),
];

void main() {
  late FakeAudioEngine engine;
  late MemoryPlaybackSettingsStore store;
  late PlayerController player;

  setUp(() {
    engine = FakeAudioEngine();
    store = MemoryPlaybackSettingsStore();
    player = PlayerController(
        api: FakeTracksApi(),
        engine: engine,
        token: () => 'tok',
        settingsStore: store);
  });
  tearDown(() => player.dispose());

  Future<void> pumpApp(WidgetTester tester, {Widget? body}) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) =>
          PlayerShortcuts(player: player, child: child!),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: body ?? const SizedBox.expand(),
          bottomNavigationBar: MiniPlayer(player: player, showVolume: true),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('keys drive the player', (tester) async {
    await player.playFrom(_tracks, 0);
    await pumpApp(tester);
    engine.positionCtl.add(const Duration(seconds: 30));

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(player.status, PlayerStatus.paused);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(player.status, PlayerStatus.playing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(engine.calls.last, 'seek:35');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(engine.calls.last, 'seek:30');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(player.track?.id, 'b');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(player.volume, closeTo(0.9, 1e-9));
    expect(engine.volumes.last, closeTo(0.9, 1e-9));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(player.muted, isTrue);
    expect(engine.volumes.last, 0);
    expect(store.settings.muted, isTrue, reason: 'remembered');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(player.muted, isFalse, reason: 'raising the volume unmutes');
    expect(player.volume, closeTo(1, 1e-9));
  });

  testWidgets('typing in a text field does not play or pause', (tester) async {
    await player.playFrom(_tracks, 0);
    await pumpApp(tester,
        body: const Center(child: TextField(autofocus: true)));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    expect(player.status, PlayerStatus.playing);
    expect(player.muted, isFalse);
  });

  testWidgets('the volume control mutes and is remembered', (tester) async {
    await player.playFrom(_tracks, 0);
    await pumpApp(tester);

    expect(find.byType(VolumeControl), findsOneWidget);
    await tester.tap(find.byTooltip('بی‌صدا'));
    await tester.pump();
    expect(player.muted, isTrue);
    expect(find.byTooltip('صدا'), findsOneWidget);

    final again = PlayerController(
        api: FakeTracksApi(),
        engine: FakeAudioEngine(),
        token: () => 'tok',
        settingsStore: store);
    addTearDown(again.dispose);
    await again.loadSettings();
    expect(again.muted, isTrue);
  });

  testWidgets('«?» lists the shortcuts', (tester) async {
    await pumpApp(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('میان‌برهای صفحه‌کلید'), findsOneWidget);
  });
}
