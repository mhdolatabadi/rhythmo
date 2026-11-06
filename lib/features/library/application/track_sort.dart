import 'package:rhythmo/features/library/data/track.dart';

/// How the track list is ordered.
enum TrackSort {
  /// Most recently added first, whether to the account or to the device.
  recent('تاریخ افزودن؛ جدیدترین اول'),
  oldest('تاریخ افزودن؛ قدیمی‌ترین اول'),
  title('نام آهنگ'),
  artist('خواننده'),

  /// Most liked first (#284); likes are counted on the listener's own
  /// tracks.
  mostLiked('پسندیده‌ترین'),

  /// Only tracks published to the store, most liked first.
  published('منتشرشده‌ها؛ پسندیده‌ترین اول');

  const TrackSort(this.label);

  /// The Persian name shown in the sort menu.
  final String label;
}

/// Returns [tracks] in [sort] order. Server and device tracks sort together
/// by the same key. Titles and artists compare without case; tracks without
/// an artist, or without a date when sorting by date, go last; ties keep
/// their library order, reversed for [TrackSort.oldest].
List<Track> sortTracks(List<Track> tracks, TrackSort sort) {
  if (sort == TrackSort.recent || sort == TrackSort.oldest) {
    final newestFirst = sort == TrackSort.recent;
    final indexed = [for (var i = 0; i < tracks.length; i++) (i, tracks[i])];
    indexed.sort((a, b) {
      final atA = a.$2.addedAt, atB = b.$2.addedAt;
      if ((atA == null) != (atB == null)) return atA == null ? 1 : -1;
      final order = atA == null
          ? 0
          : newestFirst
              ? atB!.compareTo(atA)
              : atA.compareTo(atB!);
      if (order != 0) return order;
      return newestFirst ? a.$1.compareTo(b.$1) : b.$1.compareTo(a.$1);
    });
    return [for (final (_, track) in indexed) track];
  }
  if (sort == TrackSort.mostLiked || sort == TrackSort.published) {
    final kept = [
      for (var i = 0; i < tracks.length; i++)
        if (sort == TrackSort.mostLiked || tracks[i].published) (i, tracks[i]),
    ];
    kept.sort((a, b) {
      final order = b.$2.likeCount.compareTo(a.$2.likeCount);
      return order != 0 ? order : a.$1.compareTo(b.$1);
    });
    return [for (final (_, track) in kept) track];
  }
  String key(String? value) => value?.trim().toLowerCase() ?? '';
  final indexed = [for (var i = 0; i < tracks.length; i++) (i, tracks[i])];
  int byTitle((int, Track) a, (int, Track) b) =>
      key(a.$2.title).compareTo(key(b.$2.title));
  indexed.sort((a, b) {
    var order = 0;
    if (sort == TrackSort.artist) {
      final artistA = key(a.$2.artist), artistB = key(b.$2.artist);
      if (artistA.isEmpty != artistB.isEmpty) {
        return artistA.isEmpty ? 1 : -1;
      }
      order = artistA.compareTo(artistB);
    }
    if (order == 0) order = byTitle(a, b);
    return order != 0 ? order : a.$1.compareTo(b.$1);
  });
  return [for (final (_, track) in indexed) track];
}
