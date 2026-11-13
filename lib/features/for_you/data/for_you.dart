import 'package:rhythmo/features/library/data/track.dart';

/// One «برای تو» list: a smart playlist or a daily mix.
class ForYouList {
  const ForYouList(
      {required this.key,
      required this.title,
      required this.tracks,
      required this.smart});

  factory ForYouList.fromJson(Map<String, dynamic> json,
          {required bool smart}) =>
      ForYouList(
        key: json['key'] as String,
        title: json['title'] as String,
        smart: smart,
        tracks: [
          for (final track in json['tracks'] as List<dynamic>? ?? const [])
            Track.fromJson(track as Map<String, dynamic>),
        ],
      );

  /// Stable for a kind of list, such as `most-played` or `mix-1`.
  final String key;
  final String title;
  final List<Track> tracks;

  /// Smart playlists update themselves; mixes change once a day.
  final bool smart;
}

/// Everything «برای تو» shows.
class ForYou {
  const ForYou({this.smart = const [], this.mixes = const []});

  factory ForYou.fromJson(Map<String, dynamic> json) => ForYou(
        smart: [
          for (final list in json['smart'] as List<dynamic>? ?? const [])
            ForYouList.fromJson(list as Map<String, dynamic>, smart: true),
        ],
        mixes: [
          for (final list in json['mixes'] as List<dynamic>? ?? const [])
            ForYouList.fromJson(list as Map<String, dynamic>, smart: false),
        ],
      );

  final List<ForYouList> smart;
  final List<ForYouList> mixes;

  List<ForYouList> get all => [...mixes, ...smart];
  bool get isEmpty => smart.isEmpty && mixes.isEmpty;
}

/// Smart playlists, daily mixes and radio (#226), computed on the server
/// from the listener's own library and listening.
abstract interface class ForYouApi {
  Future<ForYou> forYou(String token);

  /// Up to 20 tracks like [seedIds], leaving out [excludeIds].
  Future<List<Track>> radio(
      String token, List<String> seedIds, List<String> excludeIds);
}
