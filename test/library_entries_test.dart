import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/library/application/library_entries.dart';
import 'package:rhythmo/features/library/data/track.dart';

Track cloud(String id,
        {String? title, String? fileName, int size = 100, DateTime? at}) =>
    Track(
      id: id,
      title: title ?? id,
      contentType: 'audio/mpeg',
      sizeBytes: size,
      fileName: fileName,
      addedAt: at,
    );

Track device(int id,
        {String? title, String? fileName, int size = 100, DateTime? at}) =>
    Track(
      id: 'device:$id',
      title: title ?? 'Device $id',
      contentType: 'audio/mpeg',
      sizeBytes: size,
      fileName: fileName,
      sourceUri: Uri.parse('content://media/external/audio/media/$id'),
      addedAt: at,
    );

void main() {
  test('server and device copies of one file become one synced entry', () {
    final entries = mergeLibrary(
      [cloud('t1', title: 'Song', fileName: 'My_Song.mp3')],
      [device(1, title: 'Other title', fileName: 'My Song.MP3')],
    );

    expect(entries, hasLength(1));
    final entry = entries.single;
    expect(entry.location, TrackLocation.synced);
    // The cloud identity is kept, but the device file is played.
    expect(entry.track.id, 't1');
    expect(entry.track.title, 'Song');
    expect(entry.track.sourceUri,
        Uri.parse('content://media/external/audio/media/1'));
    expect(locationOf(entry.track), TrackLocation.synced);
  });

  test('a Persian filename matches by title when sizes are equal', () {
    final entries = mergeLibrary(
      [cloud('t1', title: 'آهنگ من', fileName: 'track.mp3')],
      [device(1, title: '  آهنگ   من ', fileName: 'آهنگ من.mp3')],
    );

    expect(entries.single.location, TrackLocation.synced);
  });

  test('different sizes or names stay separate rows', () {
    final entries = mergeLibrary(
      [
        cloud('t1', title: 'Song', fileName: 'Song.mp3', size: 100),
        cloud('t2', title: 'Other', fileName: 'Other.mp3'),
      ],
      [
        device(1, title: 'Song', fileName: 'Song.mp3', size: 101),
        device(2, title: 'Third', fileName: 'Third.mp3'),
      ],
    );

    expect([
      for (final e in entries) (e.track.id, e.location)
    ], [
      ('t1', TrackLocation.server),
      ('t2', TrackLocation.server),
      ('device:1', TrackLocation.device),
      ('device:2', TrackLocation.device),
    ]);
  });

  test('each server copy matches at most one device file', () {
    final entries = mergeLibrary(
      [cloud('t1', title: 'Song')],
      [device(1, title: 'Song'), device(2, title: 'Song')],
    );

    expect([
      for (final e in entries) (e.track.id, e.location)
    ], [
      ('t1', TrackLocation.synced),
      ('device:2', TrackLocation.device),
    ]);
  });

  test('a synced track keeps the server metadata version for editing', () {
    const edited = Track(
        id: 't1',
        title: 'Song',
        contentType: 'audio/mpeg',
        sizeBytes: 100,
        version: 4);

    final synced = mergeLibrary([edited], [device(1, title: 'Song')]);

    expect(synced.single.track.version, 4);
  });

  test('locationOf tells device, server and synced tracks apart', () {
    expect(locationOf(cloud('t1')), TrackLocation.server);
    expect(locationOf(device(1)), TrackLocation.device);
    expect(locationOf(cloud('t1').withDeviceCopy(Uri.parse('content://x'))),
        TrackLocation.synced);
  });

  test('safeFileName names files as the server does', () {
    // The same cases as server/internal/audio TestSafeFileName.
    for (final (input, want) in const [
      ('My Song.MP3', 'My_Song.mp3'),
      ('آهنگ من.mp3', 'track.mp3'),
      ('../../etc/passwd.mp3', 'passwd.mp3'),
      (r'C:\Music\a b.flac', 'a_b.flac'),
      ('', 'track'),
    ]) {
      expect(safeFileName(input), want, reason: input);
    }
  });

  group('recently added to device', () {
    final now = DateTime(2026, 10, 25);
    DateTime daysAgo(int days) => now.subtract(Duration(days: days));

    test('lists device files newest first, synced ones included', () {
      final entries = mergeLibrary(
        [
          cloud('server-only', size: 1, at: daysAgo(1)),
          cloud('synced', title: 'Synced', size: 2, at: daysAgo(40)),
        ],
        [
          device(1, size: 3, at: daysAgo(10)),
          device(2, title: 'Synced', size: 2, at: daysAgo(3)),
          device(3, size: 4, at: daysAgo(5)),
        ],
      );
      final recent = recentlyAddedToDevice(entries, now: now);
      expect(
          [for (final t in recent) t.id], ['synced', 'device:3', 'device:1']);
    });

    test('leaves out files older than the window or without a date', () {
      final entries = mergeLibrary([], [
        device(1, size: 1, at: daysAgo(31)),
        device(2, size: 2),
        device(3, size: 3, at: daysAgo(29)),
      ]);
      expect([for (final t in recentlyAddedToDevice(entries, now: now)) t.id],
          ['device:3']);
    });

    test('a synced track counts as added when its first copy was', () {
      final synced = mergeLibrary(
        [cloud('t1', title: 'Song', at: daysAgo(2))],
        [device(1, title: 'Song', at: daysAgo(9))],
      ).single.track;
      expect(synced.addedAt, daysAgo(9));
    });
  });
}
