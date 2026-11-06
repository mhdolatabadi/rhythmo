import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/library/application/track_groups.dart';
import 'package:rhythmo/features/library/data/track.dart';

Track track(String id, {String? artist, String? album}) => Track(
    id: id,
    title: 'song $id',
    artist: artist,
    album: album,
    contentType: 'audio/mpeg',
    sizeBytes: 1);

void main() {
  final tracks = [
    track('1', artist: 'Queen', album: 'A Night at the Opera'),
    track('2', artist: 'queen ', album: 'a night  at the opera'),
    track('3', artist: 'فرهاد', album: 'بوی عیدی'),
    track('4'),
  ];

  test('albums merge spellings, keep the first and list unknown last', () {
    final albums = groupByAlbum(tracks);
    expect([for (final a in albums) a.name],
        ['A Night at the Opera', 'بوی عیدی', unknownGroupName]);
    expect([for (final t in albums.first.tracks) t.id], ['1', '2']);
    expect(albums.first.artist, 'Queen');
    expect(albums.last.unknown, isTrue);
  });

  test('artists group the same way and carry no artist line', () {
    final artists = groupByArtist(tracks);
    expect([for (final a in artists) a.name],
        ['Queen', 'فرهاد', unknownGroupName]);
    expect(artists.first.tracks, hasLength(2));
    expect(artists.first.artist, isNull);
  });

  test('no tracks, no groups', () {
    expect(groupByAlbum(const []), isEmpty);
  });

  test('lectures group by topic in session order', () {
    Track lecture(String id, String topic, int? session) => Track(
        id: id,
        title: 'جلسه $id',
        album: topic,
        trackNumber: session,
        source: 'bale_archive',
        contentType: 'audio/mpeg',
        sizeBytes: 1);
    final lectures = [
      lecture('c', 'فاطمیه', 3),
      lecture('a', 'فاطمیه', 1),
      lecture('x', 'ولایت', null),
      lecture('b', 'فاطمیه', 2),
    ];
    expect(lectures.every(isLecture), isTrue);
    expect(isLecture(track('1')), isFalse);
    final topics = lectureTopics(lectures);
    expect([for (final t in topics) t.name], ['فاطمیه', 'ولایت']);
    expect([for (final t in topics.first.tracks) t.id], ['a', 'b', 'c']);
  });
}
