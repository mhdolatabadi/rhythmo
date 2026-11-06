import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';
import 'package:rhythmo/features/playlists/presentation/playlists_screen.dart';

Playlist _playlist({required bool public, int count = 24}) => Playlist(
      id: 'p',
      name: 'شب‌های بی‌خواب',
      trackCount: count,
      tracks: const [],
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      isPublic: public,
    );

void main() {
  Future<void> pump(WidgetTester tester, Playlist playlist) =>
      tester.pumpWidget(MaterialApp(
        theme: RhythmoTheme.dark(),
        home: Scaffold(body: PlaylistPrivacyLine(playlist: playlist)),
      ));

  testWidgets('a public playlist says so with a globe (#445)', (tester) async {
    await pump(tester, _playlist(public: true));
    expect(find.text('عمومی · ۲۴ آهنگ'), findsOneWidget);
    expect(find.byIcon(RhythmoIcons.globe), findsOneWidget);
  });

  testWidgets('a private playlist says so with a lock (#445)', (tester) async {
    await pump(tester, _playlist(public: false, count: 3));
    expect(find.text('خصوصی · ۳ آهنگ'), findsOneWidget);
    expect(find.byIcon(RhythmoIcons.lockSimple), findsOneWidget);
  });
}
