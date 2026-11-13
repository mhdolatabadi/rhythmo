import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';

/// What the home-screen widget shows (#227): the track, whether it plays,
/// and its cover when the device has one as a file.
@immutable
class HomeWidgetState {
  const HomeWidgetState({
    required this.title,
    required this.subtitle,
    required this.playing,
    this.coverPath,
  });

  /// Nothing playing: the widget invites to open the app.
  static const idle = HomeWidgetState(
      title: 'ریتمو', subtitle: 'برای پخش، ضربه بزن', playing: false);

  factory HomeWidgetState.of(Track? track, PlayerStatus status, {Uri? cover}) {
    if (track == null) return idle;
    final title =
        _clean(track.title) ?? _clean(track.fileName) ?? 'آهنگ بی‌نام';
    return HomeWidgetState(
      title: title,
      subtitle: _clean(track.artist) ?? _clean(track.album) ?? 'ریتمو',
      playing:
          status == PlayerStatus.playing || status == PlayerStatus.buffering,
      coverPath:
          cover != null && cover.isScheme('file') ? cover.toFilePath() : null,
    );
  }

  final String title;
  final String subtitle;
  final bool playing;
  final String? coverPath;

  Map<String, Object?> toMap() => {
        'title': title,
        'subtitle': subtitle,
        'playing': playing,
        'coverPath': coverPath,
      };

  static String? _clean(String? value) {
    final v = value?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return v == null || v.isEmpty ? null : v;
  }

  @override
  bool operator ==(Object other) =>
      other is HomeWidgetState &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.playing == playing &&
      other.coverPath == coverPath;

  @override
  int get hashCode => Object.hash(title, subtitle, playing, coverPath);
}

/// Keeps the Android home-screen widget showing what the player plays. The
/// widget keeps the last state itself, so it survives the app being closed;
/// its buttons go through the media session like a headset's.
class HomeScreenWidget {
  HomeScreenWidget({MethodChannel? channel, this.coverFor})
      : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'ir.mhdolatabadi.nafir/widget';

  final MethodChannel _channel;

  /// The track's cover as a file, if there is one.
  final Future<Uri?> Function(Track track)? coverFor;

  PlayerController? _player;
  HomeWidgetState? _sent;
  String? _coverTrack;
  Uri? _cover;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  void attach(PlayerController player) {
    _player?.removeListener(_sync);
    _player = player..addListener(_sync);
    _sync();
  }

  void detach() {
    _player?.removeListener(_sync);
    _player = null;
  }

  void _sync() {
    final player = _player;
    if (player == null) return;
    final track = player.track;
    if (track?.id != _coverTrack) {
      _coverTrack = track?.id;
      _cover = null;
      final cover = coverFor;
      if (track != null && cover != null) {
        cover(track).then((uri) {
          if (_coverTrack == track.id) {
            _cover = uri;
            _sync();
          }
        }).catchError((Object _) {});
      }
    }
    final state = HomeWidgetState.of(track, player.status, cover: _cover);
    if (state == _sent) return;
    _sent = state;
    _channel.invokeMethod<void>('update', state.toMap()).catchError(
        (Object error) => debugPrint('Home widget unavailable: $error'));
  }
}
