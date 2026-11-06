import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/admin/data/admin_song_reports.dart';
import 'package:rhythmo/features/admin/presentation/song_reports_screen.dart';
import 'package:rhythmo/features/library/data/track.dart';

class ReportsApi implements AdminSongReportsApi {
  final decisions = <bool>[];
  @override
  Future<List<AdminSongReport>> songReports(String token) async => [
        const AdminSongReport(
            track: Track(
                id: 'entry',
                title: 'آهنگ گزارش‌شده',
                contentType: 'audio/mpeg',
                sizeBytes: 1,
                fromStore: true),
            reason: 'wrong_info',
            count: 2,
            details: 'خواننده نادرست است')
      ];
  @override
  Future<void> moderateSong(String token, String entryId,
      {required bool remove}) async {
    decisions.add(remove);
  }
}

void main() {
  testWidgets('admin reports show details and require confirmation to remove',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = ReportsApi();
    await tester.pumpWidget(MaterialApp(
        home: Directionality(
            textDirection: TextDirection.rtl,
            child: SongReportsScreen(api: api, token: () => 'admin'))));
    await tester.pumpAndSettle();
    expect(find.text('خواننده نادرست است'), findsOneWidget);
    await tester.tap(find.text('حذف از استور و فهرست‌ها'));
    await tester.pumpAndSettle();
    expect(api.decisions, isEmpty);
    await tester
        .tap(find.widgetWithText(FilledButton, 'حذف از استور و فهرست‌ها'));
    await tester.pumpAndSettle();
    expect(api.decisions, [true]);
    expect(find.text('گزارش بازی وجود ندارد.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
