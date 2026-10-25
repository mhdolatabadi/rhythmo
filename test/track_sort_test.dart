import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/library/application/track_sort.dart';
import 'package:rhythmo/features/library/data/track.dart';

Track track(String id, String title, [String? artist]) => Track(
    id: id,
    title: title,
    artist: artist,
    contentType: 'audio/mpeg',
    sizeBytes: 1);

void main() {
  final library = [
    track('1', 'zebra', 'Beta'),
    track('2', 'Apple'),
    track('3', 'banana', 'alpha'),
    track('4', 'apple', 'Beta'),
  ];

  List<String> ids(List<Track> tracks) => [for (final t in tracks) t.id];

  test('recent keeps the library order when dates are unknown', () {
    expect(ids(sortTracks(library, TrackSort.recent)), ['1', '2', '3', '4']);
  });

  test('oldest reverses addition order without changing the library', () {
    expect(ids(sortTracks(library, TrackSort.oldest)), ['4', '3', '2', '1']);
    expect(ids(library), ['1', '2', '3', '4']);
  });

  test('title ignores case and keeps ties in library order', () {
    expect(ids(sortTracks(library, TrackSort.title)), ['2', '4', '3', '1']);
  });

  test('artist groups by artist, then title; unknown artists go last', () {
    expect(ids(sortTracks(library, TrackSort.artist)), ['3', '4', '1', '2']);
  });

  test('sorting does not change the list it was given', () {
    sortTracks(library, TrackSort.title);
    expect(ids(library), ['1', '2', '3', '4']);
  });

  group('by date', () {
    Track dated(String id, int day, {bool local = false}) => Track(
        id: id,
        title: id,
        contentType: 'audio/mpeg',
        sizeBytes: 1,
        sourceUri: local ? Uri.parse('content://media/$id') : null,
        addedAt: day < 0 ? null : DateTime(2026, 10, day));

    // As the unified library lists them: server tracks, then device ones.
    final mixed = [
      dated('server-new', 20),
      dated('server-old', 2),
      dated('undated', -1),
      dated('device-newest', 24, local: true),
      dated('device-mid', 10, local: true),
    ];

    test('recent interleaves server and device tracks by date', () {
      expect(ids(sortTracks(mixed, TrackSort.recent)), [
        'device-newest',
        'server-new',
        'device-mid',
        'server-old',
        'undated'
      ]);
    });

    test('oldest interleaves them the other way', () {
      expect(ids(sortTracks(mixed, TrackSort.oldest)), [
        'server-old',
        'device-mid',
        'server-new',
        'device-newest',
        'undated'
      ]);
    });

    test('title and artist ignore where a track is kept', () {
      expect(ids(sortTracks(mixed, TrackSort.title)), [
        'device-mid',
        'device-newest',
        'server-new',
        'server-old',
        'undated',
      ]);
    });
  });
}
