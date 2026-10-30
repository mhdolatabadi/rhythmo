import 'package:rhythmo/core/api/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/bale_archive/bale_archive.dart';
import 'package:rhythmo/features/bale_archive/bale_archive_screen.dart';

class _ArchiveApi implements BaleArchiveApi {
  final imported = <BaleLecture>[];
  final cursors = <int?>[];
  Object? previewError;
  int? failAt;
  bool emptyPreview = false;
  List<BaleArchiveJob> jobs = [];
  @override
  Future<BaleArchivePage> previewBaleArchive(
    String token, {
    int? before,
  }) async {
    cursors.add(before);
    if (previewError != null && (failAt == null || failAt == cursors.length)) {
      throw previewError!;
    }
    if (emptyPreview) return const BaleArchivePage([], 1234, false);
    return const BaleArchivePage(
      [
        BaleLecture(
          id: '13',
          date: 1234,
          title: 'مهدویت؛ جلسه سیزدهم',
          topic: 'مهدویت',
          session: 13,
          needsReview: false,
        ),
        BaleLecture(
          id: '1',
          date: 1235,
          title: 'فاطمیه؛ جلسه اول',
          topic: 'فاطمیه',
          session: 1,
          needsReview: false,
        ),
        BaleLecture(
          id: '2',
          date: 1236,
          title: 'مهدویت؛ جلسه دوم',
          topic: 'مهدویت',
          session: 2,
          needsReview: false,
        ),
        BaleLecture(
          id: '4',
          date: 1237,
          title: '',
          topic: '',
          session: 0,
          needsReview: true,
        ),
      ],
      1234,
      false,
    );
  }

  @override
  Future<BaleArchiveJob> importBaleLecture(
    String token,
    BaleLecture lecture,
  ) async {
    imported.add(lecture);
    return BaleArchiveJob(lecture.id, 'queued', 'lecture.mp3', null);
  }

  @override
  Future<List<BaleArchiveJob>> baleArchiveJobs(String token) async => jobs;
}

void main() {
  testWidgets('separate topics, ordered sessions, review and narrow layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _ArchiveApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: BaleArchiveScreen(api: api, token: () => 'token'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('مهدویت'), findsOneWidget);
    expect(find.text('فاطمیه'), findsOneWidget);
    final second = tester.getTopLeft(find.text('مهدویت؛ جلسه دوم'));
    final thirteenth = tester.getTopLeft(find.text('مهدویت؛ جلسه سیزدهم'));
    expect(second.dy, lessThan(thirteenth.dy));
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(FilledButton, 'واردکردن').first);
    await tester.pumpAndSettle();
    expect(api.imported.single.session, 2);
    expect(api.imported.single.topic, 'مهدویت');
    expect(tester.takeException(), isNull);
    // Dispose the timer even if the app isn't navigated away during the test.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'reopening restores topic groups even when preview is rate limited',
      (tester) async {
    final api = _ArchiveApi()
      ..previewError = const ApiException('limited',
          statusCode: 429,
          code: 'rate_limited',
          details: {'retryAfterSeconds': 60})
      ..jobs = const [
        BaleArchiveJob('a', 'done', 'raw-13.mp3', null,
            messageId: '13',
            date: 1234,
            title: 'مهدویت؛ جلسه سیزدهم',
            topic: 'مهدویت',
            session: 13),
        BaleArchiveJob('b', 'done', 'raw-2.mp3', null,
            messageId: '2',
            date: 1235,
            title: 'مهدویت؛ جلسه دوم',
            topic: 'مهدویت',
            session: 2),
      ];
    await tester.pumpWidget(
        MaterialApp(home: BaleArchiveScreen(api: api, token: () => 'token')));
    await tester.pumpAndSettle();
    expect(find.text('مهدویت'), findsOneWidget);
    expect(find.text('raw-13.mp3'), findsNothing);
    expect(find.textContaining('در این بخش از تاریخچه'), findsNothing);
    expect(find.text('وارد شد'), findsNWidgets(2));
    expect(tester.getTopLeft(find.text('مهدویت؛ جلسه دوم')).dy,
        lessThan(tester.getTopLeft(find.text('مهدویت؛ جلسه سیزدهم')).dy));
    final retry = find.ancestor(
        of: find.textContaining('تلاش دوباره در '),
        matching: find.byType(TextButton));
    expect(retry, findsOneWidget);
    expect(tester.widget<TextButton>(retry).onPressed, isNull);
    expect(api.cursors, [null]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed history request retains cursor and retries the same page',
      (tester) async {
    final api = _ArchiveApi()
      ..emptyPreview = true
      ..failAt = 2
      ..previewError =
          const ApiException('unavailable', code: 'archive_unavailable');
    await tester.pumpWidget(
        MaterialApp(home: BaleArchiveScreen(api: api, token: () => 'token')));
    await tester.pumpAndSettle();
    expect(find.textContaining('در این بخش از تاریخچه'), findsOneWidget);
    await tester.tap(find.text('بررسی پست‌های قدیمی‌تر'));
    await tester.pumpAndSettle();
    expect(find.textContaining('در این بخش از تاریخچه'), findsNothing);
    expect(find.text('تلاش دوباره'), findsOneWidget);
    api.previewError = null;
    await tester.tap(find.text('تلاش دوباره'));
    await tester.pumpAndSettle();
    expect(api.cursors, [null, 1234, 1234]);
    expect(find.textContaining('در این بخش از تاریخچه'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('Bale post IDs stay strings, including negative 64-bit values', () {
    final page = BaleArchivePage.fromJson({
      'entries': [
        {
          'id': '-5951363129833672291',
          'date': 1793266150479,
          'title': 'عنوان',
          'topic': 'فاطمیه',
          'session': 5,
          'needsReview': false,
        },
      ],
      'nextBefore': 1793266150479,
      'done': false,
    });
    expect(page.entries.single.id, '-5951363129833672291');
    expect(page.entries.single.session, 5);
  });
}
