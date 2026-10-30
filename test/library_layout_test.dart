import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/features/auth/data/token_store.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/library/presentation/library_screen.dart'
    show libraryTabViewPhysics;
import 'package:rhythmo/main.dart';

import 'cache_controller_test.dart' show FakeAudioCache;
import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi, FakeUploader;
import 'widget_test.dart' show FakeAuthApi, FakePicker;

Future<void> _pump(WidgetTester tester, Size size, List<Track> tracks) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(RhythmoApp(
    healthCheck: () async {},
    authApi: FakeAuthApi(),
    tokenStore: MemoryTokenStore('valid-token'),
    tracksApi: FakeTracksApi(tracks),
    audioEngine: FakeAudioEngine(),
    audioCache: FakeAudioCache(),
    uploader: FakeUploader(),
    picker: FakePicker(null),
  ));
  await tester.pumpAndSettle();
}

void main() {
  for (final size in const [Size(360, 740), Size(1280, 900)]) {
    final label = '${size.width.toInt()} px';

    testWidgets('add button follows the content gutter at $label',
        (tester) async {
      await _pump(tester, size, const []);
      final rect = tester.getRect(find.byType(FloatingActionButton));
      final gutter = size.width >= 900
          ? ((size.width - 880) / 2).clamp(40.0, 10000.0)
          : 16.0;
      expect(rect.left, closeTo(gutter, 1));
      expect(rect.width, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
      // Settings and sign-out live behind «حساب», not in the header.
      expect(find.byTooltip('حساب'), findsOneWidget);
      expect(find.byTooltip('خروج'), findsNothing);
      expect(find.byTooltip('گنجینه'), findsNothing);
    });

    testWidgets('an empty library says what to do at $label', (tester) async {
      await _pump(tester, size, const []);
      expect(tester.takeException(), isNull);
      expect(find.byType(RhythmoStateView), findsWidgets);
      expect(find.text('«موسیقی من» خالی است'), findsOneWidget);
    });

    testWidgets('the mini player never covers the last track at $label',
        (tester) async {
      final tracks = [
        for (var i = 1; i <= 30; i++)
          Track(
            id: 't$i',
            title: 'آهنگ شمارهٔ $i با عنوانی که شاید طولانی باشد',
            artist: 'هنرمند',
            contentType: 'audio/mpeg',
            sizeBytes: 1024 * 1024,
          ),
      ];
      await _pump(tester, size, tracks);
      await tester.tap(find.text(tracks.first.title));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      final last = find.text(tracks.last.title);
      final list = find
          .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down)
          .last;
      await tester.dragUntilVisible(last, list, const Offset(0, -300));
      await tester.drag(list, const Offset(0, -2000));
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);

      final mini = tester.getRect(find.byTooltip('توقف').first);
      final row = tester.getRect(last);
      expect(row.bottom, lessThanOrEqualTo(mini.top),
          reason: 'the last row ends above the mini player');
      if (size.width > RhythmoSpace.pageWidth) {
        // Desktop content keeps away from the window edges.
        expect(row.left, greaterThan(RhythmoSpace.lg));
      }
    });

    testWidgets('search opens its own screen and remembers searches at $label',
        (tester) async {
      await _pump(tester, size, [
        for (final (id, title, artist) in [
          ('a', 'Clair de lune', 'Debussy'),
          ('b', 'Gymnopédie', 'Satie'),
        ])
          Track(
              id: id,
              title: title,
              artist: artist,
              contentType: 'audio/mpeg',
              sizeBytes: 1),
      ]);
      // No search field above the list; a 48 px header button instead.
      expect(find.byType(SearchBar), findsNothing);
      final button = find.byTooltip('جست‌وجو');
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      await tester.tap(button);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'satie');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('Gymnopédie'), findsOneWidget);
      await tester.tap(find.byTooltip('پاک کردن جست‌وجو'));
      await tester.pumpAndSettle();

      // The submitted search is listed; tapping it runs it again.
      expect(find.text('جست‌وجوهای اخیر'), findsOneWidget);
      final recent = find.widgetWithText(ListTile, 'satie');
      expect(tester.getSize(recent).height, greaterThanOrEqualTo(48));
      final remove = find.byTooltip('حذف از جست‌وجوهای اخیر');
      expect(tester.getSize(remove).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
      await tester.tap(recent);
      await tester.pumpAndSettle();
      expect(find.text('Gymnopédie'), findsOneWidget);
      expect(find.text('Clair de lune'), findsNothing);

      // Removing the last one leaves the empty hint.
      await tester.tap(find.byTooltip('پاک کردن جست‌وجو'));
      await tester.pumpAndSettle();
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(find.text('جست‌وجوهای اخیر'), findsNothing);
      expect(find.text('در همهٔ موسیقی‌ات بگرد'), findsOneWidget);
    });

    testWidgets(
        'rows are compact: artist only, no lines between them, '
        'and tabs inside the gutter at $label', (tester) async {
      await _pump(tester, size, [
        for (var i = 1; i <= 3; i++)
          Track(
            id: 't$i',
            title: 'آهنگ $i',
            artist: i == 3 ? null : 'هنرمند $i',
            contentType: 'audio/mpeg',
            sizeBytes: 3 * 1024 * 1024,
          ),
      ]);
      expect(tester.takeException(), isNull);
      expect(find.text('هنرمند 1'), findsOneWidget);
      expect(find.text('خواننده نامشخص'), findsOneWidget);
      expect(find.textContaining('مگابایت'), findsNothing);

      // No lines between rows: artwork and spacing tell them apart.
      expect(
          find.byWidgetPredicate(
              (w) => w is Divider && w.height == 1 && (w.indent ?? 0) > 48),
          findsNothing);

      // Each tab is a 48 px target; its pill stays inside the gutter.
      final gutter = size.width > RhythmoSpace.pageWidth
          ? RhythmoSpace.xxl
          : RhythmoSpace.lg;
      final tab = find.byType(Tab).first;
      expect(tester.getSize(tab).height, 48);
      final bar = tester.getRect(find.byType(TabBar));
      for (final element in find.byType(Tab).evaluate()) {
        final rect = tester.getRect(find.byWidget(element.widget));
        expect(rect.left, greaterThanOrEqualTo(bar.left + gutter - 0.5));
        expect(rect.right, lessThanOrEqualTo(bar.right - gutter + 0.5));
      }
    });
  }

  test('horizontal scrolling switches library tabs on phones, not on web', () {
    expect(libraryTabViewPhysics(isWeb: false), isNull);
    expect(libraryTabViewPhysics(isWeb: true),
        isA<NeverScrollableScrollPhysics>());
  });
}
