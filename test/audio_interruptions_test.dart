import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/audio_interruptions.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi;

const _a = Track(id: 'a', title: 'A', contentType: 'audio/mpeg', sizeBytes: 1);

AudioInterruptionEvent _begin(AudioInterruptionType type) =>
    AudioInterruptionEvent(true, type);
AudioInterruptionEvent _end(AudioInterruptionType type) =>
    AudioInterruptionEvent(false, type);

void main() {
  late FakeAudioEngine engine;
  late PlayerController player;
  late StreamController<AudioInterruptionEvent> events;
  var calling = false;

  AudioInterruptions interruptions({bool android = true}) => AudioInterruptions(
        events: events.stream,
        inCall: android ? () async => calling : null,
      )..attach(player);

  setUp(() {
    engine = FakeAudioEngine();
    player = PlayerController(
        api: FakeTracksApi(), engine: engine, token: () => 'tok');
    events = StreamController<AudioInterruptionEvent>(sync: true);
    calling = false;
  });

  test('a call that borrows the speaker pauses and then resumes', () async {
    interruptions();
    await player.play(_a);

    events.add(_begin(AudioInterruptionType.pause));
    await Future<void>.delayed(Duration.zero);
    expect(player.status, PlayerStatus.paused);

    events.add(_end(AudioInterruptionType.pause));
    expect(player.status, PlayerStatus.playing);
  });

  test('stays paused when the listener had paused already', () async {
    interruptions();
    await player.play(_a);
    await player.pause();

    events.add(_begin(AudioInterruptionType.pause));
    events.add(_end(AudioInterruptionType.pause));
    expect(player.status, PlayerStatus.paused);
  });

  test('resumes after a call that took audio focus for good', () {
    fakeAsync((async) {
      interruptions();
      player.play(_a);
      async.flushMicrotasks();

      events.add(_begin(AudioInterruptionType.unknown));
      async.flushMicrotasks();
      expect(player.status, PlayerStatus.paused);

      calling = true;
      async.elapse(const Duration(minutes: 2));
      expect(player.status, PlayerStatus.paused);

      calling = false;
      async.elapse(const Duration(seconds: 2));
      expect(player.status, PlayerStatus.playing);
    });
  });

  test('another app taking over for good leaves the music paused', () {
    fakeAsync((async) {
      interruptions();
      player.play(_a);
      async.flushMicrotasks();

      events.add(_begin(AudioInterruptionType.unknown));
      async.elapse(const Duration(seconds: 10));
      calling = true;
      async.elapse(const Duration(seconds: 2));
      calling = false;
      async.elapse(const Duration(seconds: 2));
      expect(player.status, PlayerStatus.paused);
    });
  });

  test('playing by hand during the call cancels the resume', () {
    fakeAsync((async) {
      interruptions();
      player.play(_a);
      async.flushMicrotasks();

      events.add(_begin(AudioInterruptionType.unknown));
      calling = true;
      async.elapse(const Duration(seconds: 2));
      player.resume();
      player.pause();
      async.flushMicrotasks();

      calling = false;
      async.elapse(const Duration(seconds: 2));
      expect(player.status, PlayerStatus.paused);
    });
  });

  test('iOS resumes only when the system says to', () async {
    interruptions(android: false);
    await player.play(_a);

    events.add(_begin(AudioInterruptionType.unknown));
    await Future<void>.delayed(Duration.zero);
    events.add(_end(AudioInterruptionType.unknown));
    expect(player.status, PlayerStatus.paused);

    await player.resume();
    events.add(_begin(AudioInterruptionType.unknown));
    await Future<void>.delayed(Duration.zero);
    events.add(_end(AudioInterruptionType.pause));
    expect(player.status, PlayerStatus.playing);
  });

  group('#237', () {
    late StreamController<void> noisy;

    AudioInterruptions withNoisy() {
      noisy = StreamController<void>(sync: true);
      return AudioInterruptions(
          events: events.stream, becomingNoisy: noisy.stream)
        ..attach(player);
    }

    test('unplugging headphones pauses and does not resume', () async {
      withNoisy();
      await player.play(_a);

      noisy.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(player.status, PlayerStatus.paused);

      // A call ending later must not start the music on the speaker.
      events.add(_begin(AudioInterruptionType.pause));
      events.add(_end(AudioInterruptionType.pause));
      expect(player.status, PlayerStatus.paused);
    });

    test('a notification turns the music down and back up', () async {
      withNoisy();
      await player.play(_a);

      events.add(_begin(AudioInterruptionType.duck));
      await Future<void>.delayed(Duration.zero);
      expect(player.status, PlayerStatus.playing);
      expect(player.ducked, isTrue);
      expect(engine.volumes.last, closeTo(duckedVolume, 1e-9));

      events.add(_end(AudioInterruptionType.duck));
      await Future<void>.delayed(Duration.zero);
      expect(player.ducked, isFalse);
      expect(engine.volumes.last, 1);
    });

    test('ducking keeps the listener\'s own volume', () async {
      withNoisy();
      await player.play(_a);
      await player.setVolume(0.5);

      events.add(_begin(AudioInterruptionType.duck));
      await Future<void>.delayed(Duration.zero);
      expect(engine.volumes.last, closeTo(0.5 * duckedVolume, 1e-9));
      events.add(_end(AudioInterruptionType.duck));
      await Future<void>.delayed(Duration.zero);
      expect(engine.volumes.last, closeTo(0.5, 1e-9));
    });
  });
}
