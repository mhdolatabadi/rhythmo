import 'package:flutter/foundation.dart';
import 'package:rhythmo/core/quiet_after_dispose.dart';
import 'package:rhythmo/features/for_you/data/for_you.dart';
import 'package:rhythmo/features/library/data/track.dart';

/// «برای تو» (#226): the listener's smart playlists and daily mixes, built
/// by the server from their own library, and radio for when a queue runs
/// out. Tracks are swapped for the library's copies, which may play from
/// the device.
class ForYouController extends ChangeNotifier with QuietAfterDispose {
  ForYouController({
    required ForYouApi api,
    required String? Function() token,
    List<Track> Function()? library,
  })  : _api = api,
        _token = token,
        _library = library ?? (() => const []);

  final ForYouApi _api;
  final String? Function() _token;
  final List<Track> Function() _library;

  ForYou _lists = const ForYou();
  bool _loading = false;

  ForYou get lists {
    final byId = _byId();
    if (byId.isEmpty) return _lists;
    ForYouList swap(ForYouList list) => ForYouList(
          key: list.key,
          title: list.title,
          smart: list.smart,
          tracks: [for (final t in list.tracks) byId[t.id] ?? t],
        );
    return ForYou(
      smart: [for (final l in _lists.smart) swap(l)],
      mixes: [for (final l in _lists.mixes) swap(l)],
    );
  }

  Map<String, Track> _byId() => {for (final t in _library()) t.id: t};

  /// Fetches the lists again; a failure keeps what was shown.
  Future<void> load() async {
    final token = _token();
    if (token == null || _loading) return;
    _loading = true;
    try {
      _lists = await _api.forYou(token);
      notifyListeners();
    } catch (error) {
      debugPrint('«برای تو» unavailable: $error');
    } finally {
      _loading = false;
    }
  }

  /// Tracks like [seeds] from the library, none of [exclude]; for
  /// [PlayerController.radioSource].
  Future<List<Track>> radio(List<Track> seeds, List<Track> exclude) async {
    final token = _token();
    if (token == null || seeds.isEmpty) return const [];
    final found = await _api.radio(
        token, [for (final t in seeds) t.id], [for (final t in exclude) t.id]);
    final byId = _byId();
    return [for (final t in found) byId[t.id] ?? t];
  }

  /// Forgets the account's lists, on signing out.
  void clear() {
    _lists = const ForYou();
    notifyListeners();
  }
}
