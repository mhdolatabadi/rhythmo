import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/last_playback.dart';
import 'package:rhythmo/features/player/application/play_queue.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi;

const _a = Track(
  id: 'a',
  title: 'A',
  artist: 'Artist',
  contentType: 'audio/mpeg',
  sizeBytes: 1,
  replayGain: ReplayGain(trackGainDb: -3),
);
const _b = Track(id: 'b', title: 'B', contentType: 'audio/mpeg', sizeBytes: 1);
const _c = Track(id: 'c', title: 'C', contentType: 'audio/mpeg', sizeBytes: 1);

void main() {
  late FakeTracksApi api;
  late FakeAudioEngine engine;
  late MemoryLastPlaybackStore store;
  String? token;

  setUp(() {
    api = FakeTracksApi();
    engine = FakeAudioEngine();
    store = MemoryLastPlaybackStore();
    token = 'tok';
  });

  PlayerController controller() => PlayerController(
        api: api,
        engine: engine,
        token: () => token,
        lastPlaybackStore: store,
      );

  /// Lets the queued store writes finish.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('a snapshot survives a JSON round trip', () {
    const saved = LastPlayback(
      track: _a,
      upcoming: [_b, _c],
      position: Duration(seconds: 42),
      duration: Duration(minutes: 3),
      shuffle: true,
      repeat: QueueRepeat.all,
    );
    final read = LastPlayback.fromJson(jsonDecode(jsonEncode(saved.toJson())))!;
    expect(read.track.id, 'a');
    expect(read.track.artist, 'Artist');
    expect(read.track.replayGain?.trackGainDb, -3);
    expect(read.upcoming.map((t) => t.id), ['b', 'c']);
    expect(read.position, const Duration(seconds: 42));
    expect(read.duration, const Duration(minutes: 3));
    expect(read.shuffle, isTrue);
    expect(read.repeat, QueueRepeat.all);
  });

  test('unreadable snapshots and browser-only files are dropped', () {
    expect(LastPlayback.fromJson('nope'), isNull);
    expect(
        LastPlayback.fromJson({
          'track': {'id': 'a'}
        }),
        isNull);
    final blob = Track(
      id: 'device:x',
      title: 'X',
      contentType: 'audio/mpeg',
      sizeBytes: 1,
      sourceUri: Uri.parse('blob:https://rhythmo.ir/123'),
    );
    expect(
      LastPlayback.fromJson(LastPlayback(track: blob).toJson()),
      isNull,
    );
  });

  test('the playing track and position are shown again after a restart',
      () async {
    final player = controller();
    await player.playFrom([_a, _b, _c], 0);
    engine.positionCtl.add(const Duration(seconds: 50));
    await player.pause();
    player.dispose();
    await settle();

    engine = FakeAudioEngine();
    final next = controller();
    await next.restoreLastPlayback();
    expect(next.track?.id, 'a');
    expect(next.restored, isTrue);
    expect(next.position, const Duration(seconds: 50));
    expect(next.duration, const Duration(minutes: 3));
    expect(next.status, PlayerStatus.idle);
    expect(next.upcoming.map((t) => t.id), ['b', 'c']);
    // Nothing loads until the listener asks.
    expect(engine.loads, isEmpty);

    await next.toggle();
    expect(engine.loads.single.$1, 'a');
    expect(engine.loads.single.$3, const Duration(seconds: 50));
    expect(engine.calls, contains('play'));
    expect(next.restored, isFalse);
    next.dispose();
  });

  test('seeking a restored track moves where it continues from', () async {
    store.playback = const LastPlayback(
      track: _a,
      position: Duration(seconds: 10),
      duration: Duration(minutes: 3),
    );
    final player = controller();
    await player.restoreLastPlayback();
    await player.seek(const Duration(seconds: 90));
    expect(engine.calls, isEmpty);
    await settle();
    expect(store.playback?.position, const Duration(seconds: 90));

    await player.resume();
    expect(engine.loads.single.$3, const Duration(seconds: 90));
    player.dispose();
  });

  test('tapping the restored track in a list continues it', () async {
    store.playback =
        const LastPlayback(track: _b, position: Duration(seconds: 20));
    final player = controller();
    await player.restoreLastPlayback();
    await player.playFrom([_a, _b, _c], 1);
    expect(engine.loads.single,
        ('b', engine.loads.single.$2, const Duration(seconds: 20)));
    expect(player.upcoming.map((t) => t.id), ['c']);
    player.dispose();
  });

  test('next on a restored track plays the queued one from its start',
      () async {
    store.playback = const LastPlayback(
      track: _a,
      upcoming: [_b],
      position: Duration(seconds: 20),
    );
    final player = controller();
    await player.restoreLastPlayback();
    await player.next();
    expect(engine.loads.single.$1, 'b');
    expect(engine.loads.single.$3, Duration.zero);
    player.dispose();
  });

  test('stopping keeps the snapshot; forgetting clears it', () async {
    final player = controller();
    await player.play(_a);
    await player.stop();
    await settle();
    expect(store.playback?.track.id, 'a');

    await player.play(_b);
    await player.stop(forget: true);
    await settle();
    expect(store.playback, isNull);
    player.dispose();
  });

  test('something already playing is not replaced by the restore', () async {
    store.playback = const LastPlayback(track: _a);
    final player = controller();
    await player.play(_b);
    await player.restoreLastPlayback();
    expect(player.track?.id, 'b');
    expect(player.restored, isFalse);
    player.dispose();
  });

  test('a signed-out listener cannot continue an account track', () async {
    store.playback = const LastPlayback(track: _a);
    token = null;
    final player = controller();
    await player.restoreLastPlayback();
    await player.resume();
    expect(engine.loads, isEmpty);
    expect(player.track, isNull);
    await settle();
    expect(store.playback, isNull);
    player.dispose();
  });
}
