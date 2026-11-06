import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rhythmo/core/offline/response_cache.dart';

/// Keeps each answer in its own file in the app's support directory, which
/// the OS does not clear on its own like the temporary one. File names are
/// hashes of the keys. Failing or missing storage only means less works
/// offline, never a failed action.
class FileResponseCache implements ResponseCache {
  FileResponseCache([Future<Directory> Function()? directory])
      : _directory = directory ??
            (() async => Directory(
                '${(await getApplicationSupportDirectory()).path}/offline'));

  final Future<Directory> Function() _directory;

  Future<File> _file(String key, String extension) async {
    final directory = await _directory();
    final name = sha256.convert(utf8.encode(key)).toString().substring(0, 32);
    return File('${directory.path}/$name.$extension');
  }

  @override
  Future<String?> read(String key) async {
    try {
      final file = await _file(key, 'json');
      return await file.exists() ? await file.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      final file = await _file(key, 'json');
      await file.parent.create(recursive: true);
      // Write beside it, then swap, so a crash never leaves half a file.
      final partial = File('${file.path}.part');
      await partial.writeAsString(value, flush: true);
      await partial.rename(file.path);
    } catch (_) {/* Optional. */}
  }

  @override
  Future<Uint8List?> readBytes(String key) async {
    try {
      final file = await _file(key, 'bin');
      return await file.exists() ? await file.readAsBytes() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeBytes(String key, Uint8List value) async {
    try {
      final file = await _file(key, 'bin');
      await file.parent.create(recursive: true);
      final partial = File('${file.path}.part');
      await partial.writeAsBytes(value, flush: true);
      await partial.rename(file.path);
    } catch (_) {/* Optional. */}
  }

  @override
  Future<void> clear() async {
    try {
      final directory = await _directory();
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (_) {/* Optional. */}
  }
}

ResponseCache createResponseCache() => FileResponseCache();
