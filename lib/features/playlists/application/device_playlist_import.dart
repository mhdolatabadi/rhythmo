import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:rhythmo/features/library/application/library_entries.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/data/device_playlist_source.dart';

/// Which device playlists each account was already asked about, so the
/// offer to import them comes once, not on every start.
abstract interface class DevicePlaylistOfferStore {
  Future<Set<String>> read(String scope);
  Future<void> write(String scope, Set<String> ids);
}

class SecureDevicePlaylistOfferStore implements DevicePlaylistOfferStore {
  SecureDevicePlaylistOfferStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  String _key(String scope) => 'rhythmo.device_playlist_offers.$scope';

  @override
  Future<Set<String>> read(String scope) async {
    final raw = await _storage.read(key: _key(scope));
    if (raw == null) return {};
    return {for (final id in jsonDecode(raw) as List<dynamic>) id as String};
  }

  @override
  Future<void> write(String scope, Set<String> ids) =>
      _storage.write(key: _key(scope), value: jsonEncode(ids.toList()));
}

class MemoryDevicePlaylistOfferStore implements DevicePlaylistOfferStore {
  final Map<String, Set<String>> _ids = {};

  @override
  Future<Set<String>> read(String scope) async => {...?_ids[scope]};

  @override
  Future<void> write(String scope, Set<String> ids) async =>
      _ids[scope] = {...ids};
}

class DevicePlaylistImportResult {
  const DevicePlaylistImportResult({
    this.imported = 0,
    this.tracks = 0,
    this.missing = 0,
    this.failed = 0,
  });

  /// Playlists made in rhythmo.
  final int imported;

  /// Tracks put in them.
  final int tracks;

  /// Tracks whose file is no longer among the device's music.
  final int missing;

  /// Playlists that could not be made.
  final int failed;
}

/// Brings playlists from Samsung Music and other players on the device into
/// the account's playlists. A device file that is already uploaded joins as
/// the account's track; the rest stay device-only, as when added by hand.
class DevicePlaylistImporter {
  DevicePlaylistImporter({
    required DevicePlaylistSource source,
    required PlaylistsController playlists,
    DevicePlaylistOfferStore? offers,
  })  : _source = source,
        _playlists = playlists,
        _offers = offers ?? SecureDevicePlaylistOfferStore();

  final DevicePlaylistSource _source;
  final PlaylistsController _playlists;
  final DevicePlaylistOfferStore _offers;

  bool get supported => _source.supported;

  /// The device's playlists that have tracks.
  Future<List<DevicePlaylist>> available() async {
    if (!supported) return const [];
    try {
      return [
        for (final playlist in await _source.load())
          if (playlist.trackIds.isNotEmpty) playlist,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// The playlists not offered to this account yet.
  Future<List<DevicePlaylist>> toOffer() async {
    if (!_playlists.signedIn) return const [];
    final found = await available();
    if (found.isEmpty) return const [];
    final offered = await _readOffers();
    return [
      for (final playlist in found)
        if (!offered.contains(playlist.id)) playlist,
    ];
  }

  /// Remembers that the user saw [playlists], imported or not.
  Future<void> markOffered(Iterable<DevicePlaylist> playlists) async {
    final scope = _playlists.deviceScope;
    try {
      await _offers.write(scope, {
        ...await _readOffers(),
        for (final playlist in playlists) playlist.id,
      });
    } catch (_) {
      // Asking again later is better than failing the import.
    }
  }

  Future<Set<String>> _readOffers() async {
    try {
      return await _offers.read(_playlists.deviceScope);
    } catch (_) {
      return {};
    }
  }

  /// Makes a rhythmo playlist for each of [chosen], with the tracks found
  /// among [device] music in their order; as in every playlist, device-only
  /// tracks come after the account's.
  Future<DevicePlaylistImportResult> import(
    List<DevicePlaylist> chosen, {
    required List<Track> cloud,
    required List<Track> device,
  }) async {
    final byDeviceId = {
      for (final entry in mergeLibrary(cloud, device))
        if (entry.local case final local?) local.id: entry.track,
    };
    var imported = 0, tracks = 0, missing = 0, failed = 0;
    for (final source in chosen) {
      final members = <String, Track>{};
      for (final id in source.trackIds) {
        final track = byDeviceId[id];
        if (track == null) {
          missing++;
        } else {
          members.putIfAbsent(track.id, () => track);
        }
      }
      if (members.isEmpty) {
        failed++;
        continue;
      }
      final playlist = await _playlists.create(source.name);
      if (playlist == null) {
        failed++;
        continue;
      }
      final filled = await _playlists.replaceTracks(
        playlist.id,
        members.keys.toList(),
        deviceTracks: members.values.toList(),
      );
      if (filled == null) {
        // No empty leftovers from an import that went wrong.
        await _playlists.delete(playlist.id);
        failed++;
        continue;
      }
      imported++;
      tracks += members.length;
    }
    await markOffered(chosen);
    return DevicePlaylistImportResult(
        imported: imported, tracks: tracks, missing: missing, failed: failed);
  }
}
