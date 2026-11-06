import 'package:flutter/foundation.dart';
import 'package:rhythmo/features/player/data/audio_cache.dart';
import 'package:rhythmo/core/quiet_after_dispose.dart';

/// The audio cache as the Settings screen sees it: its size, and clearing it.
class CacheController extends ChangeNotifier with QuietAfterDispose {
  CacheController(
      {required AudioCache cache, required String? Function() playing})
      : _cache = cache,
        _playing = playing;

  final AudioCache _cache;
  final String? Function() _playing;

  int? _sizeBytes;
  bool _busy = false;
  bool _failed = false;

  bool get isManaged => _cache.isManaged;

  /// Null until measured.
  int? get sizeBytes => _sizeBytes;
  bool get busy => _busy;

  /// The last measurement or clear failed.
  bool get failed => _failed;

  Future<void> refresh() => _run(() async {});

  /// Deletes cached audio, except the track playing now. Returns whether it
  /// worked.
  Future<bool> clear() => _run(() => _cache.clear(keep: _playing()));

  Future<bool> _run(Future<void> Function() action) async {
    if (_busy) return false;
    _busy = true;
    _failed = false;
    notifyListeners();
    try {
      await action();
      _sizeBytes = await _cache.sizeBytes();
    } catch (_) {
      _failed = true;
    }
    _busy = false;
    notifyListeners();
    return !_failed;
  }
}
