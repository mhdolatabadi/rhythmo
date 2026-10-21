import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/play_queue.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/data/audio_engine.dart';

import 'upload_controller_test.dart' show FakeTracksApi;

/// Records calls and lets tests drive the engine's streams.
class FakeAudioEngine implements AudioEngine {
  final positionCtl = StreamController<Duration>.broadcast(sync: true);
  final durationCtl = StreamController<Duration?>.broadcast(sync: true);
  final playingCtl = StreamController<bool>.broadcast(sync: true);
  final stateCtl = StreamController<EngineState>.broadcast(sync: true);
  final errorCtl = StreamController<Object>.broadcast(sync: true);
  final advancedCtl = StreamController<String>.broadcast(sync: true);
  final loads = <(String, Uri, Duration)>[];
  final calls = <String>[];
  Object? loadError;

  /// Tracks handed to [preload], by id; null entries are [clearPreload]s.
  final preloads = <String?>[];
  final volumes = <double>[];
  double speed = 1;
  Duration crossfade = Duration.zero;
  bool crossfadeSupported = true;

  /// The track preloaded now, if any.
  String? get preloaded => preloads.isEmpty ? null : preloads.last;

  @override
  Stream<Duration> get position => positionCtl.stream;
  @override
  Stream<Duration?> get duration => durationCtl.stream;
  @override
  Stream<bool> get playing => playingCtl.stream;
  @override
  Stream<EngineState> get state => stateCtl.stream;
  @override
  Stream<Object> get errors => errorCtl.stream;
  @override
  Stream<String> get advanced => advancedCtl.stream;
  @override
  bool get supportsCrossfade => crossfadeSupported;

  @override
  Future<void> load(Track track, Uri url,
      {Duration start = Duration.zero}) async {
    loads.add((track.id, url, start));
    if (preloaded != null) preloads.add(null);
    if (loadError != null) throw loadError!;
    stateCtl.add(EngineState.ready);
    durationCtl.add(const Duration(minutes: 3));
  }

  @override
  void play() {
    calls.add('play');
    playingCtl.add(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    playingCtl.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek:${position.inSeconds}');
    positionCtl.add(position);
    // Like just_audio, seeking leaves the completed state.
    stateCtl.add(EngineState.ready);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    playingCtl.add(false);
    stateCtl.add(EngineState.idle);
  }

  @override
  Future<void> preload(Track track, Uri url) async => preloads.add(track.id);

  @override
  Future<void> clearPreload() async {
    if (preloaded != null) preloads.add(null);
  }

  @override
  Future<void> setSpeed(double speed) async => this.speed = speed;

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);

  @override
  Future<void> setCrossfade(Duration crossfade) async =>
      this.crossfade = crossfade;

  /// The engine's current loudness gain, see [AudioEngine.setTrackGain].
  double Function(Track track) trackGain = (_) => 1;

  @override
  Future<void> setTrackGain(double Function(Track track) gainFor) async =>
      trackGain = gainFor;

  /// Moves on to the preloaded track by itself, as gapless playback does.
  void advance() {
    final id = preloaded!;
    preloads.add(null);
    advancedCtl.add(id);
    durationCtl.add(const Duration(minutes: 4));
    positionCtl.add(Duration.zero);
  }

  @override
  Future<void> dispose() async {}
}

const _a = Track(id: 'a', title: 'A', contentType: 'audio/mpeg', sizeBytes: 1);
const _b = Track(id: 'b', title: 'B', contentType: 'audio/mpeg', sizeBytes: 1);
const _c = Track(id: 'c', title: 'C', contentType: 'audio/mpeg', sizeBytes: 1);
const _abc = [_a, _b, _c];

void main() {
  late FakeTracksApi api;
  late FakeAudioEngine engine;
  late PlayerController player;

  setUp(() {
    api = FakeTracksApi();
    engine = FakeAudioEngine();
    player = PlayerController(api: api, engine: engine, token: () => 'tok');
  });

  test('rewriting a playing device file releases it and restores its queue',
      () async {
    final local = _a.withDeviceCopy(Uri.parse('content://media/audio/1'));
    await player.playFrom([local, _b], 0);
    await player.seek(const Duration(seconds: 42));
    final result = await player.whileEditingLocalFile(local, () async {
      expect(engine.calls.last, 'stop');
      return 'saved';
    });
    expect(result, 'saved');
    expect(engine.loads.map((load) => load.$1), ['a', 'a']);
    expect(engine.calls, contains('seek:42'));
    expect(player.position, const Duration(seconds: 42));
    expect(player.upcoming.map((track) => track.id), ['b']);
    expect(player.status, PlayerStatus.playing);
  });

  test('a failed local rewrite still restores playback', () async {
    final local = _a.withDeviceCopy(Uri.parse('content://media/audio/1'));
    await player.play(local);
    await expectLater(
        player.whileEditingLocalFile(local, () async {
          throw StateError('write failed');
        }),
        throwsStateError);
    expect(engine.loads.length, 2);
    expect(player.status, PlayerStatus.playing);
  });

  test('an edited track shows its new metadata without restarting', () async {
    const a =
        Track(id: 'a', title: 'A', contentType: 'audio/mpeg', sizeBytes: 1);
    const b =
        Track(id: 'b', title: 'B', contentType: 'audio/mpeg', sizeBytes: 1);
    await player.playFrom([a, b], 0);
    final loads = engine.loads.length;
    var notified = 0;
    player.addListener(() => notified++);

    player.updateTrack(const Track(
        id: 'a', title: 'A edited', contentType: 'audio/mpeg', sizeBytes: 1));
    player.updateTrack(const Track(
        id: 'b', title: 'B edited', contentType: 'audio/mpeg', sizeBytes: 1));
    player.updateTrack(const Track(
        id: 'x', title: 'Not queued', contentType: 'audio/mpeg', sizeBytes: 1));

    expect(player.track?.title, 'A edited');
    expect(player.upcoming.single.title, 'B edited');
    expect(engine.loads, hasLength(loads));
    expect(notified, 2);
  });

  test('plays a track from a fresh stream link', () async {
    final seen = <PlayerStatus>[];
    player.addListener(() => seen.add(player.status));

    await player.play(_a);

    expect(seen.first, PlayerStatus.loading);
    expect(player.status, PlayerStatus.playing);
    expect(player.track?.id, 'a');
    expect(player.duration, const Duration(minutes: 3));
    expect(engine.loads.single.$2.path, '/nafir-music/a');
  });

  test('tapping the current track pauses and resumes it', () async {
    await player.play(_a);

    await player.play(_a);
    expect(player.status, PlayerStatus.paused);
    await player.play(_a);
    expect(player.status, PlayerStatus.playing);
    expect(engine.loads, hasLength(1), reason: 'no reload for the same track');
  });

  test('buffering while playing is reported', () async {
    await player.play(_a);
    engine.stateCtl.add(EngineState.buffering);
    expect(player.status, PlayerStatus.buffering);
    engine.stateCtl.add(EngineState.ready);
    expect(player.status, PlayerStatus.playing);
  });

  test('seek moves the engine and the reported position', () async {
    await player.play(_a);
    await player.seek(const Duration(seconds: 42));
    expect(engine.calls, contains('seek:42'));
    expect(player.position, const Duration(seconds: 42));
  });

  test('a failed link or load is an error that retry recovers', () async {
    api.linkError = Exception('offline');
    await player.play(_a);
    expect(player.status, PlayerStatus.error);

    api.linkError = null;
    await player.toggle();
    expect(player.status, PlayerStatus.playing);
  });

  test('an expired URL is replaced once and playback resumes in place',
      () async {
    await player.play(_a);
    engine.positionCtl.add(const Duration(seconds: 90));

    engine.errorCtl.add(Exception('403'));
    await pumpEventQueue();

    expect(engine.loads, hasLength(2));
    expect(engine.loads.last.$3, const Duration(seconds: 90));
    expect(engine.loads.last.$2, isNot(engine.loads.first.$2));
    expect(player.status, PlayerStatus.playing);

    engine.errorCtl.add(Exception('403 again'));
    await pumpEventQueue();
    expect(player.status, PlayerStatus.error);
    expect(engine.loads, hasLength(2), reason: 'only one automatic retry');
  });

  test('switching tracks while one is loading keeps the newest', () async {
    final first = player.play(_a);
    final second = player.play(_b);
    await Future.wait([first, second]);
    expect(player.track?.id, 'b');
    expect(player.status, PlayerStatus.playing);
  });

  test('completion, then play restarts from the beginning', () async {
    await player.play(_a);
    engine.playingCtl.add(false);
    engine.stateCtl.add(EngineState.completed);
    await pumpEventQueue();
    expect(player.status, PlayerStatus.completed);

    await player.toggle();
    expect(engine.calls, contains('seek:0'));
    expect(player.status, PlayerStatus.playing);
  });

  test('stop forgets the track', () async {
    await player.play(_a);
    await player.stop();
    expect(player.track, isNull);
    expect(player.status, PlayerStatus.idle);
  });

  test('a local device track plays directly without a token or API call',
      () async {
    final local = Track(
      id: 'device:42',
      title: 'On device',
      contentType: 'audio/mpeg',
      sizeBytes: 10,
      sourceUri: Uri.parse('content://media/external/audio/media/42'),
    );
    final signedOut =
        PlayerController(api: api, engine: engine, token: () => null);

    await signedOut.play(local);

    expect(api.calls, isEmpty);
    expect(engine.loads.single.$2, local.sourceUri);
    expect(signedOut.status, PlayerStatus.playing);
  });

  test('without a session nothing is requested', () async {
    final signedOut =
        PlayerController(api: api, engine: engine, token: () => null);
    await signedOut.play(_a);
    expect(api.calls, isEmpty);
    expect(signedOut.track, isNull);
  });

  group('queue', () {
    List<String> loaded() => [for (final load in engine.loads) load.$1];

    Future<void> finishTrack() async {
      engine.stateCtl.add(EngineState.completed);
      await pumpEventQueue();
    }

    test('shuffle-all starts randomized and keeps shuffle enabled', () async {
      final shuffled = PlayerController(
        api: api,
        engine: engine,
        token: () => 'tok',
        random: Random(11),
      );
      await shuffled.playShuffled(_abc);
      expect(shuffled.shuffle, isTrue);
      expect(_abc, contains(shuffled.track));
      expect(loaded(), hasLength(1));
      shuffled.dispose();
    });

    test('a finished track moves on to the next one', () async {
      await player.playFrom(_abc, 0);
      await finishTrack();
      expect(player.track?.id, 'b');
      expect(loaded(), ['a', 'b']);
    });

    test('the end of the queue stops as completed', () async {
      await player.playFrom(_abc, 2);
      await finishTrack();
      expect(player.status, PlayerStatus.completed);
      expect(loaded(), ['c']);
    });

    test('repeat all wraps to the first track', () async {
      player.cycleRepeat();
      expect(player.repeat, QueueRepeat.all);
      await player.playFrom(_abc, 2);
      await finishTrack();
      expect(player.track?.id, 'a');
    });

    test('repeat one replays in place without reloading', () async {
      player
        ..cycleRepeat()
        ..cycleRepeat();
      expect(player.repeat, QueueRepeat.one);
      await player.playFrom(_abc, 0);
      await finishTrack();
      expect(player.track?.id, 'a');
      expect(loaded(), ['a']);
      expect(engine.calls, contains('seek:0'));
      expect(player.status, PlayerStatus.playing);
    });

    test('next and previous', () async {
      await player.playFrom(_abc, 1);
      await player.next();
      expect(player.track?.id, 'c');
      await player.previous();
      expect(player.track?.id, 'b');
    });

    test('previous restarts a track that has played a few seconds', () async {
      await player.playFrom(_abc, 1);
      engine.positionCtl.add(const Duration(seconds: 10));
      await player.previous();
      expect(player.track?.id, 'b');
      expect(engine.calls, contains('seek:0'));
    });

    test('next at the end without repeat does nothing', () async {
      await player.playFrom(_abc, 2);
      await player.next();
      expect(player.track?.id, 'c');
      expect(loaded(), ['c']);
    });

    test('deleting the current track stops and clears playback', () async {
      await player.playFrom(_abc, 1);

      await player.removeTrack('b');

      expect(player.track, isNull);
      expect(player.status, PlayerStatus.idle);
      expect(engine.calls, contains('stop'));
    });

    test('deleting an upcoming track removes it from the queue', () async {
      await player.playFrom(_abc, 0);

      await player.removeTrack('b');
      await player.next();

      expect(player.track?.id, 'c');
      expect(loaded(), ['a', 'c']);
    });

    test('shuffle carries over to a newly started queue', () async {
      player.toggleShuffle();
      await player.playFrom(_abc, 0);
      expect(player.shuffle, isTrue);
      expect(player.track?.id, 'a', reason: 'the tapped track plays first');
      await player.next();
      await player.next();
      expect(loaded()..sort(), ['a', 'b', 'c']);
    });

    test('tapping the playing track again pauses it', () async {
      await player.playFrom(_abc, 1);
      await player.playFrom(_abc, 1);
      expect(player.status, PlayerStatus.paused);
    });

    test('replaying after the end still advances next time', () async {
      await player.playFrom(_abc, 2);
      await finishTrack();
      expect(player.status, PlayerStatus.completed);
      await player.toggle();
      expect(player.status, PlayerStatus.playing);
      await finishTrack();
      expect(player.status, PlayerStatus.completed);
    });
  });

  test('the queue can be read and a queued track played', () async {
    expect(player.upcoming, isEmpty);
    await player.playFrom(_abc, 0);
    expect(player.upcoming.map((t) => t.id), ['b', 'c']);

    await player.skipTo(1);
    expect(player.track?.id, 'c');
    expect(player.status, PlayerStatus.playing);
    expect(player.upcoming, isEmpty);

    await player.skipTo(3);
    expect(player.track?.id, 'c', reason: 'out of range is ignored');
  });
}
