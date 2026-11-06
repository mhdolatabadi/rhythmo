import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/store/data/store_catalog.dart';
import 'package:rhythmo/core/quiet_after_dispose.dart';

enum StoreStatus { idle, loading, loaded, error }

/// One store listing, loaded a page at a time as the listener scrolls. A
/// response that arrives after the listing was reloaded is dropped.
class StoreListing<T> extends ChangeNotifier with QuietAfterDispose {
  StoreListing(this._fetch);

  final Future<StorePage<T>> Function(int offset) _fetch;

  List<T> _items = const [];
  bool _hasMore = false;
  StoreStatus _status = StoreStatus.idle;
  bool _loadingMore = false;
  bool _moreFailed = false;
  int _generation = 0;

  List<T> get items => _items;
  bool get hasMore => _hasMore;
  StoreStatus get status => _status;

  /// A next page is on its way.
  bool get loadingMore => _loadingMore;

  /// The last next page failed; scrolling to the end tries again.
  bool get moreFailed => _moreFailed;

  /// Loads the first page, unless it is loaded or loading already.
  Future<void> ensureLoaded() async {
    if (_status == StoreStatus.idle) await refresh();
  }

  /// Loads the first page again.
  Future<void> refresh() async {
    final generation = ++_generation;
    _status = StoreStatus.loading;
    _loadingMore = false;
    _moreFailed = false;
    notifyListeners();
    try {
      final page = await _fetch(0);
      if (generation != _generation) return;
      _items = page.items;
      _hasMore = page.hasMore;
      _status = StoreStatus.loaded;
    } catch (_) {
      if (generation != _generation) return;
      _status = StoreStatus.error;
    }
    notifyListeners();
  }

  /// Appends the next page, once at a time.
  Future<void> loadMore() async {
    if (!_hasMore || _loadingMore || _status != StoreStatus.loaded) return;
    final generation = _generation;
    _loadingMore = true;
    _moreFailed = false;
    notifyListeners();
    try {
      final page = await _fetch(_items.length);
      if (generation != _generation) return;
      _items = [..._items, ...page.items];
      _hasMore = page.hasMore;
    } catch (_) {
      if (generation != _generation) return;
      _moreFailed = true;
    }
    _loadingMore = false;
    notifyListeners();
  }

  /// Drops [item], for example a song that left the store.
  void remove(T item) {
    _items = [..._items]..remove(item);
    notifyListeners();
  }
}

/// What adding a store song to the library came to.
enum StoreSaveResult {
  saved,
  alreadyYours,
  noSpace,
  uploadsDisabled,
  gone,
  failed
}

/// What reporting a store song came to.
enum StoreReportResult { sent, gone, tooMany, failed }

/// The public store (#243): songs, artists and albums from every public
/// playlist, searchable and playable without an account. Adding a song to
/// the library and reporting one need an account.
class StoreController extends ChangeNotifier with QuietAfterDispose {
  StoreController({
    required StoreApi api,
    required String? Function() token,
    this.onSaved,
  })  : _api = api,
        _token = token {
    songs = StoreListing<Track>(
        (offset) => _api.storeTracks(_token(), query: _query, offset: offset));
    artists = StoreListing<StoreArtist>(
        (offset) => _api.storeArtists(_token(), query: _query, offset: offset));
    albums = StoreListing<StoreAlbum>(
        (offset) => _api.storeAlbums(_token(), query: _query, offset: offset));
    popular = StoreListing<Track>((offset) =>
        _api.storeRanked(_token(), StoreRanking.popular, offset: offset));
    trending = StoreListing<Track>((offset) =>
        _api.storeRanked(_token(), StoreRanking.trending, offset: offset));
  }

  final StoreApi _api;
  final String? Function() _token;

  /// Called after a song is added to the library, to show it there.
  final Future<void> Function()? onSaved;

  late final StoreListing<Track> songs;
  late final StoreListing<StoreArtist> artists;
  late final StoreListing<StoreAlbum> albums;

  /// The carousels: most liked and played of all time, and of late.
  late final StoreListing<Track> popular;
  late final StoreListing<Track> trending;

  StoreListing<Track> ranked(StoreRanking ranking) => switch (ranking) {
        StoreRanking.popular => popular,
        StoreRanking.trending => trending,
      };

  /// How long typing rests before a search is sent.
  static const searchDelay = Duration(milliseconds: 350);

  String _query = '';
  final _saving = <String>{};
  Timer? _searchTimer;

  String get query => _query;
  bool get signedIn => _token() != null;
  bool isSaving(Track track) => _saving.contains(track.id);

  /// Searches songs, artists and albums for [query]. Only listings already
  /// shown are reloaded; the others load when first shown.
  Future<void> search(String query) async {
    final trimmed = query.trim();
    if (trimmed == _query) return;
    _query = trimmed;
    notifyListeners();
    await Future.wait([
      for (final listing in <StoreListing<Object>>[songs, artists, albums])
        if (listing.status != StoreStatus.idle) listing.refresh(),
    ]);
  }

  /// [search] once typing rests for [searchDelay].
  void searchSoon(String query) {
    _searchTimer?.cancel();
    _searchTimer = Timer(searchDelay, () => search(query));
  }

  /// The songs of one artist or album.
  StoreListing<Track> songsOf({String? artist, String? album}) =>
      StoreListing<Track>((offset) => _api.storeTracks(_token(),
          artist: artist, album: album, offset: offset));

  /// One store song, or null when it is no longer in the store. Throws
  /// when the server can't be reached.
  Future<Track?> song(String id) async {
    try {
      return await _api.storeTrack(_token(), id);
    } on ApiException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  /// «افزودن به کتابخانه‌ی من»: a copy of the song becomes the listener's.
  Future<StoreSaveResult> save(Track track) async {
    final token = _token();
    if (token == null || !_saving.add(track.id)) return StoreSaveResult.failed;
    notifyListeners();
    try {
      await _api.saveStoreTrack(token, track.id);
      await onSaved?.call();
      return StoreSaveResult.saved;
    } on ApiException catch (error) {
      return switch (error.code) {
        'already_yours' => StoreSaveResult.alreadyYours,
        'quota_exceeded' => StoreSaveResult.noSpace,
        'uploads_disabled' => StoreSaveResult.uploadsDisabled,
        'not_found' => StoreSaveResult.gone,
        _ => StoreSaveResult.failed,
      };
    } catch (_) {
      return StoreSaveResult.failed;
    } finally {
      _saving.remove(track.id);
      notifyListeners();
    }
  }

  /// «گزارش تخلف»: tells the admins what is wrong with the song.
  Future<StoreReportResult> report(Track track, StoreReportReason reason,
      {String? details}) async {
    final token = _token();
    if (token == null) return StoreReportResult.failed;
    try {
      await _api.reportStoreTrack(token, track.id, reason, details: details);
      return StoreReportResult.sent;
    } on ApiException catch (error) {
      return switch (error.code) {
        'not_found' => StoreReportResult.gone,
        'rate_limited' => StoreReportResult.tooMany,
        _ => StoreReportResult.failed,
      };
    } catch (_) {
      return StoreReportResult.failed;
    }
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    songs.dispose();
    artists.dispose();
    albums.dispose();
    popular.dispose();
    trending.dispose();
    super.dispose();
  }
}
