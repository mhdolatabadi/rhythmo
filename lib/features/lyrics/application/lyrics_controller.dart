import 'package:flutter/foundation.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/lyrics/data/lyrics.dart';
import 'package:rhythmo/core/quiet_after_dispose.dart';

/// Why lyrics can't be shown for a track at all.
enum LyricsUnavailable {
  /// Only on this device: the server doesn't know the track.
  deviceOnly,

  /// Signed out, and the track isn't from a public playlist.
  signedOut,

  /// A public store song: lyrics come once it is added to the library.
  store,
}

/// Loads lyrics from the server and keeps them for the session, so going
/// back to a track doesn't ask again.
class LyricsController extends ChangeNotifier with QuietAfterDispose {
  LyricsController({required LyricsApi api, required String? Function() token})
      : _api = api,
        _token = token;

  final LyricsApi _api;
  final String? Function() _token;
  final _cache = <String, TrackLyrics>{};

  /// Why [track] can have no lyrics, or null when it can.
  LyricsUnavailable? unavailable(Track track) {
    if (track.id.startsWith('device:')) return LyricsUnavailable.deviceOnly;
    if (track.fromStore) return LyricsUnavailable.store;
    if (_token() == null && track.sharedVia == null) {
      return LyricsUnavailable.signedOut;
    }
    return null;
  }

  /// The same track reached another way is another request: what the
  /// server answers depends on the route, and an edit changes [Track.version].
  static String _key(Track track) =>
      '${track.id}|${track.version}|${track.sharedVia}|${track.viaPlaylist}';

  /// Lyrics already loaded for [track], if any.
  TrackLyrics? cached(Track track) => _cache[_key(track)];

  /// The lyrics of [track], from memory or the server. Throws
  /// [ApiException] when the server can't answer.
  Future<TrackLyrics> load(Track track, {Duration? duration}) async {
    final key = _key(track);
    final cached = _cache[key];
    if (cached != null) return cached;
    final lyrics = await _api.trackLyrics(_token(), track, duration: duration);
    _cache[key] = lyrics;
    return lyrics;
  }

  bool canExtract(Track track) =>
      _api is TranscriptionApi &&
      unavailable(track) == null &&
      track.sharedVia == null &&
      track.viaPlaylist == null;

  Future<Map<String, dynamic>?> extraction(Track track,
      {bool start = false}) async {
    if (!canExtract(track)) return null;
    try {
      return await (_api as TranscriptionApi)
          .transcription(_token()!, track.id, start: start);
    } on ApiException catch (error) {
      if (!start && error.code == 'transcription_disabled') return null;
      rethrow;
    }
  }

  /// Other LRCLIB entries the owner may pick for [track].
  Future<List<LyricsMatch>> candidates(Track track, {String query = ''}) {
    final token = _token();
    if (token == null) return Future.value(const []);
    return _api.lyricsCandidates(token, track.id, query: query);
  }

  /// Makes [match] the lyrics of the owner's [track].
  Future<TrackLyrics> choose(Track track, LyricsMatch match) async {
    final lyrics = await _api.chooseLyrics(_token()!, track.id, match.id);
    _cache[_key(track)] = lyrics;
    notifyListeners();
    return lyrics;
  }

  /// Forgets everything, for example on sign out.
  void clear() {
    _cache.clear();
    notifyListeners();
  }
}
