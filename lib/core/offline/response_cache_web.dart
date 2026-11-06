import 'dart:typed_data';

import 'package:rhythmo/core/offline/response_cache.dart';
import 'package:web/web.dart' as web;

const _prefix = 'rhythmo.offline.';

/// Keeps answers in the browser's local storage. Covers are left out: the
/// few megabytes it allows are kept for the library and playlists. A full
/// or blocked storage only means less works offline.
class LocalStorageResponseCache implements ResponseCache {
  @override
  Future<String?> read(String key) async {
    try {
      return web.window.localStorage.getItem('$_prefix$key');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      web.window.localStorage.setItem('$_prefix$key', value);
    } catch (_) {/* Quota exceeded or storage blocked. */}
  }

  @override
  Future<Uint8List?> readBytes(String key) async => null;

  @override
  Future<void> writeBytes(String key, Uint8List value) async {}

  @override
  Future<void> clear() async {
    try {
      final storage = web.window.localStorage;
      for (var i = storage.length - 1; i >= 0; i--) {
        final key = storage.key(i);
        if (key != null && key.startsWith(_prefix)) storage.removeItem(key);
      }
    } catch (_) {/* Storage blocked. */}
  }
}

ResponseCache createResponseCache() => LocalStorageResponseCache();
