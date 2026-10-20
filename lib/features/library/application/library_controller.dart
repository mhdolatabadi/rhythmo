import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/library/data/track_metadata.dart';
import 'package:rhythmo/features/likes/data/likes.dart';

enum LibraryStatus { loading, error, loaded }

/// Runs [callback] after [delay] and returns a function that cancels it.
typedef Schedule = void Function() Function(
    Duration delay, void Function() callback);

void Function() _timer(Duration delay, void Function() callback) =>
    Timer(delay, callback).cancel;

/// How long to wait between checks while bot imports are in progress: soon
/// at first, then less often, and not at all after about a quarter hour.
/// How long to wait between checks while a track's embedded tags are being
/// rewritten after an edit; usually done within seconds.
const tagPollDelays = [
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 15),
  Duration(seconds: 30),
  Duration(minutes: 1),
];

const importPollDelays = [
  Duration(seconds: 3),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 20),
  Duration(seconds: 30),
  Duration(minutes: 1),
  Duration(minutes: 2),
  Duration(minutes: 5),
  Duration(minutes: 5),
];

/// The signed-in user's tracks, as the server lists them.
class LibraryController extends ChangeNotifier {
  LibraryController({
    required TracksApi api,
    required String? Function() token,
    Schedule? schedule,
    LikesApi? likes,
  })  : _api = api,
        _token = token,
        _likes = likes,
        _schedule = schedule ?? _timer;

  final TracksApi _api;

  /// Publishes single tracks to the store (#284); null hides it.
  final LikesApi? _likes;

  bool get canPublish => _likes != null;

  /// Publishes [track] to the store, or makes it private again, then
  /// reloads the library so the row shows it. Returns where it stands now,
  /// pending when an admin has to approve (#322), or null when it failed.
  Future<PublishState?> setPublished(Track track, bool published) async {
    final likes = _likes, token = _token();
    if (likes == null || token == null) return null;
    final PublishState state;
    try {
      state = await likes.setPublished(token, track.id, published);
    } catch (error) {
      debugPrint('Could not publish: $error');
      return null;
    }
    await load();
    return state;
  }

  final String? Function() _token;
  final Schedule _schedule;
  void Function()? _cancelPoll;
  int _pollStep = 0;
  int _importsInProgress = 0;

  LibraryStatus _status = LibraryStatus.loading;
  List<Track> _tracks = const [];
  int _usedBytes = 0;
  int _limitBytes = 0;
  int _generation = 0;
  final Set<String> _deletingTrackIds = {};
  final Set<String> _updatingTrackIds = {};

  LibraryStatus get status => _status;
  List<Track> get tracks => _tracks;
  int get usedBytes => _usedBytes;
  int get limitBytes => _limitBytes;

  /// Files sent to a rhythmo bot that are still being added.
  int get importsInProgress => _importsInProgress;
  bool isDeleting(String trackId) => _deletingTrackIds.contains(trackId);
  bool isUpdating(String trackId) => _updatingTrackIds.contains(trackId);

  /// Loads the list and reports whether it succeeded. Existing tracks stay on
  /// screen while refreshing; only a first load shows the loading state.
  Future<bool> load() async {
    final token = _token();
    if (token == null) return false;
    final generation = ++_generation;
    if (_status != LibraryStatus.loaded) {
      _status = LibraryStatus.loading;
      notifyListeners();
    }
    try {
      final library = await _api.listTracks(token);
      if (generation != _generation) return false;
      _tracks = List.unmodifiable(library.tracks);
      _usedBytes = library.usedBytes;
      _limitBytes = library.limitBytes;
      _status = LibraryStatus.loaded;
      _followImports(library.importsInProgress);
      for (final track in _tracks) {
        if (track.embeddedTags.status == EmbeddedTagStatus.pending &&
            !_cancelTagPolls.containsKey(track.id)) {
          _followTags(track.id, 0);
        }
      }
      return true;
    } catch (_) {
      if (generation != _generation) return false;
      if (_status != LibraryStatus.loaded) _status = LibraryStatus.error;
      return false;
    } finally {
      if (generation == _generation) notifyListeners();
    }
  }

  /// Deletes an owned cloud track and removes it from the visible library.
  /// The API also removes it from playlists through the database relation.
  Future<bool> deleteTrack(String trackId) async {
    final token = _token();
    if (token == null || _deletingTrackIds.contains(trackId)) return false;
    _deletingTrackIds.add(trackId);
    notifyListeners();
    try {
      final deleted = _tracks.where((track) => track.id == trackId).firstOrNull;
      await _api.deleteTrack(token, trackId);
      _generation++;
      _tracks = List.unmodifiable(
        _tracks.where((track) => track.id != trackId),
      );
      if (deleted != null) {
        final remaining = _usedBytes - deleted.sizeBytes;
        _usedBytes = remaining < 0 ? 0 : remaining;
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      _deletingTrackIds.remove(trackId);
      notifyListeners();
    }
  }

  /// Saves [draft] for an owned cloud track, based on metadata [version]
  /// (the version the editor started from). The server is the authority on
  /// validation; a newer version on the server is a [MetadataConflict].
  Future<MetadataSaveResult> saveTrackMetadata(
    String trackId,
    TrackMetadataDraft draft, {
    required int version,
  }) async {
    final token = _token();
    if (token == null || _updatingTrackIds.contains(trackId)) {
      return const MetadataSaveFailed();
    }
    String? clean(String value) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    _updatingTrackIds.add(trackId);
    notifyListeners();
    try {
      final updated = await _api.updateTrackMetadata(
        token,
        trackId,
        version: version,
        fileName: clean(draft.fileName),
        title: draft.title.trim(),
        artist: clean(draft.artist),
        album: clean(draft.album),
        albumArtist: clean(draft.albumArtist),
        composer: clean(draft.composer),
        genre: clean(draft.genre),
        year: draft.year,
        trackNumber: draft.trackNumber,
        discNumber: draft.discNumber,
        comment: clean(draft.comment),
      );
      replaceTrack(updated);
      return MetadataSaved(updated);
    } on ApiException catch (error) {
      final latest = error.details['track'];
      if (error.statusCode == 409 && latest is Map<String, dynamic>) {
        final track = Track.fromJson(latest);
        replaceTrack(track);
        return MetadataConflict(track);
      }
      final field = error.details['field'];
      if (error.statusCode == 400 && field is String) {
        return MetadataInvalid(field);
      }
      return const MetadataSaveFailed();
    } catch (_) {
      return const MetadataSaveFailed();
    } finally {
      _updatingTrackIds.remove(trackId);
      notifyListeners();
    }
  }

  /// Shows [track] in place of the copy with the same ID, and follows its
  /// embedded tag rewrite while the server is still writing the file.
  void replaceTrack(Track track) {
    final index = _tracks.indexWhere((current) => current.id == track.id);
    if (index == -1) return;
    _tracks = List.unmodifiable(
        [..._tracks]..[index] = track.keepingContextOf(_tracks[index]));
    notifyListeners();
    if (track.embeddedTags.status == EmbeddedTagStatus.pending) {
      _followTags(track.id, 0);
    } else {
      _cancelTagPolls.remove(track.id)?.call();
    }
  }

  final Map<String, void Function()> _cancelTagPolls = {};

  /// Changes when the signed-in user does, so late answers are ignored.
  int _account = 0;

  /// Checks a track again after a growing delay until its tags are no
  /// longer pending, so the library knows when the file is up to date.
  void _followTags(String trackId, int step) {
    _cancelTagPolls.remove(trackId)?.call();
    if (step >= tagPollDelays.length) return;
    final account = _account;
    _cancelTagPolls[trackId] = _schedule(tagPollDelays[step], () async {
      _cancelTagPolls.remove(trackId);
      final token = _token();
      if (token == null || account != _account) return;
      try {
        final fresh = await _api.getTrack(token, trackId);
        if (account != _account) return;
        if (fresh.embeddedTags.status == EmbeddedTagStatus.pending) {
          _followTags(trackId, step + 1);
        } else {
          replaceTrack(fresh);
        }
      } catch (_) {
        if (account == _account) _followTags(trackId, step + 1);
      }
    });
  }

  /// While bot imports are in progress, loads again after a growing delay
  /// so finished imports appear on their own.
  void _followImports(int inProgress) {
    final started = _importsInProgress == 0 && inProgress > 0;
    _importsInProgress = inProgress;
    _cancelPoll?.call();
    _cancelPoll = null;
    if (inProgress == 0) {
      _pollStep = 0;
      return;
    }
    if (started) _pollStep = 0;
    if (_pollStep >= importPollDelays.length) return;
    _cancelPoll = _schedule(importPollDelays[_pollStep++], () {
      _cancelPoll = null;
      load();
    });
  }

  @override
  void dispose() {
    _cancelPoll?.call();
    for (final cancel in _cancelTagPolls.values) {
      cancel();
    }
    super.dispose();
  }

  /// Forgets the previous user's tracks, for example on logout.
  void clear() {
    _cancelPoll?.call();
    for (final cancel in _cancelTagPolls.values) {
      cancel();
    }
    _cancelTagPolls.clear();
    _account++;
    _cancelPoll = null;
    _importsInProgress = 0;
    _pollStep = 0;
    _generation++;
    _tracks = const [];
    _deletingTrackIds.clear();
    _updatingTrackIds.clear();
    _usedBytes = 0;
    _limitBytes = 0;
    _status = LibraryStatus.loading;
    notifyListeners();
  }
}
