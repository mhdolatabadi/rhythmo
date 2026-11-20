import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/core/offline/offline_playback.dart';
import 'package:rhythmo/features/library/application/library_entries.dart';
import 'package:rhythmo/features/library/presentation/library_screen.dart';

void main() {
  testWidgets('unavailable cloud music explains the offline limitation',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: RhythmoTheme.dark(),
      home: const Scaffold(
        body: Center(
          child: TrackSyncMark(
            location: TrackLocation.server,
            offlineUnavailable: true,
          ),
        ),
      ),
    ));
    expect(find.text('نیازمند اینترنت'), findsOneWidget);
    expect(find.byTooltip(offlineUnavailableMessage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a cloud copy online keeps its normal status', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: RhythmoTheme.dark(),
      home: const Scaffold(
        body: Center(child: TrackSyncMark(location: TrackLocation.server)),
      ),
    ));
    expect(find.text('نیازمند اینترنت'), findsNothing);
    expect(find.byTooltip('در فضای ابری'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
