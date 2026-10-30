import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/bale_archive/bale_archive.dart';
import 'package:rhythmo/features/bale_archive/bale_archive_screen.dart';

class _ArchiveApi implements BaleArchiveApi {
  final imported = <BaleLecture>[];
  @override
  Future<BaleArchivePage> previewBaleArchive(
    String token, {
    int? before,
  }) async =>
      const BaleArchivePage(
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
  @override
  Future<BaleArchiveJob> importBaleLecture(
    String token,
    BaleLecture lecture,
  ) async {
    imported.add(lecture);
    return BaleArchiveJob(lecture.id, 'queued', 'lecture.mp3', null);
  }

  @override
  Future<List<BaleArchiveJob>> baleArchiveJobs(String token) async => [];
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
