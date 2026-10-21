import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/likes/data/likes.dart';

/// Where liked track ids are kept between launches.
abstract interface class FavoritesStore {
  Future<Set<String>> read();
  Future<void> write(Set<String> ids);
}

/// Keeps likes on this device, next to the session token.
class SecureFavoritesStore implements FavoritesStore {
  SecureFavoritesStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'nafir.favorite_tracks';

  final FlutterSecureStorage _storage;

  @override
  Future<Set<String>> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return {};
    final decoded = jsonDecode(raw);
    return decoded is List ? {...decoded.whereType<String>()} : {};
  }

  @override
  Future<void> write(Set<String> ids) =>
      _storage.write(key: _key, value: jsonEncode(ids.toList()));
}

class MemoryFavoritesStore implements FavoritesStore {
  MemoryFavoritesStore([Set<String>? ids]) : ids = {...?ids};

  Set<String> ids;

  @override
  Future<Set<String>> read() async => {...ids};

  @override
  Future<void> write(Set<String> ids) async => this.ids = {...ids};
}

/// What liking or unliking a track came to.
enum TrackLikeResult { done, needsAccount, failed }

/// The tracks the listener likes («پسندیده‌ها», #284). Signed in, likes
/// live on the server and follow the listener to every device; music only
/// on this device, and every like while signed out, stays on the device.
/// Likes saved on the device before server likes existed are moved to the
/// server once, when they are the listener's own cloud tracks.
class FavoriteTracks extends ChangeNotifier {
  FavoriteTracks(
      {FavoritesStore? store, LikesApi? api, String? Function()? token})
      : _store = store ?? MemoryFavoritesStore(),
        _api = api,
        _token = token ?? (() => null);

  final FavoritesStore _store;
  final LikesApi? _api;
  final String? Function() _token;

  /// Liked ids kept on this device.
  Set<String> _local = {};

  /// Liked ids on the server, and the songs they are, newest like first.
  Set<String> _remote = {};
  List<Track> _songs = const [];
  final _busy = <String>{};

  bool contains(String trackId) =>
      _local.contains(trackId) || _remote.contains(trackId);

  /// The listener's server likes, most recently liked first: their own
  /// cloud tracks and store songs.
  final Map<String, Set<String>> _aliases = {};

  List<Track> get songs => _songs;

  /// «پسندیده‌ها» as the listener sees it: server likes newest first (the
  /// library's copy of their own tracks, which may play from the device),
  /// then tracks of [library] liked only on this device.
  List<Track> likedFrom(List<Track> library) {
    final byId = {for (final track in library) track.id: track};
    return [
      for (final track in _songs) byId[track.id] ?? track,
      for (final track in library)
        if (_local.contains(track.id) && !_remote.contains(track.id)) track,
    ];
  }

  /// Whether a like change for [trackId] is on its way.
  bool isBusy(String trackId) => _busy.contains(trackId);

  /// How many listeners like [track], counting this listener's like as it
  /// stands now rather than when the track was loaded.
  int countFor(Track track) {
    final now = contains(track.id);
    if (now == track.liked) return track.likeCount;
    return now ? track.likeCount + 1 : (track.likeCount - 1).clamp(0, 1 << 30);
  }

  bool _onServer(Track track) =>
      track.fromStore || (!track.isLocal && !track.id.startsWith('device:'));

  /// Restores saved likes, then the server's, moving device likes of cloud
  /// tracks to the server. Likes made before it finishes are kept.
  Future<void> load() async {
    try {
      final saved = await _store.read();
      _local = {...saved, ..._local};
      notifyListeners();
    } catch (error) {
      debugPrint('Favorites unavailable: $error');
    }
    await refresh();
  }

  /// Fetches the server's likes again, for example after signing in.
  Future<void> refresh() async {
    final api = _api, token = _token();
    if (api == null || token == null) return;
    try {
      final moved = <String>{};
      for (final id in _local.where((id) => !id.startsWith('device:'))) {
        try {
          await api.setLike(token,
              Track(id: id, title: '', contentType: '', sizeBytes: 0), true);
          moved.add(id);
        } on ApiException catch (error) {
          // Someone else's track, liked from a shared playlist: it stays
          // on the device.
          if (error.statusCode != 404) rethrow;
        }
      }
      if (moved.isNotEmpty) {
        _local = {..._local}..removeAll(moved);
        await _save();
      }
      final liked = await api.likedSongs(token);
      _songs = [for (final song in liked) song.track];
      _aliases.clear();
      for (final song in liked) {
        final ids = {song.track.id, ...song.trackIds};
        for (final id in ids) {
          _aliases[id] = ids;
        }
      }
      _remote = {
        for (final song in liked) ...{song.track.id, ...song.trackIds}
      };
      notifyListeners();
    } catch (error) {
      debugPrint('Server likes unavailable: $error');
    }
  }

  /// Forgets the account's likes, for example on signing out. Likes kept
  /// on this device stay.
  void clearAccount() {
    _remote = {};
    _aliases.clear();
    _songs = const [];
    notifyListeners();
  }

  /// Likes or unlikes [track]. The heart flips at once; a server change
  /// that fails flips it back. A store song needs an account.
  Future<TrackLikeResult> toggleTrack(Track track) async {
    final api = _api, token = _token();
    if (!_onServer(track) ||
        (api == null && !track.fromStore && track.sharedVia == null)) {
      await toggle(track.id);
      return TrackLikeResult.done;
    }
    if (api == null || token == null) {
      if (track.fromStore || track.sharedVia != null) {
        return TrackLikeResult.needsAccount;
      }
      await toggle(track.id);
      return TrackLikeResult.done;
    }
    if (!_busy.add(track.id)) return TrackLikeResult.done;
    final liked = !contains(track.id);
    final before = (_remote, _songs, _local);
    _setRemote(track, liked);
    if (!liked && _local.contains(track.id)) {
      _local = {..._local}..remove(track.id);
      unawaited(_save());
    }
    notifyListeners();
    try {
      await api.setLike(token, track, liked);
      return TrackLikeResult.done;
    } catch (error) {
      debugPrint('Could not change like: $error');
      _remote = before.$1;
      _songs = before.$2;
      _local = before.$3;
      return TrackLikeResult.failed;
    } finally {
      _busy.remove(track.id);
      notifyListeners();
    }
  }

  void _setRemote(Track track, bool liked) {
    if (liked) {
      _remote = {..._remote, track.id};
      _songs = [track, ..._songs.where((t) => t.id != track.id)];
    } else {
      final ids = _aliases[track.id] ?? {track.id};
      _remote = {..._remote}..removeAll(ids);
      _songs = [..._songs.where((t) => !ids.contains(t.id))];
    }
  }

  /// Likes or unlikes [trackId] on this device only. The heart flips at
  /// once; a failed save is only logged, since the like still holds for
  /// this session.
  Future<void> toggle(String trackId) async {
    _local = {..._local};
    if (!_local.remove(trackId)) _local.add(trackId);
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    try {
      await _store.write(_local);
    } catch (error) {
      debugPrint('Could not save favorites: $error');
    }
  }
}
