import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/presentation/now_playing_screen.dart';

Track _track({String? artist, String? album, Uri? sourceUri}) => Track(
    id: 'x',
    title: 'Song',
    artist: artist,
    album: album,
    sourceUri: sourceUri,
    contentType: 'audio/mpeg',
    sizeBytes: 1);

void main() {
  test('the artist line never names where the song is stored', () {
    expect(trackSubtitle(_track(artist: ' Artist ')), 'Artist');
    expect(trackSubtitle(_track(artist: ' ', album: 'Album')), 'Album');
    expect(trackSubtitle(_track()), unknownArtist);
    expect(trackSubtitle(_track(sourceUri: Uri.file('/music/a.mp3'))),
        unknownArtist);
  });
}
