import 'package:just_audio/just_audio.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/data/audio_cache.dart';

/// The web has no file system to cache into; stream straight from the URL.
class StreamingAudioCache implements AudioCache {
  @override
  Future<AudioSource> sourceFor(Track track, Uri url) async =>
      AudioSource.uri(url, tag: track.id);

  @override
  Future<bool> hasComplete(Track track) async => false;

  @override
  bool get isManaged => false;

  @override
  Future<int> sizeBytes() async => 0;

  @override
  Future<void> clear({String? keep}) async {}
}

AudioCache createAudioCache() => StreamingAudioCache();
