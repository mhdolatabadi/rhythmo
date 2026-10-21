import 'package:rhythmo/features/journey/application/listening_journey.dart';
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/lyrics/application/lyrics_controller.dart';
import 'package:rhythmo/features/player/application/favorite_tracks.dart';
import 'package:rhythmo/features/player/application/playback_metrics.dart';
import 'package:rhythmo/features/player/application/play_queue.dart';
import 'package:rhythmo/features/player/application/playback_settings.dart';
import 'package:rhythmo/features/player/data/audio_engine.dart';
import 'package:rhythmo/features/player/data/loudness.dart';

enum PlayerStatus {
  idle,
  loading,
  playing,
  paused,
  buffering,
  completed,
  error
}

/// "Previous" restarts the current track once it has played this long.
const restartThreshold = Duration(seconds: 3);

/// How long the sleep timer fades the music out before pausing.
const sleepFade = Duration(seconds: 5);

/// How close to the end of a track the next one is fetched and buffered.
/// Late enough that its short-lived link is still fresh when it starts.
const preloadLead = Duration(seconds: 30);

/// A play counts as a real listen, for the recently played history, after
/// this long, or after half of a shorter track.
const meaningfulListen = Duration(seconds: 30);

/// How long [duration] must play to count as a listen.
Duration listenThreshold(Duration? duration) {
  if (duration == null || duration <= Duration.zero) return meaningfulListen;
  final half = duration ~/ 2;
  return half < meaningfulListen ? half : meaningfulListen;
}

/// Plays a queue of tracks, one at a time, from short-lived stream URLs.
class PlayerController extends ChangeNotifier {
  PlayerController({
    required TracksApi api,
    required AudioEngine engine,
    required String? Function() token,
    Random? random,
    FavoriteTracks? favorites,
    PlaybackSettingsStore? settingsStore,
    DateTime Function()? now,
    this.onListened,
    this.journey,
    this.lyrics,
  })  : _api = api,
        _engine = engine,
        _token = token,
        _random = random ?? Random(),
        _settingsStore = settingsStore ?? MemoryPlaybackSettingsStore(),
        _now = now ?? DateTime.now,
        favorites = favorites ?? FavoriteTracks() {
    _subscriptions = [
      engine.position.listen((value) {
        _countHeard(value - _position);
        _position = value;
        _maybePreload();
        _maybeFadeAtTrackEnd();
        notifyListeners();
      }),
      engine.duration.listen((value) {
        _duration = value;
        notifyListeners();
      }),
      engine.playing.listen((value) {
        _playing = value;
        _refreshStatus();
      }),
      engine.state.listen((value) {
        _engineState = value;
        _refreshStatus();
      }),
      engine.errors.listen(_onEngineError),
      engine.advanced.listen(_onAdvanced),
    ];
    // Normalization is on until the saved settings say otherwise.
    unawaited(_applyLoudness(_settings.loudness));
  }

  final TracksApi _api;
  final AudioEngine _engine;
  final String? Function() _token;
  final Random _random;
  final PlaybackSettingsStore _settingsStore;
  final DateTime Function() _now;
  late final List<StreamSubscription<Object?>> _subscriptions;

  /// The tracks the listener liked, shown on the now-playing screen.
  final FavoriteTracks favorites;

  /// Time to first audio and stalls per play; printed in debug builds.
  final metrics = PlaybackMetrics();

  /// Lyrics for the now-playing screen; null where there is no server.
  final LyricsController? lyrics;

  /// Called once each time a track has played long enough to count, see
  /// [listenThreshold].
  final void Function(Track track)? onListened;

  final ListeningJourney? journey;

  /// Whether the current play of the track has been counted.
  bool _listened = false;

  /// How much of the current play was heard; seeking past music does not
  /// count towards it.
  Duration _heard = Duration.zero;

  PlayQueue? _queue;
  bool _shuffle = false;
  QueueRepeat _repeat = QueueRepeat.off;
  bool _advancing = false;
  Track? _track;
  PlayerStatus _status = PlayerStatus.idle;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  EngineState _engineState = EngineState.idle;
  bool _loading = false;
  bool _retriedLink = false;
  int _request = 0;

  PlaybackSettings _settings = const PlaybackSettings();
  bool _queueSettingsChanged = false;
  bool _systemSettingsChanged = false;

  /// The track after the current one handed to the engine, and its link.
  String? _preloadedId;
  ({String id, Uri url, DateTime? expiresAt})? _prefetched;

  DateTime? _sleepAt;
  bool _sleepAtTrackEnd = false;
  Timer? _sleepTick;
  Timer? _fadeTimer;

  Track? get track => _track;
  bool get shuffle => _shuffle;
  QueueRepeat get repeat => _repeat;
  PlayerStatus get status => _status;

  /// The browser blocked audio until the listener taps play (web autoplay
  /// rules); cleared once playback is asked for again.
  bool get needsTap => _needsTap;
  bool _needsTap = false;
  Duration get position => _position;
  Duration? get duration => _duration;

  double get speed => _settings.speed;
  bool get playOnlySelected => _settings.playOnlySelected;
  bool get preventDuplicates => _settings.preventDuplicates;

  Future<void> setQueuePreferences({
    bool? playOnlySelected,
    bool? preventDuplicates,
  }) async {
    _queueSettingsChanged = true;
    _settings = _settings.copyWith(
      playOnlySelected: playOnlySelected,
      preventDuplicates: preventDuplicates,
    );
    notifyListeners();
    await _saveSettings();
  }

  bool get systemControls => _settings.systemControls;
  bool get externalPlayback => _settings.externalPlayback;
  bool get skipSilence => _settings.skipSilence;
  bool get supportsSilenceSkipping =>
      _engine is SilenceSkippingEngine &&
      (_engine as SilenceSkippingEngine).supportsSilenceSkipping;

  Future<void> setSystemPreferences({
    bool? systemControls,
    bool? externalPlayback,
    bool? skipSilence,
  }) async {
    _systemSettingsChanged = true;
    if (skipSilence != null && supportsSilenceSkipping) {
      await (_engine as SilenceSkippingEngine).setSkipSilence(skipSilence);
    }
    _settings = _settings.copyWith(
      systemControls: systemControls,
      externalPlayback: externalPlayback,
      skipSilence: supportsSilenceSkipping ? skipSilence : null,
    );
    notifyListeners();
    await _saveSettings();
  }

  /// How long consecutive tracks overlap; zero when off or unsupported.
  Duration get crossfade => _settings.crossfade;

  /// Whether this platform can overlap tracks; otherwise crossfade is hidden.
  bool get supportsCrossfade => _engine.supportsCrossfade;

  /// Whether a sleep timer is set, for a duration or the track's end.
  bool get sleepTimerActive => _sleepAt != null || _sleepAtTrackEnd;

  /// The sleep timer waits for the current track to end.
  bool get sleepsAtTrackEnd => _sleepAtTrackEnd;

  /// Time left on a duration sleep timer.
  Duration? get sleepRemaining {
    final at = _sleepAt;
    if (at == null) return null;
    final left = at.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Whether the sleep timer is fading the music out right now.
  bool get sleepFading => _fadeTimer != null;

  /// Restores saved speed and crossfade; changes made meanwhile win.
  Future<void> loadSettings() async {
    try {
      final saved = await _settingsStore.read();
      if (_settings.speed == 1) await _applySpeed(saved.speed);
      if (_settings.crossfade == Duration.zero) {
        await _applyCrossfade(saved.crossfade);
      }
      if (_settings.loudness == const PlaybackSettings().loudness) {
        await _applyLoudness(saved.loudness);
      }
      if (!_systemSettingsChanged) {
        if (supportsSilenceSkipping) {
          await (_engine as SilenceSkippingEngine)
              .setSkipSilence(saved.skipSilence);
        }
        if (!_systemSettingsChanged) {
          _settings = _settings.copyWith(
              systemControls: saved.systemControls,
              externalPlayback: saved.externalPlayback,
              skipSilence: supportsSilenceSkipping && saved.skipSilence);
        }
      }
      if (!_queueSettingsChanged) {
        _settings = _settings.copyWith(
          playOnlySelected: saved.playOnlySelected,
          preventDuplicates: saved.preventDuplicates,
        );
      }
      notifyListeners();
    } catch (error) {
      debugPrint('Playback settings unavailable: $error');
    }
  }

  /// Plays faster or slower, keeping the pitch; remembered between sessions.
  Future<void> setSpeed(double speed) async {
    await _applySpeed(speed);
    notifyListeners();
    await _saveSettings();
  }

  /// Overlaps the end of each track with the next by [value] (zero is off);
  /// remembered between sessions. Ignored where [supportsCrossfade] is false.
  Future<void> setCrossfade(Duration value) async {
    if (!supportsCrossfade) return;
    await _applyCrossfade(value);
    notifyListeners();
    await _saveSettings();
    // The next track is buffered differently with and without an overlap.
    await _dropPreload();
    _maybePreload();
  }

  /// How tracks are evened out in loudness; remembered between sessions.
  LoudnessMode get loudness => _settings.loudness;

  /// Turns loudness normalization off, or evens out each track or album.
  /// The files are never changed; only each track's volume is.
  Future<void> setLoudness(LoudnessMode mode) async {
    await _applyLoudness(mode);
    notifyListeners();
    await _saveSettings();
  }

  Future<void> _applyLoudness(LoudnessMode mode) async {
    _settings = _settings.copyWith(loudness: mode);
    await _engine.setTrackGain((track) => normalizationGain(track, mode));
  }

  Future<void> _applySpeed(double speed) async {
    final value =
        speed.clamp(playbackSpeeds.first, playbackSpeeds.last).toDouble();
    _settings = _settings.copyWith(speed: value);
    await _engine.setSpeed(value);
  }

  Future<void> _applyCrossfade(Duration value) async {
    if (!supportsCrossfade) return;
    final clamped = Duration(
      milliseconds: value.inMilliseconds.clamp(0, maxCrossfade.inMilliseconds),
    );
    _settings = _settings.copyWith(crossfade: clamped);
    await _engine.setCrossfade(clamped);
  }

  Future<void> _saveSettings() async {
    try {
      await _settingsStore.write(_settings);
    } catch (error) {
      debugPrint('Could not save playback settings: $error');
    }
  }

  /// Pauses after [after] of listening, fading out over [sleepFade] first.
  /// Replaces any earlier sleep timer.
  void setSleepTimer(Duration after) {
    _clearSleep();
    _sleepAt = _now().add(after);
    _sleepTick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    notifyListeners();
  }

  /// Pauses when the current track ends, fading out its last seconds; the
  /// next track is then ready to play.
  void setSleepAtTrackEnd() {
    _clearSleep();
    _sleepAtTrackEnd = true;
    // The track must end by itself, without sliding into the next one.
    unawaited(_dropPreload());
    notifyListeners();
  }

  void cancelSleepTimer() {
    final wasEndOfTrack = _sleepAtTrackEnd;
    _clearSleep();
    notifyListeners();
    if (wasEndOfTrack) _maybePreload();
  }

  void _onTick() {
    final remaining = sleepRemaining;
    if (remaining == null) return;
    if (remaining <= sleepFade && _fadeTimer == null) {
      if (_status == PlayerStatus.playing ||
          _status == PlayerStatus.buffering) {
        _startFade(remaining);
      } else {
        // Already quiet: nothing to stop.
        _clearSleep();
      }
    }
    notifyListeners();
  }

  void _maybeFadeAtTrackEnd() {
    final duration = _duration;
    if (!_sleepAtTrackEnd ||
        _fadeTimer != null ||
        duration == null ||
        _status != PlayerStatus.playing) {
      return;
    }
    final left = (duration - _position) * (1 / speed);
    if (left <= sleepFade) _startFade(left);
  }

  /// Lowers the volume step by step over [over]. A duration timer pauses
  /// when it is silent; a track-end timer waits for the track to finish.
  void _startFade(Duration over) {
    const step = Duration(milliseconds: 100);
    final steps = max(1, (over.inMilliseconds / step.inMilliseconds).ceil());
    var done = 0;
    _fadeTimer = Timer.periodic(step, (timer) {
      done++;
      unawaited(_engine.setVolume(max(0, 1 - done / steps)));
      if (done < steps) return;
      timer.cancel();
      if (!_sleepAtTrackEnd) unawaited(_sleep());
    });
    notifyListeners();
  }

  Future<void> _sleep() async {
    _clearSleep(restoreVolume: false);
    await pause();
    await _engine.setVolume(1);
    notifyListeners();
  }

  void _clearSleep({bool restoreVolume = true}) {
    final fading = _fadeTimer != null;
    _sleepTick?.cancel();
    _fadeTimer?.cancel();
    _sleepTick = null;
    _fadeTimer = null;
    _sleepAt = null;
    _sleepAtTrackEnd = false;
    if (fading && restoreVolume) unawaited(_engine.setVolume(1));
  }

  /// The tracks that will play after the current one, in order.
  List<Track> get upcoming => _queue?.upcoming ?? const [];

  /// Plays the upcoming track at [index], as picked from the queue.
  Future<void> skipTo(int index) async {
    final queue = _queue;
    if (queue == null || index < 0 || index >= queue.upcoming.length) return;
    await _start(queue.skipTo(index));
  }

  /// Tapping a row respects queue mode; explicit play-all uses [playFrom].
  Future<void> playTapped(List<Track> tracks, int index) =>
      playOnlySelected ? playFrom([tracks[index]], 0) : playFrom(tracks, index);

  List<Track> _queueTracks(List<Track> tracks) {
    if (!preventDuplicates) return tracks;
    final seen = <String>{};
    return tracks.where((track) => seen.add(track.id)).toList();
  }

  /// Plays [tracks] starting at [index], or toggles pause when that track
  /// is already the current one. Shuffle and repeat settings carry over.
  Future<void> playFrom(List<Track> tracks, int index) async {
    final track = tracks[index];
    if (_track?.id == track.id && _status != PlayerStatus.error) {
      return toggle();
    }
    final queued = _queueTracks(tracks);
    final start = preventDuplicates
        ? queued.indexWhere((item) => item.id == track.id)
        : index;
    _queue = PlayQueue(queued, start: start, random: _random)
      ..repeat = _repeat
      ..shuffled = _shuffle;
    await _start(_queue!.current);
  }

  /// Starts with a randomized first track and keeps the full source shuffled.
  Future<void> playShuffled(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    _shuffle = true;
    _queue = PlayQueue.shuffled(_queueTracks(tracks), random: _random)
      ..repeat = _repeat;
    notifyListeners();
    await _start(_queue!.current);
  }

  /// Plays a single track.
  Future<void> play(Track track) => playFrom([track], 0);

  Future<void> next() async {
    final next = _queue?.next();
    if (next != null) await _start(next);
  }

  /// Restarts the current track after its first seconds, otherwise goes back.
  Future<void> previous() async {
    final queue = _queue;
    if (queue == null) return;
    if (_position > restartThreshold) return seek(Duration.zero);
    await _start(queue.previous());
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    _queue?.shuffled = _shuffle;
    notifyListeners();
    unawaited(_replanPreload());
  }

  /// Off → all → one → off.
  void cycleRepeat() {
    _repeat =
        QueueRepeat.values[(_repeat.index + 1) % QueueRepeat.values.length];
    _queue?.repeat = _repeat;
    notifyListeners();
    unawaited(_replanPreload());
  }

  /// Loads [track] and plays it, or leaves it paused when [autoplay] is false.
  Future<void> _start(Track track, {bool autoplay = true}) async {
    final token = _token();
    if (token == null && !track.playsWithoutAccount) return;
    final request = ++_request;
    final prefetched = _freshPrefetch(track.id);
    _preloadedId = null;
    _prefetched = null;
    _track = track;
    _position = Duration.zero;
    _duration = null;
    _retriedLink = false;
    _listened = false;
    _heard = Duration.zero;
    _advancing = false;
    _loading = true;
    if (_fadeTimer != null && _sleepAtTrackEnd) {
      // A new track restarts the wait for a track's end at full volume.
      _fadeTimer!.cancel();
      _fadeTimer = null;
      unawaited(_engine.setVolume(1));
    }
    metrics.started(track.id, _now());
    _setStatus(PlayerStatus.loading);
    try {
      final url =
          track.sourceUri ?? prefetched ?? (await _link(token, track)).url;
      if (request != _request) return;
      await _engine.load(track, url);
      if (request != _request) return;
      _loading = false;
      if (autoplay) _engine.play();
      _refreshStatus();
    } catch (_) {
      if (request != _request) return;
      _loading = false;
      _setStatus(PlayerStatus.error);
    }
  }

  /// A finished track moves the queue on, or replays itself on repeat-one.
  /// With the sleep timer set for the track's end, the next track is only
  /// loaded, paused, so playing again continues from it.
  Future<void> _onCompleted() async {
    final queue = _queue;
    if (_advancing || queue == null) return;
    _advancing = true;
    final sleep = _sleepAtTrackEnd;
    if (sleep) {
      _clearSleep(restoreVolume: false);
      await _engine.setVolume(1);
    }
    final next = queue.next(auto: true);
    if (next == null) {
      _setStatus(PlayerStatus.completed);
    } else if (next.id == _track?.id && _repeat == QueueRepeat.one) {
      _advancing = false;
      _listened = false;
      _heard = Duration.zero;
      await _engine.seek(Duration.zero);
      if (!sleep) _engine.play();
    } else {
      await _start(next, autoplay: !sleep);
    }
  }

  /// The engine moved on to the preloaded track by itself, gaplessly or by
  /// a crossfade: follow it in the queue without loading anything.
  void _onAdvanced(String id) {
    final queue = _queue;
    if (queue == null || id != _preloadedId) return;
    if (queue.peekNext(auto: true)?.id != id) return;
    final next = queue.next(auto: true)!;
    _request++;
    _preloadedId = null;
    _prefetched = null;
    _track = next;
    _position = Duration.zero;
    _duration = null;
    _retriedLink = false;
    _listened = false;
    _heard = Duration.zero;
    _advancing = false;
    metrics.started(next.id, _now(), preloaded: true);
    _refreshStatus();
  }

  /// Hands the engine the next track once the current one nears its end.
  void _maybePreload() {
    final queue = _queue;
    final track = _track;
    final duration = _duration;
    if (queue == null ||
        track == null ||
        duration == null ||
        _loading ||
        _sleepAtTrackEnd ||
        _preloadedId != null ||
        (_status != PlayerStatus.playing &&
            _status != PlayerStatus.buffering &&
            _status != PlayerStatus.paused)) {
      return;
    }
    final next = queue.peekNext(auto: true);
    // Repeating one track replays it through the completed state instead.
    if (next == null || next.id == track.id) return;
    final lead = preloadLead + crossfade * speed;
    if (duration - _position > lead) return;
    unawaited(_preload(next));
  }

  Future<void> _preload(Track next) async {
    final token = _token();
    if (token == null && !next.playsWithoutAccount) return;
    final request = _request;
    _preloadedId = next.id;
    try {
      final link = next.sourceUri == null ? await _link(token, next) : null;
      if (request != _request || _preloadedId != next.id) return;
      final url = next.sourceUri ?? link!.url;
      _prefetched = (id: next.id, url: url, expiresAt: link?.expiresAt);
      await _engine.preload(next, url);
    } catch (error) {
      // The track still starts, with a short gap, when this one ends.
      debugPrint('Could not preload the next track: $error');
    }
  }

  /// The link fetched while preloading [trackId], unless it is about to
  /// expire.
  Uri? _freshPrefetch(String trackId) {
    final prefetched = _prefetched;
    if (prefetched == null || prefetched.id != trackId) return null;
    final expiresAt = prefetched.expiresAt;
    if (expiresAt != null &&
        expiresAt.isBefore(_now().add(const Duration(minutes: 1)))) {
      return null;
    }
    return prefetched.url;
  }

  Future<void> _dropPreload() async {
    if (_preloadedId == null) return;
    _preloadedId = null;
    _prefetched = null;
    await _engine.clearPreload();
  }

  /// The queue changed: drop a preloaded track that no longer comes next.
  Future<void> _replanPreload() async {
    final planned = _queue?.peekNext(auto: true)?.id;
    if (_preloadedId != null && _preloadedId != planned) await _dropPreload();
    _maybePreload();
  }

  Future<void> toggle() async {
    switch (_status) {
      case PlayerStatus.playing || PlayerStatus.buffering:
        await pause();
      case PlayerStatus.paused || PlayerStatus.completed || PlayerStatus.error:
        await resume();
      case PlayerStatus.idle || PlayerStatus.loading:
        break;
    }
  }

  Future<void> pause() async {
    if (_status == PlayerStatus.playing || _status == PlayerStatus.buffering) {
      await _engine.pause();
    }
  }

  /// Continues a paused track, replays a completed one from the start, or
  /// retries one that failed.
  Future<void> resume() async {
    _needsTap = false;
    switch (_status) {
      case PlayerStatus.paused:
        if (_fadeTimer != null) {
          // Playing again while it fades means the listener is still awake.
          _clearSleep();
          notifyListeners();
        }
        _engine.play();
      case PlayerStatus.completed:
        _advancing = false;
        await _engine.seek(Duration.zero);
        _engine.play();
      case PlayerStatus.error:
        if (_track != null) await _start(_track!);
      case PlayerStatus.idle ||
            PlayerStatus.loading ||
            PlayerStatus.playing ||
            PlayerStatus.buffering:
        break;
    }
  }

  Future<void> seek(Duration position) async {
    _position = position;
    notifyListeners();
    await _engine.seek(position);
  }

  /// Removes a deleted cloud track from the active queue. Deleting the
  /// current track stops playback so a stale stream cannot keep playing.
  Future<void> removeTrack(String trackId) async {
    final queue = _queue;
    if (_track?.id == trackId || (queue != null && !queue.remove(trackId))) {
      await stop();
      return;
    }
    notifyListeners();
    await _replanPreload();
  }

  /// Release a local file while its tags are rewritten, then reopen it at the
  /// same position. The queue and repeat/shuffle choices stay intact.
  Future<T> whileEditingLocalFile<T>(
      Track edited, Future<T> Function() edit) async {
    final current = _track;
    if (current == null ||
        current.sourceUri == null ||
        current.sourceUri != edited.sourceUri) return edit();
    final position = _position;
    final wasPlaying =
        _status == PlayerStatus.playing || _status == PlayerStatus.buffering;
    final request = _request;
    await _engine.stop();
    try {
      return await edit();
    } finally {
      // Do not replace a different song the listener selected meanwhile.
      if (request == _request && _track?.id == current.id) {
        await _start(current, autoplay: false);
        await seek(position);
        if (wasPlaying) await resume();
      }
    }
  }

  /// Shows edited metadata for a queued or playing track without
  /// interrupting playback; the audio itself does not change.
  void updateTrack(Track track) {
    final queued = _queue?.replace(track) ?? false;
    final current = _track;
    final playing = current != null && current.id == track.id;
    if (playing) _track = track.keepingContextOf(current);
    if (queued || playing) notifyListeners();
  }

  /// Stops playback and forgets the track, for example on logout.
  Future<void> stop() async {
    _request++;
    _clearSleep();
    _preloadedId = null;
    _prefetched = null;
    _queue = null;
    _track = null;
    _position = Duration.zero;
    _duration = null;
    _loading = false;
    await _engine.stop();
    _setStatus(PlayerStatus.idle);
  }

  /// Someone else's track is played through the shared link or the
  /// collaborative playlist it was opened from, a store song through the
  /// store; the user's own directly.
  Future<StreamLink> _link(String? token, Track track) {
    if (track.fromStore) return _api.storeStreamLink(token, track.id);
    final shareToken = track.sharedVia;
    final playlistId = track.viaPlaylist;
    if (shareToken != null) {
      return _api.sharedStreamLink(token, shareToken, track.id);
    }
    // Another member's track in a collaborative playlist.
    if (playlistId != null) {
      return _api.playlistStreamLink(token!, playlistId, track.id);
    }
    return _api.streamLink(token!, track.id);
  }

  /// Stream URLs expire; when playback fails (typically on a seek after the
  /// URL expired), fetch a fresh one once and resume where it stopped.
  Future<void> _onEngineError(Object error) async {
    if (error is PlaybackBlocked) {
      // Nothing is wrong with the track: the browser wants a tap first.
      _needsTap = true;
      _refreshStatus();
      return;
    }
    final track = _track;
    final token = _token();
    if (track == null ||
        track.isLocal ||
        (token == null && !track.playsWithoutAccount) ||
        _retriedLink) {
      _setStatus(PlayerStatus.error);
      return;
    }
    _retriedLink = true;
    final request = _request;
    final resumeAt = _position;
    try {
      final link = await _link(token, track);
      if (request != _request) return;
      // Reloading drops the preloaded track; it is fetched again later.
      _preloadedId = null;
      _prefetched = null;
      await _engine.load(track, link.url, start: resumeAt);
      _engine.play();
    } catch (_) {
      if (request == _request) _setStatus(PlayerStatus.error);
    }
  }

  /// Position updates arrive a fraction of a second apart while playing;
  /// a bigger jump is a seek.
  static const _maxStep = Duration(seconds: 2);

  void _countHeard(Duration step) {
    final track = _track;
    if (_listened || track == null || _loading || !_playing) return;
    if (step <= Duration.zero || step > _maxStep) return;
    _heard += step;
    if (_heard < listenThreshold(_duration)) return;
    _listened = true;
    journey?.record(track);
    onListened?.call(track);
  }

  void _refreshStatus() {
    if (_loading || _status == PlayerStatus.error || _track == null) {
      notifyListeners();
      return;
    }
    if (_engineState == EngineState.completed) {
      // Outside the engine's event callback, which it may re-trigger.
      unawaited(Future.microtask(_onCompleted));
      return;
    }
    _setStatus(switch (_engineState) {
      EngineState.completed => PlayerStatus.completed,
      EngineState.loading ||
      EngineState.buffering when _playing =>
        PlayerStatus.buffering,
      _ => _playing ? PlayerStatus.playing : PlayerStatus.paused,
    });
  }

  void _setStatus(PlayerStatus status) {
    if (status == PlayerStatus.playing) _needsTap = false;
    _status = status;
    metrics.status(status, _now());
    notifyListeners();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _clearSleep(restoreVolume: false);
    _engine.dispose();
    favorites.dispose();
    super.dispose();
  }
}
