import 'package:rhythmo/features/library/data/track.dart';

/// Where a library track's file is kept.
enum TrackLocation {
  /// Only in this device's music, not uploaded.
  device,

  /// Only in the account on the server.
  server,

  /// The same file is on the device and on the server.
  synced,
}

/// One row of the unified library: a track and the copies it stands for.
class LibraryEntry {
  const LibraryEntry({this.cloud, this.local})
      : assert(cloud != null || local != null);

  /// The account's copy, when uploaded.
  final Track? cloud;

  /// The copy in this device's music, when present.
  final Track? local;

  TrackLocation get location => switch ((cloud, local)) {
        (_?, _?) => TrackLocation.synced,
        (_?, null) => TrackLocation.server,
        _ => TrackLocation.device,
      };

  /// What the list shows and plays. A synced track keeps the cloud identity
  /// (playlists, editing, deletion), but plays the device file, offline and
  /// without using data.
  Track get track {
    final cloud = this.cloud;
    final local = this.local;
    if (cloud == null) return local!;
    if (local == null) return cloud;
    return cloud.withDeviceCopy(local.sourceUri!, deviceAddedAt: local.addedAt);
  }
}

/// Merges the account's tracks with the device's music so each file appears
/// once. A device file is the server copy of a track when their sizes match
/// exactly (uploads are never transcoded) and so does their filename, as the
/// server stores it, or their title.
List<LibraryEntry> mergeLibrary(List<Track> cloud, List<Track> local) {
  final unmatched = <int, List<Track>>{};
  for (final track in cloud) {
    unmatched.putIfAbsent(track.sizeBytes, () => []).add(track);
  }
  final localFor = <String, Track>{};
  final deviceOnly = <Track>[];
  for (final device in local) {
    final candidates = unmatched[device.sizeBytes];
    final match = candidates?.where((c) => _sameFile(c, device)).firstOrNull;
    if (match == null) {
      deviceOnly.add(device);
    } else {
      candidates!.remove(match);
      localFor[match.id] = device;
    }
  }
  return [
    for (final track in cloud)
      LibraryEntry(cloud: track, local: localFor[track.id]),
    for (final track in deviceOnly) LibraryEntry(local: track),
  ];
}

/// The library's files that are on this device, the ones added to it most
/// recently first, as the list shows them: only those added within [window]
/// of [now]. Files whose date the device doesn't know are left out.
List<Track> recentlyAddedToDevice(
  List<LibraryEntry> entries, {
  required DateTime now,
  Duration window = const Duration(days: 30),
}) {
  final since = now.subtract(window);
  final recent = [
    for (final entry in entries)
      if (entry.local?.addedAt case final at? when at.isAfter(since))
        (at, entry.track),
  ];
  recent.sort((a, b) => b.$1.compareTo(a.$1));
  return [for (final (_, track) in recent) track];
}

bool _sameFile(Track cloud, Track device) {
  final cloudName = cloud.fileName;
  final deviceName = device.fileName;
  if (cloudName != null &&
      deviceName != null &&
      safeFileName(deviceName) == cloudName) {
    return true;
  }
  return _comparable(cloud.title) == _comparable(device.title);
}

String _comparable(String text) =>
    text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// The server's object name for an uploaded filename (`audio.SafeFileName`):
/// ASCII letters, digits, `-` and `_` with the lowercase extension, for
/// example "آهنگ من.MP3" becomes "track.mp3".
String safeFileName(String name) {
  var base = name.replaceAll('\\', '/').split('/').last;
  if (base == '.' || base == '..') base = '';
  final dot = base.lastIndexOf('.');
  final ext = dot < 0 ? '' : base.substring(dot).toLowerCase();
  final stemSource = dot < 0 ? base : base.substring(0, dot);
  var stem = stemSource.runes.map((rune) {
    final ok = (rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x41 && rune <= 0x5a) ||
        (rune >= 0x61 && rune <= 0x7a) ||
        rune == 0x2d ||
        rune == 0x5f;
    return ok ? String.fromCharCode(rune) : '_';
  }).join();
  stem = stem.replaceAll(RegExp(r'^_+|_+$'), '');
  if (stem.length > 80) stem = stem.substring(0, 80);
  if (stem.isEmpty) stem = 'track';
  return '$stem$ext';
}

/// Where [track], as the unified library lists it, is kept: device tracks
/// have `device:` IDs, and a cloud track with a device file is synced.
TrackLocation locationOf(Track track) => switch (track) {
      Track(isLocal: false) => TrackLocation.server,
      Track(id: final id) when id.startsWith('device:') => TrackLocation.device,
      _ => TrackLocation.synced,
    };
