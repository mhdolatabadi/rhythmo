import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/journey/application/listening_journey.dart';
import 'package:rhythmo/features/journey/presentation/journey_widgets.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi;
import 'recently_played_test.dart' show track;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'distinct weekly progress, repeat counts, persistence and isolation',
    () async {
      final journey = ListeningJourney(now: () => DateTime(2026, 10, 14));
      await journey.selectAccount('alice');
      journey.record(track('a'));
      journey.record(track('a'));
      expect(journey.weeklyCount, 1);
      expect(journey.discoveries, 1);
      expect(journey.monthlyPlays['a'], 2);
      await journey.saved;
      await journey.selectAccount('bob');
      expect(journey.discoveries, 0);
      await journey.selectAccount('alice');
      expect(journey.discoveries, 1);
      journey.setEnabled(false);
      journey.record(track('b'));
      expect(journey.discoveries, 1);
      await journey.saved;
      await journey.selectAccount(null);
      expect(journey.discoveries, 0);
      await journey.selectAccount('alice');
      expect(journey.enabled, isFalse);
      journey.dispose();
    },
  );

  test(
    'Saturday resets the weekly journey without losing achievements',
    () async {
      var now = DateTime(2026, 10, 16, 23, 59);
      final journey = ListeningJourney(now: () => now);
      await journey.selectAccount('alice');
      journey.record(track('a'));
      now = DateTime(2026, 10, 17);
      expect(journey.weeklyCount, 0);
      expect(journey.suggestions([track('a')]).length, 1);
      journey.record(track('b'));
      expect(journey.weeklyCount, 1);
      expect(journey.discoveries, 2);
      await journey.saved;
      journey.dispose();
    },
  );

  test('seeks and paused position events do not unlock achievements', () async {
    final journey = ListeningJourney();
    await journey.selectAccount('alice');
    final engine = FakeAudioEngine();
    final player = PlayerController(
      api: FakeTracksApi(),
      engine: engine,
      token: () => 'token',
      journey: journey,
    );
    await player.play(track('a'));
    await player.seek(const Duration(minutes: 2));
    expect(journey.discoveries, 0);
    await player.pause();
    for (var second = 121; second <= 160; second++) {
      engine.positionCtl.add(Duration(seconds: second));
    }
    expect(journey.discoveries, 0);
    await player.resume();
    for (var second = 161; second <= 190; second++) {
      engine.positionCtl.add(Duration(seconds: second));
    }
    expect(journey.discoveries, 1);
    await journey.saved;
    player.dispose();
    journey.dispose();
  });

  testWidgets('narrow RTL journey opens and can be disabled', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final journey = ListeningJourney();
    await journey.selectAccount('alice');
    final player = PlayerController(
      api: FakeTracksApi(),
      engine: FakeAudioEngine(),
      token: () => 'token',
      journey: journey,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: JourneyCard(
              journey: journey,
              tracks: [track('a')],
              player: player,
            ),
          ),
        ),
      ),
    );
    expect(find.text('۰ از ۱ آهنگ متفاوت'), findsOneWidget);
    await tester.tap(find.text('سفر من'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final enabledSwitch = find.widgetWithText(SwitchListTile, 'سفر شنیداری');
    await tester.scrollUntilVisible(enabledSwitch, 150);
    await tester.ensureVisible(enabledSwitch);
    await tester.pumpAndSettle();
    await tester.tap(enabledSwitch);
    await tester.pumpAndSettle();
    expect(journey.enabled, isFalse);
    await journey.saved;
    await tester.pumpWidget(const SizedBox.shrink());
    player.dispose();
    journey.dispose();
  });

  test('collapsed and hidden library card choices persist per account',
      () async {
    final journey = ListeningJourney();
    await journey.selectAccount('alice');
    expect(journey.collapsed, isFalse);
    expect(journey.hiddenInLibrary, isFalse);
    journey.setCollapsed(true);
    journey.setHiddenInLibrary(true);
    await journey.saved;
    await journey.selectAccount('bob');
    expect(journey.collapsed, isFalse);
    expect(journey.hiddenInLibrary, isFalse);
    await journey.selectAccount('alice');
    expect(journey.collapsed, isTrue);
    expect(journey.hiddenInLibrary, isTrue);
    expect(journey.enabled, isTrue);
    journey.dispose();
  });

  testWidgets('narrow RTL journey card collapses, hides and comes back',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final journey = ListeningJourney();
    await journey.selectAccount('alice');
    final player = PlayerController(
      api: FakeTracksApi(),
      engine: FakeAudioEngine(),
      token: () => 'token',
      journey: journey,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: ListView(
              children: [
                JourneyCard(
                  journey: journey,
                  tracks: [track('a')],
                  player: player,
                ),
                JourneySetting(journey: journey),
              ],
            ),
          ),
        ),
      ),
    );
    final expandedHeight = tester.getSize(find.byType(JourneyCard)).height;

    await tester.tap(find.byTooltip('جمع کردن سفر شنیداری'));
    await tester.pumpAndSettle();
    expect(journey.collapsed, isTrue);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('سفر شنیداری · ۰ از ۱ آهنگ متفاوت'), findsOneWidget);
    final collapsedHeight = tester.getSize(find.byType(JourneyCard)).height;
    expect(collapsedHeight, lessThan(expandedHeight));
    expect(collapsedHeight, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);

    await tester.tap(find.bySemanticsLabel('باز کردن سفر شنیداری'));
    await tester.pumpAndSettle();
    expect(journey.collapsed, isFalse);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.tap(find.byTooltip('جمع کردن سفر شنیداری'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('پنهان کردن از کتابخانه'));
    await tester.pumpAndSettle();
    expect(journey.hiddenInLibrary, isTrue);
    expect(find.textContaining('سفر شنیداری ·'), findsNothing);
    await tester.tap(find.text('بازگردانی'));
    await tester.pumpAndSettle();
    expect(journey.hiddenInLibrary, isFalse);
    expect(find.textContaining('سفر شنیداری ·'), findsOneWidget);

    await tester.tap(find.byTooltip('پنهان کردن از کتابخانه'));
    await tester.pumpAndSettle();
    expect(find.text('بازگردانی'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('بازگردانی'), findsNothing);
    expect(journey.hiddenInLibrary, isTrue);
    final showSwitch =
        find.widgetWithText(SwitchListTile, 'نمایش سفر شنیداری در کتابخانه');
    expect(tester.widget<SwitchListTile>(showSwitch).value, isFalse);
    await tester.tap(showSwitch);
    await tester.pumpAndSettle();
    expect(journey.hiddenInLibrary, isFalse);
    expect(journey.enabled, isTrue);
    expect(find.textContaining('سفر شنیداری ·'), findsOneWidget);

    await journey.saved;
    await tester.pumpWidget(const SizedBox.shrink());
    player.dispose();
    journey.dispose();
  });
}
