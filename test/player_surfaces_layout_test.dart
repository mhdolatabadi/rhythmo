import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/features/identify/application/identify_controller.dart';
import 'package:rhythmo/features/identify/presentation/identify_screen.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/favorite_tracks.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/now_playing_screen.dart';

import 'identify_test.dart' show FakeIdentifyApi, FakeRecorder;
import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi;

void main() {
  late PlayerController player;

  setUp(() {
    player = PlayerController(
      api: FakeTracksApi(),
      engine: FakeAudioEngine(),
      token: () => 'tok',
      favorites: FavoriteTracks(store: MemoryFavoritesStore()),
    );
  });

  Widget app(Widget home) => MaterialApp(
        locale: const Locale('fa'),
        supportedLocales: const [Locale('fa')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: RhythmoTheme.dark(),
        home: home,
      );

  void setSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.reset);
  }

  for (final size in const [Size(360, 640), Size(1280, 860)]) {
    final label = '${size.width.toInt()} px';

    testWidgets('identify keeps a centred reading column at $label',
        (tester) async {
      setSize(tester, size);
      final controller = IdentifyController(
          api: FakeIdentifyApi(), recorder: FakeRecorder(), token: () => 't');
      await tester.pumpWidget(
          app(IdentifyScreen(controller: controller, player: player)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final listen =
          tester.getRect(find.widgetWithText(FilledButton, 'گوش بده'));
      expect(listen.height, greaterThanOrEqualTo(RhythmoSpace.target));
      expect(listen.bottom, lessThanOrEqualTo(size.height - 34));
      final title = tester.getRect(find.text('آهنگی که پخش می‌شود را بشناسید'));
      expect(title.width, lessThanOrEqualTo(RhythmoSpace.readingWidth));
      // Centred: equal room on both sides, within a pixel.
      expect((title.left - (size.width - title.right)).abs(), lessThan(2));
    });

    testWidgets('long now-playing titles wrap without overflow at $label',
        (tester) async {
      setSize(tester, size);
      const title =
          'عنوان طولانی یک سخنرانی که باید در دو خط نمایش داده شود و نه فقط یک خط';
      await player.playFrom(const [
        Track(
          id: 'long-title',
          title: title,
          contentType: 'audio/mpeg',
          sizeBytes: 1,
        ),
      ], 0);
      await tester.pumpWidget(app(NowPlayingScreen(player: player)));
      await tester.pumpAndSettle();
      final heading = tester.widget<Text>(find.text(title).first);
      expect(heading.maxLines, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the queue sheet uses shared rows and states at $label',
        (tester) async {
      setSize(tester, size);
      await player.playFrom(const [
        Track(
            id: 'only',
            title: 'تنها آهنگ',
            artist: 'هنرمند',
            contentType: 'audio/mpeg',
            sizeBytes: 1),
      ], 0);
      await tester.pumpWidget(app(Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => QueueSheet(player: player),
            ),
            child: const Text('open'),
          ),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(RhythmoTrackRow), findsOneWidget);
      expect(find.byType(RhythmoStateView), findsOneWidget,
          reason: 'nothing comes next');
      expect(find.text('در حال پخش · هنرمند'), findsOneWidget);
    });
  }
}
