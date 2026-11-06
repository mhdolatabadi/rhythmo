import 'dart:io';

import 'package:flutter/services.dart';
import 'package:rhythmo/features/playlists/data/device_playlist_source.dart';

class AndroidDevicePlaylistSource implements DevicePlaylistSource {
  static const _channel = MethodChannel('ir.mhdolatabadi.nafir/local_audio');

  @override
  bool get supported => Platform.isAndroid;

  @override
  Future<List<DevicePlaylist>> load() async {
    if (!supported) return const [];
    final raw = await _channel.invokeMethod<List<Object?>>('queryPlaylists') ??
        const [];
    return raw.map((item) {
      final map = Map<Object?, Object?>.from(item! as Map);
      return DevicePlaylist(
        id: map['id']! as String,
        name: map['name']! as String,
        owner: map['owner'] as String?,
        trackIds: [
          for (final id in map['audioIds'] as List<Object?>? ?? const [])
            'device:$id',
        ],
      );
    }).toList(growable: false);
  }
}

DevicePlaylistSource createDevicePlaylistSource() =>
    AndroidDevicePlaylistSource();
