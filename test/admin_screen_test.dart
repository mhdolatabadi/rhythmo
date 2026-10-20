import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/admin/data/admin_account.dart';
import 'package:rhythmo/features/admin/presentation/admin_screen.dart';
import 'package:rhythmo/features/admin/presentation/publication_review_screen.dart';
import 'package:rhythmo/features/auth/data/auth_models.dart';

class FakeAdminApi implements AdminApi {
  bool verified = false;
  bool fail = false;
  bool denied = false;
  String query = '';

  AdminAccount get account => AdminAccount(
        user: AuthUser(
            id: 'account', email: 'member@example.com', verified: verified),
        createdAt: DateTime(2026),
      );

  @override
  Future<AdminAccountPage> listAccounts(String token,
      {String query = '', int offset = 0}) async {
    this.query = query;
    if (denied) throw const ApiException('denied', statusCode: 403);
    return (accounts: [account], hasMore: false);
  }

  List<PendingPublication> pending = [];
  final reviews = <String>[];
  int? reviewStatus;

  @override
  Future<List<PendingPublication>> listPendingPublications(String token) async {
    if (denied) throw const ApiException('denied', statusCode: 403);
    return pending;
  }

  @override
  Future<void> reviewPublication(
      String token, PendingPublication publication, bool approved) async {
    if (reviewStatus case final status?) {
      throw ApiException('failed', statusCode: status);
    }
    reviews.add('${approved ? 'approve' : 'reject'}:${publication.id}');
  }

  @override
  Future<AdminAccount> setAccountVerification(
      String token, String accountId, bool verified) async {
    if (fail) throw const ApiException('unavailable', statusCode: 500);
    this.verified = verified;
    return account;
  }
}

void main() {
  Future<void> pump(WidgetTester tester, FakeAdminApi api) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('fa'),
      supportedLocales: const [Locale('fa')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: RhythmoTheme.dark(),
      home: AdminScreen(api: api, token: () => 'token'),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('search, confirmation, verification and revoke', (tester) async {
    final api = FakeAdminApi();
    await pump(tester, api);
    await tester.enterText(find.byType(TextField), 'member');
    await tester.tap(find.text('جست‌وجو'));
    await tester.pumpAndSettle();
    expect(api.query, 'member');
    await tester.tap(find.text('تأیید حساب'));
    await tester.pumpAndSettle();
    expect(api.verified, isFalse);
    await tester.tap(find.text('تأیید حساب').last);
    await tester.pumpAndSettle();
    expect(api.verified, isTrue);
    expect(find.text('حساب تأییدشده'), findsOneWidget);
    await tester.tap(find.text('لغو تأیید'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('لغو تأیید').last);
    await tester.pumpAndSettle();
    expect(api.verified, isFalse);
  });

  testWidgets('failed verification preserves displayed state', (tester) async {
    final api = FakeAdminApi()..fail = true;
    await pump(tester, api);
    await tester.tap(find.text('تأیید حساب'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تأیید حساب').last);
    await tester.pumpAndSettle();
    expect(api.verified, isFalse);
    expect(find.text('تأیید نشده'), findsOneWidget);
    expect(find.text('تغییر ذخیره نشد. دوباره تلاش کن.'), findsOneWidget);
  });

  testWidgets('forbidden directory hides accounts', (tester) async {
    await pump(tester, FakeAdminApi()..denied = true);
    expect(find.text('member@example.com'), findsNothing);
    expect(find.text('دسترسی مدیریت نداری. دوباره وارد حساب مدیر شو.'),
        findsOneWidget);
  });

  testWidgets('narrow screen clears insets and keeps 48px actions',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.reset);
    await pump(tester, FakeAdminApi());
    await tester.ensureVisible(find.text('تأیید حساب'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final button = find.ancestor(
        of: find.text('تأیید حساب'), matching: find.byType(OutlinedButton));
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    expect(tester.getRect(button).right, lessThanOrEqualTo(336));
  });

  group('publication review', () {
    PendingPublication item(String id, PublicationKind kind, String title) =>
        PendingPublication(
          kind: kind,
          id: id,
          title: title,
          artist: kind == PublicationKind.track ? 'خواننده' : null,
          trackCount: 3,
          ownerEmail: 'member@example.com',
          requestedAt: DateTime(2026),
        );

    Future<void> pumpReview(WidgetTester tester, FakeAdminApi api) async {
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('fa'),
        supportedLocales: const [Locale('fa')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: RhythmoTheme.dark(),
        home: PublicationReviewScreen(api: api, token: () => 'token'),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('the admin screen opens the review queue', (tester) async {
      await pump(tester, FakeAdminApi());
      await tester.tap(find.byTooltip('درخواست‌های انتشار'));
      await tester.pumpAndSettle();
      expect(find.text('درخواستی در انتظار نیست.'), findsOneWidget);
    });

    testWidgets('approves and rejects pending requests', (tester) async {
      final api = FakeAdminApi()
        ..pending = [
          item('p1', PublicationKind.playlist, 'میکس'),
          item('t1', PublicationKind.track, 'آهنگ تازه'),
        ];
      await pumpReview(tester, api);
      expect(find.text('فهرست پخش · ۳ آهنگ'), findsOneWidget);
      expect(find.text('آهنگ · خواننده'), findsOneWidget);

      await tester.tap(find.text('تأیید و عمومی کردن').first);
      await tester.pumpAndSettle();
      expect(api.reviews, ['approve:p1']);
      expect(find.text('میکس'), findsNothing);
      expect(find.text('«میکس» عمومی شد.'), findsOneWidget);

      await tester.tap(find.text('رد'));
      await tester.pumpAndSettle();
      expect(api.reviews, ['approve:p1', 'reject:t1']);
      expect(find.text('درخواستی در انتظار نیست.'), findsOneWidget);
    });

    testWidgets('a request decided elsewhere leaves the queue', (tester) async {
      final api = FakeAdminApi()
        ..pending = [item('t1', PublicationKind.track, 'آهنگ')]
        ..reviewStatus = 409;
      await pumpReview(tester, api);
      await tester.tap(find.text('تأیید و عمومی کردن'));
      await tester.pumpAndSettle();
      expect(find.text('این درخواست دیگر در انتظار نیست.'), findsOneWidget);
      expect(find.text('آهنگ'), findsNothing);
    });

    testWidgets('a failed decision keeps the request', (tester) async {
      final api = FakeAdminApi()
        ..pending = [item('t1', PublicationKind.track, 'آهنگ')]
        ..reviewStatus = 500;
      await pumpReview(tester, api);
      await tester.tap(find.text('رد'));
      await tester.pumpAndSettle();
      expect(find.text('تصمیم ذخیره نشد. دوباره تلاش کن.'), findsOneWidget);
      expect(find.text('آهنگ'), findsOneWidget);
    });

    testWidgets('narrow screen fits long titles and keeps 48px actions',
        (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewPadding = const FakeViewPadding(bottom: 34);
      addTearDown(tester.view.reset);
      final api = FakeAdminApi()
        ..pending = [
          item('p1', PublicationKind.playlist,
              'یک فهرست پخش با نامی بسیار بلند که باید کوتاه شود ' * 4),
        ];
      await pumpReview(tester, api);
      expect(tester.takeException(), isNull);
      for (final label in ['رد', 'تأیید و عمومی کردن']) {
        final button = find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));
        expect(tester.getSize(button.first).height, greaterThanOrEqualTo(48));
        expect(tester.getRect(button.first).right, lessThanOrEqualTo(336));
      }
    });
  });
}
