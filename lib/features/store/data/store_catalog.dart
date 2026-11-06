import 'package:rhythmo/features/library/data/track.dart';

/// One page of a store listing, and whether another follows.
class StorePage<T> {
  const StorePage(this.items, {required this.hasMore});

  final List<T> items;
  final bool hasMore;
}

/// An artist with songs in the store.
class StoreArtist {
  const StoreArtist({required this.name, required this.trackCount});

  factory StoreArtist.fromJson(Map<String, dynamic> json) => StoreArtist(
        name: json['name'] as String,
        trackCount: (json['trackCount'] as num).toInt(),
      );

  final String name;
  final int trackCount;
}

/// An album with songs in the store, by its album artist when known.
class StoreAlbum {
  const StoreAlbum({
    required this.name,
    this.artist,
    required this.trackCount,
  });

  factory StoreAlbum.fromJson(Map<String, dynamic> json) => StoreAlbum(
        name: json['name'] as String,
        artist: json['artist'] as String?,
        trackCount: (json['trackCount'] as num).toInt(),
      );

  final String name;
  final String? artist;
  final int trackCount;
}

/// How store songs are ranked for the carousels (#284).
enum StoreRanking {
  /// All-time likes plus plays.
  popular('popular', 'محبوب‌ترین‌ها'),

  /// Likes and plays of the last two weeks, newest weighing most.
  trending('trending', 'داغ این هفته');

  const StoreRanking(this.wire, this.label);

  final String wire;
  final String label;
}

/// Why a listener reports a store song («گزارش تخلف»).
enum StoreReportReason {
  copyright('copyright', 'نقض حق نشر'),
  offensive('offensive', 'محتوای توهین‌آمیز یا نامناسب'),
  wrongInfo('wrong_info', 'مشخصات اشتباه'),
  other('other', 'دلیل دیگر');

  const StoreReportReason(this.wire, this.label);

  /// What the server calls it.
  final String wire;

  /// What the listener reads.
  final String label;
}

/// The public store (#243): every song in a public playlist, once, open to
/// everyone. Songs are [Track]s with [Track.fromStore] set.
abstract interface class StoreApi {
  /// Store songs by title; [query] searches title, artist and album, and
  /// [artist] or [album] pick one artist's or album's songs.
  Future<StorePage<Track>> storeTracks(
    String? token, {
    String query = '',
    String? artist,
    String? album,
    int offset = 0,
  });

  /// One store song; throws [ApiException] 404 when it left the store.
  Future<Track> storeTrack(String? token, String id);

  Future<StorePage<StoreArtist>> storeArtists(String? token,
      {String query = '', int offset = 0});

  Future<StorePage<StoreAlbum>> storeAlbums(String? token,
      {String query = '', String? artist, int offset = 0});

  /// Store songs ranked by [ranking], best first.
  Future<StorePage<Track>> storeRanked(String? token, StoreRanking ranking,
      {int offset = 0});

  /// Adds a copy of the song to the listener's own library.
  Future<Track> saveStoreTrack(String token, String id);

  /// Reports the song to the admins.
  Future<void> reportStoreTrack(
      String token, String id, StoreReportReason reason,
      {String? details});
}
