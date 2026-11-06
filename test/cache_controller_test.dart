import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/data/audio_cache.dart';
import 'package:rhythmo/features/settings/application/cache_controller.dart';

/// An in-memory cache: track id to bytes.
class FakeAudioCache implements AudioCache {
  FakeAudioCache({this.isManaged = true, Map<String, int>? files})
      : files = files ?? {};

  @override
  final bool isManaged;
  final Map<String, int> files;
  Object? error;

  @override
  Future<AudioSource> sourceFor(Track track, Uri url) async =>
      AudioSource.uri(url, tag: track.id);

  @override
  Future<bool> hasComplete(Track track) async =>
      files[track.id] == track.sizeBytes;

  @override
  Future<int> sizeBytes() async {
    if (error != null) throw error!;
    return files.values.fold<int>(0, (sum, bytes) => sum + bytes);
  }

  @override
  Future<void> clear({String? keep}) async {
    if (error != null) throw error!;
    files.removeWhere((id, _) => id != keep);
  }
}

void main() {
  test('refresh measures the cache', () async {
    final controller = CacheController(
      cache: FakeAudioCache(files: {'a': 300, 'b': 200}),
      playing: () => null,
    );
    expect(controller.sizeBytes, isNull);

    await controller.refresh();

    expect(controller.sizeBytes, 500);
    expect(controller.busy, isFalse);
    expect(controller.failed, isFalse);
  });

  test('clear keeps the playing track and reports the new size', () async {
    final cache = FakeAudioCache(files: {'a': 300, 'playing': 200});
    final controller = CacheController(cache: cache, playing: () => 'playing');

    expect(await controller.clear(), isTrue);

    expect(cache.files.keys, ['playing']);
    expect(controller.sizeBytes, 200);
  });

  test('a failure is reported, not thrown', () async {
    final cache = FakeAudioCache(files: {'a': 1})..error = Exception('disk');
    final controller = CacheController(cache: cache, playing: () => null);

    expect(await controller.clear(), isFalse);

    expect(controller.failed, isTrue);
    expect(controller.busy, isFalse);
  });
}
