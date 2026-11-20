import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_configuration.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/android/home_widget.dart';
import 'package:rhythmo/features/player/android/media_tree.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi;

Track _track(String id,
        {String title = 'آهنگ', String? artist, String? album, String? file}) =>
    Track(
      id: id,
      title: title,
      artist: artist,
      album: album,
      contentType: 'audio/mpeg',
      sizeBytes: 1,
      fileName: file,
    );

void main() {
  final a = _track('a', title: 'باران', artist: 'شجریان', album: 'آسمان');
  final b = _track('b', title: 'شب', artist: 'شجریان', album: ' ');
  final c = _track('c', title: '', artist: '  ', album: 'آسمان', file: 'c.mp3');
  final playlist = Playlist(
    id: 'p1',
    name: 'سفر',
    trackCount: 2,
    tracks: [b, a],
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
  final tree = MediaTree(
      MediaLibrary(tracks: [a, b, c], recent: [c, a], playlists: [playlist]));

  group('MediaTree', () {
    test('root lists only what has something in it', () {
      expect(tree.children(MediaTree.root).map((i) => i.id), [
        MediaTree.shuffle,
        MediaTree.recent,
        MediaTree.playlists,
        MediaTree.albums,
        MediaTree.artists,
      ]);
      expect(MediaTree(const MediaLibrary()).children(MediaTree.root), isEmpty);
    });

    test('albums and artists skip blank names', () {
      expect(tree.children(MediaTree.albums).map((i) => i.id), ['album/آسمان']);
      expect(
          tree.children(MediaTree.artists).map((i) => i.id), ['artist/شجریان']);
      expect(tree.children('album/آسمان').map((i) => i.id),
          ['album/آسمان|a', 'album/آسمان|c']);
    });

    test('a nameless track falls back to its file name', () {
      final items = tree.children(MediaTree.recent);
      expect(items.first.title, 'c.mp3');
      expect(items.first.playable, isTrue);
    });

    test('a track plays in the order of its list', () {
      final queue = tree.queueFor('playlist/p1|a')!;
      expect(queue.tracks.map((t) => t.id), ['b', 'a']);
      expect(queue.index, 1);
      expect(queue.shuffle, isFalse);
    });

    test('shuffle plays the whole library shuffled', () {
      final queue = tree.queueFor(MediaTree.shuffle)!;
      expect(queue.tracks, hasLength(3));
      expect(queue.shuffle, isTrue);
    });

    test('unknown ids play and list nothing', () {
      expect(tree.queueFor('playlist/gone|a'), isNull);
      expect(tree.queueFor('recent|gone'), isNull);
      expect(tree.queueFor('nonsense'), isNull);
      expect(tree.children('nonsense'), isEmpty);
    });
  });

  group('HomeWidgetState', () {
    test('nothing playing is idle', () {
      expect(HomeWidgetState.of(null, PlayerStatus.idle), HomeWidgetState.idle);
    });

    test('playing and buffering both show pause', () {
      expect(HomeWidgetState.of(a, PlayerStatus.playing).playing, isTrue);
      expect(HomeWidgetState.of(a, PlayerStatus.buffering).playing, isTrue);
      expect(HomeWidgetState.of(a, PlayerStatus.paused).playing, isFalse);
    });

    test('only a file cover reaches the widget', () {
      final state = HomeWidgetState.of(a, PlayerStatus.paused,
          cover: Uri.file('/data/cover.jpg'));
      expect(state.coverPath, '/data/cover.jpg');
      expect(
          HomeWidgetState.of(a, PlayerStatus.paused,
                  cover: Uri.parse('https://x/cover.jpg'))
              .coverPath,
          isNull);
    });

    test('blank fields fall back', () {
      final state = HomeWidgetState.of(c, PlayerStatus.paused);
      expect(state.title, 'c.mp3');
      expect(state.subtitle, 'آسمان');
      expect(state.toMap()['title'], 'c.mp3');
    });
  });

  group('HomeScreenWidget', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('sends the state once per change', () async {
      const channel = MethodChannel('test/widget');
      final sent = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        sent.add(call.arguments);
        return null;
      });
      final player = PlayerController(
          api: FakeTracksApi(), engine: FakeAudioEngine(), token: () => 'tok');
      final widget = HomeScreenWidget(channel: channel)..attach(player);
      await pumpEventQueue();
      await player.playFrom([a], 0);
      await pumpEventQueue();
      widget.attach(player);
      await pumpEventQueue();
      expect(sent.first, HomeWidgetState.idle.toMap());
      expect(sent.last, HomeWidgetState.of(a, player.status).toMap());
      expect(sent.toSet().length, sent.length);
      widget.detach();
      player.dispose();
    });
  });

  group('app shortcuts', () {
    test('a shortcut link is taken once', () {
      AppConfiguration.openLink(Uri.parse('rhythmo://shortcut/shuffle'));
      expect(AppConfiguration.takeShortcut(), AppShortcut.shuffle);
      expect(AppConfiguration.takeShortcut(), isNull);
      AppConfiguration.openLink(Uri.parse('rhythmo://shortcut/search'));
      expect(AppConfiguration.takeShortcut(), AppShortcut.search);
    });

    test('other links are not shortcuts', () {
      AppConfiguration.openLink(Uri.parse('https://rhythmo.ir/p/abc'));
      expect(AppConfiguration.takeShortcut(), isNull);
      AppConfiguration.openLink(Uri.parse('rhythmo://shortcut/delete'));
      expect(AppConfiguration.takeShortcut(), isNull);
    });
  });
}
