import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/library/data/track_artwork.dart';

const song = Track(
  id: 'one',
  title: 'آهنگ',
  contentType: 'audio/mpeg',
  sizeBytes: 100,
);

void main() {
  test('cache shares requests, separates contexts and clears on account change',
      () async {
    var calls = 0;
    final controller = TrackArtworkController((track) async {
      calls++;
      return Uint8List.fromList([1, 2, 3]);
    });
    await Future.wait([controller.load(song), controller.load(song)]);
    expect(calls, 1);
    await controller.load(const Track(
      id: 'one',
      title: 'آهنگ',
      contentType: 'audio/mpeg',
      sizeBytes: 100,
      fromStore: true,
    ));
    expect(calls, 2);
    controller.clear();
    await controller.load(song);
    expect(calls, 3);
    controller.dispose();
  });

  test('private, shared, collaborative and store covers use playback access',
      () async {
    final requests = <http.Request>[];
    final api = ApiClient(
      Uri.parse('https://music.example.com'),
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response.bytes([1], 200,
            headers: {'content-type': 'image/jpeg'});
      }),
    );
    for (final track in [
      song,
      const Track(
          id: 'two',
          title: '',
          contentType: '',
          sizeBytes: 1,
          sharedVia: 'shared'),
      const Track(
          id: 'three',
          title: '',
          contentType: '',
          sizeBytes: 1,
          viaPlaylist: 'collab'),
      const Track(
          id: 'four',
          title: '',
          contentType: '',
          sizeBytes: 1,
          fromStore: true),
    ]) {
      await api.trackArtwork('token', track);
    }
    expect(requests.map((r) => r.url.path), [
      '/api/v1/tracks/one/artwork',
      '/api/v1/shared-playlists/shared/tracks/two/artwork',
      '/api/v1/playlists/collab/tracks/three/artwork',
      '/api/v1/store/tracks/four/artwork',
    ]);
    expect(requests.every((r) => r.headers['Authorization'] == 'Bearer token'),
        isTrue);
    await api.trackArtwork(null, song);
    expect(requests.length, 4);
  });

  testWidgets('cover replaces placeholder at narrow width; no cover falls back',
      (tester) async {
    final picture = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
    );
    final pending = Completer<Uint8List?>();
    final controller = TrackArtworkController((_) => pending.future);
    Widget app() => MaterialApp(
          home: TrackArtworkScope(
            controller: controller,
            child: const Center(
              child: SizedBox(
                width: 48,
                height: 48,
                child: TrackCover(track: song, child: Icon(Icons.music_note)),
              ),
            ),
          ),
        );
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app());
    expect(find.byIcon(Icons.music_note), findsOneWidget);
    pending.complete(picture);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(tester.getSize(find.byType(TrackCover)), const Size(48, 48));
    expect(tester.takeException(), isNull);
    controller.dispose();

    final missing = TrackArtworkController((_) async => null);
    await tester.pumpWidget(MaterialApp(
      home: TrackArtworkScope(
        controller: missing,
        child: const SizedBox(
          width: 48,
          height: 48,
          child: TrackCover(track: song, child: Icon(Icons.music_note)),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.music_note), findsOneWidget);
    missing.dispose();
  });
}
