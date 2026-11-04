import 'dart:math';

import 'package:rhythmo/features/library/data/track.dart';

enum QueueRepeat { off, all, one }

/// The order tracks play in. Pure logic with an injectable [Random], so its
/// behaviour is deterministic in tests.
class PlayQueue {
  PlayQueue(List<Track> tracks, {int start = 0, Random? random})
      : assert(tracks.isNotEmpty),
        _tracks = List.unmodifiable(tracks),
        _random = random ?? Random(),
        _order = List.generate(tracks.length, (i) => i),
        _position = start.clamp(0, tracks.length - 1);

  /// Creates a queue whose first track and remaining order are randomized.
  factory PlayQueue.shuffled(List<Track> tracks, {Random? random}) {
    final queue = PlayQueue(tracks, random: random);
    final order = List.generate(tracks.length, (index) => index)
      ..shuffle(queue._random);
    queue
      .._order = order
      .._position = 0
      .._shuffled = true;
    return queue;
  }

  List<Track> _tracks;
  final Random _random;

  /// Indexes into [_tracks] in play order; [_position] points into it.
  List<int> _order;
  int _position;
  bool _shuffled = false;
  QueueRepeat repeat = QueueRepeat.off;

  Track get current => _tracks[_order[_position]];
  bool get shuffled => _shuffled;

  /// Tracks in the order they will play.
  List<Track> get upcoming =>
      [for (final i in _order.skip(_position + 1)) _tracks[i]];

  /// Jumps to the upcoming track at [index] (0 is the next one), skipping
  /// those before it, and returns it.
  Track skipTo(int index) {
    RangeError.checkValidIndex(index, upcoming, 'index');
    _position += index + 1;
    return current;
  }

  /// Shuffles everything except the current track, which keeps playing
  /// and becomes the first of the new order. Turning shuffle off returns to
  /// library order at the current track.
  set shuffled(bool value) {
    if (value == _shuffled) return;
    final currentIndex = _order[_position];
    if (value) {
      final rest = [
        for (var i = 0; i < _tracks.length; i++)
          if (i != currentIndex) i
      ]..shuffle(_random);
      _order = [currentIndex, ...rest];
      _position = 0;
    } else {
      _order = List.generate(_tracks.length, (i) => i);
      _position = currentIndex;
    }
    _shuffled = value;
  }

  /// The track after the current one, or null at the end of the queue.
  ///
  /// [auto] is true when the current track finished by itself: only then
  /// does [QueueRepeat.one] replay it. A user pressing "next" always moves on.
  Track? next({bool auto = false}) {
    if (auto && repeat == QueueRepeat.one) return current;
    if (_position < _order.length - 1) {
      _position++;
      return current;
    }
    if (repeat == QueueRepeat.off) return null;
    _position = 0;
    return current;
  }

  /// What [next] would return, without moving the queue.
  Track? peekNext({bool auto = false}) {
    if (auto && repeat == QueueRepeat.one) return current;
    if (_position < _order.length - 1) return _tracks[_order[_position + 1]];
    if (repeat == QueueRepeat.off) return null;
    return _tracks[_order.first];
  }

  /// The track before the current one; at the start it wraps only when
  /// repeating the whole queue, otherwise it stays on the first track.
  /// Removes a track while preserving the current position and play order.
  /// Returns false when [id] is the current track, which the player must stop.
  bool remove(String id) {
    final removedIndex = _tracks.indexWhere((track) => track.id == id);
    if (removedIndex < 0) return true;
    if (_order[_position] == removedIndex) return false;

    final removedOrderPosition = _order.indexOf(removedIndex);
    _tracks = List.unmodifiable([
      for (var i = 0; i < _tracks.length; i++)
        if (i != removedIndex) _tracks[i],
    ]);
    _order = [
      for (final index in _order)
        if (index != removedIndex) index > removedIndex ? index - 1 : index,
    ];
    if (removedOrderPosition < _position) _position--;
    return true;
  }

  /// Puts [track] right after the current one ([next] true) or at the end
  /// of the queue. A track already waiting moves rather than repeats; the
  /// current track is never queued again. Returns false when it was the
  /// current one and nothing changed.
  bool enqueue(Track track, {required bool next}) {
    final existing = _tracks.indexWhere((queued) => queued.id == track.id);
    if (existing >= 0 && _order[_position] == existing) return false;
    if (existing >= 0) remove(track.id);
    _tracks = List.unmodifiable([..._tracks, track]);
    final added = _tracks.length - 1;
    _order = [..._order];
    if (next) {
      _order.insert(_position + 1, added);
    } else {
      _order.add(added);
    }
    return true;
  }

  /// Swaps in fresh metadata for the track with [track]'s ID, keeping the
  /// position and play order. Returns whether the track was queued.
  bool replace(Track track) {
    final index = _tracks.indexWhere((queued) => queued.id == track.id);
    if (index < 0) return false;
    _tracks = List.unmodifiable(
        [..._tracks]..[index] = track.keepingContextOf(_tracks[index]));
    return true;
  }

  Track previous() {
    if (_position > 0) {
      _position--;
    } else if (repeat == QueueRepeat.all) {
      _position = _order.length - 1;
    }
    return current;
  }
}
