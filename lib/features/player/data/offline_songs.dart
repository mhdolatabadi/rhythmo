import 'package:flutter/widgets.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/core/quiet_after_dispose.dart';

/// Songs the listener chose to keep in the browser for offline play. On
/// Android the audio cache already keeps what was played.
abstract interface class OfflineSongStore {
  /// The ids of the songs kept.
  Future<Set<String>> keptIds();

  /// Fetches all of [track] from [url] and keeps it.
  Future<void> keep(Track track, Uri url);
  Future<void> forget(Track track);
}

/// «ذخیره برای آفلاین» in the browser: which songs are kept, and keeping or
/// letting go of one.
class OfflineSongs extends ChangeNotifier with QuietAfterDispose {
  OfflineSongs({
    required OfflineSongStore store,
    required Future<Uri> Function(Track track) link,
  })  : _store = store,
        _link = link;

  final OfflineSongStore _store;
  final Future<Uri> Function(Track track) _link;

  Set<String> _kept = {};
  final _saving = <String>{};

  bool isKept(String trackId) => _kept.contains(trackId);
  bool isSaving(String trackId) => _saving.contains(trackId);

  Future<void> load() async {
    try {
      _kept = await _store.keptIds();
      notifyListeners();
    } catch (error) {
      debugPrint('Offline songs unavailable: $error');
    }
  }

  /// Keeps [track] for offline play; false when that failed.
  Future<bool> keep(Track track) async {
    if (!_saving.add(track.id)) return false;
    notifyListeners();
    try {
      await _store.keep(track, await _link(track));
      _kept = {..._kept, track.id};
      return true;
    } catch (error) {
      debugPrint('Could not keep for offline: $error');
      return false;
    } finally {
      _saving.remove(track.id);
      notifyListeners();
    }
  }

  Future<void> forget(Track track) async {
    try {
      await _store.forget(track);
    } catch (error) {
      debugPrint('Could not forget an offline song: $error');
    }
    _kept = {..._kept}..remove(track.id);
    notifyListeners();
  }
}

/// Makes [OfflineSongs] reachable from track menus; absent off the web.
class OfflineSongsScope extends InheritedNotifier<OfflineSongs> {
  const OfflineSongsScope(
      {super.key, required OfflineSongs songs, required super.child})
      : super(notifier: songs);

  static OfflineSongs? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OfflineSongsScope>()?.notifier;
}
