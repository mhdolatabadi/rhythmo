import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/audio_interruptions.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/data/notification_artwork.dart';

/// Shown when a track has neither a title nor a filename.
const untitledTrack = 'آهنگ بی‌نام';

/// Connects the system's media controls (notification, lock screen, headset
/// buttons and, on the web, the browser's MediaSession) to [PlayerController].
class RhythmoAudioHandler extends BaseAudioHandler with SeekHandler {
  /// [artwork] is used only when the file has no readable cover.
  RhythmoAudioHandler({this.artwork, this.interruptions});

  final Uri? artwork;

  /// Pauses for calls and resumes after them.
  final AudioInterruptions? interruptions;
  Future<Uri?> Function(Track)? _artworkFor;
  PlayerController? _player;
  Object? _mediaKey;
  PlaybackState? _last;

  /// Drives [player] from the system controls and mirrors its state back.
  void attach(PlayerController player,
      {Future<Uri?> Function(Track)? artworkFor}) {
    _artworkFor = artworkFor;
    _player?.removeListener(_sync);
    _player = player;
    player.addListener(_sync);
    interruptions?.attach(player);
    _sync();
  }

  @override
  Future<void> play() async {
    final player = _player;
    if (player != null && player.systemControls && player.externalPlayback) {
      await player.resume();
    }
  }

  @override
  Future<void> pause() async {
    if (_player?.systemControls == true) await _player?.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_player?.systemControls == true) await _player?.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    if (_canNavigate) await _player?.next();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_canNavigate) await _player?.previous();
  }

  bool get _canNavigate {
    final player = _player;
    return player != null &&
        player.systemControls &&
        (player.externalPlayback ||
            player.status == PlayerStatus.playing ||
            player.status == PlayerStatus.buffering);
  }

  @override
  Future<void> stop() async {
    await _player?.stop();
    await super.stop();
  }

  void _sync() {
    final player = _player;
    if (player == null) return;
    final track = player.track;

    // Republish when anything shown changes, including an edited title, but
    // not on every tick: MediaItem equality only compares ids.
    final key = track == null
        ? null
        : (
            track.id,
            track.title,
            track.artist,
            track.album,
            track.fileName,
            player.duration,
          );
    if (key != _mediaKey) {
      _mediaKey = key;
      mediaItem.add(
        track == null ? null : _mediaItemFor(track, player.duration),
      );
      if (track != null && _artworkFor != null) {
        final duration = player.duration;
        _artworkFor!(track).then((cover) {
          if (_mediaKey == key && cover != null) {
            mediaItem.add(_mediaItemFor(track, duration, cover: cover));
          }
        }).catchError((Object _) {});
      }
    }

    final playing = player.status == PlayerStatus.playing ||
        player.status == PlayerStatus.buffering;
    final next = PlaybackState(
      controls: player.systemControls
          ? [
              MediaControl.skipToPrevious,
              playing ? MediaControl.pause : MediaControl.play,
              MediaControl.skipToNext,
            ]
          : const [],
      systemActions:
          player.systemControls ? const {MediaAction.seek} : const {},
      androidCompactActionIndices:
          player.systemControls ? const [0, 1, 2] : const [],
      processingState: switch (player.status) {
        PlayerStatus.idle => AudioProcessingState.idle,
        PlayerStatus.loading => AudioProcessingState.loading,
        PlayerStatus.buffering => AudioProcessingState.buffering,
        PlayerStatus.playing ||
        PlayerStatus.paused =>
          AudioProcessingState.ready,
        PlayerStatus.completed => AudioProcessingState.completed,
        PlayerStatus.error => AudioProcessingState.error,
      },
      playing: playing,
      updatePosition: player.position,
      errorMessage:
          player.status == PlayerStatus.error ? 'پخش ناموفق بود' : null,
    );
    // Position ticks many times a second; the system extrapolates it from
    // updatePosition, so only publish real changes and seeks.
    if (_last != null &&
        !_changed(_last!, next) &&
        listEquals(_last!.controls, next.controls)) {
      return;
    }
    _last = next;
    playbackState.add(next);
  }

  MediaItem _mediaItemFor(Track track, Duration? duration, {Uri? cover}) {
    final title = notificationTitle(track);
    final album = _clean(track.album);
    final sourceLabel = track.isLocal ? 'روی دستگاه' : 'روی سرور';
    final subtitle = _clean(track.artist) ?? sourceLabel;
    return MediaItem(
      id: track.id,
      title: title,
      artist: subtitle,
      album: album ?? 'ریتمو',
      duration: duration,
      artUri: cover ?? artwork,
      displayTitle: title,
      displaySubtitle: subtitle,
      displayDescription: track.isLocal
          ? 'پخش از فایل‌های دستگاه'
          : switch (track.importedFrom) {
              final from? => 'واردشده از $from',
              null => 'پخش از کتابخانهٔ ریتمو',
            },
      extras: {
        'source': track.source ?? (track.isLocal ? 'device' : 'upload'),
        'location': track.isLocal ? 'device' : 'server',
      },
    );
  }

  /// The track's title on one line; tags often carry stray whitespace or
  /// line breaks. Falls back to the filename without its extension.
  static String notificationTitle(Track track) {
    final title = _clean(track.title);
    if (title != null) return title;
    final name = _clean(track.fileName);
    if (name == null) return untitledTrack;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  static String? _clean(String? value) {
    final cleaned = value?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return cleaned == null || cleaned.isEmpty ? null : cleaned;
  }

  static bool _changed(PlaybackState before, PlaybackState after) {
    if (before.playing != after.playing ||
        before.processingState != after.processingState ||
        before.errorMessage != after.errorMessage) {
      return true;
    }
    final drift = (after.updatePosition - before.position).inMilliseconds.abs();
    return drift > 1500;
  }
}

/// The running media session, if [startMediaSession] succeeded.
RhythmoAudioHandler? activeMediaSession;

/// Starts the platform media session. Returns null where it cannot run (for
/// example in tests), in which case the app simply has no system controls.
Future<RhythmoAudioHandler?> startMediaSession() async {
  try {
    final session = await AudioSession.instance;
    // Music: pause for calls and other apps' audio, duck for notifications.
    await session.configure(const AudioSessionConfiguration.music());
    final interruptions = AudioInterruptions(
      events: session.interruptionEventStream,
      inCall: !kIsWeb && defaultTargetPlatform == TargetPlatform.android
          ? _androidInCall
          : null,
    );
    final artwork = await resolveNotificationArtwork();
    return activeMediaSession = await AudioService.init(
      builder: () =>
          RhythmoAudioHandler(artwork: artwork, interruptions: interruptions),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'ir.mhdolatabadi.nafir.playback',
        androidNotificationChannelName: 'پخش موسیقی',
        androidNotificationIcon: 'drawable/ic_stat_rhythmo',
        androidNotificationOngoing: true,
      ),
    );
  } catch (error) {
    debugPrint('Media session unavailable: $error');
    return null;
  }
}

/// Whether a phone or VoIP call is ringing or under way.
Future<bool> _androidInCall() async {
  final mode = await AndroidAudioManager().getMode();
  return mode == AndroidAudioHardwareMode.ringtone ||
      mode == AndroidAudioHardwareMode.inCall ||
      mode == AndroidAudioHardwareMode.inCommunication;
}
