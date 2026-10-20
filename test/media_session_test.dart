import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/media_session.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/data/audio_engine.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi;

final _artwork = Uri.file('/data/rhythmo_notification_artwork.png');

const _tracks = [
  Track(
      id: 'a',
      title: 'First',
      artist: 'Artist',
      album: 'Album',
      contentType: 'audio/mpeg',
      sizeBytes: 1),
  Track(id: 'b', title: 'Second', contentType: 'audio/mpeg', sizeBytes: 1),
];

void main() {
  late FakeAudioEngine engine;
  late PlayerController player;
  late RhythmoAudioHandler handler;

  setUp(() {
    engine = FakeAudioEngine();
    player = PlayerController(
        api: FakeTracksApi(), engine: engine, token: () => 'tok');
    handler = RhythmoAudioHandler(artwork: _artwork)..attach(player);
  });

  test('embedded cover wins; stale results cannot overwrite the next song',
      () async {
    final first = Completer<Uri?>();
    final second = Uri.parse('https://example.com/second.jpg');
    handler.attach(player,
        artworkFor: (track) async => track.id == 'a' ? first.future : second);
    await player.playFrom(_tracks, 0);
    await player.playFrom(_tracks, 1);
    await pumpEventQueue();
    expect(handler.mediaItem.value?.artUri, second);
    first.complete(Uri.parse('https://example.com/first.jpg'));
    await pumpEventQueue();
    expect(handler.mediaItem.value?.id, 'b');
    expect(handler.mediaItem.value?.artUri, second);
  });

  test('the system shows the current track and its duration', () async {
    await player.playFrom(_tracks, 0);

    final item = handler.mediaItem.value!;
    expect(item.id, 'a');
    expect(item.title, 'First');
    expect(item.artist, 'Artist');
    expect(item.album, 'Album');
    expect(item.duration, const Duration(minutes: 3));
    expect(item.artUri, _artwork);
    expect(item.displayTitle, 'First');
    expect(item.displaySubtitle, 'Artist');
    expect(item.displayDescription, 'پخش از کتابخانهٔ ریتمو');
    expect(item.extras?['location'], 'server');
  });

  test('playback state mirrors the player with prev/pause/next controls',
      () async {
    await player.playFrom(_tracks, 0);

    var state = handler.playbackState.value;
    expect(state.playing, isTrue);
    expect(state.processingState, AudioProcessingState.ready);
    expect(state.controls, [
      MediaControl.skipToPrevious,
      MediaControl.pause,
      MediaControl.skipToNext,
    ]);
    expect(state.systemActions, contains(MediaAction.seek));

    await player.pause();
    state = handler.playbackState.value;
    expect(state.playing, isFalse);
    expect(state.controls[1], MediaControl.play);
  });

  test('system control opt-out hides controls and blocks remote commands',
      () async {
    await player.playFrom(_tracks, 0);
    await player.setSystemPreferences(systemControls: false);
    expect(handler.playbackState.value.controls, isEmpty);
    expect(handler.playbackState.value.systemActions, isEmpty);
    await handler.skipToNext();
    await handler.pause();
    expect(player.track?.id, 'a');
    expect(player.status, PlayerStatus.playing);
    await player.pause();
    await handler.play();
    expect(player.status, PlayerStatus.paused);
    await player.resume();
    expect(player.status, PlayerStatus.playing);
    await player.setSystemPreferences(systemControls: true);
    expect(handler.playbackState.value.controls, isNotEmpty);
  });

  test('external start opt-out blocks resume but keeps pause available',
      () async {
    await player.playFrom(_tracks, 0);
    await player.setSystemPreferences(externalPlayback: false);
    await handler.pause();
    await handler.play();
    await handler.skipToNext();
    await handler.skipToPrevious();
    expect(player.track?.id, 'a');
    expect(player.status, PlayerStatus.paused);
    await player.resume();
    expect(player.status, PlayerStatus.playing);
  });

  test('lock-screen buttons drive the player', () async {
    await player.playFrom(_tracks, 0);

    await handler.pause();
    expect(player.status, PlayerStatus.paused);
    await handler.play();
    expect(player.status, PlayerStatus.playing);

    await handler.skipToNext();
    expect(player.track?.id, 'b');
    expect(handler.mediaItem.value?.title, 'Second');
    expect(handler.mediaItem.value?.artist, 'روی سرور');
    expect(handler.mediaItem.value?.displaySubtitle, 'روی سرور');

    await handler.skipToPrevious();
    expect(player.track?.id, 'a');

    await handler.seek(const Duration(seconds: 42));
    expect(engine.calls, contains('seek:42'));
    expect(handler.playbackState.value.updatePosition,
        const Duration(seconds: 42));
  });

  test('ordinary position ticks do not flood the system with updates',
      () async {
    await player.playFrom(_tracks, 0);
    final updates = <PlaybackState>[];
    final subscription = handler.playbackState.skip(1).listen(updates.add);

    for (var ms = 200; ms <= 1000; ms += 200) {
      engine.positionCtl.add(Duration(milliseconds: ms));
    }
    await pumpEventQueue();

    expect(updates, isEmpty);
    await subscription.cancel();
  });

  test('stop from the system clears the track', () async {
    await player.playFrom(_tracks, 0);
    await handler.stop();
    expect(player.track, isNull);
    expect(handler.mediaItem.value, isNull);
  });

  test('titles are cleaned and fall back to the filename', () {
    String title(String value, {String? fileName}) =>
        RhythmoAudioHandler.notificationTitle(Track(
            id: 'x',
            title: value,
            fileName: fileName,
            contentType: 'audio/mpeg',
            sizeBytes: 1));

    expect(title('  سلام\n  Hello  '), 'سلام Hello');
    expect(title(' ', fileName: 'My Song.final.mp3'), 'My Song.final');
    expect(title('', fileName: '.mp3'), '.mp3');
    expect(title(''), untitledTrack);
  });

  test('a track without artist or album shows where it plays from', () async {
    const local = Track(
        id: 'l',
        title: 'Local',
        artist: '  ',
        album: '',
        contentType: 'audio/mpeg',
        sizeBytes: 1);
    await player.playFrom([local], 0);

    final item = handler.mediaItem.value!;
    expect(item.artist, 'روی سرور');
    expect(item.album, 'ریتمو');
    expect(item.artUri, _artwork, reason: 'the rhythmo logo is the fallback');
  });

  test(
      'without resolved artwork the item has no image rather than a '
      'URI the system cannot load', () async {
    final bare = RhythmoAudioHandler()..attach(player);
    await player.playFrom(_tracks, 0);
    expect(bare.mediaItem.value?.artUri, isNull);
  });

  test('loading, buffering, completed and error map to system states',
      () async {
    final states = <AudioProcessingState>[];
    final subscription = handler.playbackState
        .map((state) => state.processingState)
        .distinct()
        .listen(states.add);

    await player.playFrom(_tracks, 1);
    engine.stateCtl.add(EngineState.buffering);
    engine.stateCtl.add(EngineState.ready);
    engine.playingCtl.add(false);
    engine.stateCtl.add(EngineState.completed);
    await pumpEventQueue();
    expect(player.status, PlayerStatus.completed);
    expect(handler.playbackState.value.playing, isFalse);
    expect(handler.playbackState.value.controls[1], MediaControl.play);

    engine.loadError = Exception('unreachable');
    await player.playFrom(_tracks, 0);
    await pumpEventQueue();
    await subscription.cancel();

    expect(states, [
      AudioProcessingState.idle,
      AudioProcessingState.loading,
      AudioProcessingState.ready,
      AudioProcessingState.buffering,
      AudioProcessingState.ready,
      AudioProcessingState.completed,
      AudioProcessingState.loading,
      AudioProcessingState.error,
    ]);
    expect(handler.playbackState.value.errorMessage, isNotEmpty);
  });

  test('the item is published once per track, not on every tick', () async {
    final items = <MediaItem?>[];
    final subscription = handler.mediaItem.skip(1).listen(items.add);

    await player.playFrom(_tracks, 0);
    for (var s = 1; s <= 5; s++) {
      engine.positionCtl.add(Duration(seconds: s));
    }
    engine.playingCtl.add(false);
    engine.playingCtl.add(true);
    await pumpEventQueue();
    await subscription.cancel();

    // Once for the new track, once when its duration became known.
    expect(items.map((item) => item?.duration), [
      null,
      const Duration(minutes: 3),
    ]);
  });
}
