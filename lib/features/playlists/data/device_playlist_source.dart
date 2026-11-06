import 'device_playlist_source_stub.dart'
    if (dart.library.io) 'device_playlist_source_io.dart' as platform;

/// Samsung Music's package; its playlists are named after it.
const samsungMusicPackage = 'com.sec.android.app.music';

/// A playlist another player keeps on this device, such as Samsung Music.
class DevicePlaylist {
  const DevicePlaylist({
    required this.id,
    required this.name,
    required this.trackIds,
    this.owner,
  });

  /// MediaStore's playlist ID.
  final String id;
  final String name;

  /// The device tracks in play order, as `device:` IDs.
  final List<String> trackIds;

  /// The app that made it, when Android says (Android 10 and newer).
  final String? owner;

  bool get fromSamsungMusic => owner == samsungMusicPackage;
}

abstract interface class DevicePlaylistSource {
  bool get supported;

  /// The device's playlists, or none without the music permission.
  Future<List<DevicePlaylist>> load();
}

DevicePlaylistSource createDevicePlaylistSource() =>
    platform.createDevicePlaylistSource();
