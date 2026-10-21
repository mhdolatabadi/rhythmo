import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/feedback/feedback_api.dart';
import 'package:rhythmo/features/feedback/feedback_screen.dart';

class FeedbackFake implements FeedbackApi {
  String? subject;
  bool resolved = false;
  @override
  Future<void> submitFeedback(
      String token, String kind, String subject, String body) async {
    this.subject = subject;
  }

  @override
  Future<List<Map<String, dynamic>>> feedbackInbox(String token) async => [
        {
          'id': 'one',
          'kind': 'bug',
          'subject': 'مشکل پخش',
          'email': 'member@example.com',
          'body': 'پخش متوقف می‌شود',
          'created_at': '2026-10-21T00:00:00Z'
        }
      ];
  @override
  Future<void> resolveFeedback(String token, String id) async {
    resolved = true;
  }
}

void main() {
  testWidgets('narrow RTL feedback form validates and retains text',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FeedbackFake();
    await tester.pumpWidget(MaterialApp(
        home: Directionality(
            textDirection: TextDirection.rtl,
            child: FeedbackScreen(api: api, token: () => 'member'))));
    await tester.ensureVisible(find.text('ارسال برای مدیر'));
    await tester.tap(find.text('ارسال برای مدیر'));
    await tester.pumpAndSettle();
    expect(find.text('موضوع را بنویس.'), findsOneWidget);
    expect(api.subject, isNull);
    await tester.enterText(find.byType(TextFormField).first, 'مشکل پخش');
    await tester.enterText(
        find.byType(TextFormField).last, 'پس از انتخاب آهنگ');
    expect(find.text('پس از انتخاب آهنگ'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('admin reads and resolves a message', (tester) async {
    final api = FeedbackFake();
    await tester.pumpWidget(MaterialApp(
        home: FeedbackScreen(api: api, token: () => 'admin', admin: true)));
    await tester.pumpAndSettle();
    expect(find.text('member@example.com'), findsOneWidget);
    await tester.tap(find.text('رسیدگی شد'));
    await tester.pumpAndSettle();
    expect(api.resolved, isTrue);
    expect(find.text('پیام بازی وجود ندارد.'), findsOneWidget);
  });
}
