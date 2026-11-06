import 'package:rhythmo/features/playlists/data/device_playlist_source.dart';

class UnsupportedDevicePlaylistSource implements DevicePlaylistSource {
  @override
  bool get supported => false;

  @override
  Future<List<DevicePlaylist>> load() async => const [];
}

DevicePlaylistSource createDevicePlaylistSource() =>
    UnsupportedDevicePlaylistSource();
