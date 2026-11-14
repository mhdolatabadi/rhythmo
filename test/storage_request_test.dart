import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/admin/presentation/storage_requests_screen.dart';
import 'package:rhythmo/features/settings/application/storage_request_controller.dart';
import 'package:rhythmo/features/settings/data/storage_request.dart';
import 'package:rhythmo/features/settings/presentation/storage_request_section.dart';

const gib = 1 << 30;

class FakeStorageRequests implements StorageRequestApi {
  StorageRequest? latest;
  final asked = <(int, String)>[];
  final decisions = <(bool, int, String)>[];
  ApiException? failure;

  @override
  Future<StorageRequest?> myStorageRequest(String token) async => latest;

  @override
  Future<StorageRequest> requestStorage(String token, int bytes,
      {String reason = ''}) async {
    if (failure case final failure?) throw failure;
    asked.add((bytes, reason));
    return latest = StorageRequest(
        id: 'r1',
        requestedBytes: bytes,
        status: 'pending',
        reason: reason,
        createdAt: DateTime(2026));
  }

  @override
  Future<List<PendingStorageRequest>> pendingStorageRequests(
          String token) async =>
      decisions.isNotEmpty
          ? []
          : [
              PendingStorageRequest(
                request: StorageRequest(
                    id: 'r1',
                    requestedBytes: 5 * gib,
                    status: 'pending',
                    reason: 'آرشیو کنسرت‌ها',
                    createdAt: DateTime(2026)),
                accountId: 'a1',
                email: 'member@example.com',
                usedBytes: gib,
                quotaBytes: gib,
              )
            ];

  @override
  Future<void> decideStorageRequest(String token, String id,
      {required bool approved, int bytes = 0, String reason = ''}) async {
    decisions.add((approved, bytes, reason));
  }
}

Widget app(Widget child) => MaterialApp(
    home: Directionality(
        textDirection: TextDirection.rtl, child: Scaffold(body: child)));

void main() {
  testWidgets('asks for more storage and shows it pending', (tester) async {
    final api = FakeStorageRequests();
    final controller = StorageRequestController(api: api, token: () => 't');
    await tester.pumpWidget(
        app(StorageRequestSection(controller: controller, limitBytes: gib)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('درخواست فضای بیشتر'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('۵.۰ گیگابایت'));
    await tester.enterText(find.byType(TextField), 'پادکست');
    await tester.tap(find.text('فرستادن درخواست'));
    await tester.pumpAndSettle();
    expect(api.asked, [(5 * gib, 'پادکست')]);
    expect(find.textContaining('در حال بررسی است'), findsOneWidget);
    expect(find.text('درخواست فضای بیشتر'), findsNothing);
  });

  testWidgets('shows why a request was turned down', (tester) async {
    final api = FakeStorageRequests()
      ..latest = StorageRequest(
          id: 'r1',
          requestedBytes: 2 * gib,
          status: 'rejected',
          decisionReason: 'فعلاً فضای کافی نداریم',
          createdAt: DateTime(2026));
    final controller = StorageRequestController(api: api, token: () => 't');
    await tester.pumpWidget(
        app(StorageRequestSection(controller: controller, limitBytes: gib)));
    await tester.pumpAndSettle();
    expect(find.textContaining('فعلاً فضای کافی نداریم'), findsOneWidget);
    expect(find.text('درخواست فضای بیشتر'), findsOneWidget);
  });

  test('explains an unverified email', () async {
    final api = FakeStorageRequests()
      ..failure =
          const ApiException('no', statusCode: 403, code: 'email_unverified');
    final controller = StorageRequestController(api: api, token: () => 't');
    expect(await controller.request(2 * gib), isFalse);
    expect(controller.error, contains('ایمیلت را تأیید کن'));
  });

  testWidgets('admin approves with an amount', (tester) async {
    final api = FakeStorageRequests();
    await tester
        .pumpWidget(app(StorageRequestsScreen(api: api, token: () => 'admin')));
    await tester.pumpAndSettle();
    expect(find.text('member@example.com'), findsOneWidget);
    expect(find.text('آرشیو کنسرت‌ها'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'پذیرفتن'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('storage-grant-gib')), '1');
    await tester.pump();
    expect(find.textContaining('باید از'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('storage-grant-gib')), '3');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'پذیرفتن').last);
    await tester.pumpAndSettle();
    expect(api.decisions, [(true, 3 * gib, '')]);
    expect(find.text('درخواستی در انتظار نیست.'), findsOneWidget);
  });

  testWidgets('admin rejects with a reason', (tester) async {
    final api = FakeStorageRequests();
    await tester
        .pumpWidget(app(StorageRequestsScreen(api: api, token: () => 'admin')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('رد'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('storage-reject-reason')), 'سهمیه تمام شد');
    await tester.tap(find.text('رد درخواست').last);
    await tester.pumpAndSettle();
    expect(api.decisions, [(false, 0, 'سهمیه تمام شد')]);
  });
}
