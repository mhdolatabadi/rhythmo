import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';

/// Pauses for phone calls and other apps' audio, and picks the track up
/// again once the call or the other sound is over.
///
/// just_audio's own handling is turned off (see `JustAudioEngine`): it
/// pauses the player behind the controller's back, skipping the fade and
/// leaving a crossfading second player alone, and it never resumes after a
/// permanent loss of audio focus, which is how some dialers and calling
/// apps take the speaker on Android.
class AudioInterruptions {
  /// [inCall], where given, says whether a call is ringing or under way. It
  /// tells a call, which ends, from another app that took over for good.
  AudioInterruptions({
    required Stream<AudioInterruptionEvent> events,
    Stream<void>? becomingNoisy,
    this.inCall,
    this.pollEvery = const Duration(seconds: 1),
    this.callStartsWithin = const Duration(seconds: 5),
    this.callLastsAtMost = const Duration(hours: 3),
  }) {
    _events = events.listen(_onEvent);
    _noisy = becomingNoisy?.listen((_) => _onNoisy());
  }

  final Future<bool> Function()? inCall;
  final Duration pollEvery;

  /// After a permanent loss, how long to wait for a call to show up before
  /// taking it to be another player.
  final Duration callStartsWithin;

  /// How long to keep waiting for a call to end before giving up.
  final Duration callLastsAtMost;

  late final StreamSubscription<AudioInterruptionEvent> _events;
  StreamSubscription<void>? _noisy;
  PlayerController? _player;

  /// Paused by an interruption, not by the listener: play again after it.
  bool _resume = false;
  Timer? _poll;

  PlayerStatus? _status;

  void attach(PlayerController player) {
    _player?.removeListener(_onPlayer);
    _player = player;
    _status = player.status;
    player.addListener(_onPlayer);
  }

  void _onPlayer() {
    final before = _status;
    final status = _status = _player?.status;
    // Playing again by hand, or something new, cancels the pending resume.
    // The pause still fading out is not that.
    final wasStopped =
        before != PlayerStatus.playing && before != PlayerStatus.buffering;
    if (_resume &&
        wasStopped &&
        (status == PlayerStatus.playing || status == PlayerStatus.loading)) {
      _cancel();
    }
  }

  /// Headphones unplugged or a Bluetooth speaker gone: the music would
  /// suddenly come out of the phone's speaker, so it pauses and stays
  /// paused (#237).
  void _onNoisy() {
    final player = _player;
    if (player == null) return;
    _cancel();
    final status = player.status;
    if (status == PlayerStatus.playing || status == PlayerStatus.buffering) {
      unawaited(player.pause());
    }
  }

  void _onEvent(AudioInterruptionEvent event) {
    final player = _player;
    if (player == null) return;
    if (event.type == AudioInterruptionType.duck) {
      // A notification sound: play on, quieter, until it is over (#237).
      unawaited(player.setDucked(event.begin));
      return;
    }
    if (event.begin) {
      final status = player.status;
      if (status == PlayerStatus.playing || status == PlayerStatus.buffering) {
        _resume = true;
        unawaited(player.pause());
      }
      // A permanent loss never ends with an event: watch for the call.
      if (_resume &&
          event.type == AudioInterruptionType.unknown &&
          inCall != null) {
        _watchCall();
      }
      return;
    }
    switch (event.type) {
      case AudioInterruptionType.pause:
        if (_resume) _resumeNow();
      case AudioInterruptionType.unknown:
        // iOS: the interruption ended without asking to resume.
        if (_poll == null) _cancel();
      case AudioInterruptionType.duck:
        break; // handled above
    }
  }

  void _watchCall() {
    _poll?.cancel();
    var waited = Duration.zero;
    var sawCall = false;
    var checking = false;
    _poll = Timer.periodic(pollEvery, (_) async {
      waited += pollEvery;
      if (checking) return;
      checking = true;
      try {
        final calling = await inCall!();
        if (calling) {
          sawCall = true;
          if (waited > callLastsAtMost) _cancel();
        } else if (sawCall) {
          _resumeNow();
        } else if (waited > callStartsWithin) {
          // No call: another app is playing now, so stay paused.
          _cancel();
        }
      } catch (_) {
        _cancel();
      } finally {
        checking = false;
      }
    });
  }

  void _resumeNow() {
    final player = _player;
    _cancel();
    if (player?.status == PlayerStatus.paused) unawaited(player!.resume());
  }

  void _cancel() {
    _resume = false;
    _poll?.cancel();
    _poll = null;
  }

  void dispose() {
    _cancel();
    _player?.removeListener(_onPlayer);
    unawaited(_events.cancel());
    unawaited(_noisy?.cancel());
  }
}
