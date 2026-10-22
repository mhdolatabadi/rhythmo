import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/data/audio_cache.dart';
import 'package:rhythmo/features/player/data/crossfade.dart';
import 'package:rhythmo/features/player/data/volume_ramp.dart';

enum EngineState { idle, loading, buffering, ready, completed }

/// Reported on [AudioEngine.errors] when the browser refused to start audio
/// without a tap first (its autoplay rules), so playback did not start.
class PlaybackBlocked implements Exception {
  const PlaybackBlocked();

  /// Whether [error] is a browser refusing to play without a user gesture.
  static bool matches(Object error) {
    final text = error.toString();
    return text.contains('NotAllowedError') ||
        text.contains('play() failed because the user') ||
        text.contains("user didn't interact");
  }

  @override
  String toString() => 'PlaybackBlocked';
}

/// The part of an audio player the app uses, so it can be replaced in tests.
abstract interface class AudioEngine {
  Stream<Duration> get position;
  Stream<Duration?> get duration;
  Stream<bool> get playing;
  Stream<EngineState> get state;

  /// Playback failures after loading, for example an expired URL on seek.
  Stream<Object> get errors;

  /// The id of a [preload]ed track the engine moved on to by itself, at the
  /// end of the current one or as a crossfade began. Position and duration
  /// that follow belong to that track.
  Stream<String> get advanced;

  /// Whether tracks can overlap here; see [setCrossfade].
  bool get supportsCrossfade;

  /// Loads [track] as the current one, dropping anything preloaded.
  Future<void> load(Track track, Uri url, {Duration start = Duration.zero});

  /// Buffers [track] to follow the current one without a gap, or with the
  /// [setCrossfade] overlap. Replaces an earlier preload.
  Future<void> preload(Track track, Uri url);

  /// Forgets the preloaded track, so the current one ends by itself.
  Future<void> clearPreload();

  /// Starts playback without waiting for it to finish.
  void play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();

  /// Playback rate; 1 is normal. The pitch stays the same.
  Future<void> setSpeed(double speed);

  /// Overall loudness from 0 to 1, for example for a fade-out.
  Future<void> setVolume(double volume);

  /// How long a preloaded track overlaps the end of the current one. Only
  /// applies to later [preload]s, and only where [supportsCrossfade].
  Future<void> setCrossfade(Duration crossfade);

  /// Each track's own volume from 0 to 1, for loudness normalization. It
  /// multiplies [setVolume] and fades, follows gapless and crossfaded track
  /// changes, and applies to the current track at once.
  Future<void> setTrackGain(double Function(Track track) gainFor);

  Future<void> dispose();
}

/// Optional native capability; unsupported engines keep silence unchanged.
abstract interface class SilenceSkippingEngine {
  bool get supportsSilenceSkipping;
  Future<void> setSkipSilence(bool enabled);
}

/// One just_audio player and the tracks queued in it, by id.
class _Deck {
  _Deck() : player = AudioPlayer();

  final AudioPlayer player;
  ConcatenatingAudioSource? playlist;
  final ids = <String>[];

  /// The tracks behind [ids], for their gain.
  final tracks = <Track>[];

  int get index => player.currentIndex ?? 0;

  Track? get current => index < tracks.length ? tracks[index] : null;
}

/// Plays through just_audio. The current track and the preloaded next one
/// share a playlist, so the player moves between them without a gap; that
/// is sample-accurate on Android (ExoPlayer) and, in browsers, saves fetching
/// a new link before the next track starts.
///
/// A crossfade instead buffers the next track in a second player, which
/// starts quietly before the current track ends while the first fades out.
/// Browsers are left out: the fade steps run on JavaScript timers, which are
/// throttled in background tabs and on a locked phone, and a second media
/// element may not start there without a fresh tap. Fades would stutter or
/// the next track would not start, so crossfade is not offered on the web.
class JustAudioEngine implements AudioEngine, SilenceSkippingEngine {
  JustAudioEngine({AudioCache? cache, bool? supportsCrossfade})
      : _cache = cache ?? createAudioCache(),
        supportsCrossfade = supportsCrossfade ?? !kIsWeb {
    _active = _listen(_Deck());
  }

  final AudioCache _cache;

  @override
  final bool supportsCrossfade;

  late _Deck _active;

  /// The second player, created for the first crossfade.
  _Deck? _standby;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _state = StreamController<EngineState>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _advanced = StreamController<String>.broadcast();

  String? _currentId;
  String? _nextId;
  double _speed = 1;
  double _volume = 1;
  Duration _crossfade = Duration.zero;
  double Function(Track track) _gainFor = (_) => 1;

  /// The volume [deck] plays at: the overall volume times its track's gain.
  double _deckVolume(_Deck deck) => _volumeFor(deck.current);

  double _volumeFor(Track? track) =>
      _volume *
      _transportGain *
      (track == null ? 1 : _gainFor(track).clamp(0.0, 1.0));

  bool _skipSilence = false;

  @override
  bool get supportsSilenceSkipping =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> setSkipSilence(bool enabled) async {
    if (!supportsSilenceSkipping) return;
    await _active.player.setSkipSilenceEnabled(enabled);
    await _standby?.player.setSkipSilenceEnabled(enabled);
    _skipSilence = enabled;
  }

  /// Pause, resume and seek fade through this gain instead of cutting the
  /// sound, which clicks (#254). It multiplies [_volume].
  double _transportGain = 1;
  late final _transport = VolumeRamp(_applyTransport);

  /// Bumped by play (and new tracks): a pause still fading out when play is
  /// tapped again does not pause after all.
  int _playOp = 0;

  /// Bumped by seek and pause: only the latest seek fades back in, and not
  /// once a pause has started.
  int _seekOp = 0;

  void _applyTransport(double gain) {
    _transportGain = gain;
    if (_fade == null) {
      unawaited(_active.player.setVolume(_deckVolume(_active)));
    }
  }

  Timer? _fade;
  _Deck? _fadingOut;
  Completer<void>? _fadeDone;

  /// Bumped by every load, stop and clear, so a preload that was still
  /// fetching its source when the queue moved on is dropped.
  int _generation = 0;

  // Unlike preload generation, this is invalidated only by load/stop/dispose.
  // A slow cache lookup must never replace a newer selection or undo stop.
  int _loadOperation = 0;

  _Deck _listen(_Deck deck) {
    final player = deck.player;
    if (supportsSilenceSkipping && _skipSilence) {
      unawaited(player.setSkipSilenceEnabled(true));
    }
    player.positionStream.listen((value) {
      if (deck != _active) return;
      _position.add(value);
      _maybeCrossfade(value);
    });
    player.durationStream.listen((value) {
      if (deck == _active) _duration.add(value);
    });
    player.playingStream.listen((value) {
      if (deck == _active) _playing.add(value);
    });
    player.processingStateStream.listen((value) {
      if (deck == _active) _state.add(_engineState(value));
    });
    player.currentIndexStream.listen((index) => _onIndex(deck, index));
    player.playbackEventStream.listen(
      (_) {},
      onError: (Object error) {
        if (deck == _active) _errors.add(error);
      },
    );
    return deck;
  }

  static EngineState _engineState(ProcessingState state) => switch (state) {
        ProcessingState.idle => EngineState.idle,
        ProcessingState.loading => EngineState.loading,
        ProcessingState.buffering => EngineState.buffering,
        ProcessingState.ready => EngineState.ready,
        ProcessingState.completed => EngineState.completed,
      };

  @override
  Stream<Duration> get position => _position.stream;

  @override
  Stream<Duration?> get duration => _duration.stream;

  @override
  Stream<bool> get playing => _playing.stream;

  @override
  Stream<EngineState> get state => _state.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  Stream<String> get advanced => _advanced.stream;

  Future<AudioSource> _source(Track track, Uri url) async => track.isLocal
      ? AudioSource.uri(url, tag: track.id)
      : await _cache.sourceFor(track, url);

  @override
  Future<void> load(
    Track track,
    Uri url, {
    Duration start = Duration.zero,
  }) async {
    final operation = ++_loadOperation;
    _generation++;
    await _finishCrossfade();
    if (operation != _loadOperation) return;
    await _clearStandby();
    if (operation != _loadOperation) return;
    final source = await _source(track, url);
    if (operation != _loadOperation) return;
    final deck = _active;
    final playlist = ConcatenatingAudioSource(children: [source]);
    deck
      ..playlist = playlist
      ..ids.replaceRange(0, deck.ids.length, [track.id])
      ..tracks.replaceRange(0, deck.tracks.length, [track]);
    _currentId = track.id;
    _nextId = null;
    // A new track starts from its own beginning, at full volume.
    _playOp++;
    _seekOp++;
    _transport.jump(1);
    await deck.player.setVolume(_deckVolume(deck));
    if (operation != _loadOperation) return;
    try {
      await deck.player.setAudioSource(playlist, initialPosition: start);
    } catch (_) {
      if (operation != _loadOperation) return;
      if (track.isLocal) rethrow;
      // A corrupt cached file (even one with the expected length), or a
      // failed cache proxy, must not poison every subsequent attempt. Try
      // the original URL directly once; the controller can refresh it if
      // that URL has expired. Keep the same requested seek position.
      final direct = ConcatenatingAudioSource(
        children: [AudioSource.uri(url, tag: track.id)],
      );
      deck.playlist = direct;
      await deck.player.setAudioSource(direct, initialPosition: start);
    }
  }

  @override
  Future<void> preload(Track track, Uri url) async {
    await clearPreload();
    final generation = _generation;
    // A short track can reach its preload point while it is still fading
    // in; the second player is free once that fade is over.
    await _fadeDone?.future;
    final source = await _source(track, url);
    if (generation != _generation) return;
    _nextId = track.id;
    if (supportsCrossfade && _crossfade > Duration.zero) {
      final deck = _standby ??= _listen(_Deck());
      final playlist = ConcatenatingAudioSource(children: [source]);
      deck
        ..playlist = playlist
        ..ids.replaceRange(0, deck.ids.length, [track.id])
        ..tracks.replaceRange(0, deck.tracks.length, [track]);
      await deck.player.setVolume(0);
      await deck.player.setSpeed(_speed);
      // Prepares and buffers it, paused, ready to fade in.
      await deck.player.setAudioSource(playlist);
    } else {
      final deck = _active;
      deck.ids.add(track.id);
      deck.tracks.add(track);
      await deck.playlist?.add(source);
    }
  }

  @override
  Future<void> clearPreload() async {
    _generation++;
    _nextId = null;
    final deck = _active;
    final after = deck.index + 1;
    if (deck.ids.length > after) {
      deck.ids.removeRange(after, deck.ids.length);
      deck.tracks.removeRange(after, deck.tracks.length);
      await deck.playlist?.removeRange(after, deck.playlist!.length);
    }
    await _clearStandby();
  }

  Future<void> _clearStandby() async {
    final standby = _standby;
    if (standby == null || standby == _fadingOut || standby.ids.isEmpty) {
      return;
    }
    standby.ids.clear();
    standby.tracks.clear();
    await standby.player.stop();
  }

  /// The active player reached the preloaded track by itself (gaplessly):
  /// report it, then drop the finished tracks before it.
  void _onIndex(_Deck deck, int? index) {
    if (deck != _active || index == null || index >= deck.ids.length) return;
    final id = deck.ids[index];
    if (id == _currentId || id != _nextId) return;
    final track = deck.tracks[index];
    _currentId = id;
    _nextId = null;
    _advanced.add(id);
    _duration.add(deck.player.duration);
    if (index > 0) {
      deck.ids.removeRange(0, index);
      deck.tracks.removeRange(0, index);
      unawaited(deck.playlist?.removeRange(0, index));
    }
    // The next track of a gapless pair has its own gain.
    if (_fade == null) unawaited(deck.player.setVolume(_volumeFor(track)));
  }

  void _maybeCrossfade(Duration position) {
    final standby = _standby;
    final duration = _active.player.duration;
    if (_fade != null ||
        standby == null ||
        standby.ids.isEmpty ||
        standby.ids.first != _nextId ||
        duration == null ||
        !_active.player.playing ||
        // Not buffered in time: the current track ends and the app moves on
        // as usual.
        standby.player.processingState != ProcessingState.ready) {
      return;
    }
    final overlap = effectiveCrossfade(_crossfade, duration, speed: _speed);
    if (!shouldStartCrossfade(
      position: position,
      duration: duration,
      crossfade: overlap,
      speed: _speed,
    )) {
      return;
    }
    _startCrossfade(standby, overlap);
  }

  void _startCrossfade(_Deck into, Duration overlap) {
    final out = _active;
    _active = into;
    _standby = out;
    _fadingOut = out;
    final id = into.ids.first;
    _currentId = id;
    _nextId = null;
    _fadeDone = Completer<void>();
    unawaited(into.player.play());
    _advanced.add(id);
    _duration.add(into.player.duration);
    _position.add(into.player.position);
    _playing.add(true);
    _state.add(_engineState(into.player.processingState));

    const step = Duration(milliseconds: 50);
    final steps = (overlap.inMilliseconds / step.inMilliseconds).ceil();
    var done = 0;
    _fade = Timer.periodic(step, (_) {
      done++;
      final (outGain, inGain) = crossfadeGains(done / steps);
      out.player.setVolume(_deckVolume(out) * outGain);
      into.player.setVolume(_deckVolume(into) * inGain);
      if (done >= steps) unawaited(_finishCrossfade());
    });
  }

  /// Ends a running crossfade at once: the outgoing track stops and the
  /// incoming one plays at full volume.
  Future<void> _finishCrossfade() async {
    final fade = _fade;
    final out = _fadingOut;
    if (fade == null || out == null) return;
    fade.cancel();
    _fade = null;
    _fadingOut = null;
    out.ids.clear();
    out.tracks.clear();
    await _active.player.setVolume(_deckVolume(_active));
    await out.player.stop();
    _fadeDone?.complete();
    _fadeDone = null;
  }

  @override
  void play() {
    _playOp++;
    final player = _active.player;
    // Resuming mid-track fades in; a track starting from the top already
    // starts from silence.
    if (!player.playing &&
        player.position > const Duration(milliseconds: 500)) {
      _transport.jump(0);
      unawaited(_play(player));
      unawaited(_transport.to(1, transportFade));
    } else {
      unawaited(_transport.to(1, transportFade));
      unawaited(_play(player));
    }
  }

  Future<void> _play(AudioPlayer player) async {
    try {
      await player.play();
    } catch (error) {
      if (!PlaybackBlocked.matches(error)) {
        _errors.add(error);
        return;
      }
      // just_audio already counts itself as playing; it is silent, so say
      // so and wait for a tap instead of showing a playing state.
      await player.pause();
      _errors.add(const PlaybackBlocked());
    }
  }

  @override
  Future<void> pause() async {
    await _finishCrossfade();
    final op = _playOp;
    _seekOp++;
    if (_active.player.playing) {
      await _transport.to(0, transportFade);
      // Play was tapped while fading out: keep playing.
      if (op != _playOp) return;
    }
    await _active.player.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    await _finishCrossfade();
    final op = ++_seekOp;
    if (!_active.player.playing) {
      await _active.player.seek(position);
      return;
    }
    await _transport.to(0, seekFadeOut);
    await _active.player.seek(position);
    if (op == _seekOp) unawaited(_transport.to(1, seekFadeIn));
  }

  @override
  Future<void> stop() async {
    _loadOperation++;
    _generation++;
    _playOp++;
    _seekOp++;
    await _finishCrossfade();
    await _clearStandby();
    _currentId = null;
    _nextId = null;
    await _active.player.stop();
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _active.player.setSpeed(speed);
    await _standby?.player.setSpeed(speed);
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    // A running crossfade applies it on its next step.
    if (_fade == null) await _active.player.setVolume(_deckVolume(_active));
  }

  @override
  Future<void> setCrossfade(Duration crossfade) async {
    _crossfade = supportsCrossfade ? crossfade : Duration.zero;
  }

  @override
  Future<void> setTrackGain(double Function(Track track) gainFor) async {
    _gainFor = gainFor;
    // A running crossfade picks it up on its next step.
    if (_fade == null) await _active.player.setVolume(_deckVolume(_active));
  }

  @override
  Future<void> dispose() async {
    _loadOperation++;
    _transport.dispose();
    _fade?.cancel();
    _fadeDone?.complete();
    await _active.player.dispose();
    await _standby?.player.dispose();
    await Future.wait([
      _position.close(),
      _duration.close(),
      _playing.close(),
      _state.close(),
      _errors.close(),
      _advanced.close(),
    ]);
  }
}
