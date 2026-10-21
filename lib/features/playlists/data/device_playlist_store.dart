import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:rhythmo/features/library/data/track.dart';

/// Device-only membership never travels to the playlist API or share links.
/// Playlist UUIDs scope each record to the corresponding account's playlist.
abstract interface class DevicePlaylistStore {
  Future<List<Track>> read(String playlistId);
  Future<void> write(String playlistId, List<Track> tracks);
}

class SecureDevicePlaylistStore implements DevicePlaylistStore {
  SecureDevicePlaylistStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  String _key(String id) => 'rhythmo.device_playlist.$id';

  @override
  Future<List<Track>> read(String playlistId) async {
    final raw = await _storage.read(key: _key(playlistId));
    if (raw == null) return [];
    final entries = jsonDecode(raw) as List<dynamic>;
    return [
      for (final entry in entries)
        Track(
          id: entry['id'] as String,
          title: entry['title'] as String,
          artist: entry['artist'] as String?,
          album: entry['album'] as String?,
          fileName: entry['fileName'] as String?,
          contentType: entry['contentType'] as String,
          sizeBytes: entry['sizeBytes'] as int,
          sourceUri: Uri.parse(entry['sourceUri'] as String),
        ),
    ];
  }

  @override
  Future<void> write(String playlistId, List<Track> tracks) async {
    if (tracks.isEmpty) {
      await _storage.delete(key: _key(playlistId));
      return;
    }
    await _storage.write(
      key: _key(playlistId),
      value: jsonEncode([
        for (final track in tracks)
          if (track.isLocal && track.id.startsWith('device:'))
            {
              'id': track.id,
              'title': track.title,
              'artist': track.artist,
              'album': track.album,
              'fileName': track.fileName,
              'contentType': track.contentType,
              'sizeBytes': track.sizeBytes,
              'sourceUri': track.sourceUri.toString(),
            },
      ]),
    );
  }
}

class MemoryDevicePlaylistStore implements DevicePlaylistStore {
  final Map<String, List<Track>> _tracks = {};

  @override
  Future<List<Track>> read(String playlistId) async =>
      List.of(_tracks[playlistId] ?? const <Track>[]);

  @override
  Future<void> write(String playlistId, List<Track> tracks) async {
    _tracks[playlistId] = List.of(tracks);
  }
}
