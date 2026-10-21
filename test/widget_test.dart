import 'package:flutter/material.dart';
import 'package:rhythmo/app/app_preferences.dart';
import 'package:rhythmo/features/settings/presentation/settings_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/auth/data/auth_models.dart';
import 'package:rhythmo/features/auth/data/token_store.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/library/presentation/track_metadata_editor.dart';
import 'package:rhythmo/features/link_import/data/link_import.dart';
import 'package:rhythmo/features/upload/data/audio_picker.dart';
import 'package:rhythmo/features/upload/data/upload_models.dart';
import 'package:rhythmo/features/library/application/library_controller.dart'
    show importPollDelays;
import 'package:rhythmo/features/player/presentation/mini_player.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/features/playlists/presentation/popular_playlists_screen.dart';
import 'package:rhythmo/features/store/data/store_catalog.dart' show StoreApi;
import 'package:rhythmo/features/store/presentation/store_screen.dart';
import 'package:rhythmo/main.dart';

import 'bot_link_controller_test.dart' show FakeBotsApi, linkedBale;
import 'cache_controller_test.dart' show FakeAudioCache;
import 'player_controller_test.dart' show FakeAudioEngine;
import 'store_test.dart' show FakeStoreApi;
import 'playlist_sharing_test.dart'
    show FakePlaylistsApi, listed, sharedMix, token;
import 'upload_controller_test.dart' show FakeTracksApi, FakeUploader;

const _user = AuthUser(id: 'u1', email: 'listener@example.com');

class FakeAuthApi implements AuthApi {
  FakeAuthApi({this.validToken = 'valid-token', this.meError});

  final String validToken;
  final Object? meError;
  final registered = <String>{};
  final deleted = <String>[];

  @override
  Future<AuthSession> login(String email, String password) async {
    if (email == 'locked@example.com') {
      throw const ApiException('429', statusCode: 429, code: 'rate_limited');
    }
    if (email != _user.email || password != 'correct horse') {
      throw const ApiException('401',
          statusCode: 401, code: 'invalid_credentials');
    }
    return AuthSession(token: validToken, user: _user);
  }

  @override
  Future<AuthSession> register(String email, String password) async {
    if (password == 'password') {
      throw const ApiException('400', statusCode: 400, code: 'weak_password');
    }
    if (!registered.add(email)) {
      throw const ApiException('409', statusCode: 409, code: 'email_taken');
    }
    return AuthSession(
        token: validToken, user: AuthUser(id: 'u2', email: email));
  }

  final revoked = <String>[];

  @override
  Future<AuthSession> revokeSessions(String token) async {
    if (token != validToken) {
      throw const ApiException('401', statusCode: 401, code: 'unauthorized');
    }
    revoked.add(token);
    return const AuthSession(token: 'rotated-token', user: _user);
  }

  @override
  Future<AuthUser> me(String token) async {
    if (meError != null) throw meError!;
    if (token != validToken) {
      throw const ApiException('401', statusCode: 401, code: 'unauthorized');
    }
    return _user;
  }

  @override
  Future<void> deleteAccount(String token, String password) async {
    if (token != validToken) {
      throw const ApiException('401', statusCode: 401, code: 'unauthorized');
    }
    if (password != 'correct horse') {
      throw const ApiException('403',
          statusCode: 403, code: 'invalid_password');
    }
    deleted.add(token);
  }

  @override
  Future<DateTime> sendEmailCode(String token) async =>
      DateTime.now().add(const Duration(minutes: 15));

  @override
  Future<AuthUser> verifyEmail(String token, String code) async =>
      throw const ApiException('404', statusCode: 404);

  @override
  Future<({AuthUser user, bool codeSent})> changeEmail(
          String token, String email) async =>
      throw const ApiException('404', statusCode: 404);
}

class FakePicker implements AudioPicker {
  FakePicker(this.file);

  final PickedAudio? file;

  @override
  Future<PickedAudio?> pick({void Function()? onReading}) async {
    if (file != null) onReading?.call();
    return file;
  }
}

Future<void> _revealSetting(WidgetTester tester, Finder target) async {
  final scrollable = find.descendant(
      of: find.byType(SettingsScreen), matching: find.byType(Scrollable));
  await tester.scrollUntilVisible(target, 160, scrollable: scrollable.first);
  await tester.pumpAndSettle();
}

Future<void> _pumpApp(
  WidgetTester tester, {
  required TokenStore tokenStore,
  AuthApi? api,
  FakeUploader? uploader,
  AudioPicker? picker,
  FakeTracksApi? tracks,
  FakeAudioCache? cache,
  FakeBotsApi? bots,
  PlaylistsApi? playlists,
  LinkImportsApi? linkImports,
  StoreApi? store,
  bool settle = true,
  AppPreferencesStore? appPreferencesStore,
}) async {
  await tester.pumpWidget(RhythmoApp(
    healthCheck: () async {},
    appPreferencesStore: appPreferencesStore ?? MemoryAppPreferencesStore(),
    authApi: api ?? FakeAuthApi(),
    tokenStore: tokenStore,
    tracksApi: tracks ?? FakeTracksApi(),
    audioEngine: FakeAudioEngine(),
    audioCache: cache ?? FakeAudioCache(),
    botsApi: bots,
    playlistsApi: playlists,
    linkImportsApi: linkImports,
    storeApi: store,
    uploader: uploader ?? FakeUploader(),
    picker: picker ?? FakePicker(null),
  ));
  if (settle) await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester, String email, String password) async {
  await tester.enterText(find.widgetWithText(TextFormField, 'ایمیل'), email);
  await tester.enterText(
      find.widgetWithText(TextFormField, 'رمز عبور'), password);
  await tester.tap(find.byType(FilledButton));
  await tester.pumpAndSettle();
}

class FakeLinkImportsApi implements LinkImportsApi {
  final submitted = <String>[];
  String? refuseWith;
  List<LinkImport> recent = [];

  @override
  Future<List<LinkImportCandidate>> previewLink(
      String token, String url) async {
    if (refuseWith case final code?) {
      throw ApiException(code, statusCode: 422, code: code);
    }
    if (url.contains('youtu')) {
      return [
        LinkImportCandidate(
          url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          fileName: 'song.m4a',
          site: 'www.youtube.com',
          title:
              'یک عنوان خیلی خیلی طولانی برای ویدیو که در صفحه‌ی باریک جا نمی‌شود',
          artist: 'Singer',
          thumbnailUrl: 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hq.jpg',
          durationSeconds: 215,
          sizeBytes: 3400000,
        ),
      ];
    }
    return [
      LinkImportCandidate(
          url: url, fileName: 'Artist - Song.mp3', site: 'music.example.ir'),
    ];
  }

  final spotifyLinks = <String>[];

  @override
  Future<SpotifyImportResult> importSpotify(String token, String url) async {
    spotifyLinks.add(url);
    if (refuseWith case final code?) {
      throw ApiException(code, statusCode: 422, code: code);
    }
    return const SpotifyImportResult(
      name: 'Road Trip',
      playlistId: 'pl1',
      matched: [
        SpotifyTitle(title: 'Hello', artists: ['Adele'])
      ],
      missing: [
        SpotifyTitle(
            title:
                'A very long missing Spotify title that cannot fit on a narrow phone screen',
            artists: ['Somebody', 'Somebody Else']),
        SpotifyTitle(title: 'آهنگ پیدا نشده'),
      ],
    );
  }

  @override
  Future<LinkImport> importFromLink(String token, String url) async {
    submitted.add(url);
    if (refuseWith case final code?) {
      throw ApiException(code, statusCode: 422, code: code);
    }
    return LinkImport(
        id: 'l${submitted.length}',
        fileName: 'Artist - Song.mp3',
        site: 'music.example.ir',
        state: LinkImportState.queued);
  }

  @override
  Future<List<LinkImport>> listLinkImports(String token) async => recent;
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets('shows setup instructions without API configuration', (
    tester,
  ) async {
    await tester.pumpWidget(const RhythmoApp());

    expect(find.textContaining('API_BASE_URL'), findsOneWidget);
  });

  testWidgets('shows retry when the API is unavailable', (tester) async {
    await tester.pumpWidget(
      RhythmoApp(healthCheck: () async => throw Exception('offline')),
    );
    await tester.pumpAndSettle();

    expect(find.text('اتصال به سرور برقرار نشد'), findsOneWidget);
    expect(find.text('تلاش دوباره'), findsOneWidget);
  });

  testWidgets('without a saved token the sign-in screen is shown', (
    tester,
  ) async {
    await _pumpApp(tester, tokenStore: MemoryTokenStore());

    expect(find.text('ورود به ریتمو'), findsOneWidget);
  });

  group('guest', () {
    FakePlaylistsApi guestPlaylists() => FakePlaylistsApi()
      ..public = [listed('loved', likes: 5)]
      ..shared[token] = sharedMix();

    testWidgets('signed out, popular playlists play without an account',
        (tester) async {
      final tracks = FakeTracksApi();
      await _pumpApp(tester,
          tokenStore: MemoryTokenStore(),
          tracks: tracks,
          playlists: guestPlaylists());

      expect(find.text('فهرست‌های پخش محبوب'), findsOneWidget);
      expect(find.text('loved'), findsOneWidget);
      expect(find.text('ورود / ثبت‌نام'), findsOneWidget);

      // Liking needs an account; the guest is offered sign-in instead.
      await tester.tap(find.text('۵'));
      await tester.pumpAndSettle();
      expect(find.text('برای پسندیدن وارد حسابت شو.'), findsOneWidget);

      await tester.tap(find.text('loved'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Their song'));
      await tester.pumpAndSettle();
      expect(tracks.calls, contains('shared:$token:s1'));
      expect(find.byTooltip('توقف'), findsOneWidget);

      await tester.tap(find.text('افزودن به حساب من'));
      await tester.pumpAndSettle();
      expect(
          find.text('برای افزودن به کتابخانه وارد حسابت شو.'), findsOneWidget);
    });

    testWidgets('signing in from the guest home lands in the library',
        (tester) async {
      final tokens = MemoryTokenStore();
      await _pumpApp(tester, tokenStore: tokens, playlists: guestPlaylists());
      await tester.tap(find.text('loved'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('افزودن به حساب من'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SnackBarAction, 'ورود'));
      await tester.pumpAndSettle();
      expect(find.text('ورود به ریتمو'), findsOneWidget);

      await _submit(tester, 'listener@example.com', 'correct horse');
      expect(find.text('ورود به ریتمو'), findsNothing);
      expect(find.text('Friend mix'), findsNothing);
      expect(find.widgetWithText(Tab, 'آهنگ‌ها'), findsOneWidget);
      expect(await tokens.read(), 'valid-token');
    });

    testWidgets('the guest home fits a narrow phone', (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpApp(tester,
          tokenStore: MemoryTokenStore(), playlists: guestPlaylists());

      expect(tester.takeException(), isNull);
      final signIn = tester.getRect(find.text('ورود / ثبت‌نام'));
      expect(signIn.right, lessThanOrEqualTo(360));
      expect(signIn.left, greaterThanOrEqualTo(0));
      final button = tester.getSize(find.ancestor(
          of: find.text('ورود / ثبت‌نام'),
          matching: find.byType(FilledButton)));
      expect(button.height, greaterThanOrEqualTo(48));
    });
  });

  testWidgets('signing in opens the library and saves the token', (
    tester,
  ) async {
    final tokens = MemoryTokenStore();
    await _pumpApp(tester, tokenStore: tokens);

    await _submit(tester, 'listener@example.com', 'correct horse');

    expect(find.text('کتابخانهٔ شما خالی است'), findsOneWidget);
    expect(await tokens.read(), 'valid-token');
    // The header shows the account by its icon; the address is only the
    // tooltip.
    expect(find.text('listener@example.com'), findsNothing);
    expect(find.byTooltip('listener@example.com'), findsOneWidget);
    expect(find.byKey(const ValueKey('verified-badge')), findsNothing);
  });

  testWidgets('wrong credentials show an error and stay signed out', (
    tester,
  ) async {
    final tokens = MemoryTokenStore();
    await _pumpApp(tester, tokenStore: tokens);

    await _submit(tester, 'listener@example.com', 'wrong horse');

    expect(find.text('ایمیل یا رمز عبور درست نیست.'), findsOneWidget);
    expect(await tokens.read(), isNull);
  });

  testWidgets('registering creates a session; a taken email is reported', (
    tester,
  ) async {
    final api = FakeAuthApi()..registered.add('taken@example.com');
    await _pumpApp(tester, tokenStore: MemoryTokenStore(), api: api);
    await tester.tap(find.text('حساب نداری؟ ثبت‌نام کن'));
    await tester.pumpAndSettle();

    await _submit(tester, 'taken@example.com', 'long enough');
    expect(find.text('با این ایمیل قبلاً حساب ساخته شده است.'), findsOneWidget);

    await _submit(tester, 'new@example.com', 'long enough');
    expect(find.text('کتابخانهٔ شما خالی است'), findsOneWidget);
  });

  testWidgets('a common password and too many attempts are explained', (
    tester,
  ) async {
    // Narrow phone: the longer messages must wrap, not overflow.
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tokens = MemoryTokenStore();
    await _pumpApp(tester, tokenStore: tokens);

    await _submit(tester, 'locked@example.com', 'correct horse');
    expect(find.text('تلاش‌ها زیاد بود. چند دقیقه بعد دوباره امتحان کن.'),
        findsOneWidget);

    await tester.tap(find.text('حساب نداری؟ ثبت‌نام کن'));
    await tester.pumpAndSettle();
    await _submit(tester, 'new@example.com', 'password');
    expect(
        find.text(
            'این رمز عبور خیلی رایج یا قابل حدس است. رمز دیگری انتخاب کن.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(await tokens.read(), isNull);
  });

  testWidgets('registration rejects a short password before calling the API', (
    tester,
  ) async {
    await _pumpApp(tester, tokenStore: MemoryTokenStore());
    await tester.tap(find.text('حساب نداری؟ ثبت‌نام کن'));
    await tester.pumpAndSettle();

    await _submit(tester, 'new@example.com', 'short');

    expect(find.text('رمز عبور باید حداقل ۸ کاراکتر باشد.'), findsOneWidget);
  });

  testWidgets('a saved valid token restores the session', (tester) async {
    await _pumpApp(tester, tokenStore: MemoryTokenStore('valid-token'));

    expect(find.text('کتابخانهٔ شما خالی است'), findsOneWidget);
  });

  testWidgets('a rejected saved token is cleared and sign-in is shown', (
    tester,
  ) async {
    final tokens = MemoryTokenStore('expired-token');
    await _pumpApp(tester, tokenStore: tokens);

    expect(find.text('ورود به ریتمو'), findsOneWidget);
    expect(await tokens.read(), isNull);
  });

  testWidgets('a network failure during restore keeps the token for retry', (
    tester,
  ) async {
    final tokens = MemoryTokenStore('valid-token');
    await _pumpApp(
      tester,
      tokenStore: tokens,
      api: FakeAuthApi(meError: Exception('offline')),
    );

    expect(find.text('بازیابی ورود قبلی ممکن نشد'), findsOneWidget);
    expect(await tokens.read(), 'valid-token');
  });

  testWidgets('logging out clears the token and returns to sign-in', (
    tester,
  ) async {
    final tokens = MemoryTokenStore('valid-token');
    await _pumpApp(tester, tokenStore: tokens);

    await tester.tap(find.byIcon(RhythmoIcons.signOut));
    await tester.pumpAndSettle();

    expect(find.text('ورود به ریتمو'), findsOneWidget);
    expect(await tokens.read(), isNull);
  });

  testWidgets(
      'deleting the account from Settings on a narrow phone signs out to '
      'the guest home', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final tokens = MemoryTokenStore('valid-token');
    final api = FakeAuthApi();
    await _pumpApp(tester,
        tokenStore: tokens,
        api: api,
        playlists: FakePlaylistsApi()..public = [listed('loved', likes: 5)]);

    await tester.tap(find.byTooltip('حساب و تنظیمات'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تنظیمات').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('حذف حساب کاربری'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('حریم خصوصی'), findsOneWidget);
    // Built is not the same as on screen; bring the tile fully into view.
    await tester.ensureVisible(find.text('حذف حساب کاربری'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف حساب کاربری'));
    await tester.pumpAndSettle();

    // The screen says what goes before asking for the password.
    expect(find.text('این کار قابل بازگشت نیست'), findsOneWidget);
    expect(find.textContaining('موسیقی‌هایی که در فضای ابری'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final password = find.widgetWithText(TextFormField, 'رمز عبور');
    final delete = find.ancestor(
        of: find.text('حذف حساب برای همیشه'),
        matching: find.bySubtype<ButtonStyleButton>());
    await tester.enterText(password, 'wrong horse');
    await tester.scrollUntilVisible(delete, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text('رمز عبور درست نیست.'), findsOneWidget);
    expect(api.deleted, isEmpty);
    expect(await tokens.read(), 'valid-token');

    await tester.enterText(password, 'correct horse');
    await tester.scrollUntilVisible(delete, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(delete);
    await tester.pumpAndSettle();

    expect(api.deleted, ['valid-token']);
    expect(await tokens.read(), isNull);
    expect(
        find.text('حساب کاربری‌ات و همه‌ی اطلاعاتش حذف شد.'), findsOneWidget);
    expect(find.text('فهرست‌های پخش محبوب'), findsOneWidget);
    expect(find.text('حذف حساب کاربری'), findsNothing);
    expect(find.widgetWithText(Tab, 'آهنگ‌ها'), findsNothing);
  });

  testWidgets('picking a file uploads it and shows the result', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      picker: FakePicker(PickedAudio(
        name: 'song.mp3',
        sizeBytes: 4,
        openRead: () => Stream.value([1, 2, 3, 4]),
      )),
    );

    await tester.tap(find.byTooltip('افزودن موسیقی'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('افزودن از فایل'));
    await tester.pumpAndSettle();

    expect(find.text('«Song» به کتابخانه اضافه شد.'), findsOneWidget);
    await tester.tap(find.byTooltip('بستن'));
    await tester.pumpAndSettle();
    expect(find.textContaining('به کتابخانه اضافه شد'), findsNothing);
  });

  testWidgets('an unsupported file shows an error', (tester) async {
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      picker: FakePicker(PickedAudio(
        name: 'notes.txt',
        sizeBytes: 4,
        openRead: () => const Stream.empty(),
      )),
    );

    await tester.tap(find.byTooltip('افزودن موسیقی'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('افزودن از فایل'));
    await tester.pumpAndSettle();

    expect(find.textContaining('این قالب پشتیبانی نمی‌شود'), findsOneWidget);
  });

  testWidgets('an upload in progress can be cancelled', (tester) async {
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      uploader: FakeUploader()..stall = true,
      picker: FakePicker(PickedAudio(
        name: 'song.mp3',
        sizeBytes: 4,
        openRead: () => Stream.value([1, 2, 3, 4]),
      )),
    );

    await tester.tap(find.byTooltip('افزودن موسیقی'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('افزودن از فایل'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('در حال آپلود «song.mp3»'), findsOneWidget);

    await tester.tap(find.text('لغو'));
    await tester.pumpAndSettle();

    expect(find.textContaining('در حال آپلود'), findsNothing);
    expect(find.text('لغو'), findsNothing);
  });

  testWidgets('after a restart the library lists the uploaded tracks', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      tracks: FakeTracksApi(const [
        Track(
          id: 's1',
          title: 'Uploaded earlier',
          artist: 'Artist',
          contentType: 'audio/mpeg',
          sizeBytes: 3 * 1024 * 1024,
        ),
      ]),
    );

    expect(find.text('Uploaded earlier'), findsOneWidget);
    expect(find.text('Artist'), findsOneWidget);
    // Rows show the artist only; the file size stays out of the list.
    expect(find.textContaining('مگابایت'), findsNothing);
    // Storage use lives in the account screen, not above the tracks.
    expect(find.textContaining('از ۵.۰ گیگابایت'), findsNothing);
    expect(find.text('کتابخانهٔ شما خالی است'), findsNothing);
  });

  testWidgets('settings opens playlists even when their tab is hidden',
      (tester) async {
    final store = MemoryAppPreferencesStore()
      ..value = const AppPreferences(
          hidden: {LibraryTab.playlists, LibraryTab.favorites});
    await _pumpApp(tester,
        tokenStore: MemoryTokenStore('valid-token'),
        appPreferencesStore: store,
        playlists: FakePlaylistsApi());
    expect(find.widgetWithText(Tab, 'فهرست‌های پخش'), findsNothing);
    await tester.tap(find.byTooltip('تنظیمات'));
    await tester.pumpAndSettle();
    await _revealSetting(tester, find.text('مدیریت فهرست‌های پخش'));
    await tester.tap(find.text('مدیریت فهرست‌های پخش'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'فهرست‌های پخش'), findsOneWidget);
    await tester.tap(find.byTooltip('فهرست‌های پخش محبوب'));
    await tester.pumpAndSettle();
    expect(find.byType(PopularPlaylistsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('popular playlists and the store open from the top bar',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpApp(tester,
        tokenStore: MemoryTokenStore('valid-token'),
        playlists: FakePlaylistsApi()..public = [listed('loved', likes: 5)],
        store: FakeStoreApi());
    expect(tester.takeException(), isNull);

    final popular = find.byTooltip('فهرست‌های پخش محبوب');
    final store = find.byTooltip('استور');
    for (final button in [popular, store]) {
      expect(find.descendant(of: find.byType(AppBar), matching: button),
          findsOneWidget);
      final size = tester.getSize(button);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    final flame = tester.widget<Icon>(
        find.descendant(of: popular, matching: find.byType(Icon)));
    expect(flame.icon, RhythmoIcons.fire);
    expect(flame.color, RhythmoColors.fire);
    // The brand still fits beside the actions on a narrow phone.
    final brand = tester.getRect(find.text('ریتمو').first);
    expect(brand.left, greaterThanOrEqualTo(0));
    expect(brand.right, lessThanOrEqualTo(320));

    await tester.tap(popular);
    await tester.pumpAndSettle();
    expect(find.byType(PopularPlaylistsScreen), findsOneWidget);
    expect(find.text('loved'), findsOneWidget);
    Navigator.of(tester.element(find.byType(PopularPlaylistsScreen))).pop();
    await tester.pumpAndSettle();

    await tester.tap(store);
    await tester.pumpAndSettle();
    expect(find.byType(StoreScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tab preferences rebuild safely and retain the tracks tab',
      (tester) async {
    final store = MemoryAppPreferencesStore();
    await _pumpApp(tester,
        tokenStore: MemoryTokenStore('valid-token'),
        appPreferencesStore: store);
    final context = tester.element(find.byType(TabBar));
    final preferences = AppPreferencesScope.maybeOf(context)!;
    await preferences.update(
        order: [LibraryTab.artists, LibraryTab.tracks],
        hidden: {LibraryTab.albums, LibraryTab.playlists, LibraryTab.tracks});
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Tab, 'آلبوم‌ها'), findsNothing);
    expect(find.widgetWithText(Tab, 'آهنگ‌ها'), findsOneWidget);
    expect(tester.getCenter(find.widgetWithText(Tab, 'هنرمندان')).dx,
        greaterThan(tester.getCenter(find.widgetWithText(Tab, 'آهنگ‌ها')).dx));
    await preferences.update(hidden: {});
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Tab, 'پسندیده‌ها'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the account screen shows cloud storage use on a narrow phone',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      tracks: FakeTracksApi(const [
        Track(
          id: 's1',
          title: 'Uploaded earlier',
          contentType: 'audio/mpeg',
          sizeBytes: 3 * 1024 * 1024,
        ),
      ]),
    );

    // On a phone, settings is in the account menu.
    await tester.tap(find.byTooltip('حساب و تنظیمات'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تنظیمات').last);
    await tester.pumpAndSettle();
    await _revealSetting(tester, find.text('فضای ابری'));
    expect(find.text('فضای ابری'), findsOneWidget);
    expect(find.textContaining('از ۵.۰ گیگابایت'), findsOneWidget);
    expect(
        find.bySemanticsLabel(RegExp('^فضای ابری مصرف‌شده')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the search screen offers a clear action when nothing matches', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      tracks: FakeTracksApi(const [
        Track(
          id: 's1',
          title: 'First song',
          contentType: 'audio/mpeg',
          sizeBytes: 1,
        ),
        Track(
          id: 's2',
          title: 'Second song',
          contentType: 'audio/mpeg',
          sizeBytes: 1,
        ),
      ]),
    );

    expect(find.text('۲ آهنگ'), findsOneWidget);
    // The library list has no search field of its own.
    expect(find.byType(SearchBar), findsNothing);
    await tester.tap(find.byTooltip('جست‌وجو در کتابخانه'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(SearchBar), 'missing');
    await tester.pumpAndSettle();

    expect(find.text('نتیجه‌ای پیدا نشد'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'پاک کردن جست‌وجو'));
    await tester.pumpAndSettle();

    expect(find.text('در همهٔ کتابخانه بگرد'), findsOneWidget);
  });

  testWidgets(
      'long press selects tracks without playback and supports clear/all',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester,
        tokenStore: MemoryTokenStore('valid-token'),
        tracks: FakeTracksApi(const [
          Track(
              id: 's1',
              title: 'First',
              contentType: 'audio/mpeg',
              sizeBytes: 1),
          Track(
              id: 's2',
              title: 'Second',
              contentType: 'audio/mpeg',
              sizeBytes: 1),
        ]));
    await tester.longPress(find.text('First'));
    await tester.pumpAndSettle();
    expect(find.text('۱ آهنگ انتخاب‌شده'), findsOneWidget);
    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(find.byTooltip('توقف'), findsNothing);
    expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .where((checkbox) => checkbox.value == true)
            .length,
        1);
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(find.text('۲ آهنگ انتخاب‌شده'), findsOneWidget);
    expect(find.byTooltip('توقف'), findsNothing);
    await tester.tap(find.text('لغو انتخاب همه'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    await tester.longPress(find.text('First'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('انتخاب همه'));
    await tester.pumpAndSettle();
    expect(find.text('۲ آهنگ انتخاب‌شده'), findsOneWidget);
    await tester.tap(find.byTooltip('لغو انتخاب'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('توقف'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('right click opens track actions without playing the track',
      (tester) async {
    await _pumpApp(tester,
        tokenStore: MemoryTokenStore('valid-token'),
        tracks: FakeTracksApi(const [
          Track(
              id: 's1',
              title: 'First',
              contentType: 'audio/mpeg',
              sizeBytes: 1),
        ]));
    final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await mouse.down(tester.getCenter(find.text('First')));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.text('ویرایش اطلاعات آهنگ'), findsOneWidget);
    expect(find.text('حذف آهنگ'), findsOneWidget);
    expect(find.byTooltip('توقف'), findsNothing);
    await tester.tap(find.text('ویرایش اطلاعات آهنگ'));
    await tester.pumpAndSettle();
    expect(find.byType(TrackMetadataEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the track list sorts by title and artist', (tester) async {
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      tracks: FakeTracksApi(const [
        Track(
            id: 's1',
            title: 'Zebra',
            artist: 'Alpha',
            contentType: 'audio/mpeg',
            sizeBytes: 1),
        Track(
            id: 's2',
            title: 'Apple',
            artist: 'Beta',
            contentType: 'audio/mpeg',
            sizeBytes: 1),
      ]),
    );
    double top(String title) => tester.getTopLeft(find.text(title)).dy;
    expect(top('Zebra'), lessThan(top('Apple')));

    await tester.tap(find.byTooltip('مرتب‌سازی: تاریخ افزودن؛ جدیدترین اول'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('نام آهنگ'));
    await tester.pumpAndSettle();
    expect(top('Apple'), lessThan(top('Zebra')));

    await tester.tap(find.byTooltip('مرتب‌سازی: نام آهنگ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('خواننده'));
    await tester.pumpAndSettle();
    expect(top('Zebra'), lessThan(top('Apple')));

    await tester.tap(find.byTooltip('مرتب‌سازی: خواننده'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تاریخ افزودن؛ قدیمی‌ترین اول'));
    await tester.pumpAndSettle();
    expect(top('Apple'), lessThan(top('Zebra')));

    // The choice lasts the session; put it back for the tests that follow.
    await tester.tap(find.byTooltip('مرتب‌سازی: تاریخ افزودن؛ قدیمی‌ترین اول'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تاریخ افزودن؛ جدیدترین اول'));
    await tester.pumpAndSettle();
  });

  testWidgets('compact rows fit many tracks on a 360 px phone', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      tracks: FakeTracksApi([
        for (var i = 0; i < 20; i++)
          Track(
            id: 's$i',
            title: 'یک عنوان خیلی خیلی طولانی برای آهنگ شماره‌ی $i Long Title',
            artist: 'Artist with a really long name number $i',
            contentType: 'audio/mpeg',
            sizeBytes: 3 * 1024 * 1024,
          ),
      ]),
    );

    expect(tester.takeException(), isNull);
    final height = tester
        .getSize(find.ancestor(
            of: find.text('Artist with a really long name number 0'),
            matching: find.byType(ListTile)))
        .height;
    expect(height, inInclusiveRange(56, 72));
    // The artist is the only secondary detail: no file size.
    expect(
        find.text('Artist with a really long name number 0'), findsOneWidget);
    expect(find.textContaining('مگابایت'), findsNothing);
    expect(find.byTooltip('روی سرور'), findsWidgets);
  });

  group('import from a link', () {
    Future<FakeLinkImportsApi> pumpWithLinks(WidgetTester tester,
        {Size size = const Size(800, 900)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FakeLinkImportsApi();
      await _pumpApp(tester,
          tokenStore: MemoryTokenStore('valid-token'), linkImports: api);
      return api;
    }

    testWidgets('a song page link is queued and refusals are explained',
        (tester) async {
      final api = await pumpWithLinks(tester);
      await tester.tap(find.byTooltip('افزودن موسیقی'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('افزودن از لینک'));
      await tester.pumpAndSettle();
      expect(find.text('افزودن از لینک'), findsWidgets);

      // An empty link is caught before asking the server.
      await tester.tap(find.widgetWithText(FilledButton, 'بررسی لینک'));
      await tester.pumpAndSettle();
      expect(find.text('لینک صفحه‌ی آهنگ یا فایل را بچسبان.'), findsOneWidget);
      expect(api.submitted, isEmpty);

      api.refuseWith = 'no_audio';
      await tester.enterText(
          find.byType(TextField), ' https://music.example.ir/song/1 ');
      await tester.tap(find.widgetWithText(FilledButton, 'بررسی لینک'));
      await tester.pumpAndSettle();
      expect(find.textContaining('در این صفحه فایل صوتی پیدا نشد'),
          findsOneWidget);

      api.refuseWith = null;
      await tester.tap(find.widgetWithText(FilledButton, 'بررسی لینک'));
      await tester.pumpAndSettle();
      expect(find.text('Artist - Song.mp3'), findsOneWidget);
      await tester
          .tap(find.widgetWithText(FilledButton, 'افزودن انتخاب‌شده‌ها'));
      await tester.pumpAndSettle();
      expect(api.submitted.last, 'https://music.example.ir/song/1');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('در حال اضافه کردن «Artist - Song.mp3»'),
          findsOneWidget);
    });

    testWidgets('a failed import says why until dismissed', (tester) async {
      final api = await pumpWithLinks(tester);
      await tester.tap(find.byTooltip('افزودن موسیقی'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('افزودن از لینک'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'https://x.ir/a.mp3');
      await tester.tap(find.widgetWithText(FilledButton, 'بررسی لینک'));
      await tester.pumpAndSettle();
      await tester
          .tap(find.widgetWithText(FilledButton, 'افزودن انتخاب‌شده‌ها'));
      await tester.pumpAndSettle();

      api.recent = const [
        LinkImport(
            id: 'l1',
            fileName: 'Artist - Song.mp3',
            site: 'music.example.ir',
            state: LinkImportState.failed,
            error: 'quota_exceeded'),
      ];
      // The library reloads with nothing in progress any more.
      await tester.drag(find.byType(TabBarView), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(find.text('افزودن از لینک ناموفق بود'), findsOneWidget);
      expect(find.textContaining('فضای کافی در حسابت نیست'), findsOneWidget);

      await tester.tap(find.byTooltip('بستن'));
      await tester.pumpAndSettle();
      expect(find.text('افزودن از لینک ناموفق بود'), findsNothing);
    });

    testWidgets('a video link shows its title and artist on a narrow phone',
        (tester) async {
      final api = await pumpWithLinks(tester, size: const Size(360, 740));
      await tester.tap(find.byTooltip('افزودن موسیقی'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('افزودن از لینک'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byType(TextField), 'https://youtu.be/dQw4w9WgXcQ');
      await tester.tap(find.widgetWithText(FilledButton, 'بررسی لینک'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('یک عنوان خیلی خیلی طولانی'), findsOneWidget);
      expect(find.textContaining('Singer · ۳:۳۵'), findsOneWidget);
      final dialog = tester.getRect(find.byType(AlertDialog));
      expect(dialog.left, greaterThanOrEqualTo(0));
      expect(dialog.right, lessThanOrEqualTo(360));
      final tile = tester.getRect(find.byType(CheckboxListTile));
      expect(tile.right, lessThanOrEqualTo(dialog.right));

      await tester
          .tap(find.widgetWithText(FilledButton, 'افزودن انتخاب‌شده‌ها'));
      await tester.pumpAndSettle();
      expect(
          api.submitted.single, 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    });

    testWidgets('a Spotify link builds a playlist and lists missing titles',
        (tester) async {
      final api = await pumpWithLinks(tester, size: const Size(360, 740));
      await tester.tap(find.byTooltip('افزودن موسیقی'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('افزودن از لینک'));
      await tester.pumpAndSettle();
      const link = 'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M';
      await tester.enterText(find.byType(TextField), link);
      await tester.tap(find.widgetWithText(FilledButton, 'بررسی لینک'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Nothing is downloaded: it never reaches the link import.
      expect(api.spotifyLinks, [link]);
      expect(api.submitted, isEmpty);
      expect(find.text('فهرست پخش «Road Trip» با ۱ آهنگ ساخته شد.'),
          findsOneWidget);
      expect(find.text('۲ آهنگ در کتابخانه‌ات پیدا نشد:'), findsOneWidget);
      expect(find.text('Somebody، Somebody Else'), findsOneWidget);
      expect(find.text('آهنگ پیدا نشده'), findsOneWidget);
      final dialog = tester.getRect(find.byType(AlertDialog));
      expect(dialog.left, greaterThanOrEqualTo(0));
      expect(dialog.right, lessThanOrEqualTo(360));
      final done = tester.getRect(find.widgetWithText(FilledButton, 'تمام'));
      expect(done.bottom, lessThanOrEqualTo(dialog.bottom));

      await tester.tap(find.widgetWithText(FilledButton, 'تمام'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('فهرست پخش «Road Trip» با ۱ آهنگ ساخته شد.'),
          findsOneWidget);
    });

    testWidgets('a Spotify link that names no tracks is explained',
        (tester) async {
      final api = await pumpWithLinks(tester);
      api.refuseWith = 'no_tracks';
      await tester.tap(find.byTooltip('افزودن موسیقی'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('افزودن از لینک'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField),
          'https://open.spotify.com/album/1111111111111111111111');
      await tester.tap(find.widgetWithText(FilledButton, 'بررسی لینک'));
      await tester.pumpAndSettle();
      expect(
          find.text('در این لینک اسپاتیفای آهنگی پیدا نشد.'), findsOneWidget);
    });

    testWidgets('the link action and dialog fit a narrow phone',
        (tester) async {
      await pumpWithLinks(tester, size: const Size(360, 740));
      final add = tester.getRect(find.byTooltip('افزودن موسیقی'));
      expect(add.width, greaterThanOrEqualTo(48));
      expect(add.left, greaterThanOrEqualTo(0));
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.text('افزودن موسیقی'), findsNothing);

      await tester.tap(find.byTooltip('افزودن موسیقی'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('افزودن از لینک'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final dialog = tester.getRect(find.byType(AlertDialog));
      expect(dialog.left, greaterThanOrEqualTo(0));
      expect(dialog.right, lessThanOrEqualTo(360));
      final paste = tester.getSize(find.ancestor(
          of: find.byTooltip('چسباندن'), matching: find.byType(IconButton)));
      expect(paste.height, greaterThanOrEqualTo(48));
    });
  });

  group('library tabs', () {
    List<Track> manyTracks() => [
          for (var i = 0; i < 30; i++)
            Track(
              id: 's$i',
              title: 'Track number $i',
              artist: i.isEven ? 'Queen' : 'فرهاد',
              album: i.isEven ? 'Opera' : null,
              contentType: 'audio/mpeg',
              sizeBytes: 1,
            ),
        ];

    Future<void> pumpPhone(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpApp(
        tester,
        tokenStore: MemoryTokenStore('valid-token'),
        tracks: FakeTracksApi(manyTracks()),
        playlists: FakePlaylistsApi(),
      );
    }

    testWidgets('switch between tracks, playlists, albums and artists',
        (tester) async {
      await pumpPhone(tester);
      for (final tab in ['آهنگ‌ها', 'فهرست‌های پخش', 'آلبوم‌ها', 'هنرمندان']) {
        expect(find.widgetWithText(Tab, tab), findsOneWidget);
      }
      expect(find.byTooltip('افزودن موسیقی'), findsOneWidget);

      await tester.tap(find.widgetWithText(Tab, 'فهرست‌های پخش'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('فهرست پخش جدید'), findsOneWidget);
      expect(find.text('فهرست پخش جدید'), findsNothing);
      expect(find.text('mix'), findsWidgets);
      // Adding music belongs to the tracks tab only.
      expect(find.byTooltip('افزودن موسیقی'), findsNothing);

      await tester.tap(find.widgetWithText(Tab, 'آلبوم‌ها'));
      await tester.pumpAndSettle();
      expect(find.text('Opera'), findsOneWidget);
      expect(find.text('Queen · ۱۵ آهنگ'), findsOneWidget);
      expect(find.text('نامشخص'), findsOneWidget);

      await tester.tap(find.widgetWithText(Tab, 'هنرمندان'));
      await tester.pumpAndSettle();
      expect(find.text('فرهاد'), findsOneWidget);
      // An artist opens their page, which plays all of their tracks.
      await tester.tap(find.text('فرهاد'));
      await tester.pumpAndSettle();
      expect(find.text('۱۵ آهنگ'), findsOneWidget);
      expect(find.text('Track number 1'), findsOneWidget);
      await tester.tap(find.text('پخش همه'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('توقف'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an album page fits a narrow phone and clears the player',
        (tester) async {
      await pumpPhone(tester);
      await tester.tap(find.widgetWithText(Tab, 'آلبوم‌ها'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Opera'));
      await tester.pumpAndSettle();
      expect(find.text('پخش همه'), findsOneWidget);
      expect(find.text('پخش تصادفی'), findsOneWidget);

      await tester.tap(find.text('پخش تصادفی'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 8; i++) {
        await tester.drag(find.byType(Scrollable).last, const Offset(0, -400));
        await tester.pumpAndSettle();
      }
      final lastRow = tester.getRect(find.ancestor(
          of: find.text('Track number 28'), matching: find.byType(ListTile)));
      final miniPlayerTop = tester.getTopLeft(find.byTooltip('توقف')).dy - 16;
      expect(lastRow.bottom, lessThanOrEqualTo(miniPlayerTop));
      expect(lastRow.right, lessThanOrEqualTo(360));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the compact toolbar stays pinned and scroll is kept per tab',
        (tester) async {
      await pumpPhone(tester);
      final expandedTabsTop =
          tester.getTopLeft(find.widgetWithText(Tab, 'آهنگ‌ها')).dy;

      await tester.drag(find.byType(TabBarView), const Offset(0, -500));
      await tester.pumpAndSettle();
      final collapsedTabsTop =
          tester.getTopLeft(find.widgetWithText(Tab, 'آهنگ‌ها')).dy;
      expect(collapsedTabsTop, expandedTabsTop);
      // The tabs stay pinned and nothing slides under them.
      expect(find.widgetWithText(Tab, 'هنرمندان'), findsOneWidget);
      final tabsBottom = tester.getBottomLeft(find.byType(TabBar)).dy;
      final firstVisibleRow = find.byType(ListTile).evaluate().map((e) {
        final box = e.renderObject! as RenderBox;
        return box.localToGlobal(Offset.zero).dy + box.size.height;
      }).where((bottom) => bottom > tabsBottom);
      expect(firstVisibleRow, isNotEmpty);
      expect(find.text('Track number 0'), findsNothing);

      await tester.tap(find.widgetWithText(Tab, 'آلبوم‌ها'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'آهنگ‌ها'));
      await tester.pumpAndSettle();
      // Coming back, the tracks list is where it was left.
      expect(find.text('Track number 0'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the last track menu clears the mini player and add button',
        (tester) async {
      await pumpPhone(tester);
      await tester.tap(find.text('Track number 0'));
      await tester.pumpAndSettle();
      // Swipe up through the list, then as far past the end as it goes.
      for (var i = 0; i < 12; i++) {
        await tester.drag(find.byType(TabBarView), const Offset(0, -300));
        await tester.pumpAndSettle();
      }
      await tester.pumpAndSettle();
      final lastRow = tester.getRect(find.ancestor(
          of: find.text('Track number 29'), matching: find.byType(ListTile)));
      final miniPlayerTop = tester.getTopLeft(find.byTooltip('توقف')).dy - 16;
      expect(lastRow.bottom, lessThan(miniPlayerTop));
      final add = tester.getRect(find.byTooltip('افزودن موسیقی'));
      expect(lastRow.bottom, lessThan(add.top));
      final row = find.ancestor(
          of: find.text('Track number 29'), matching: find.byType(ListTile));
      final menu =
          find.descendant(of: row, matching: find.byTooltip('اقدامات آهنگ'));
      expect(menu, findsOneWidget);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.text('ویرایش اطلاعات آهنگ'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a finished upload appears in the list', (tester) async {
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      picker: FakePicker(PickedAudio(
        name: 'song.mp3',
        sizeBytes: 4,
        openRead: () => Stream.value([1, 2, 3, 4]),
      )),
    );
    expect(find.text('کتابخانهٔ شما خالی است'), findsOneWidget);

    await tester.tap(find.byTooltip('افزودن موسیقی'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('افزودن از فایل'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListTile, 'Song'), findsOneWidget);
    expect(find.text('کتابخانهٔ شما خالی است'), findsNothing);
  });

  testWidgets('deleting a cloud track requires confirmation and removes it', (
    tester,
  ) async {
    final tracks = FakeTracksApi(const [
      Track(
        id: 's1',
        title: 'Song to delete',
        contentType: 'audio/mpeg',
        sizeBytes: 1,
      ),
    ]);
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      tracks: tracks,
    );

    await tester.tap(find.byTooltip('اقدامات آهنگ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف آهنگ'));
    await tester.pumpAndSettle();

    expect(find.text('حذف «Song to delete»؟'), findsOneWidget);
    expect(find.textContaining('قابل بازگشت نیست'), findsOneWidget);
    await tester.tap(find.text('حذف برای همیشه'));
    await tester.pumpAndSettle();

    expect(tracks.deleted, ['s1']);
    expect(find.text('Song to delete'), findsNothing);
    expect(find.text('«Song to delete» حذف شد.'), findsOneWidget);
  });

  testWidgets('adding a track can create a playlist from the picker', (
    tester,
  ) async {
    final tracks = FakeTracksApi(const [
      Track(id: 's1', title: 'Song', contentType: 'audio/mpeg', sizeBytes: 1),
    ]);
    final playlists = FakePlaylistsApi()..userPlaylists = [];

    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      tracks: tracks,
      playlists: playlists,
    );

    await tester.tap(find.byTooltip('اقدامات آهنگ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('افزودن به فهرست پخش'));
    await tester.pumpAndSettle();

    expect(find.text('فهرست پخش جدید'), findsOneWidget);
    final nameField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'نام فهرست پخش',
    );
    await tester.enterText(nameField, 'Road songs');
    await tester.tap(find.text('ساخت'));
    await tester.pumpAndSettle();

    expect(playlists.createdNames, ['Road songs']);
    expect(playlists.replacedWith, ['s1']);
    expect(find.text('آهنگ به فهرست پخش اضافه شد.'), findsOneWidget);
  });

  testWidgets('a failed list load offers a retry', (tester) async {
    final tracks = FakeTracksApi(const [
      Track(id: 's1', title: 'Song', contentType: 'audio/mpeg', sizeBytes: 1),
    ])
      ..listError = Exception('offline');
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      tracks: tracks,
    );
    expect(find.text('کتابخانه دریافت نشد'), findsOneWidget);

    tracks.listError = null;
    await tester.tap(find.text('تلاش دوباره'));
    await tester.pumpAndSettle();

    expect(find.text('Song'), findsOneWidget);
  });

  testWidgets('logging out hides the previous account\'s tracks', (
    tester,
  ) async {
    final tracks = FakeTracksApi(const [
      Track(
          id: 's1', title: 'Private', contentType: 'audio/mpeg', sizeBytes: 1),
    ]);
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      tracks: tracks,
    );
    expect(find.text('Private'), findsOneWidget);

    await tester.tap(find.byIcon(RhythmoIcons.signOut));
    await tester.pumpAndSettle();
    tracks.tracks.clear();
    await _submit(tester, 'listener@example.com', 'correct horse');

    expect(find.text('Private'), findsNothing);
    expect(find.text('کتابخانهٔ شما خالی است'), findsOneWidget);
  });

  testWidgets('the interface is right-to-left Persian', (tester) async {
    await _pumpApp(tester, tokenStore: MemoryTokenStore('valid-token'));

    final context = tester.element(find.text('کتابخانهٔ شما خالی است'));
    expect(Directionality.of(context), TextDirection.rtl);
    expect(Localizations.localeOf(context), const Locale('fa'));
    // In RTL the floating button sits on the left and the logout action on
    // the left end of the app bar.
    final width = tester.getSize(find.byType(Scaffold).first).width;
    expect(tester.getCenter(find.byType(FloatingActionButton)).dx,
        lessThan(width / 2));
    expect(tester.getCenter(find.byIcon(RhythmoIcons.signOut)).dx,
        lessThan(width / 2));
  });

  testWidgets('tapping a track plays it in the mini player', (tester) async {
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      tracks: FakeTracksApi(const [
        Track(
            id: 's1',
            title: 'Song',
            artist: 'Artist',
            contentType: 'audio/mpeg',
            sizeBytes: 1),
      ]),
    );
    expect(find.byTooltip('توقف'), findsNothing);

    await tester.tap(find.text('Song'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('توقف'), findsOneWidget);
    expect(find.text('۳:۰۰'), findsOneWidget);
    expect(find.text('Song'), findsWidgets);
    // The playing row says so with an icon and in words, not color alone.
    expect(
        find.descendant(
            of: find.widgetWithText(ListTile, 'Song'),
            matching: find.byIcon(RhythmoIcons.waveformFill)),
        findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('در حال پخش')), findsWidgets);

    await tester.tap(find.byTooltip('توقف'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('پخش'), findsOneWidget);
  });

  testWidgets('shuffle-all follows the visible search result set', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      tracks: FakeTracksApi(const [
        Track(
            id: 's1',
            title: 'First Song',
            artist: 'Alpha',
            contentType: 'audio/mpeg',
            sizeBytes: 1),
        Track(
            id: 's2',
            title: 'Second Song',
            artist: 'Beta',
            contentType: 'audio/mpeg',
            sizeBytes: 1),
      ]),
    );
    expect(find.text('پخش تصادفی'), findsOneWidget);
    await tester.tap(find.byTooltip('جست‌وجو در کتابخانه'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(SearchBar), 'Beta');
    await tester.pump();
    expect(find.text('پخش تصادفی نتایج'), findsOneWidget);
    expect(find.text('First Song'), findsNothing);
    expect(find.text('Second Song'), findsOneWidget);
    await tester.tap(find.text('پخش تصادفی نتایج'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('توقف'), findsOneWidget);
    expect(find.text('Second Song'), findsWidgets);
  });

  testWidgets('mini player stays usable on a narrow screen', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      tracks: FakeTracksApi(const [
        Track(
          id: 's1',
          title: 'A very long track title that must remain readable',
          artist: 'A very long artist name',
          contentType: 'audio/mpeg',
          sizeBytes: 1,
        ),
      ]),
    );
    await tester.tap(
      find.text('A very long track title that must remain readable'),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('قبلی'), findsOneWidget);
    expect(find.byTooltip('توقف'), findsOneWidget);
    expect(find.byTooltip('بعدی'), findsOneWidget);
    expect(find.byTooltip('پخش تصادفی'), findsNothing);
    expect(
      find.text('A very long track title that must remain readable'),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the mini player stays a bar and leaves the library usable',
      (tester) async {
    for (final size in const [Size(360, 740), Size(1280, 800)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpApp(
        tester,
        tokenStore: MemoryTokenStore('valid-token'),
        tracks: FakeTracksApi(const [
          Track(
              id: 's1',
              title: 'First',
              contentType: 'audio/mpeg',
              sizeBytes: 1),
          Track(
              id: 's2',
              title: 'Second',
              contentType: 'audio/mpeg',
              sizeBytes: 1),
        ]),
      );
      await tester.tap(find.text('First'));
      await tester.pumpAndSettle();

      final bar = tester.getRect(find.byType(MiniPlayer));
      expect(bar.height, lessThan(160), reason: '$size');
      expect(bar.bottom, size.height, reason: '$size');
      // The rest of the library can still be tapped.
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsWidgets);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('mini player controls are at least 48 px on a 360 px phone',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      tracks: FakeTracksApi(const [
        Track(
          id: 's1',
          title: 'A very long track title that must remain readable',
          artist: 'A very long artist name',
          contentType: 'audio/mpeg',
          sizeBytes: 1,
        ),
      ]),
    );
    await tester.tap(
      find.text('A very long track title that must remain readable'),
    );
    await tester.pumpAndSettle();

    for (final tooltip in ['قبلی', 'توقف', 'بعدی']) {
      final size = tester.getSize(find.descendant(
        of: find.byTooltip(tooltip),
        matching: find.byType(InkWell),
      ));
      expect(size.width, greaterThanOrEqualTo(48), reason: tooltip);
      expect(size.height, greaterThanOrEqualTo(48), reason: tooltip);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('next, shuffle and repeat controls in the mini player', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      tracks: FakeTracksApi(const [
        Track(
            id: 's1', title: 'First', contentType: 'audio/mpeg', sizeBytes: 1),
        Track(
            id: 's2', title: 'Second', contentType: 'audio/mpeg', sizeBytes: 1),
      ]),
    );
    await tester.tap(find.text('First'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('بعدی'));
    await tester.pumpAndSettle();
    // Now in both the list and the mini player, and selected in the list.
    expect(find.text('Second'), findsNWidgets(2));
    expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'Second'))
            .selected,
        isTrue);

    await tester.tap(find.byTooltip('تکرار: خاموش'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('تکرار: همه'), findsOneWidget);
    await tester.tap(find.byTooltip('تکرار: همه'));
    await tester.pumpAndSettle();
    expect(find.byIcon(RhythmoIcons.repeatOnceFill), findsOneWidget);

    await tester.tap(find.byTooltip('پخش تصادفی'));
    await tester.pumpAndSettle();
    final shuffle = tester.widget<IconButton>(find.ancestor(
        of: find.byIcon(RhythmoIcons.shuffleFill),
        matching: find.byType(IconButton)));
    expect(shuffle.isSelected, isTrue);
  });

  testWidgets('media controls keep their left-to-right order in RTL', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      tracks: FakeTracksApi(const [
        Track(id: 's1', title: 'Song', contentType: 'audio/mpeg', sizeBytes: 1),
      ]),
    );
    await tester.tap(find.text('Song'));
    await tester.pumpAndSettle();

    double x(String tooltip) => tester.getCenter(find.byTooltip(tooltip)).dx;
    expect(x('قبلی'), lessThan(x('توقف')));
    expect(x('توقف'), lessThan(x('بعدی')));
    expect(tester.getCenter(find.text('۰:۰۰')).dx,
        lessThan(tester.getCenter(find.text('۳:۰۰')).dx),
        reason: 'elapsed time on the left, duration on the right');
  });

  testWidgets('settings shows the cache size and clears it after confirming',
      (tester) async {
    final cache = FakeAudioCache(files: {'a': 3 * 1024 * 1024});
    await _pumpApp(tester,
        tokenStore: MemoryTokenStore('valid-token'), cache: cache);

    await tester.tap(find.byTooltip('تنظیمات'));
    await tester.pumpAndSettle();
    await _revealSetting(tester, find.text('پاک کردن کش'));
    expect(find.text('حجم کش: ۳.۰ مگابایت'), findsOneWidget);

    // Cancelling keeps everything.
    await _revealSetting(tester, find.text('پاک کردن کش'));
    await tester.tap(find.text('پاک کردن کش'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('انصراف'));
    await tester.pumpAndSettle();
    expect(cache.files, isNotEmpty);

    await _revealSetting(tester, find.text('پاک کردن کش'));
    await tester.tap(find.text('پاک کردن کش'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('پاک کن'));
    await tester.pumpAndSettle();

    expect(cache.files, isEmpty);
    expect(find.text('حجم کش: ۰ کیلوبایت'), findsOneWidget);
    expect(find.text('کش پاک شد.'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'پاک کردن کش'));
    expect(button.onPressed, isNull, reason: 'nothing left to clear');
  });

  testWidgets('clearing the cache keeps the library and the playing track', (
    tester,
  ) async {
    final cache = FakeAudioCache(files: {'s1': 100, 'old': 100});
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      cache: cache,
      tracks: FakeTracksApi(const [
        Track(id: 's1', title: 'Song', contentType: 'audio/mpeg', sizeBytes: 1),
      ]),
    );
    await tester.tap(find.text('Song'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('تنظیمات'));
    await tester.pumpAndSettle();
    await _revealSetting(tester, find.text('پاک کردن کش'));
    await tester.tap(find.text('پاک کردن کش'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('پاک کن'));
    await tester.pumpAndSettle();
    expect(cache.files.keys, ['s1']);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.text('Song'), findsWidgets);
    expect(find.byTooltip('توقف'), findsOneWidget);
  });

  testWidgets('on the web the browser manages the cache', (tester) async {
    await _pumpApp(tester,
        tokenStore: MemoryTokenStore('valid-token'),
        cache: FakeAudioCache(isManaged: false));

    await tester.tap(find.byTooltip('تنظیمات'));
    await tester.pumpAndSettle();

    await _revealSetting(
        tester, find.text('در نسخه‌ی وب، کش را خود مرورگر مدیریت می‌کند.'));
    expect(find.text('در نسخه‌ی وب، کش را خود مرورگر مدیریت می‌کند.'),
        findsOneWidget);
    expect(find.text('پاک کردن کش'), findsNothing);
  });

  testWidgets('settings issues a bot link code to send to the bot', (
    tester,
  ) async {
    final bots = FakeBotsApi()
      ..expiresAt = DateTime.now().add(const Duration(minutes: 10));
    await _pumpApp(tester,
        tokenStore: MemoryTokenStore('valid-token'), bots: bots);

    await tester.tap(find.byTooltip('تنظیمات'));
    await tester.pumpAndSettle();
    await _revealSetting(tester, find.text('دریافت کد اتصال'));
    expect(find.text('اتصال به بات'), findsOneWidget);

    await tester.tap(find.text('دریافت کد اتصال'));
    await tester.pumpAndSettle();

    await _revealSetting(tester, find.text('1234 5671'));
    expect(find.text('1234 5671'), findsOneWidget);
    expect(
        find.text('این کد را در بله برای @NafirBot بفرستید.'), findsOneWidget);
    expect(find.text('کپی کد'), findsOneWidget);
    expect(find.text('کپی لینک بات بله'), findsOneWidget);

    await _revealSetting(tester, find.text('کد تازه'));
    await tester.tap(find.text('کد تازه'));
    await tester.pumpAndSettle();
    await _revealSetting(tester, find.text('1234 5672'));
    expect(find.text('1234 5672'), findsOneWidget);
  });

  testWidgets('without bots on the server, settings shows no bot section', (
    tester,
  ) async {
    await _pumpApp(tester,
        tokenStore: MemoryTokenStore('valid-token'),
        bots: FakeBotsApi(bots: const []));

    await tester.tap(find.byTooltip('تنظیمات'));
    await tester.pumpAndSettle();

    expect(find.text('اتصال به بات'), findsNothing);
  });

  testWidgets('a track can be sent to a linked bot from its menu', (
    tester,
  ) async {
    final bots = FakeBotsApi(bots: const [linkedBale]);
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      bots: bots,
      tracks: FakeTracksApi(const [
        Track(id: 's1', title: 'Song', contentType: 'audio/mpeg', sizeBytes: 1),
      ]),
    );

    await tester.tap(find.byTooltip('اقدامات آهنگ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ارسال به بله'));
    await tester.pumpAndSettle();

    expect(bots.sent, ['bale/s1']);
    expect(find.text('بات ریتمو «Song» را در بله برایت می‌فرستد.'),
        findsOneWidget);
  });

  testWidgets('without a linked bot the track menu offers no sending', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      tokenStore: MemoryTokenStore('valid-token'),
      bots: FakeBotsApi(),
      tracks: FakeTracksApi(const [
        Track(id: 's1', title: 'Song', contentType: 'audio/mpeg', sizeBytes: 1),
      ]),
    );

    await tester.tap(find.byTooltip('اقدامات آهنگ'));
    await tester.pumpAndSettle();

    expect(find.textContaining('ارسال به'), findsNothing);
  });

  testWidgets('imported tracks say where they came from; imports show progress',
      (tester) async {
    final tracks = FakeTracksApi(const [
      Track(
          id: 'b1',
          title: 'Imported',
          contentType: 'audio/mpeg',
          sizeBytes: 1,
          source: 'bale'),
      Track(
          id: 'u1',
          title: 'Uploaded',
          contentType: 'audio/mpeg',
          sizeBytes: 1,
          source: 'upload'),
    ])
      ..importsInProgress = 1;
    await _pumpApp(tester,
        tokenStore: MemoryTokenStore('valid-token'),
        tracks: tracks,
        settle: false);
    // The spinner never settles, so step through startup instead.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byTooltip('از بله'), findsOneWidget);
    expect(find.text('یک فایل در حال اضافه شدن است…'), findsOneWidget);

    // The import finishes; the next scheduled check picks it up.
    tracks.importsInProgress = 0;
    await tester.pump(importPollDelays.first);
    await tester.pump();
    expect(find.text('یک فایل در حال اضافه شدن است…'), findsNothing);
  });

  testWidgets('every library tab label fits on a 360 px phone', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester,
        tokenStore: MemoryTokenStore('valid-token'),
        playlists: FakePlaylistsApi());

    for (final label in ['آهنگ‌ها', 'فهرست‌های پخش', 'آلبوم‌ها', 'هنرمندان']) {
      final text =
          find.descendant(of: find.byType(TabBar), matching: find.text(label));
      expect(text, findsOneWidget, reason: label);
      final tab = tester
          .getRect(find.ancestor(of: text, matching: find.byType(Tab)).first);
      final shown = tester.getRect(text);
      expect(shown.left, greaterThanOrEqualTo(tab.left - 0.5), reason: label);
      expect(shown.right, lessThanOrEqualTo(tab.right + 0.5), reason: label);
      expect(tab.height, greaterThanOrEqualTo(48), reason: label);
    }
    expect(tester.takeException(), isNull);
  });
}
