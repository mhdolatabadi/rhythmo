import 'package:rhythmo/features/library/data/track.dart';

/// Tracks that share an album or an artist.
class TrackGroup {
  const TrackGroup({
    required this.key,
    required this.name,
    required this.tracks,
    this.artist,
    this.unknown = false,
  });

  /// What identifies the group however it is spelled: the name in lower
  /// case with single spaces, or "" for tracks without one.
  final String key;

  /// The first spelling seen, or «نامشخص» for tracks without one.
  final String name;

  /// For an album, the artist of its first track.
  final String? artist;

  /// Whether this collects the tracks that have no album or artist.
  final bool unknown;
  final List<Track> tracks;
}

/// Name shown for tracks without an album or artist.
const unknownGroupName = 'نامشخص';

/// Groups [tracks] by album, in name order, with tracks without an album
/// last. Names match regardless of case and extra spaces.
List<TrackGroup> groupByAlbum(List<Track> tracks) =>
    _group(tracks, (track) => track.album, withArtist: true);

/// Groups [tracks] by artist, like [groupByAlbum].
List<TrackGroup> groupByArtist(List<Track> tracks) =>
    _group(tracks, (track) => track.artist);

List<TrackGroup> _group(
  List<Track> tracks,
  String? Function(Track track) nameOf, {
  bool withArtist = false,
}) {
  final names = <String, String>{};
  final members = <String, List<Track>>{};
  final unknown = <Track>[];
  for (final track in tracks) {
    final name = nameOf(track)?.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name == null || name.isEmpty) {
      unknown.add(track);
      continue;
    }
    final key = name.toLowerCase();
    names.putIfAbsent(key, () => name);
    (members[key] ??= []).add(track);
  }
  final keys = names.keys.toList()..sort();
  String? artistOf(List<Track> group) {
    final artist = group.first.artist?.trim();
    return artist == null || artist.isEmpty ? null : artist;
  }

  return [
    for (final key in keys)
      TrackGroup(
        key: key,
        name: names[key]!,
        artist: withArtist ? artistOf(members[key]!) : null,
        tracks: members[key]!,
      ),
    if (unknown.isNotEmpty)
      TrackGroup(
          key: '', name: unknownGroupName, unknown: true, tracks: unknown),
  ];
}

/// The group with [key] in [groups], or null when it has no tracks left.
TrackGroup? groupWithKey(List<TrackGroup> groups, String key) {
  for (final group in groups) {
    if (group.key == key) return group;
  }
  return null;
}

/// Whether [track] is a talk imported from the lecture archive in Bale
///, which the library folds away from the music.
bool isLecture(Track track) => track.source == 'bale_archive';

/// [lectures] by topic (their album), in name order, each in session
/// order.
List<TrackGroup> lectureTopics(List<Track> lectures) => [
      for (final group in groupByAlbum(lectures))
        TrackGroup(
          key: group.key,
          name: group.name,
          artist: group.artist,
          unknown: group.unknown,
          tracks: [...group.tracks]..sort((a, b) {
              final bySession = (a.trackNumber ?? 1 << 30)
                  .compareTo(b.trackNumber ?? 1 << 30);
              return bySession != 0 ? bySession : a.title.compareTo(b.title);
            }),
        ),
    ];
