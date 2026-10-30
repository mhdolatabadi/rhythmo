import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/bale_archive/bale_archive.dart';
import 'package:rhythmo/features/bale_archive/bale_archive_screen.dart';

const _topic = BaleTopic(
    key: 'مهدویت',
    name: 'ما و حضرت ولی‌عصر',
    total: 13,
    imported: 2,
    pending: 0,
    failed: 0,
    state: 'partial');

class _TopicsApi implements BaleTopicCatalogApi {
  final requested = <String>[];
  Object? error;
  bool scanning = false;
  int refreshes = 0;
  List<BaleTopic> topics = const [
    _topic,
    BaleTopic(
        key: 'فاطمیه',
        name: 'فاطمیه دقیقاً چیست؟',
        total: 5,
        imported: 5,
        pending: 0,
        failed: 0,
        state: 'imported')
  ];
  @override
  Future<BaleTopicCatalog> baleTopics(String token) async {
    if (error != null) throw error!;
    return BaleTopicCatalog(
        topics: topics,
        scanState: scanning ? 'scanning' : 'done',
        scannedPosts: 12345,
        unclassified: 0);
  }

  @override
  Future<void> refreshBaleTopics(String token) async {
    refreshes++;
    scanning = true;
  }

  @override
  Future<void> importBaleTopic(String token, String key) async {
    requested.add(key);
    topics = [
      for (final t in topics)
        if (t.key == key)
          BaleTopic(
              key: t.key,
              name: t.name,
              total: t.total,
              imported: t.imported,
              pending: 1,
              failed: 0,
              state: 'importing')
        else
          t
    ];
  }
}

void main() {
  testWidgets(
      'all topics, previous imports and one-click whole-topic request on narrow screen',
      (tester) async {
    tester.view.physicalSize = const Size(360, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _TopicsApi();
    await tester.pumpWidget(MaterialApp(
        home: Directionality(
            textDirection: TextDirection.rtl,
            child: BaleArchiveScreen(api: api, token: () => 'token'))));
    await tester.pumpAndSettle();
    expect(find.text('ما و حضرت ولی‌عصر'), findsOneWidget);
    expect(find.text('فاطمیه دقیقاً چیست؟'), findsOneWidget);
    expect(find.text('قبلاً کامل وارد شده'), findsOneWidget);
    expect(find.textContaining('۱۳ جلسه · ۲ واردشده'), findsOneWidget);
    await tester.tap(find.text('واردکردن جلسه‌های باقی‌مانده'));
    await tester.pumpAndSettle();
    expect(api.requested, ['مهدویت']);
    expect(find.text('در حال واردکردن کامل موضوع'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'scan is explicitly incomplete and does not require manual pagination',
      (tester) async {
    final api = _TopicsApi()..scanning = true;
    await tester.pumpWidget(
        MaterialApp(home: BaleArchiveScreen(api: api, token: () => 'token')));
    await tester.pumpAndSettle();
    expect(find.textContaining('در حال بررسی کل تاریخچه'), findsOneWidget);
    expect(find.textContaining('فهرست موضوع‌ها کامل است'), findsNothing);
    expect(find.text('بررسی پست‌های قدیمی‌تر'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('failed catalog read never claims there are no topics',
      (tester) async {
    final api = _TopicsApi()
      ..error = const ApiException('limited',
          code: 'rate_limited',
          statusCode: 429,
          details: {'retryAfterSeconds': 60});
    await tester.pumpWidget(
        MaterialApp(home: BaleArchiveScreen(api: api, token: () => 'token')));
    await tester.pumpAndSettle();
    expect(find.textContaining('محدودیت درخواست'), findsOneWidget);
    expect(find.textContaining('موضوعی پیدا نشد'), findsNothing);
    final retry = find.ancestor(
        of: find.textContaining('تلاش دوباره در '),
        matching: find.byType(TextButton));
    expect(tester.widget<TextButton>(retry).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });
  test(
      'catalog metadata records completed, partial and newly discovered sessions',
      () {
    final result = BaleTopicCatalog.fromJson({
      'scan': {'state': 'done', 'scannedPosts': 12500, 'unclassified': 2},
      'topics': [
        {
          'key': 'موضوع',
          'name': 'موضوع',
          'total': 10,
          'imported': 9,
          'pending': 0,
          'failed': 0,
          'state': 'partial'
        }
      ]
    });
    expect(result.complete, isTrue);
    expect(result.topics.single.total - result.topics.single.imported, 1);
    expect(result.unclassified, 2);
  });
}
