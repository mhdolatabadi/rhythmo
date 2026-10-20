import 'package:flutter/foundation.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';

enum PlaylistsStatus { loading, loaded, error }

enum AddTrackResult { added, alreadyPresent, failure }

enum SaveSharedResult {
  saved,
  alreadyYours,
  noSpace,
  uploadsDisabled,
  gone,
  failed
}

enum LikeResult { done, gone, failed }

/// A shared playlist link that is malformed, unknown or no longer shared.
class SharedPlaylistUnavailable implements Exception {
  const SharedPlaylistUnavailable();
}

class PlaylistsController extends ChangeNotifier {
  PlaylistsController(
      {required PlaylistsApi api,
      required String? Function() token,
      bool Function()? isAdmin})
      : _api = api,
        _token = token,
        _isAdmin = isAdmin;

  final PlaylistsApi _api;
  final String? Function() _token;
  final bool Function()? _isAdmin;

  /// Whether the signed-in account may take playlists out of the popular
  /// list. The server checks again on every request.
  bool get canModeratePopular => signedIn && (_isAdmin?.call() ?? false);

  PlaylistsStatus status = PlaylistsStatus.loading;
  List<Playlist> playlists = const [];

  /// Public playlists, most liked first, once [loadPopular] has run.
  PlaylistsStatus popularStatus = PlaylistsStatus.loading;
  List<PublicPlaylist> popular = const [];

  /// Share tokens whose like is on its way to the server.
  final Set<String> _liking = {};
  bool isLiking(String shareToken) => _liking.contains(shareToken);

  /// Whether there is an account to like or save with. Without one,
  /// public and shared playlists can still be browsed and played.
  bool get signedIn => _token() != null;

  Future<void> loadPopular() async {
    final token = _token();
    popularStatus = PlaylistsStatus.loading;
    notifyListeners();
    try {
      popular = await _api.listPublicPlaylists(token);
      popularStatus = PlaylistsStatus.loaded;
    } catch (_) {
      popularStatus = PlaylistsStatus.error;
    }
    notifyListeners();
  }

  /// An admin takes [playlist] out of the popular list, or with
  /// `hidden: false` puts it back. The list shows the change at once and
  /// goes back if the server refuses it. Returns whether it was saved.
  Future<bool> setPopularHidden(PublicPlaylist playlist,
      {bool hidden = true}) async {
    final token = _token();
    if (token == null || !canModeratePopular) return false;
    final before = popular;
    if (hidden) {
      popular = [
        for (final p in popular)
          if (p.shareToken != playlist.shareToken) p,
      ];
      notifyListeners();
    }
    try {
      await _api.setPopularPlaylistHidden(token, playlist.shareToken, hidden);
    } catch (_) {
      if (hidden) {
        popular = before;
        notifyListeners();
      }
      return false;
    }
    if (!hidden) await loadPopular();
    return true;
  }

  /// An admin deletes [playlist], whoever owns it; it leaves the popular
  /// list once the server confirms. Returns whether it was deleted.
  Future<bool> deletePublic(PublicPlaylist playlist) async {
    final token = _token();
    if (token == null || !canModeratePopular) return false;
    try {
      await _api.deletePublicPlaylist(token, playlist.shareToken);
    } catch (_) {
      return false;
    }
    popular = [
      for (final p in popular)
        if (p.shareToken != playlist.shareToken) p,
    ];
    notifyListeners();
    return true;
  }

  /// Likes or unlikes a shared playlist. The popular list shows the change
  /// at once and goes back if the server refuses it; [onChange] lets a
  /// screen do the same with its own copy. A like already on its way is
  /// not sent twice.
  Future<LikeResult> setLike(String shareToken, PlaylistLikes current,
      {void Function(PlaylistLikes likes)? onChange}) async {
    final token = _token();
    if (token == null || _liking.contains(shareToken)) {
      return LikeResult.failed;
    }
    void show(PlaylistLikes likes) {
      onChange?.call(likes);
      popular = [
        for (final p in popular)
          p.shareToken == shareToken ? p.withLikes(likes) : p,
      ];
      notifyListeners();
    }

    final wanted = current.toggled();
    _liking.add(shareToken);
    show(wanted);
    try {
      show(await _api.setPlaylistLike(token, shareToken, wanted.liked));
      return LikeResult.done;
    } on ApiException catch (e) {
      show(current);
      return e.statusCode == 404 ? LikeResult.gone : LikeResult.failed;
    } catch (_) {
      show(current);
      return LikeResult.failed;
    } finally {
      _liking.remove(shareToken);
      notifyListeners();
    }
  }

  Future<bool> load() async {
    final token = _token();
    if (token == null) return false;
    status = PlaylistsStatus.loading;
    notifyListeners();
    try {
      playlists = await _api.listPlaylists(token);
      status = PlaylistsStatus.loaded;
      notifyListeners();
      return true;
    } catch (_) {
      status = PlaylistsStatus.error;
      notifyListeners();
      return false;
    }
  }

  Future<Playlist?> create(String name) async {
    final token = _token();
    if (token == null) return null;
    try {
      final playlist = await _api.createPlaylist(token, name);
      playlists = [playlist, ...playlists];
      status = PlaylistsStatus.loaded;
      notifyListeners();
      return playlist;
    } catch (_) {
      return null;
    }
  }

  /// Shares the playlist by link, or changes whether it is [public], and
  /// returns how it is shared now, or null when that failed.
  Future<PlaylistShare?> share(String id, {bool? public}) async {
    final token = _token();
    if (token == null) return null;
    try {
      return await _api.sharePlaylist(token, id, public: public);
    } catch (_) {
      return null;
    }
  }

  /// Stops sharing; the old link stops working. Returns whether it worked.
  Future<bool> unshare(String id) async {
    final token = _token();
    if (token == null) return false;
    try {
      await _api.unsharePlaylist(token, id);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Opens a playlist someone shared. Throws [SharedPlaylistUnavailable]
  /// when the link is wrong or no longer shared, other errors when offline.
  Future<SharedPlaylist> openShared(String shareToken) async {
    final token = _token();
    try {
      return await _api.getSharedPlaylist(token, shareToken);
    } on ApiException catch (e) {
      if (e.statusCode == 404) throw const SharedPlaylistUnavailable();
      rethrow;
    }
  }

  /// Copies a shared playlist and its tracks into this account.
  Future<SaveSharedResult> saveShared(String shareToken) async {
    final token = _token();
    if (token == null) return SaveSharedResult.failed;
    try {
      final saved = await _api.saveSharedPlaylist(token, shareToken);
      playlists = [saved, ...playlists];
      status = PlaylistsStatus.loaded;
      notifyListeners();
      return SaveSharedResult.saved;
    } on ApiException catch (e) {
      return switch (e.statusCode) {
        409 => SaveSharedResult.alreadyYours,
        413 => SaveSharedResult.noSpace,
        503 => SaveSharedResult.uploadsDisabled,
        404 => SaveSharedResult.gone,
        _ => SaveSharedResult.failed,
      };
    } catch (_) {
      return SaveSharedResult.failed;
    }
  }

  /// Shows edited metadata for [track] in every loaded playlist.
  void updateTrack(Track track) {
    if (!playlists.any((p) => p.tracks.any((item) => item.id == track.id))) {
      return;
    }
    playlists = [
      for (final playlist in playlists)
        if (playlist.tracks.any((item) => item.id == track.id))
          playlist.withTracks([
            for (final item in playlist.tracks)
              item.id == track.id ? track.keepingContextOf(item) : item,
          ])
        else
          playlist,
    ];
    notifyListeners();
  }

  Future<Playlist?> loadPlaylist(String id) async {
    final token = _token();
    if (token == null) return null;
    try {
      return await _api.getPlaylist(token, id);
    } catch (_) {
      return null;
    }
  }

  Future<Playlist?> replaceTracks(String id, List<String> trackIds) async {
    final token = _token();
    if (token == null) return null;
    try {
      final playlist = await _api.replacePlaylistTracks(token, id, trackIds);
      await load();
      return playlist;
    } catch (_) {
      return null;
    }
  }

  Future<AddTrackResult> addTrack(String id, String trackId) async {
    final token = _token();
    if (token == null) return AddTrackResult.failure;
    try {
      final playlist = await _api.getPlaylist(token, id);
      final trackIds = playlist.tracks.map((track) => track.id).toList();
      if (trackIds.contains(trackId)) return AddTrackResult.alreadyPresent;
      final updated = await _api.replacePlaylistTracks(
        token,
        id,
        [...trackIds, trackId],
      );
      playlists = playlists
          .map((item) => item.id == id ? updated : item)
          .toList(growable: false);
      notifyListeners();
      return AddTrackResult.added;
    } catch (_) {
      return AddTrackResult.failure;
    }
  }

  Future<bool> rename(String id, String name) async {
    final token = _token();
    if (token == null) return false;
    try {
      await _api.renamePlaylist(token, id, name);
      await load();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> delete(String id) async {
    final token = _token();
    if (token == null) return false;
    try {
      await _api.deletePlaylist(token, id);
      playlists = playlists.where((playlist) => playlist.id != id).toList();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Makes a new collaboration link and returns its token, or null when
  /// that failed. The old link stops working.
  Future<String?> createCollabLink(String id) async {
    final token = _token();
    if (token == null) return null;
    try {
      return await _api.createCollabLink(token, id);
    } catch (_) {
      return null;
    }
  }

  /// Turns the collaboration link off; members stay. Returns whether it
  /// worked.
  Future<bool> revokeCollabLink(String id) =>
      _attempt((token) => _api.revokeCollabLink(token, id));

  /// Joins the playlist with this collaboration link. Throws
  /// [SharedPlaylistUnavailable] when the link is wrong or revoked.
  Future<Playlist> join(String collabToken) async {
    final token = _token();
    if (token == null) throw const SharedPlaylistUnavailable();
    try {
      final playlist = await _api.joinPlaylist(token, collabToken);
      await load();
      return playlist;
    } on ApiException catch (e) {
      if (e.statusCode == 404) throw const SharedPlaylistUnavailable();
      rethrow;
    }
  }

  /// The owner takes a member out, with the tracks they added.
  Future<bool> removeMember(String id, String memberId) =>
      _attempt((token) => _api.removePlaylistMember(token, id, memberId));

  /// Leaves a collaborative playlist; the tracks the user added leave too.
  Future<bool> leave(String id) async {
    final left = await _attempt((token) => _api.leavePlaylist(token, id));
    if (left) {
      playlists = playlists.where((playlist) => playlist.id != id).toList();
      notifyListeners();
    }
    return left;
  }

  Future<bool> _attempt(Future<void> Function(String token) call) async {
    final token = _token();
    if (token == null) return false;
    try {
      await call(token);
      return true;
    } catch (_) {
      return false;
    }
  }

  void clear() {
    playlists = const [];
    popular = const [];
    status = PlaylistsStatus.loading;
    popularStatus = PlaylistsStatus.loading;
    notifyListeners();
  }
}
