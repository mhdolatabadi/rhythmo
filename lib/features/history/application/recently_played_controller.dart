import 'package:flutter/foundation.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/application/library_entries.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/core/quiet_after_dispose.dart';

enum RecentlyPlayedStatus { loading, loaded, error }

/// The account's recently played tracks, kept by the server so Web and
/// Android show the same list.
class RecentlyPlayedController extends ChangeNotifier with QuietAfterDispose {
  RecentlyPlayedController({
    required HistoryApi api,
    required String? Function() token,
  })  : _api = api,
        _token = token;

  final HistoryApi _api;
  final String? Function() _token;

  RecentlyPlayedStatus status = RecentlyPlayedStatus.loading;

  /// Most recent first, each track once.
  List<Track> tracks = const [];

  /// Whether a recorded play may still be on its way to the server, so a
  /// load started meanwhile does not drop it.
  int _recording = 0;

  Future<bool> load() async {
    final token = _token();
    if (token == null) return false;
    status = RecentlyPlayedStatus.loading;
    notifyListeners();
    try {
      final loaded = await _api.listHistory(token);
      if (_recording == 0) tracks = loaded;
      status = RecentlyPlayedStatus.loaded;
      notifyListeners();
      return true;
    } catch (_) {
      status = RecentlyPlayedStatus.error;
      notifyListeners();
      return false;
    }
  }

  /// Counts a meaningful listen of [track]. It moves to the top at once;
  /// the server keeps it for the account's other devices. Music only on
  /// this device, tracks opened from someone's shared link and store songs
  /// are not kept: there is nothing the account could replay later.
  Future<void> record(Track track) async {
    final token = _token();
    if (token == null ||
        locationOf(track) == TrackLocation.device ||
        track.sharedVia != null ||
        track.fromStore) {
      return;
    }
    tracks = [track, ...tracks.where((t) => t.id != track.id)];
    notifyListeners();
    _recording++;
    try {
      await _api.recordPlay(token, track.id, playlistId: track.viaPlaylist);
    } catch (error) {
      // History is a convenience; playback goes on either way.
      debugPrint('Could not record a play: $error');
    } finally {
      _recording--;
    }
  }

  /// Forgets a deleted track at once.
  void remove(String trackId) {
    final kept = tracks.where((t) => t.id != trackId).toList();
    if (kept.length == tracks.length) return;
    tracks = kept;
    notifyListeners();
  }

  /// Clears the history on the server and here. Returns whether it worked.
  Future<bool> clearAll() async {
    final token = _token();
    if (token == null) return false;
    try {
      await _api.clearHistory(token);
      tracks = const [];
      status = RecentlyPlayedStatus.loaded;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Forgets the list, for example on logout.
  void clear() {
    tracks = const [];
    status = RecentlyPlayedStatus.loading;
    notifyListeners();
  }
}

/// [history] as the library shows it: the user's own tracks as the library
/// currently has them (edited metadata, the copy on this device), and
/// someone else's playlist tracks as the server sent them.
List<Track> resolveRecent(List<Track> history, List<Track> library) {
  final byId = {for (final track in library) track.id: track};
  return [for (final track in history) byId[track.id] ?? track];
}
