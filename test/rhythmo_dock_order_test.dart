import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/library/presentation/rhythmo_dock.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi;

void main() {
  testWidgets('signed-in dock keeps three primary destinations on a narrow phone',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = PlayerController(
        api: FakeTracksApi(), engine: FakeAudioEngine(), token: () => 't');
    addTearDown(player.dispose);
    final destinations = <DockDestination>[];

    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          bottomNavigationBar: RhythmoDock(
            player: player,
            selected: DockDestination.library,
            onSelect: destinations.add,
          ),
        ),
      ),
    ));

    // In RTL reading order, the first item is rightmost.
    final labels = ['خانه', 'موسیقی من', 'پسندیده‌ها'];
    final positions = [
      for (final label in labels) tester.getCenter(find.byTooltip(label)).dx,
    ];
    for (var i = 0; i < positions.length - 1; i++) {
      expect(positions[i], greaterThan(positions[i + 1]));
    }

    expect(find.byTooltip('جست‌وجو'), findsNothing);
    await tester.tap(find.byTooltip('پسندیده‌ها'));
    await tester.tap(find.byTooltip('موسیقی من'));
    expect(destinations, [DockDestination.liked, DockDestination.library]);
    expect(tester.takeException(), isNull);
  });
}
