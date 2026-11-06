import 'dart:typed_data';

import 'response_cache_stub.dart'
    if (dart.library.io) 'response_cache_io.dart'
    if (dart.library.js_interop) 'response_cache_web.dart' as platform;

/// What the server last answered, kept on this device so the app still
/// shows the listener's music, playlists and covers while it is offline.
/// Keys are opaque; values are replaced on every successful request.
abstract interface class ResponseCache {
  Future<String?> read(String key);
  Future<void> write(String key, String value);

  /// Small binary answers such as covers; null where they aren't kept.
  Future<Uint8List?> readBytes(String key);
  Future<void> writeBytes(String key, Uint8List value);

  /// Forgets everything, for example when the listener signs out.
  Future<void> clear();
}

/// Keeps answers for as long as the app runs; used in tests.
class MemoryResponseCache implements ResponseCache {
  final texts = <String, String>{};
  final bytes = <String, Uint8List>{};

  @override
  Future<String?> read(String key) async => texts[key];

  @override
  Future<void> write(String key, String value) async => texts[key] = value;

  @override
  Future<Uint8List?> readBytes(String key) async => bytes[key];

  @override
  Future<void> writeBytes(String key, Uint8List value) async =>
      bytes[key] = value;

  @override
  Future<void> clear() async {
    texts.clear();
    bytes.clear();
  }
}

ResponseCache createResponseCache() => platform.createResponseCache();
