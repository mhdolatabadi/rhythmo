import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rhythmo/core/network/offline_strip.dart';
import 'package:rhythmo/features/player/application/media_session.dart';
import 'package:rhythmo/main.dart' as app;

/// Runs on a real device or emulator: the real entry point with all
/// platform plugins. CI points API_BASE_URL at a port nothing listens on, so
/// a booted app must still open, offline, and say so.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app boots and reaches its first screen', (tester) async {
    await app.main();

    final offline = find.text(offlineStripText);
    for (var i = 0; i < 60 && offline.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(offline, findsOneWidget);
    expect(Directionality.of(tester.element(offline)), TextDirection.rtl);
    // Background playback: the media service, activity and permissions in
    // AndroidManifest.xml are wired correctly, or AudioService.init throws.
    expect(activeMediaSession, isNotNull);
  });
}
