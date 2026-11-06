import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract final class AppConfiguration {
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// The web build is served by the same host as the API, so it falls back to
  /// its own origin and one image works for any domain.
  static bool get isApiConfigured => apiBaseUrl.isNotEmpty || kIsWeb;

  static Uri? get apiBaseUri {
    if (apiBaseUrl.isEmpty) {
      return kIsWeb ? Uri.parse(Uri.base.origin) : null;
    }
    final uri = Uri.tryParse(apiBaseUrl);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) return null;
    return uri;
  }

  /// A public page of the rhythmo site, such as `/privacy`, which is served
  /// from the same origin as the API.
  static Uri? sitePage(String path) => apiBaseUri?.resolve(path);

  /// The rhythmo link the app was opened with: the page address on the
  /// web, the App Link that started the app on Android.
  static Uri? _launchUri = kIsWeb ? Uri.base : null;

  static const _links = MethodChannel('ir.mhdolatabadi.nafir/links');

  /// Bumped when Android opens a rhythmo link while the app is running;
  /// listeners show what it links to, as for a fresh start.
  static final linkOpened = ValueNotifier<int>(0);

  /// Reads the App Link that started the app on Android and listens for
  /// later ones. Call once before the app runs.
  static Future<void> loadLaunchLink() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      _launchUri = _parseLink(await _links.invokeMethod<String>('initialLink'));
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
    _links.setMethodCallHandler((call) async {
      if (call.method != 'link') return;
      final uri = _parseLink(call.arguments as String?);
      if (uri == null) return;
      openLink(uri);
    });
  }

  /// Treats [uri] as the link the app was just opened with.
  @visibleForTesting
  static void openLink(Uri uri) {
    _launchUri = uri;
    _shareTokenTaken = false;
    _collabTokenTaken = false;
    _storeSongTaken = false;
    linkOpened.value++;
  }

  static Uri? _parseLink(String? link) =>
      link == null ? null : Uri.tryParse(link);

  static String? _query(String name) {
    final value = _launchUri?.queryParameters[name];
    return value == null || value.isEmpty ? null : value;
  }

  /// The path segment after [prefix] in an App Link such as `/p/{token}`.
  /// The web app only ever runs under /app/, so this is for Android.
  static String? _pathAfter(List<String> prefix) {
    if (kIsWeb) return null;
    final segments = _launchUri?.pathSegments ?? const <String>[];
    if (segments.length <= prefix.length) return null;
    for (var i = 0; i < prefix.length; i++) {
      if (segments[i] != prefix[i]) return null;
    }
    final value = segments[prefix.length];
    return value.isEmpty ? null : value;
  }

  /// The share token of a playlist link the app was opened with
  /// (`/app/?shared=…`, or a public page `/p/…` on Android), taken only once.
  static String? takeInitialShareToken() {
    if (_shareTokenTaken) return null;
    _shareTokenTaken = true;
    return _query('shared') ?? _pathAfter(const ['p']);
  }

  static bool _shareTokenTaken = false;

  /// The collaboration link the app was opened with (`/app/?collab=…`),
  /// to join once signed in. Taken only once.
  static String? takeInitialCollabToken() {
    if (_collabTokenTaken) return null;
    final token = peekInitialCollabToken();
    _collabTokenTaken = true;
    return token;
  }

  /// The same, without taking it: a guest is asked to sign in first.
  static String? peekInitialCollabToken() {
    if (_collabTokenTaken) return null;
    return _query('collab');
  }

  static bool _collabTokenTaken = false;

  /// The store song the app was opened with (`/app/?store=…` from a store
  /// page's «افزودن به کتابخانه‌ی من», or `/store/t/…` on Android). Taken
  /// only once.
  static String? takeInitialStoreSong() {
    if (_storeSongTaken) return null;
    _storeSongTaken = true;
    return _query('store') ?? _pathAfter(const ['store', 't']);
  }

  static bool _storeSongTaken = false;
}
