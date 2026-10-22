import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/data/audio_cache_io.dart';

Track _track(String id,
        {int size = 100, String type = 'audio/mpeg', int? tagRevision}) =>
    Track(
      id: id,
      title: id,
      contentType: type,
      sizeBytes: size,
      embeddedTags: EmbeddedTags(
        status: tagRevision == null
            ? EmbeddedTagStatus.original
            : EmbeddedTagStatus.written,
        version: tagRevision,
      ),
    );

void main() {
  late Directory dir;

  setUp(
      () async => dir = await Directory.systemTemp.createTemp('rhythmo_cache'));
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> put(String name, int bytes, int ageMinutes) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(List.filled(bytes, 0));
    await file.setLastModified(
        DateTime.now().subtract(Duration(minutes: ageMinutes)));
  }

  List<String> names() =>
      dir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

  test('a new track streams to a file named by id and revision, not URL',
      () async {
    final cache = FileAudioCache(() async => dir, maxBytes: 1000);
    final source = await cache.sourceFor(_track('t1', type: 'audio/mp4'),
        Uri.parse('https://x/nafir-music/k?X-Amz-Signature=abc'));

    // ignore: experimental_member_use
    expect(source, isA<FileCachingAudioSource>());
    // ignore: experimental_member_use
    final file = (source as FileCachingAudioSource).cacheFile;
    expect(file.path, '${dir.path}/t1.r0.m4a');
  });

  test('unavailable cache storage falls back to direct streaming', () async {
    final blocked = File('${dir.path}/blocked');
    await blocked.writeAsString('not a directory');
    final cache = FileAudioCache(() async => Directory(blocked.path));
    final url = Uri.parse('https://music.example.com/track.mp3');
    final source = await cache.sourceFor(_track('t1'), url);
    expect(source, isA<ProgressiveAudioSource>());
    final direct = source as UriAudioSource;
    expect(direct.uri, url);
    expect(direct.tag, 't1');
  });

  test('a completed download is played from disk and marked recent', () async {
    await put('t1.r0.mp3', 10, 60);
    final cache = FileAudioCache(() async => dir, maxBytes: 1000);

    final source =
        await cache.sourceFor(_track('t1', size: 10), Uri.parse('https://x/'));

    expect(source, isA<ProgressiveAudioSource>());
    expect(
        (source as UriAudioSource).uri.toFilePath(), '${dir.path}/t1.r0.mp3');
    final age = DateTime.now()
        .difference(File('${dir.path}/t1.r0.mp3').lastModifiedSync());
    expect(age.inMinutes, lessThan(1));
  });

  test('least recently played tracks are evicted to stay under the limit',
      () async {
    await put('old.mp3', 400, 30);
    await put('old.mp3.mime', 10, 30);
    await put('mid.mp3', 400, 20);
    await put('new.mp3', 100, 10);
    final cache = FileAudioCache(() async => dir, maxBytes: 1000);

    // 910 cached + 300 incoming > 1000: the oldest (old.*) must go.
    await cache.sourceFor(_track('next', size: 300), Uri.parse('https://x/'));

    expect(names(), ['mid.mp3', 'new.mp3']);
  });

  test('evicts as many as needed and never the track being played', () async {
    await put('a.mp3', 400, 30);
    await put('b.mp3', 400, 20);
    await put('keep.mp3.part', 150, 40);
    final cache = FileAudioCache(() async => dir, maxBytes: 500);

    await cache.evict(dir, incomingBytes: 300, keep: 'keep');

    expect(names(), ['keep.mp3.part']);
  });

  test('size counts every cached file, partial downloads included', () async {
    final cache = FileAudioCache(() async => dir);
    expect(await cache.sizeBytes(), 0);

    await put('a.mp3', 300, 1);
    await put('a.mp3.mime', 10, 1);
    await put('b.m4a.part', 50, 1);

    expect(await cache.sizeBytes(), 360);
  });

  test('size of a cache that was never created is zero', () async {
    final cache = FileAudioCache(() async => Directory('${dir.path}/none'));
    expect(await cache.sizeBytes(), 0);
    await cache.clear();
  });

  test('clear empties the cache but keeps the track being played', () async {
    await put('a.mp3', 10, 1);
    await put('a.mp3.mime', 10, 1);
    await put('playing.mp3.part', 10, 1);
    final cache = FileAudioCache(() async => dir);

    await cache.clear(keep: 'playing');

    expect(names(), ['playing.mp3.part']);
    await cache.clear();
    expect(names(), isEmpty);
    expect(await cache.sizeBytes(), 0);
  });

  test('an edited track is fetched again and its old copies are dropped',
      () async {
    // Cached before the edit, in the old naming and as revision 0.
    await put('t1.mp3', 100, 5);
    await put('t1.r0.mp3', 100, 5);
    await put('t1.r0.mp3.mime', 10, 5);
    await put('other.r0.mp3', 100, 5);
    final cache = FileAudioCache(() async => dir, maxBytes: 10000);

    final source = await cache.sourceFor(
        _track('t1', size: 120, tagRevision: 2), Uri.parse('https://x/'));

    // ignore: experimental_member_use
    expect(source, isA<FileCachingAudioSource>());
    // ignore: experimental_member_use
    final file = (source as FileCachingAudioSource).cacheFile;
    expect(file.path, '${dir.path}/t1.r2.mp3');
    expect(names(), ['other.r0.mp3']);
  });

  test('a cached file of the wrong size is not played', () async {
    await put('t1.r0.mp3', 60, 5);
    final cache = FileAudioCache(() async => dir, maxBytes: 10000);

    final source =
        await cache.sourceFor(_track('t1', size: 100), Uri.parse('https://x/'));

    // ignore: experimental_member_use
    expect(source, isA<FileCachingAudioSource>());
    expect(names(), isEmpty);
  });

  test('HTTP errors stay on the request Future without detached failures',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
    });
    final source = await FileAudioCache(() async => dir).sourceFor(
      _track('t1'),
      Uri.parse('http://127.0.0.1:${server.port}/signed-audio'),
    ) as FileCachingAudioSource;
    await expectLater(
        source.request(),
        throwsA(isA<AudioTransferException>()
            .having((error) => error.code, 'code', 'http_403')));
    await pumpEventQueue();
    expect(names(), isEmpty);
  });

  test('a byte-range response streams unchanged without caching a partial file',
      () async {
    final stored = List<int>.generate(100, (i) => i);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=10-19');
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 10-19/100')
        ..headers.contentType = ContentType('audio', 'mpeg')
        ..contentLength = 10
        ..add(stored.sublist(10, 20));
      await request.response.close();
    });
    final source = await FileAudioCache(() async => dir).sourceFor(
      _track('t1'),
      Uri.parse('http://127.0.0.1:${server.port}/audio'),
    ) as FileCachingAudioSource;
    final response = await source.request(10, 20);
    expect(response.offset, 10);
    expect(response.sourceLength, 100);
    expect(response.contentLength, 10);
    expect(await response.stream.expand((chunk) => chunk).toList(),
        stored.sublist(10, 20));
    expect(names(), isEmpty);
  });

  test('the cached file holds exactly the bytes the server sent', () async {
    // Every byte value, in an order a transform would disturb.
    final stored = List<int>.generate(256 * 1024, (i) => (i * 7919) % 256);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      request.response
        ..headers.contentType = ContentType('audio', 'mpeg')
        ..contentLength = stored.length
        ..add(stored);
      await request.response.close();
    });
    final url =
        Uri.parse('http://127.0.0.1:${server.port}/nafir-music/u/t1.mp3');
    final cache = FileAudioCache(() async => dir, maxBytes: 10 << 20);
    final track = _track('t1', size: stored.length);

    // ignore: experimental_member_use
    final source = await cache.sourceFor(track, url) as FileCachingAudioSource;
    final response = await source.request();
    final played = await response.stream.expand((chunk) => chunk).toList();
    final cached = File('${dir.path}/${cacheFileName(track)}');
    for (var i = 0; i < 50 && !await cached.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(played, stored);
    expect(await cached.readAsBytes(), stored);

    // Played again, the file is used as is, offline.
    final again = await cache.sourceFor(track, url);
    expect(again, isA<ProgressiveAudioSource>());
  });
}
