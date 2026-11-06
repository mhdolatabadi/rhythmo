import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/playlists/application/device_playlist_import.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/data/device_playlist_source.dart';
import 'package:rhythmo/features/playlists/data/device_playlist_store.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';
import 'package:rhythmo/features/playlists/presentation/device_playlist_import_dialog.dart';

/// Playlists kept by name and ID, with the cloud tracks it was given.
class _Api implements PlaylistsApi {
  final playlists = <String, Playlist>{};
  final cloud = <String, Track>{};
  final deleted = <String>[];
  bool replaceFails = false;

  Playlist _make(String id, String name, List<Track> tracks) => Playlist(
        id: id,
        name: name,
        trackCount: tracks.length,
        tracks: tracks,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

  @override
  Future<List<Playlist>> listPlaylists(String token) async =>
      playlists.values.toList();

  @override
  Future<Playlist> createPlaylist(String token, String name) async {
    final id = 'p${playlists.length + 1}';
    return playlists[id] = _make(id, name, const []);
  }

  @override
  Future<Playlist> getPlaylist(String token, String playlistId) async =>
      playlists[playlistId]!;

  @override
  Future<Playlist> replacePlaylistTracks(
      String token, String playlistId, List<String> trackIds) async {
    if (replaceFails) throw const ApiException('500', statusCode: 500);
    final old = playlists[playlistId]!;
    return playlists[playlistId] =
        _make(playlistId, old.name, [for (final id in trackIds) cloud[id]!]);
  }

  @override
  Future<void> deletePlaylist(String token, String playlistId) async {
    deleted.add(playlistId);
    playlists.remove(playlistId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Source implements DevicePlaylistSource {
  _Source(this.playlists);

  List<DevicePlaylist> playlists;
  bool fails = false;

  @override
  bool get supported => true;

  @override
  Future<List<DevicePlaylist>> load() async {
    if (fails) throw StateError('no MediaStore');
    return playlists;
  }
}

Track _device(int id, {String? title, int size = 10}) => Track(
      id: 'device:$id',
      title: title ?? 'آهنگ $id',
      fileName: 'song$id.mp3',
      contentType: 'audio/mpeg',
      sizeBytes: size + id,
      sourceUri: Uri.parse('content://media/external/audio/media/$id'),
    );

void main() {
  const road = DevicePlaylist(
    id: '7',
    name: 'جاده',
    owner: samsungMusicPackage,
    trackIds: ['device:1', 'device:2', 'device:9', 'device:1'],
  );
  const empty = DevicePlaylist(id: '8', name: 'خالی', trackIds: []);

  late _Api api;
  late PlaylistsController playlists;
  late MemoryDevicePlaylistOfferStore offers;

  DevicePlaylistImporter importer(_Source source) => DevicePlaylistImporter(
      source: source, playlists: playlists, offers: offers);

  setUp(() {
    api = _Api();
    offers = MemoryDevicePlaylistOfferStore();
    playlists = PlaylistsController(
      api: api,
      token: () => 'token',
      accountId: () => 'user',
      deviceStore: MemoryDevicePlaylistStore(),
    );
  });

  test('imports in order, uploaded files as the account track', () async {
    // song2.mp3 was uploaded: the server copy has the same size and title.
    final uploaded = Track(
        id: 'cloud-2',
        title: 'آهنگ 2',
        fileName: 'song2.mp3',
        contentType: 'audio/mpeg',
        sizeBytes: 12);
    api.cloud[uploaded.id] = uploaded;
    final result = await importer(_Source([road])).import(
      [road],
      cloud: [uploaded],
      device: [_device(1), _device(2)],
    );

    expect(result.imported, 1);
    expect(result.tracks, 2);
    expect(result.missing, 1, reason: 'device:9 is no longer on the phone');
    final made = (await playlists.loadPlaylist('p1'))!;
    expect(made.name, 'جاده');
    expect(made.tracks.map((t) => t.id), ['cloud-2', 'device:1']);
    expect(api.playlists['p1']!.tracks.map((t) => t.id), ['cloud-2'],
        reason: 'device-only tracks never reach the server');
  });

  test('offers each playlist once per account, skipping empty ones', () async {
    final source = _Source([road, empty]);
    expect((await importer(source).toOffer()).map((p) => p.id), ['7']);
    await importer(source).markOffered([road]);
    expect(await importer(source).toOffer(), isEmpty);
    expect(await importer(source).available(), hasLength(1),
        reason: 'the manual import still lists it');

    source.playlists = [
      road,
      const DevicePlaylist(id: '10', name: 'تازه', trackIds: ['device:1'])
    ];
    expect((await importer(source).toOffer()).map((p) => p.id), ['10']);
  });

  test('a failing device query offers nothing', () async {
    expect(await importer(_Source([road])..fails = true).toOffer(), isEmpty);
  });

  test('nothing is offered when signed out', () async {
    final signedOut = PlaylistsController(api: api, token: () => null);
    final importer = DevicePlaylistImporter(
        source: _Source([road]), playlists: signedOut, offers: offers);
    expect(await importer.toOffer(), isEmpty);
  });

  test('a failed import leaves no empty playlist behind', () async {
    api.replaceFails = true;
    api.cloud['cloud-1'] = Track(
        id: 'cloud-1',
        title: 'آهنگ 1',
        fileName: 'song1.mp3',
        contentType: 'audio/mpeg',
        sizeBytes: 11);
    final result = await importer(_Source([road]))
        .import([road], cloud: [api.cloud['cloud-1']!], device: [_device(1)]);
    expect(result.imported, 0);
    expect(result.failed, 1);
    expect(api.deleted, ['p1']);
    expect(api.playlists, isEmpty);
    expect(await importer(_Source([road])).toOffer(), isEmpty);
  });

  test('the import message counts what came in and what did not', () {
    expect(
        importMessage(const DevicePlaylistImportResult(
            imported: 2, tracks: 15, missing: 1)),
        '۲ فهرست پخش با ۱۵ آهنگ به ریتمو آمد. ۱ آهنگ دیگر روی گوشی نبود.');
  });

  testWidgets('asks which Samsung Music playlists to import', (tester) async {
    List<DevicePlaylist>? chosen;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            chosen = await showDialog<List<DevicePlaylist>>(
              context: context,
              builder: (_) => const DevicePlaylistImportDialog(
                playlists: [
                  road,
                  DevicePlaylist(
                      id: '11',
                      name: 'ورزش',
                      owner: samsungMusicPackage,
                      trackIds: ['device:3']),
                ],
                existingNames: {'ورزش'},
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('فهرست‌های پخش سامسونگ موزیک'), findsOneWidget);
    expect(find.textContaining('هم‌نامش در ریتمو هست'), findsOneWidget);
    // The one already in rhythmo starts unticked.
    expect(find.text('وارد کردن ۱ فهرست'), findsOneWidget);
    await tester.tap(find.text('وارد کردن ۱ فهرست'));
    await tester.pumpAndSettle();
    expect(chosen!.map((p) => p.id), ['7']);
  });
}
