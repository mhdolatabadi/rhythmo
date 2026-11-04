import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/play_queue.dart';

final _tracks = [
  for (final id in ['a', 'b', 'c', 'd', 'e'])
    Track(id: id, title: id, contentType: 'audio/mpeg', sizeBytes: 1),
];

List<String> _ids(Iterable<Track> tracks) => [for (final t in tracks) t.id];

void main() {
  test('plays in library order from the chosen track', () {
    final queue = PlayQueue(_tracks, start: 2);
    expect(queue.current.id, 'c');
    expect(_ids(queue.upcoming), ['d', 'e']);
    expect(queue.next()?.id, 'd');
    expect(queue.next()?.id, 'e');
    expect(queue.next(), isNull, reason: 'the end without repeat');
  });

  test('previous steps back and stays on the first track', () {
    final queue = PlayQueue(_tracks, start: 1);
    expect(queue.previous().id, 'a');
    expect(queue.previous().id, 'a');
  });

  test('repeat all wraps in both directions', () {
    final queue = PlayQueue(_tracks, start: 4)..repeat = QueueRepeat.all;
    expect(queue.next()?.id, 'a');
    expect(queue.previous().id, 'e');
  });

  test('repeat one replays only when a track ends by itself', () {
    final queue = PlayQueue(_tracks)..repeat = QueueRepeat.one;
    expect(queue.next(auto: true)?.id, 'a');
    expect(queue.next()?.id, 'b', reason: 'the user skipping still moves on');
  });

  test('shuffle is deterministic for a seed and keeps the current track', () {
    PlayQueue shuffledWith(int seed) =>
        PlayQueue(_tracks, start: 2, random: Random(seed))..shuffled = true;

    final first = shuffledWith(7);
    final second = shuffledWith(7);
    expect(first.current.id, 'c');
    expect(_ids(first.upcoming), _ids(second.upcoming));
    expect(_ids(first.upcoming)..sort(), ['a', 'b', 'd', 'e']);
    expect(_ids(first.upcoming), isNot(['a', 'b', 'd', 'e']),
        reason: 'seed 7 produces a real reorder');
  });

  test('every track plays exactly once through a shuffled queue', () {
    final queue = PlayQueue(_tracks, random: Random(1))..shuffled = true;
    final played = [queue.current.id];
    for (var t = queue.next(); t != null; t = queue.next()) {
      played.add(t.id);
    }
    expect(played..sort(), ['a', 'b', 'c', 'd', 'e']);
  });

  test('turning shuffle off returns to library order at the current track', () {
    final queue = PlayQueue(_tracks, random: Random(3))..shuffled = true;
    queue.next();
    final now = queue.current.id;

    queue.shuffled = false;

    expect(queue.current.id, now);
    expect(_ids(queue.upcoming),
        _ids(_tracks.skipWhile((t) => t.id != now).skip(1)));
  });

  test('shuffle-all randomizes the first track and contains each track once',
      () {
    PlayQueue shuffledWith(int seed) =>
        PlayQueue.shuffled(_tracks, random: Random(seed));
    final first = shuffledWith(11);
    final second = shuffledWith(11);
    final firstOrder = [first.current, ...first.upcoming];
    final secondOrder = [second.current, ...second.upcoming];
    expect(_ids(firstOrder), _ids(secondOrder));
    expect(_ids(firstOrder)..sort(), ['a', 'b', 'c', 'd', 'e']);
    expect(first.current.id, isNot('a'),
        reason: 'seed 11 randomizes the first track too');
    expect(first.shuffled, isTrue);
  });

  test('a single track queue', () {
    final queue = PlayQueue(_tracks.take(1).toList())..repeat = QueueRepeat.all;
    expect(queue.next()?.id, 'a');
    queue.shuffled = true;
    expect(queue.current.id, 'a');
  });

  test('skipping to a queued track continues from there', () {
    final queue = PlayQueue(_tracks, start: 1);
    expect(queue.skipTo(2).id, 'e');
    expect(queue.upcoming, isEmpty);
    expect(queue.previous().id, 'd');
    expect(() => queue.skipTo(5), throwsRangeError);
  });

  test('replace swaps in fresh metadata without moving the queue', () {
    final queue = PlayQueue(_tracks, start: 1);
    final renamed = Track(
        id: 'c', title: 'C renamed', contentType: 'audio/mpeg', sizeBytes: 1);

    expect(queue.replace(renamed), isTrue);
    expect(queue.current.id, 'b');
    expect(_ids(queue.upcoming), ['c', 'd', 'e']);
    expect(queue.upcoming.first.title, 'C renamed');
    expect(
        queue.replace(Track(
            id: 'zz', title: 'zz', contentType: 'audio/mpeg', sizeBytes: 1)),
        isFalse);
  });

  test('a song can play next or join the end, and moves rather than repeats',
      () {
    final queue = PlayQueue(_tracks.take(3).toList(), start: 0);
    final x =
        Track(id: 'x', title: 'x', contentType: 'audio/mpeg', sizeBytes: 1);
    expect(queue.enqueue(x, next: true), isTrue);
    expect(_ids(queue.upcoming), ['x', 'b', 'c']);
    // Already waiting: it moves to the end instead of playing twice.
    expect(queue.enqueue(x, next: false), isTrue);
    expect(_ids(queue.upcoming), ['b', 'c', 'x']);
    // The one playing now is never queued again.
    expect(queue.enqueue(_tracks.first, next: true), isFalse);
    expect(queue.current.id, 'a');
    expect(queue.next()?.id, 'b');
  });

  test('play next follows the current track while shuffled', () {
    final queue = PlayQueue(_tracks, random: Random(3))..shuffled = true;
    final current = queue.current.id;
    final x =
        Track(id: 'x', title: 'x', contentType: 'audio/mpeg', sizeBytes: 1);
    queue.enqueue(x, next: true);
    expect(queue.upcoming.first.id, 'x');
    expect(queue.current.id, current);
    expect(queue.upcoming, hasLength(_tracks.length));
  });
}
