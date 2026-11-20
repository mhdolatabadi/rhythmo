import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_configuration.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/admin/data/admin_account.dart';
import 'package:rhythmo/features/admin/data/admin_profile_reports.dart';
import 'package:rhythmo/features/admin/presentation/profile_reports_screen.dart';
import 'package:rhythmo/features/social/data/social.dart';
import 'package:rhythmo/features/social/presentation/friends_feed_screen.dart';
import 'package:rhythmo/features/social/presentation/profile_edit_screen.dart';
import 'package:rhythmo/features/social/presentation/profile_screen.dart';
import 'package:rhythmo/features/social/presentation/social_scope.dart';

class FakeProfileReports implements AdminProfileReportsApi {
  List<ProfileReport> reports = const [
    ProfileReport(
        userId: 'u1',
        handle: 'spammer',
        displayName: 'تبلیغ',
        bio: 'خرید فالوور',
        reason: 'spam',
        reports: 3),
  ];
  final resolved = <String, bool>{};

  @override
  Future<List<ProfileReport>> listProfileReports(String token) async => reports;

  @override
  Future<void> resolveProfileReports(String token, String userId,
          {required bool hide}) async =>
      resolved[userId] = hide;
}

class FakeSocialApi implements SocialApi {
  MyProfile mine = const MyProfile();
  final profiles = <String, PublicProfile>{};
  final follows = <String, bool>{};
  final blocks = <String, bool>{};
  final reports = <String>[];
  List<FeedPage> pages = const [];
  final feedCursors = <String?>[];
  bool failFollow = false;
  String? updateError;
  ({String handle, bool public, bool hideActivity, String bio})? lastUpdate;

  @override
  Future<MyProfile> myProfile(String token) async => mine;

  @override
  Future<MyProfile> updateProfile(String token,
      {required String handle,
      required String displayName,
      required String bio,
      required bool public,
      required bool hideActivity}) async {
    if (updateError case final code?) {
      throw ApiException('refused', statusCode: 409, code: code);
    }
    lastUpdate =
        (handle: handle, public: public, hideActivity: hideActivity, bio: bio);
    return mine = MyProfile(
        handle: handle,
        displayName: displayName,
        bio: bio,
        public: public,
        hideActivity: hideActivity,
        review: public ? 'pending' : null);
  }

  @override
  Future<MyProfile> setAvatar(String token, Uint8List image) async => mine;

  @override
  Future<void> deleteAvatar(String token) async {}

  @override
  Future<PublicProfile> profile(String? token, String handle) async {
    final found = profiles[handle];
    if (found == null) {
      throw const ApiException('missing', statusCode: 404, code: 'not_found');
    }
    return found;
  }

  @override
  Future<void> setFollowing(String token, String handle, bool follow) async {
    if (failFollow) throw const ApiException('down', statusCode: 500);
    follows[handle] = follow;
  }

  @override
  Future<void> setBlocked(String token, String handle, bool block) async =>
      blocks[handle] = block;

  @override
  Future<void> report(String token, String handle, ProfileReportReason reason,
          {String? details}) async =>
      reports.add('$handle:${reason.code}');

  @override
  Future<List<({String handle, String displayName})>> blocked(
          String token) async =>
      const [];

  @override
  Future<FeedPage> feed(String token, {String? before}) async {
    feedCursors.add(before);
    return pages[feedCursors.length - 1];
  }

  @override
  Uri resolve(String path) => Uri.parse('https://rhythmo.test').resolve(path);
}

const _sara = PublicProfile(
  handle: 'sara',
  displayName: 'سارا',
  bio: 'موسیقی سنتی',
  followers: 2,
  following: 1,
  playlists: [ProfilePlaylist(shareToken: 'tok1', name: 'شب', trackCount: 3)],
);

Social _social(FakeSocialApi api,
        {String? token = 'token', List<String>? opened}) =>
    Social(
      api: api,
      token: () => token,
      openPlaylist: (_, shareToken) => opened?.add(shareToken),
      openSong: (_, entryId) => opened?.add('song:$entryId'),
    );

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(360, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('fa'),
    supportedLocales: const [Locale('fa')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: RhythmoTheme.dark(),
    home: home,
  ));
  await tester.pumpAndSettle();
}

void main() {
  test('profiles and feed items read the server JSON', () {
    final profile = PublicProfile.fromJson({
      'handle': 'sara',
      'displayName': 'سارا',
      'avatarUrl': '/api/v1/users/sara/avatar?v=1',
      'followers': 3,
      'isFollowing': true,
      'playlists': [
        {'shareToken': 't', 'name': 'شب', 'trackCount': 2}
      ],
    });
    expect(profile.isFollowing, isTrue);
    expect(profile.playlists.single.trackCount, 2);
    expect(MyProfile.fromJson({'review': 'pending', 'public': true}).pending,
        isTrue);
    expect(
        FeedItem.fromJson({
          'kind': 'like',
          'at': '2026-11-14T01:00:00Z',
          'actorHandle': 'sara',
          'name': 'باران',
          'entryId': 'e1',
        })?.kind,
        FeedKind.like);
    expect(
        FeedItem.fromJson({
          'kind': 'unknown',
          'at': '2026-11-14T01:00:00Z',
          'actorHandle': 'x'
        }),
        isNull);
  });

  test('a profile link opens the profile once', () {
    AppConfiguration.openLink(Uri.parse('https://rhythmo.ir/u/Sara'));
    expect(AppConfiguration.takeInitialProfileHandle(), 'sara');
    expect(AppConfiguration.takeInitialProfileHandle(), isNull);
    AppConfiguration.openLink(Uri.parse('https://rhythmo.ir/u/a'));
    expect(AppConfiguration.takeInitialProfileHandle(), isNull);
  });

  testWidgets('following a profile on a narrow phone, and undoing a failure',
      (tester) async {
    final api = FakeSocialApi()..profiles['sara'] = _sara;
    final opened = <String>[];
    await _pump(tester,
        ProfileScreen(handle: 'sara', social: _social(api, opened: opened)));

    expect(find.text('سارا'), findsOneWidget);
    expect(find.text('۲ دنبال‌کننده · ۱ دنبال‌شده'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('دنبال کن'));
    await tester.pumpAndSettle();
    expect(api.follows['sara'], isTrue);
    expect(find.text('دنبال می‌کنی'), findsOneWidget);
    expect(find.text('۳ دنبال‌کننده · ۱ دنبال‌شده'), findsOneWidget);

    api.failFollow = true;
    await tester.tap(find.text('دنبال می‌کنی'));
    await tester.pumpAndSettle();
    expect(find.text('دنبال می‌کنی'), findsOneWidget,
        reason: 'a refused unfollow is undone');
    expect(find.text('لغو دنبال کردن ناموفق بود.'), findsOneWidget);

    await tester.tap(find.text('شب'));
    expect(opened, ['tok1']);
  });

  testWidgets('blocking and reporting from the menu', (tester) async {
    final api = FakeSocialApi()..profiles['sara'] = _sara;
    await _pump(tester, ProfileScreen(handle: 'sara', social: _social(api)));

    await tester.tap(find.byTooltip('بیشتر'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('گزارش'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('جعل هویت'));
    await tester.pumpAndSettle();
    expect(api.reports, ['sara:impersonation']);

    await tester.tap(find.byTooltip('بیشتر'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('مسدود کن'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'مسدود کن'));
    await tester.pumpAndSettle();
    expect(api.blocks['sara'], isTrue);
    expect(find.text('رفع مسدودی'), findsOneWidget);
    expect(find.text('دنبال کن'), findsNothing);
  });

  testWidgets('a guest sees the profile without follow or menu',
      (tester) async {
    final api = FakeSocialApi()..profiles['sara'] = _sara;
    await _pump(tester,
        ProfileScreen(handle: 'sara', social: _social(api, token: null)));
    expect(find.byTooltip('بیشتر'), findsNothing);
    await tester.tap(find.text('دنبال کن'));
    await tester.pumpAndSettle();
    expect(find.text('برای این کار وارد حسابت شو.'), findsOneWidget);
    expect(api.follows, isEmpty);
  });

  testWidgets('a missing profile says so', (tester) async {
    await _pump(tester,
        ProfileScreen(handle: 'gone', social: _social(FakeSocialApi())));
    expect(find.text('این نمایه پیدا نشد'), findsOneWidget);
  });

  testWidgets('editing the profile checks the handle first', (tester) async {
    final api = FakeSocialApi();
    await _pump(tester, ProfileEditScreen(social: _social(api)));

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('ذخیره'));
    await tester.pumpAndSettle();
    expect(find.text('برای نمایه‌ی عمومی یک شناسه لازم است.'), findsOneWidget);
    expect(api.lastUpdate, isNull);

    await tester.enterText(find.widgetWithText(TextField, 'شناسه'), 'ab');
    await tester.tap(find.text('ذخیره'));
    await tester.pumpAndSettle();
    expect(find.textContaining('۳ تا ۲۰ حرف'), findsOneWidget);

    api.updateError = 'handle_taken';
    await tester.enterText(find.widgetWithText(TextField, 'شناسه'), '@Sara');
    await tester.tap(find.text('ذخیره'));
    await tester.pumpAndSettle();
    expect(find.text('این شناسه را کس دیگری برداشته.'), findsOneWidget);

    api.updateError = null;
    await tester.tap(find.text('ذخیره'));
    await tester.pumpAndSettle();
    expect(api.lastUpdate?.handle, 'sara');
    expect(api.lastUpdate?.public, isTrue);
    expect(find.textContaining('در انتظار بررسی'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the friends feed pages and opens what it shows', (tester) async {
    final api = FakeSocialApi()
      ..pages = [
        FeedPage([
          FeedItem(
              kind: FeedKind.playlist,
              at: DateTime.utc(2026, 11, 14),
              actorHandle: 'sara',
              actorName: 'سارا',
              name: 'شب',
              shareToken: 'tok1'),
        ], 'cursor1'),
        FeedPage([
          FeedItem(
              kind: FeedKind.like,
              at: DateTime.utc(2026, 11, 13),
              actorHandle: 'sara',
              actorName: 'سارا',
              name: 'باران',
              entryId: 'e1',
              artist: 'شجریان'),
        ], null),
      ];
    final opened = <String>[];
    await _pump(
        tester, FriendsFeedScreen(social: _social(api, opened: opened)));

    expect(find.text('سارا فهرست پخش عمومی ساخت'), findsOneWidget);
    await tester.tap(find.text('بیشتر'));
    await tester.pumpAndSettle();
    expect(api.feedCursors, [null, 'cursor1']);
    expect(find.text('سارا پسندید · شجریان'), findsOneWidget);
    expect(find.text('بیشتر'), findsNothing);

    await tester.tap(find.text('شب'));
    await tester.tap(find.text('باران'));
    expect(opened, ['tok1', 'song:e1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty feed invites to find people', (tester) async {
    final api = FakeSocialApi()..pages = [const FeedPage([], null)];
    await _pump(tester, FriendsFeedScreen(social: _social(api)));
    expect(find.text('هنوز خبری نیست'), findsOneWidget);
    expect(find.text('پیدا کردن با شناسه'), findsOneWidget);
  });

  test('a pending profile is its own kind in the review queue', () {
    final item = PendingPublication.fromJson({
      'kind': 'profile',
      'id': 'u1',
      'title': 'سارا',
      'handle': 'sara',
      'bio': 'سلام',
      'ownerEmail': 'sara@example.com',
      'requestedAt': '2026-11-14T00:00:00Z',
    });
    expect(item.kind, PublicationKind.profile);
    expect(item.handle, 'sara');
  });

  testWidgets('an admin takes a reported profile down', (tester) async {
    final api = FakeProfileReports();
    await _pump(tester, ProfileReportsScreen(api: api, token: () => 'admin'));
    expect(find.text('هرزنامه یا تبلیغ · ۳ گزارش'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'پایین بیاور'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'پایین بیاور').last);
    await tester.pumpAndSettle();
    expect(api.resolved, {'u1': true});
    expect(find.text('گزارشی باز نیست.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
