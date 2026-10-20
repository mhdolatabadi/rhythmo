import 'package:rhythmo/features/library/data/track.dart';

/// How many listeners like a song, and whether this listener does.
class LikeState {
  const LikeState({required this.count, required this.liked});

  factory LikeState.fromJson(Map<String, dynamic> json) => LikeState(
        count: (json['likeCount'] as num?)?.toInt() ?? 0,
        liked: json['liked'] == true,
      );

  final int count;
  final bool liked;
}

/// One of «پسندیده‌ها»: the listener's own track or a store song, and when
/// it was liked.
class LikedSong {
  const LikedSong({required this.track, required this.likedAt});

  factory LikedSong.fromJson(Map<String, dynamic> json) => LikedSong(
        track: json['source'] == 'store'
            ? Track.fromStoreJson(json['storeTrack'] as Map<String, dynamic>)
            : Track.fromJson(json['track'] as Map<String, dynamic>),
        likedAt: DateTime.parse(json['likedAt'] as String),
      );

  final Track track;
  final DateTime likedAt;
}

/// Likes and single-track publishing (#284). Likes live on the server, so
/// they follow the listener to every device.
abstract interface class LikesApi {
  /// Likes or unlikes [track]: the listener's own cloud track, or a store
  /// song ([Track.fromStore]). Both are idempotent.
  Future<LikeState> setLike(String token, Track track, bool liked);

  /// «پسندیده‌ها», most recently liked first.
  Future<List<LikedSong>> likedSongs(String token);

  /// Publishes one of the listener's own tracks to the store, or makes it
  /// private again; returns where it stands now. Unless the account is
  /// verified, publishing only asks an admin (#322) and is pending.
  Future<PublishState> setPublished(
      String token, String trackId, bool published);
}
