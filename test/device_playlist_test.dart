import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/data/device_playlist_store.dart';

import 'playlist_sharing_test.dart' show FakePlaylistsApi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final local = Track(
      id: 'device:1',
      title: 'محلی',
      artist: 'هنرمند',
      contentType: 'audio/mpeg',
      sizeBytes: 42,
      sourceUri: Uri.parse('content://media/external/audio/1'));
  const cloud = Track(
      id: 'cloud', title: 'Cloud', contentType: 'audio/mpeg', sizeBytes: 9);

  test('device membership survives restart, deduplicates and stays off API',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final api = FakePlaylistsApi()..tracks = [cloud];
    PlaylistsController controller() => PlaylistsController(
        api: api,
        token: () => 'token',
        accountId: () => 'user',
        deviceStore: SecureDevicePlaylistStore());
    final first = controller();
    expect(await first.addDeviceTrack('p1', local), AddTrackResult.added);
    expect(api.replacedWith, isNull);
    expect(
        await first.addDeviceTrack('p1', local), AddTrackResult.alreadyPresent);
    final restarted = controller();
    final restored = (await restarted.loadPlaylist('p1'))!;
    expect(restored.tracks.map((t) => t.id), ['cloud', 'device:1']);
    expect(restored.tracks.last.sourceUri, local.sourceUri);
    expect(restored.tracks.last.artist, local.artist);
    await restarted.replaceTracks('p1', ['device:1']);
    expect(api.replacedWith, isEmpty);
    expect((await restarted.loadPlaylist('p1'))!.tracks.single.id, local.id);
    await restarted.replaceTracks('p1', []);
    expect((await restarted.loadPlaylist('p1'))!.tracks, isEmpty);
  });

  test('device tracks are scoped to account even in a shared playlist',
      () async {
    final api = FakePlaylistsApi();
    final store = MemoryDevicePlaylistStore();
    var account = 'one';
    final controller = PlaylistsController(
        api: api,
        token: () => 'token',
        accountId: () => account,
        deviceStore: store);
    await controller.addDeviceTrack('p1', local);
    account = 'two';
    expect((await controller.loadPlaylist('p1'))!.tracks, isEmpty);
    account = 'one';
    expect((await controller.loadPlaylist('p1'))!.tracks.single.id, local.id);
  });

  test('adding cloud music retains the device entries', () async {
    final api = FakePlaylistsApi()..tracks = [cloud];
    final controller = PlaylistsController(api: api, token: () => 'token');
    await controller.addDeviceTrack('p1', local);
    await controller.addTrack('p1', 'another');
    expect(api.replacedWith, ['cloud', 'another']);
    expect((await controller.loadPlaylist('p1'))!.tracks.last.id, local.id);
  });
}
