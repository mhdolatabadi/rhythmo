import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/data/audio_cache.dart';
import 'package:path_provider/path_provider.dart';

const defaultCacheBytes = 500 * 1024 * 1024;

const _extensions = {
  'audio/mpeg': 'mp3',
  'audio/mp4': 'm4a',
  'audio/aac': 'aac',
  'audio/flac': 'flac',
  'audio/ogg': 'ogg',
  'audio/wav': 'wav',
  'audio/webm': 'webm',
};

/// The cache file name of [track]'s stored file: its ID plus the revision of
/// the bytes, never the presigned URL, which changes on every request. A
/// metadata edit rewrites the stored file's tags into a new revision, so the
/// edited track is fetched again instead of playing stale bytes (#252).
String cacheFileName(Track track) {
  final extension = _extensions[track.contentType] ?? 'audio';
  return '${track.id}.r${track.embeddedTags.version ?? 0}.$extension';
}

/// Caches played tracks in the app's temporary directory, which the OS may
/// also clear. Files are named by [cacheFileName]. When the cache would
/// exceed [maxBytes], the least recently played tracks are deleted first.
class FileAudioCache implements AudioCache {
  FileAudioCache(this._directory, {this.maxBytes = defaultCacheBytes});

  final Future<Directory> Function() _directory;
  final int maxBytes;

  @override
  Future<AudioSource> sourceFor(Track track, Uri url) async {
    try {
      return await _cachedSourceFor(track, url);
    } on FileSystemException {
      // Cache storage is optional. A full/unavailable temporary directory
      // must not prevent streaming an otherwise accessible cloud file.
      return AudioSource.uri(url, tag: track.id);
    }
  }

  Future<AudioSource> _cachedSourceFor(Track track, Uri url) async {
    final directory = await _directory();
    await directory.create(recursive: true);
    final name = cacheFileName(track);
    final file = File('${directory.path}/$name');
    await _dropOtherRevisions(directory, track.id, keep: name);
    if (await file.exists()) {
      if (await file.length() == track.sizeBytes) {
        // A complete earlier download of exactly these bytes: play it
        // offline and mark it recent.
        await file.setLastModified(DateTime.now());
        return AudioSource.file(file.path, tag: track.id);
      }
      // Not the stored file (truncated, or from elsewhere): fetch it again.
      await _delete(file);
    }
    await evict(directory, incomingBytes: track.sizeBytes, keep: track.id);
    // Streams the URL while writing the file (as .part until complete).
    // Experimental in just_audio, but the only built-in way to stream and
    // cache at once; it is isolated here so it is easy to replace.
    // ignore: experimental_member_use
    return LockCachingAudioSource(url, cacheFile: file, tag: track.id);
  }

  /// Deletes the cached copies of earlier revisions of track [id], and their
  /// partial downloads, keeping only [keep] and its own partial download.
  Future<void> _dropOtherRevisions(Directory directory, String id,
      {required String keep}) async {
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.split('.').first != id) continue;
      if (name == keep || name.startsWith('$keep.')) continue;
      await _delete(entity);
    }
  }

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Still open by the player; it will be retried next time.
    }
  }

  /// Deletes least recently used tracks until [incomingBytes] more fit.
  Future<void> evict(
    Directory directory, {
    int incomingBytes = 0,
    String? keep,
  }) async {
    final entries = <String, _Entry>{};
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final id = name.split('.').first;
      final stat = await entity.stat();
      final entry = entries.putIfAbsent(id, () => _Entry(id));
      entry.files.add(entity);
      entry.bytes += stat.size;
      if (stat.modified.isAfter(entry.lastUsed)) entry.lastUsed = stat.modified;
    }
    var total = entries.values.fold<int>(0, (sum, e) => sum + e.bytes);
    final oldestFirst = entries.values.toList()
      ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
    for (final entry in oldestFirst) {
      if (total + incomingBytes <= maxBytes) break;
      if (entry.id == keep) continue;
      for (final file in entry.files) {
        try {
          await file.delete();
        } on FileSystemException {
          // Still open by the player; it will be retried next time.
        }
      }
      total -= entry.bytes;
    }
  }

  @override
  bool get isManaged => true;

  @override
  Future<int> sizeBytes() async {
    final directory = await _directory();
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list()) {
      if (entity is File) total += (await entity.stat()).size;
    }
    return total;
  }

  @override
  Future<void> clear({String? keep}) async {
    final directory = await _directory();
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      if (entity.uri.pathSegments.last.split('.').first == keep) continue;
      try {
        await entity.delete();
      } on FileSystemException {
        // Still open by the player; it will be cleared next time.
      }
    }
  }
}

class _Entry {
  _Entry(this.id);

  final String id;
  final files = <File>[];
  int bytes = 0;
  DateTime lastUsed = DateTime.fromMillisecondsSinceEpoch(0);
}

AudioCache createAudioCache() => FileAudioCache(() async =>
    Directory('${(await getTemporaryDirectory()).path}/rhythmo_audio_cache'));
