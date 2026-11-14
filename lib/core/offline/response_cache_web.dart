import 'dart:js_interop';
import 'dart:typed_data';

import 'package:rhythmo/core/offline/response_cache.dart';
import 'package:web/web.dart' as web;

const _prefix = 'rhythmo.offline.';
const _cacheName = 'rhythmo-offline-v1';

/// Address an answer is filed under; never fetched.
String _address(String key) =>
    'https://offline.rhythmo.invalid/${Uri.encodeComponent(key)}';

/// Keeps answers in the browser's Cache Storage, which holds far more than
/// the few megabytes of local storage, so a large library and its covers
/// are still there offline (#405). Where Cache Storage is missing (an
/// insecure origin, an old browser) local storage is used instead, without
/// covers. A full or blocked storage only means less works offline.
class BrowserResponseCache implements ResponseCache {
  Future<web.Cache>? _cache;

  Future<web.Cache?> _open() async {
    try {
      return await (_cache ??= web.window.caches.open(_cacheName).toDart);
    } catch (_) {
      _cache = null;
      return null;
    }
  }

  Future<web.Response?> _match(String key) async {
    final cache = await _open();
    if (cache == null) return null;
    try {
      return await cache.match(_address(key).toJS).toDart;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> read(String key) async {
    final kept = await _match(key);
    if (kept != null) {
      try {
        return (await kept.text().toDart).toDart;
      } catch (_) {/* Fall back to an older copy. */}
    }
    try {
      // Kept by an earlier version, or where Cache Storage is missing.
      return web.window.localStorage.getItem('$_prefix$key');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final cache = await _open();
    if (cache != null) {
      try {
        await cache
            .put(
                _address(key).toJS,
                web.Response(
                    value.toJS,
                    web.ResponseInit(
                        headers: {'content-type': 'application/json'}.jsify()
                            as web.HeadersInit)))
            .toDart;
        try {
          web.window.localStorage.removeItem('$_prefix$key');
        } catch (_) {/* Storage blocked. */}
        return;
      } catch (_) {/* Full: try local storage. */}
    }
    try {
      web.window.localStorage.setItem('$_prefix$key', value);
    } catch (_) {/* Quota exceeded or storage blocked. */}
  }

  @override
  Future<Uint8List?> readBytes(String key) async {
    final kept = await _match(key);
    if (kept == null) return null;
    try {
      return (await kept.arrayBuffer().toDart).toDart.asUint8List();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeBytes(String key, Uint8List value) async {
    final cache = await _open();
    if (cache == null) return;
    try {
      await cache.put(_address(key).toJS, web.Response(value.toJS)).toDart;
    } catch (_) {/* Optional. */}
  }

  @override
  Future<void> clear() async {
    try {
      await web.window.caches.delete(_cacheName).toDart;
    } catch (_) {/* Unavailable. */}
    _cache = null;
    try {
      final storage = web.window.localStorage;
      for (var i = storage.length - 1; i >= 0; i--) {
        final key = storage.key(i);
        if (key != null && key.startsWith(_prefix)) storage.removeItem(key);
      }
    } catch (_) {/* Storage blocked. */}
  }
}

ResponseCache createResponseCache() => BrowserResponseCache();
