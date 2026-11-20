import 'package:audio_service/audio_service.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';

/// What Android Auto can browse (#227): the listener's recently played,
/// playlists, albums and artists, and a shuffle of the whole library.
class MediaLibrary {
  const MediaLibrary({
    this.tracks = const [],
    this.recent = const [],
    this.playlists = const [],
  });

  final List<Track> tracks;
  final List<Track> recent;

  /// With their tracks where they are loaded; an unloaded playlist lists
  /// none.
  final List<Playlist> playlists;
}

/// Where a browsed track plays from: its list, and its place in it.
typedef MediaQueue = ({List<Track> tracks, int index, bool shuffle});

/// The media tree Android Auto browses, built from a [MediaLibrary]. Ids are
/// `root`, a folder (`recent`, `playlists`, `albums`, `artists`), a list
/// inside one (`playlist/{id}`, `album/{name}`, `artist/{name}`), the
/// playable `shuffle`, and a track as `{list}|{trackId}` so it plays in the
/// order the driver saw it.
///
/// Lists are short, so a driver never scrolls far: the car's own rules
/// still limit what it shows while moving.
class MediaTree {
  MediaTree(this.library);

  final MediaLibrary library;

  static const root = AudioService.browsableRootId;
  static const recent = 'recent';
  static const playlists = 'playlists';
  static const albums = 'albums';
  static const artists = 'artists';
  static const shuffle = 'shuffle';

  /// The most items one list shows.
  static const maxItems = 100;

  List<MediaItem> children(String parentId) {
    switch (parentId) {
      case root:
        return [
          if (library.tracks.isNotEmpty)
            const MediaItem(
                id: shuffle, title: 'پخش تصادفی موسیقی من', playable: true),
          if (library.recent.isNotEmpty)
            const MediaItem(id: recent, title: 'اخیرا شنیدی', playable: false),
          if (library.playlists.isNotEmpty)
            const MediaItem(
                id: playlists, title: 'فهرست‌های پخش', playable: false),
          if (_albums().isNotEmpty)
            const MediaItem(id: albums, title: 'آلبوم‌ها', playable: false),
          if (_artists().isNotEmpty)
            const MediaItem(id: artists, title: 'خواننده‌ها', playable: false),
        ];
      case playlists:
        return [
          for (final p in library.playlists.take(maxItems))
            MediaItem(
                id: 'playlist/${p.id}',
                title: p.name,
                playable: false,
                displaySubtitle: '${p.displayTrackCount} آهنگ'),
        ];
      case albums:
        return [
          for (final name in _albums().take(maxItems))
            MediaItem(id: 'album/$name', title: name, playable: false),
        ];
      case artists:
        return [
          for (final name in _artists().take(maxItems))
            MediaItem(id: 'artist/$name', title: name, playable: false),
        ];
    }
    final tracks = tracksOf(parentId);
    if (tracks == null) return const [];
    return [
      for (final track in tracks.take(maxItems)) itemFor(parentId, track),
    ];
  }

  /// The tracks of a playable list, or null for an unknown id.
  List<Track>? tracksOf(String listId) {
    if (listId == recent) return library.recent;
    final slash = listId.indexOf('/');
    if (slash < 0) return null;
    final kind = listId.substring(0, slash);
    final key = listId.substring(slash + 1);
    return switch (kind) {
      'playlist' =>
        library.playlists.where((p) => p.id == key).firstOrNull?.tracks,
      'album' => [
          for (final t in library.tracks)
            if (_album(t) == key) t
        ],
      'artist' => [
          for (final t in library.tracks)
            if (_artist(t) == key) t
        ],
      _ => null,
    };
  }

  /// What to play for [mediaId], or null when it's gone.
  MediaQueue? queueFor(String mediaId) {
    if (mediaId == shuffle) {
      return library.tracks.isEmpty
          ? null
          : (tracks: library.tracks, index: 0, shuffle: true);
    }
    final bar = mediaId.lastIndexOf('|');
    if (bar < 0) return null;
    final tracks = tracksOf(mediaId.substring(0, bar));
    final id = mediaId.substring(bar + 1);
    final index = tracks?.indexWhere((t) => t.id == id) ?? -1;
    if (tracks == null || index < 0) return null;
    return (tracks: tracks, index: index, shuffle: false);
  }

  static MediaItem itemFor(String listId, Track track) => MediaItem(
        id: '$listId|${track.id}',
        title: track.title.trim().isNotEmpty
            ? track.title
            : (track.fileName ?? 'آهنگ بی‌نام'),
        artist: track.artist,
        album: track.album,
        playable: true,
      );

  static String? _clean(String? value) {
    final v = value?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  static String? _album(Track t) => _clean(t.album);
  static String? _artist(Track t) => _clean(t.artist) ?? _clean(t.albumArtist);

  List<String> _albums() => _distinct(library.tracks.map(_album));
  List<String> _artists() => _distinct(library.tracks.map(_artist));

  static List<String> _distinct(Iterable<String?> names) => ({
        for (final n in names)
          if (n != null) n
      }.toList()
        ..sort());
}
