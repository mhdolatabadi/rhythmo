import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/application/library_sync_controller.dart';
import 'package:rhythmo/features/library/data/local_audio_upload.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/library/data/track_download.dart';
import 'package:rhythmo/features/upload/application/upload_controller.dart';
import 'package:rhythmo/features/upload/data/upload_models.dart';

import 'upload_controller_test.dart' show FakeTracksApi, FakeUploader;

/// Copies device tracks "into the cache"; [error] makes it fail.
class FakeUploadSource implements LocalAudioUploadSource {
  Object? error;
  Completer<void>? gate;
  final prepared = <String>[];
  final released = <String>[];

  @override
  Future<PickedAudio> prepare(Track track) async {
    await gate?.future;
    if (error != null) throw error!;
    prepared.add(track.id);
    return PickedAudio(
      name: track.fileName ?? 'song.mp3',
      sizeBytes: track.sizeBytes,
      openRead: () => Stream.value(List.filled(track.sizeBytes, 0)),
      release: () async => released.add(track.id),
    );
  }
}

/// Saves downloads "to the device": reports half, then all, of the bytes.
/// With [stall] it waits halfway until cancelled; [error] makes it fail.
class FakeTrackDownloader implements TrackDownloader {
  FakeTrackDownloader({this.savesToDevice = true});

  @override
  final bool savesToDevice;
  bool stall = false;
  Object? error;
  final saved = <String>[];

  /// Called with each saved file, to add it to the fake device's music.
  void Function(DownloadLink link)? onSaved;

  @override
  Future<void> download(
    DownloadLink link, {
    required String contentType,
    required int sizeBytes,
    required void Function(int received, int total) onProgress,
    required Future<void> cancelled,
  }) async {
    onProgress(sizeBytes ~/ 2, sizeBytes);
    if (stall) {
      await cancelled;
      throw const DownloadCancelled();
    }
    if (error != null) throw error!;
    onProgress(sizeBytes, sizeBytes);
    saved.add(link.fileName);
    onSaved?.call(link);
  }
}

Track device(int id, {String fileName = 'song.mp3'}) => Track(
      id: 'device:$id',
      title: 'Device $id',
      contentType: 'audio/mpeg',
      sizeBytes: 4,
      fileName: fileName,
      sourceUri: Uri.parse('content://media/external/audio/media/$id'),
    );

void main() {
  late FakeTracksApi api;
  late FakeUploader uploader;
  late FakeUploadSource source;
  late UploadController uploads;
  late LibrarySyncController sync;
  late int refreshed;
  late int rescanned;
  late FakeTrackDownloader downloader;
  late List<SyncOperation> finished;

  setUp(() {
    api = FakeTracksApi();
    uploader = FakeUploader();
    source = FakeUploadSource();
    uploads =
        UploadController(api: api, uploader: uploader, token: () => 'token');
    refreshed = 0;
    rescanned = 0;
    sync = LibrarySyncController(
      uploads: uploads,
      uploadSource: source,
      onUploaded: () async => refreshed++,
      api: api,
      token: () => 'token',
      downloader: downloader = FakeTrackDownloader(),
      onDownloaded: () async => rescanned++,
    );
    finished = [];
    sync.finished.listen(finished.add);
  });

  Future<void> settle() => pumpEventQueue();

  test('uploads a device track and forgets it once the list shows it',
      () async {
    final track = device(1);
    final seen = <(SyncPhase, double)?>[];
    sync.addListener(() {
      final op = sync.operationFor(track.id);
      seen.add(op == null ? null : (op.phase, op.progress));
    });

    sync.upload(track);
    expect(sync.operationFor(track.id)?.phase, isNotNull);
    await settle();

    expect(source.prepared, [track.id]);
    expect(source.released, [track.id]);
    expect(api.calls, contains('create:token:song.mp3:4'));
    expect(refreshed, 1);
    expect(sync.operationFor(track.id), isNull);
    expect(
        seen,
        containsAllInOrder([
          (SyncPhase.queued, 0.0),
          (SyncPhase.running, 0.0),
          (SyncPhase.running, 0.5),
          (SyncPhase.running, 1.0),
          null,
        ]));
    expect(finished.single.error, isNull);
  });

  test('a full quota fails with a reason, and retrying succeeds', () async {
    final track = device(1);
    api.createError =
        const ApiException('quota', statusCode: 413, code: 'quota_exceeded');

    sync.upload(track);
    await settle();

    final failed = sync.operationFor(track.id)!;
    expect(failed.phase, SyncPhase.failed);
    expect(failed.error, SyncError.quota);
    expect(finished.single.error, SyncError.quota);
    expect(syncErrorMessage(SyncError.quota), contains('فضای ابری'));
    expect(refreshed, 0);

    api.createError = null;
    sync.retry(track.id);
    await settle();

    expect(sync.operationFor(track.id), isNull);
    expect(refreshed, 1);
  });

  test('a lost connection is reported as offline', () async {
    api.createError = Exception('SocketException: Failed host lookup');

    sync.upload(device(1));
    await settle();

    expect(sync.operationFor('device:1')!.error, SyncError.offline);
  });

  test('back online, transfers stopped offline start again once', () async {
    api.createError = Exception('SocketException: Failed host lookup');
    sync.upload(device(1));
    await settle();
    expect(sync.operationFor('device:1')!.error, SyncError.offline);

    // Still unreachable: one try, then it waits for the next reconnection.
    sync.retryOffline();
    await settle();
    expect(sync.operationFor('device:1')!.error, SyncError.offline);

    api.createError = null;
    sync.retryOffline();
    await settle();
    expect(sync.operationFor('device:1'), isNull);
  });

  test('denied media access is reported as a permission problem', () async {
    source.error = PlatformException(code: 'PERMISSION_DENIED');

    sync.upload(device(1));
    await settle();

    expect(sync.operationFor('device:1')!.error, SyncError.permission);
    expect(uploads.isBusy, isFalse);
  });

  test('uploads run one at a time; a queued one can be cancelled', () async {
    source.gate = Completer<void>();
    sync.upload(device(1));
    sync.upload(device(2));
    sync.upload(device(3));
    await settle();

    expect(sync.operationFor('device:1')!.phase, SyncPhase.running);
    expect(sync.operationFor('device:2')!.phase, SyncPhase.queued);
    expect(sync.canCancel('device:2'), isTrue);

    sync.cancel('device:2');
    expect(sync.operationFor('device:2'), isNull);

    source.gate!.complete();
    await settle();

    expect(source.prepared, ['device:1', 'device:3']);
    expect(sync.operations, isEmpty);
    expect(refreshed, 2);
  });

  test('a running upload can be cancelled and leaves nothing behind', () async {
    uploader.stall = true;
    sync.upload(device(1));
    await settle();

    expect(sync.operationFor('device:1')!.progress, 0.5);
    expect(sync.canCancel('device:1'), isTrue);
    sync.cancel('device:1');
    await settle();

    expect(sync.operationFor('device:1'), isNull);
    expect(api.deleted, ['t1']);
    expect(finished, isEmpty);
    expect(refreshed, 0);
  });

  test('waits for a picked file that is still uploading', () async {
    uploader.stall = true;
    unawaited(uploads.upload(PickedAudio(
      name: 'picked.mp3',
      sizeBytes: 4,
      openRead: () => Stream.value([1, 2, 3, 4]),
    )));
    await settle();

    sync.upload(device(1));
    await settle();
    expect(sync.operationFor('device:1')!.phase, SyncPhase.queued);

    uploader.stall = false;
    uploads.cancel();
    await settle();

    expect(source.prepared, ['device:1']);
    expect(sync.operations, isEmpty);
  });

  test('a failed upload can be dismissed; clear forgets everything', () async {
    api.createError = const ApiException('x', statusCode: 500, code: 'x');
    sync.upload(device(1));
    await settle();

    sync.dismiss('device:1');
    expect(sync.operationFor('device:1'), isNull);

    sync.upload(device(2));
    sync.clear();
    await settle();
    expect(sync.operations, isEmpty);
  });

  group('downloads', () {
    const cloud = Track(
      id: 's1',
      title: 'Server song',
      contentType: 'audio/mpeg',
      sizeBytes: 10,
      fileName: 'Server_song.mp3',
    );

    setUp(() => api.tracks.add(cloud));

    test('downloads the original under its filename, then rescans the device',
        () async {
      final seen = <(SyncPhase, double)?>[];
      sync.addListener(() {
        final op = sync.operationFor(cloud.id);
        seen.add(op == null ? null : (op.phase, op.progress));
      });

      sync.download(cloud);
      expect(sync.operationFor(cloud.id)!.kind, SyncKind.download);
      await settle();

      expect(api.downloadLinks, [cloud.id]);
      expect(downloader.saved, ['Server_song.mp3']);
      expect(rescanned, 1);
      expect(sync.operationFor(cloud.id), isNull);
      expect(
          seen,
          containsAllInOrder([
            (SyncPhase.queued, 0.0),
            (SyncPhase.running, 0.0),
            (SyncPhase.running, 0.5),
            (SyncPhase.running, 1.0),
            null,
          ]));
      expect(finished.single.kind, SyncKind.download);
      expect(finished.single.error, isNull);
    });

    group('while the server rewrites the tags', () {
      late List<Duration> waits;
      late Completer<void>? gate;

      LibrarySyncController waiting({int attempts = 3}) {
        waits = [];
        gate = null;
        final controller = LibrarySyncController(
          uploads: uploads,
          uploadSource: source,
          onUploaded: () async {},
          api: api,
          token: () => 'token',
          downloader: downloader,
          onDownloaded: () async => rescanned++,
          tagsPendingAttempts: attempts,
          wait: (delay) {
            waits.add(delay);
            return gate?.future ?? Future<void>.value();
          },
        );
        controller.finished.listen(finished.add);
        return controller;
      }

      test('waits, shows it is preparing, then downloads', () async {
        final sync = waiting();
        api.tagsPending = 2;
        final preparing = <bool>[];
        sync.addListener(() {
          final op = sync.operationFor(cloud.id);
          if (op != null) preparing.add(op.preparing);
        });

        sync.download(cloud);
        await settle();

        expect(waits, [const Duration(seconds: 5), const Duration(seconds: 5)]);
        expect(preparing, containsAllInOrder([true, false]));
        expect(downloader.saved, ['Server_song.mp3']);
        expect(finished.single.error, isNull);
        expect(sync.operationFor(cloud.id), isNull);
      });

      test('gives up after a bounded number of attempts', () async {
        final sync = waiting(attempts: 3);
        api.tagsPending = 10;

        sync.download(cloud);
        await settle();

        expect(api.calls.where((c) => c == 'download:${cloud.id}').length, 3);
        expect(waits, hasLength(2));
        expect(downloader.saved, isEmpty);
        final failed = sync.operationFor(cloud.id)!;
        expect(failed.phase, SyncPhase.failed);
        expect(failed.error, SyncError.tagsPending);
        expect(failed.preparing, isFalse);
        expect(syncErrorMessage(SyncError.tagsPending), contains('آماده‌سازی'));

        // Once the tags are written, retrying works.
        api.tagsPending = 0;
        sync.retry(cloud.id);
        await settle();
        expect(downloader.saved, ['Server_song.mp3']);
      });

      test('can be cancelled while it waits', () async {
        final sync = waiting();
        gate = Completer<void>();
        api.tagsPending = 1;

        sync.download(cloud);
        await settle();
        expect(sync.operationFor(cloud.id)!.preparing, isTrue);
        expect(sync.canCancel(cloud.id), isTrue);

        sync.cancel(cloud.id);
        await settle();
        expect(sync.operationFor(cloud.id), isNull);
        expect(downloader.saved, isEmpty);
        expect(api.calls.where((c) => c == 'download:${cloud.id}').length, 1);
      });
    });

    test('a cancelled download leaves nothing and can start again', () async {
      downloader.stall = true;
      sync.download(cloud);
      await settle();
      expect(sync.operationFor(cloud.id)!.progress, 0.5);
      expect(sync.canCancel(cloud.id), isTrue);

      sync.cancel(cloud.id);
      await settle();
      expect(sync.operationFor(cloud.id), isNull);
      expect(downloader.saved, isEmpty);
      expect(finished, isEmpty);

      downloader.stall = false;
      sync.download(cloud);
      await settle();
      expect(downloader.saved, ['Server_song.mp3']);
    });

    test('failures explain themselves and can be retried', () async {
      for (final (failure, error) in const [
        (DownloadFailure.storageFull, SyncError.storageFull),
        (DownloadFailure.offline, SyncError.offline),
        (DownloadFailure.permission, SyncError.permission),
        (DownloadFailure.incomplete, SyncError.incomplete),
        (DownloadFailure.duplicate, SyncError.duplicate),
      ]) {
        downloader.error = DownloadException(failure);
        sync.download(cloud);
        await settle();
        expect(sync.operationFor(cloud.id)!.error, error, reason: '$failure');
        expect(syncErrorMessage(error), isNotEmpty);
        sync.dismiss(cloud.id);
      }

      downloader.error = null;
      sync.download(cloud);
      await settle();
      downloader.error = const DownloadException(DownloadFailure.offline);
      // Already saved, so nothing failed; retry a fresh failure instead.
      sync.download(cloud);
      await settle();
      expect(sync.operationFor(cloud.id)!.phase, SyncPhase.failed);
      downloader.error = null;
      sync.retry(cloud.id);
      await settle();
      expect(sync.operationFor(cloud.id), isNull);
      expect(downloader.saved, hasLength(2));
    });

    test('without a connection the link fails as offline', () async {
      api.linkError = Exception('SocketException');

      sync.download(cloud);
      await settle();

      expect(sync.operationFor(cloud.id)!.error, SyncError.offline);
      expect(downloader.saved, isEmpty);
    });

    test('a track already on the device is not downloaded twice', () async {
      sync.download(cloud.withDeviceCopy(Uri.parse('content://media/1')));
      await settle();

      expect(sync.operationFor(cloud.id)!.error, SyncError.duplicate);
      expect(api.downloadLinks, isEmpty);
    });

    test('one download at a time, alongside an upload', () async {
      api.tracks.add(const Track(
          id: 's2', title: 'Second', contentType: 'audio/mpeg', sizeBytes: 8));
      downloader.stall = true;
      uploader.stall = true;
      sync.download(cloud);
      sync.download(api.tracks.last);
      sync.upload(device(1));
      await settle();

      expect(sync.operationFor('s1')!.phase, SyncPhase.running);
      expect(sync.operationFor('s2')!.phase, SyncPhase.queued);
      expect(sync.operationFor('device:1')!.phase, SyncPhase.running);

      sync.clear();
      await settle();
      expect(sync.operations, isEmpty);
    });

    test('on the web the browser saves it; no device rescan', () async {
      final web = LibrarySyncController(
        uploads: uploads,
        uploadSource: source,
        onUploaded: () async {},
        api: api,
        token: () => 'token',
        downloader: FakeTrackDownloader(savesToDevice: false),
        onDownloaded: () async => rescanned++,
      );
      expect(web.downloadsToDevice, isFalse);

      web.download(cloud);
      await settle();

      expect(web.operationFor(cloud.id), isNull);
      expect(rescanned, 0);
    });
  });
}
