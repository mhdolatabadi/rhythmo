import 'package:flutter/widgets.dart';
import 'package:rhythmo/core/network/network_status.dart';
import 'package:rhythmo/core/quiet_after_dispose.dart';
import 'package:rhythmo/features/library/data/track.dart';

/// Which songs can play while the server can't be reached (#405): songs on
/// this device, and cloud songs kept whole on it (the Android audio cache,
/// or «ذخیره برای آفلاین» in the browser). Online every song can.
///
/// Rows ask [canPlay] as they build. A cloud song not checked yet counts as
/// playable until its check answers, so nothing flickers dim by mistake.
class OfflinePlayback extends ChangeNotifier with QuietAfterDispose {
  OfflinePlayback(
      {required NetworkStatus network,
      required Future<bool> Function(Track track) isCached})
      : _network = network,
        _isCached = isCached {
    _network.addListener(_onNetwork);
  }

  final NetworkStatus _network;
  final Future<bool> Function(Track track) _isCached;

  /// Answers by track ID and tags revision, which names the cached file.
  final _known = <String, bool>{};
  final _checking = <String>{};

  bool get offline => !_network.online;

  static String _key(Track track) =>
      '${track.id}.${track.embeddedTags.version ?? 0}';

  bool canPlay(Track track) {
    if (_network.online || track.isLocal) return true;
    final key = _key(track);
    final known = _known[key];
    if (known != null) return known;
    if (_checking.add(key)) _check(track, key);
    return true;
  }

  Future<void> _check(Track track, String key) async {
    bool cached;
    try {
      cached = await _isCached(track);
    } catch (_) {
      cached = false;
    }
    _checking.remove(key);
    _known[key] = cached;
    if (!cached) notifyListeners();
  }

  void _onNetwork() {
    // Songs cached while online are checked afresh next time.
    _known.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _network.removeListener(_onNetwork);
    super.dispose();
  }
}

/// Makes [OfflinePlayback] reachable from track rows.
class OfflinePlaybackScope extends InheritedNotifier<OfflinePlayback> {
  const OfflinePlaybackScope(
      {super.key, required OfflinePlayback playback, required super.child})
      : super(notifier: playback);

  static OfflinePlayback? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<OfflinePlaybackScope>()
      ?.notifier;
}

/// What a listener is told on tapping a song that can't play offline.
const offlineUnavailableMessage =
    'این آهنگ روی دستگاه نیست؛ با وصل‌شدن اینترنت پخش می‌شود.';
