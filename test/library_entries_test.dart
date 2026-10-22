import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/library/application/library_entries.dart';
import 'package:rhythmo/features/library/data/track.dart';

Track cloud(String id, {String? title, String? fileName, int size = 100}) =>
    Track(
      id: id,
      title: title ?? id,
      contentType: 'audio/mpeg',
      sizeBytes: size,
      fileName: fileName,
    );

Track device(int id, {String? title, String? fileName, int size = 100}) =>
    Track(
      id: 'device:$id',
      title: title ?? 'Device $id',
      contentType: 'audio/mpeg',
      sizeBytes: size,
      fileName: fileName,
      sourceUri: Uri.parse('content://media/external/audio/media/$id'),
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
    expect(
      entry.track.sourceUri,
      Uri.parse('content://media/external/audio/media/1'),
    );
    expect(locationOf(entry.track), TrackLocation.synced);
  });

  for (final name in ['آهنگ من', 'My Song', 'اجرای زنده 🎵']) {
    test('original display filename $name merges despite different titles', () {
      final server = cloud('uploaded', title: name, fileName: '$name.mp3');
      final local = device(1, title: 'Embedded title', fileName: '$name.MP3');

      // Both immediately after upload and on subsequent library refreshes.
      for (var refresh = 0; refresh < 2; refresh++) {
        final entries = mergeLibrary([server], [local]);
        expect(entries, hasLength(1));
        expect(entries.single.location, TrackLocation.synced);
        expect(entries.single.track.id, server.id);
        expect(entries.single.track.sourceUri, local.sourceUri);
      }
    });
  }

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

    expect(
      [for (final e in entries) (e.track.id, e.location)],
      [
        ('t1', TrackLocation.server),
        ('t2', TrackLocation.server),
        ('device:1', TrackLocation.device),
        ('device:2', TrackLocation.device),
      ],
    );
  });

  test('each server copy matches at most one device file', () {
    final entries = mergeLibrary(
      [cloud('t1', title: 'Song')],
      [device(1, title: 'Song'), device(2, title: 'Song')],
    );

    expect(
      [for (final e in entries) (e.track.id, e.location)],
      [('t1', TrackLocation.synced), ('device:2', TrackLocation.device)],
    );
  });

  test('a synced track keeps the server metadata version for editing', () {
    const edited = Track(
      id: 't1',
      title: 'Song',
      contentType: 'audio/mpeg',
      sizeBytes: 100,
      version: 4,
    );

    final synced = mergeLibrary([edited], [device(1, title: 'Song')]);

    expect(synced.single.track.version, 4);
  });

  test('locationOf tells device, server and synced tracks apart', () {
    expect(locationOf(cloud('t1')), TrackLocation.server);
    expect(locationOf(device(1)), TrackLocation.device);
    expect(
      locationOf(cloud('t1').withDeviceCopy(Uri.parse('content://x'))),
      TrackLocation.synced,
    );
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
}
