import 'dart:js_interop';

import 'package:just_audio/just_audio.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/data/audio_cache.dart';
import 'package:rhythmo/features/player/data/audio_cache_names.dart';
import 'package:rhythmo/features/player/data/offline_songs.dart';
import 'package:web/web.dart' as web;

const _cacheName = 'rhythmo-songs';

/// Address a kept song is filed under; never fetched.
String _keyFor(Track track) =>
    'https://offline.rhythmo.invalid/${cacheFileName(track)}';

/// Streams from the URL, as the browser always did, except songs the
/// listener kept for offline play: those are in the browser's Cache Storage
/// and play from there, with or without a connection.
class BrowserAudioCache implements AudioCache, OfflineSongStore {
  /// Object URLs of kept songs handed to the player; each holds its file in
  /// memory, so only the last few stay.
  final _objectUrls = <String>[];

  Future<web.Cache> _open() => web.window.caches.open(_cacheName).toDart;

  Future<web.Response?> _kept(Track track) async {
    if (track.isLocal) return null;
    try {
      return await (await _open()).match(_keyFor(track).toJS).toDart;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> hasComplete(Track track) async => await _kept(track) != null;

  @override
  Future<AudioSource> sourceFor(Track track, Uri url) async {
    final kept = await _kept(track);
    if (kept == null) return AudioSource.uri(url, tag: track.id);
    final blob = await kept.blob().toDart;
    final objectUrl = web.URL.createObjectURL(blob);
    _objectUrls.add(objectUrl);
    // The playing song and the one after it.
    while (_objectUrls.length > 3) {
      web.URL.revokeObjectURL(_objectUrls.removeAt(0));
    }
    return AudioSource.uri(Uri.parse(objectUrl), tag: track.id);
  }

  @override
  Future<Set<String>> keptIds() async {
    final requests = (await (await _open()).keys().toDart).toDart;
    return {
      for (final request in requests)
        Uri.parse(request.url).pathSegments.last.split('.').first,
    };
  }

  @override
  Future<void> keep(Track track, Uri url) async {
    final response = await web.window.fetch(url.toString().toJS).toDart;
    if (!response.ok) {
      throw StateError('HTTP ${response.status} while keeping a song.');
    }
    final cache = await _open();
    // Earlier revisions of the same song go.
    for (final request in (await cache.keys().toDart).toDart) {
      if (Uri.parse(request.url).pathSegments.last.split('.').first ==
          track.id) {
        await cache.delete(request).toDart;
      }
    }
    await cache.put(_keyFor(track).toJS, response).toDart;
  }

  @override
  Future<void> forget(Track track) async {
    final cache = await _open();
    for (final request in (await cache.keys().toDart).toDart) {
      if (Uri.parse(request.url).pathSegments.last.split('.').first ==
          track.id) {
        await cache.delete(request).toDart;
      }
    }
  }

  @override
  bool get isManaged => true;

  @override
  Future<int> sizeBytes() async {
    var total = 0;
    for (final response in (await (await _open()).matchAll().toDart).toDart) {
      total += int.tryParse(response.headers.get('content-length') ?? '') ?? 0;
    }
    return total;
  }

  @override
  Future<void> clear({String? keep}) async {
    await web.window.caches.delete(_cacheName).toDart;
  }
}

AudioCache createAudioCache() => BrowserAudioCache();
