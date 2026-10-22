import 'package:just_audio/just_audio.dart';
import 'package:rhythmo/features/library/data/track.dart';

import 'audio_cache_stub.dart' if (dart.library.io) 'audio_cache_io.dart'
    as platform;

/// Builds the audio source for a track. On devices with a file system, played
/// tracks are kept in a bounded, disposable cache; on the web the browser's
/// own HTTP cache is used.
abstract interface class AudioCache {
  Future<AudioSource> sourceFor(Track track, Uri url);

  /// Whether the app controls this cache. On the web the browser's HTTP cache
  /// holds audio instead, and the app can neither measure nor clear it.
  bool get isManaged;

  /// Bytes on disk, including partial downloads.
  Future<int> sizeBytes();

  /// Deletes cached audio, except the track [keep] (the one playing, which
  /// may still be downloading). Tracks and their metadata in the cloud are
  /// never touched.
  Future<void> clear({String? keep});
}

/// Optional lifecycle for caches that own a local streaming server.
abstract interface class DisposableAudioCache {
  Future<void> dispose();
}

AudioCache createAudioCache() => platform.createAudioCache();
