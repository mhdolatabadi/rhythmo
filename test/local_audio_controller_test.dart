import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/library/application/local_audio_controller.dart';
import 'package:rhythmo/features/library/data/local_audio_library.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/library/data/track_metadata.dart';
import 'package:rhythmo/features/library/data/local_track_metadata_store.dart';
import 'package:rhythmo/features/library/data/local_audio_metadata_writer.dart';

class FakeLocalAudioLibrary implements LocalAudioLibrary {
  FakeLocalAudioLibrary(this.result, {this.supported = true});

  LocalAudioResult result;
  @override
  final bool supported;

  @override
  Future<LocalAudioResult> load() async => result;

  /// What deleting answers: true, false (declined) or an error to throw.
  Object deleteAnswer = true;
  final deleted = <Uri>[];

  @override
  Future<bool> delete(Track track) async {
    final answer = deleteAnswer;
    if (answer is! bool) throw answer;
    if (answer) {
      deleted.add(track.sourceUri!);
      result = LocalAudioResult(result.status, [
        for (final t in result.tracks)
          if (t.sourceUri != track.sourceUri) t,
      ]);
    }
    return answer;
  }
}

class FakeMetadataWriter implements LocalAudioMetadataWriter {
  Object? error;
  int writes = 0;
  @override
  Future<Map<String, dynamic>> read(Track track) async =>
      {'title': track.title};
  @override
  Future<int> write(Track track, TrackMetadataDraft draft) async {
    writes++;
    if (error != null) throw error!;
    return track.sizeBytes + 1;
  }
}

void main() {
  const track = Track(
    id: 'device:1',
    title: 'Local',
    contentType: 'audio/mpeg',
    sizeBytes: 10,
  );

  test('device metadata saves offline and survives reload and restart',
      () async {
    final local = Track(
        id: 'device:42',
        title: 'Original',
        artist: 'Old',
        fileName: 'song.mp3',
        contentType: 'audio/mpeg',
        sizeBytes: 10,
        sourceUri: Uri.parse('content://media/external/audio/media/42'));
    final library = FakeLocalAudioLibrary(
        LocalAudioResult(LocalAudioStatus.loaded, [local]));
    final store = MemoryLocalTrackMetadataStore();
    final controller = LocalAudioController(library,
        metadataStore: store, metadataWriter: FakeMetadataWriter());
    await controller.load();
    const draft = TrackMetadataDraft(
        fileName: 'new.mp3',
        title: 'عنوان جدید',
        artist: 'خواننده',
        album: 'آلبوم',
        albumArtist: 'گروه',
        composer: 'آهنگساز',
        genre: 'ژانر',
        year: 2026,
        trackNumber: 3,
        discNumber: 2,
        comment: 'یادداشت');
    final result = await controller.saveTrackMetadata(local, draft, version: 1);
    expect(result, isA<MetadataSaved>());
    await controller.load();
    final restarted = LocalAudioController(library,
        metadataStore: store, metadataWriter: FakeMetadataWriter());
    await restarted.load();
    final saved = restarted.tracks.single;
    expect(TrackMetadataDraft.fromTrack(saved).sameAs(draft), isTrue);
    expect(saved.id, local.id);
    expect(saved.sourceUri, local.sourceUri);
    expect(saved.sizeBytes, local.sizeBytes + 1);
    expect(saved.version, 2);
    expect(await restarted.saveTrackMetadata(saved, draft, version: 1),
        isA<MetadataConflict>());
  });

  test('a declined or failed original write never reports a saved edit',
      () async {
    final local = Track(
        id: 'device:9',
        title: 'Original',
        contentType: 'audio/mpeg',
        sizeBytes: 10,
        sourceUri: Uri.parse('content://media/9'));
    final store = MemoryLocalTrackMetadataStore();
    final writer = FakeMetadataWriter()
      ..error = PlatformException(code: 'PERMISSION_DENIED');
    final controller = LocalAudioController(
        FakeLocalAudioLibrary(
            LocalAudioResult(LocalAudioStatus.loaded, [local])),
        metadataStore: store,
        metadataWriter: writer);
    await controller.load();
    expect(
        await controller.saveTrackMetadata(local,
            const TrackMetadataDraft(fileName: 'x.mp3', title: 'Changed'),
            version: 1),
        isA<MetadataSaveFailed>());
    expect(controller.tracks.single.title, 'Original');
    expect(store.metadata, isEmpty);
    expect(writer.writes, 1);
  });

  test('concurrent offline edits preserve both tracks', () async {
    final files = [
      for (final id in ['a', 'b'])
        Track(
            id: 'device:$id',
            title: id,
            contentType: 'audio/mpeg',
            sizeBytes: 1,
            sourceUri: Uri.parse('content://media/$id'))
    ];
    final store = MemoryLocalTrackMetadataStore();
    final controller = LocalAudioController(
        FakeLocalAudioLibrary(LocalAudioResult(LocalAudioStatus.loaded, files)),
        metadataStore: store,
        metadataWriter: FakeMetadataWriter());
    await controller.load();
    final results = await Future.wait([
      for (final file in files)
        controller.saveTrackMetadata(
            file,
            TrackMetadataDraft(
                fileName: 'song.mp3', title: 'edited ${file.title}'),
            version: 1)
    ]);
    expect(results, everyElement(isA<MetadataSaved>()));
    expect(store.metadata.length, 2);
  });

  test('loads device tracks', () async {
    final controller = LocalAudioController(FakeLocalAudioLibrary(
      const LocalAudioResult(LocalAudioStatus.loaded, [track]),
    ));

    await controller.load();

    expect(controller.status, LocalAudioViewStatus.loaded);
    expect(controller.tracks, [track]);
  });

  test('reports denied permission and supports retry', () async {
    final library = FakeLocalAudioLibrary(
      const LocalAudioResult(LocalAudioStatus.permissionDenied),
    );
    final controller = LocalAudioController(library);

    await controller.load();
    expect(controller.status, LocalAudioViewStatus.permissionDenied);

    library.result = const LocalAudioResult(LocalAudioStatus.loaded, [track]);
    await controller.load();
    expect(controller.status, LocalAudioViewStatus.loaded);
    expect(controller.tracks, [track]);
  });

  test('unsupported platforms do not query', () async {
    final controller = LocalAudioController(FakeLocalAudioLibrary(
      const LocalAudioResult(LocalAudioStatus.loaded, [track]),
      supported: false,
    ));

    await controller.load();

    expect(controller.status, LocalAudioViewStatus.unsupported);
    expect(controller.tracks, isEmpty);
  });

  group('deleting a device track', () {
    final local = Track(
      id: 'device:7',
      title: 'Local',
      contentType: 'audio/mpeg',
      sizeBytes: 10,
      sourceUri: Uri.parse('content://media/external/audio/media/7'),
    );

    Future<(FakeLocalAudioLibrary, LocalAudioController)> loaded() async {
      final library = FakeLocalAudioLibrary(
          LocalAudioResult(LocalAudioStatus.loaded, [local]));
      final controller = LocalAudioController(library);
      await controller.load();
      return (library, controller);
    }

    test('removes it from the list once deleted', () async {
      final (library, controller) = await loaded();

      expect(await controller.delete(local), DeviceDeleteResult.deleted);
      expect(library.deleted, [local.sourceUri]);
      expect(controller.tracks, isEmpty);
    });

    test('a synced track is deleted by its device file', () async {
      final (library, controller) = await loaded();
      const cloud = Track(
          id: 't1', title: 'Local', contentType: 'audio/mpeg', sizeBytes: 10);

      expect(await controller.delete(cloud.withDeviceCopy(local.sourceUri!)),
          DeviceDeleteResult.deleted);
      expect(library.deleted, [local.sourceUri]);
      expect(controller.tracks, isEmpty);
    });

    test('keeps it when the user declines or access is denied', () async {
      final (library, controller) = await loaded();

      library.deleteAnswer = false;
      expect(await controller.delete(local), DeviceDeleteResult.declined);
      library.deleteAnswer = PlatformException(code: 'PERMISSION_DENIED');
      expect(
          await controller.delete(local), DeviceDeleteResult.permissionDenied);
      library.deleteAnswer = PlatformException(code: 'DELETE_FAILED');
      expect(await controller.delete(local), DeviceDeleteResult.failed);
      expect(controller.tracks, [local]);
    });
  });
}
