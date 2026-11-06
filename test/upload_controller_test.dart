import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/upload/application/upload_controller.dart';
import 'package:rhythmo/features/upload/data/storage_uploader.dart';
import 'package:rhythmo/features/upload/data/upload_models.dart';

const _pendingTrack = Track(
  id: 't1',
  title: 'Song',
  contentType: 'audio/mpeg',
  sizeBytes: 4,
);

class FakeTracksApi implements TracksApi {
  FakeTracksApi([List<Track>? tracks]) : tracks = [...?tracks];

  /// What the server lists; a completed upload is added to it.
  final List<Track> tracks;
  Object? listError;
  int importsInProgress = 0;
  Completer<void>? createGate;
  Object? createError;
  Object? completeError;
  Object? updateError;
  Object? deleteError;
  final deleted = <String>[];
  final calls = <String>[];

  @override
  Future<TrackLibrary> listTracks(String token) async {
    calls.add('list');
    if (listError != null) throw listError!;
    return TrackLibrary(
      tracks: List.of(tracks),
      usedBytes: tracks.fold(0, (sum, track) => sum + track.sizeBytes),
      limitBytes: 5 * 1024 * 1024 * 1024,
      importsInProgress: importsInProgress,
    );
  }

  /// How many stream links were issued, and optional failure.
  int links = 0;
  Object? linkError;

  /// The embedded tag state the server reports right after an edit.
  EmbeddedTags tagsAfterUpdate = const EmbeddedTags();

  @override
  Future<Track> getTrack(String token, String trackId) async {
    calls.add('get:$trackId');
    return tracks.firstWhere((track) => track.id == trackId);
  }

  @override
  Future<StreamLink> streamLink(String token, String trackId) async {
    calls.add('stream:$trackId');
    if (linkError != null) throw linkError!;
    links++;
    return StreamLink(
      Uri.parse('https://music.example.com/nafir-music/$trackId?sig=$links'),
      DateTime.now().add(const Duration(hours: 1)),
    );
  }

  /// Download links issued, by track ID.
  final downloadLinks = <String>[];

  /// How many more download link requests answer 409 tags_pending.
  int tagsPending = 0;

  @override
  Future<DownloadLink> downloadLink(String token, String trackId) async {
    calls.add('download:$trackId');
    if (linkError != null) throw linkError!;
    if (tagsPending > 0) {
      tagsPending--;
      throw const ApiException('tags pending',
          statusCode: 409, code: 'tags_pending');
    }
    downloadLinks.add(trackId);
    final track = tracks.firstWhere((t) => t.id == trackId);
    return DownloadLink(
      url: Uri.parse('https://music.example.com/nafir-music/$trackId?dl=1'),
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      fileName: track.fileName ?? 'track.mp3',
      version: track.version,
      tagsUpToDate: true,
    );
  }

  @override
  Future<StreamLink> playlistStreamLink(
      String token, String playlistId, String trackId) async {
    calls.add('playlist:$playlistId:$trackId');
    links++;
    return StreamLink(
      Uri.parse('https://music.example.com/nafir-music/$trackId?sig=$links'),
      DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<StreamLink> storeStreamLink(String? token, String id) async {
    calls.add('store:$id');
    if (linkError != null) throw linkError!;
    links++;
    return StreamLink(
      Uri.parse('https://music.example.com/nafir-music/store/$id?sig=$links'),
      DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<StreamLink> sharedStreamLink(
      String? token, String shareToken, String trackId) async {
    calls.add('shared:$shareToken:$trackId');
    if (linkError != null) throw linkError!;
    links++;
    return StreamLink(
      Uri.parse('https://music.example.com/nafir-music/$trackId?sig=$links'),
      DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<UploadTicket> createUpload(
      String token, String fileName, int sizeBytes) async {
    calls.add('create:$token:$fileName:$sizeBytes');
    await createGate?.future;
    if (createError != null) throw createError!;
    return UploadTicket(
      track: _pendingTrack,
      url: Uri.parse('https://music.example.com/nafir-music/'),
      fields: const {'key': 'users/u1/tracks/t1/song.mp3'},
    );
  }

  @override
  Future<Track> completeUpload(String token, String trackId) async {
    calls.add('complete:$trackId');
    if (completeError != null) throw completeError!;
    tracks.insert(0, _pendingTrack);
    return _pendingTrack;
  }

  @override
  Future<Track> updateTrackMetadata(
    String token,
    String trackId, {
    required int version,
    String? fileName,
    required String title,
    String? artist,
    String? album,
    String? albumArtist,
    String? composer,
    String? genre,
    int? year,
    int? trackNumber,
    int? discNumber,
    String? comment,
  }) async {
    calls.add('update:$trackId');
    if (updateError != null) throw updateError!;
    final index = tracks.indexWhere((track) => track.id == trackId);
    if (index == -1) {
      throw const ApiException(
        'not found',
        statusCode: 404,
        code: 'not_found',
      );
    }
    final current = tracks[index];
    if (current.version != version) {
      throw ApiException(
        'conflict',
        statusCode: 409,
        code: 'version_conflict',
        details: {
          'error': 'version_conflict',
          'track': {
            'id': current.id,
            'title': current.title,
            'artist': current.artist,
            'contentType': current.contentType,
            'sizeBytes': current.sizeBytes,
            'fileName': current.fileName,
            'version': current.version,
          },
        },
      );
    }
    final updated = Track(
      id: current.id,
      title: title,
      artist: artist,
      album: album,
      albumArtist: albumArtist,
      composer: composer,
      genre: genre,
      year: year,
      trackNumber: trackNumber,
      discNumber: discNumber,
      comment: comment,
      contentType: current.contentType,
      sizeBytes: current.sizeBytes,
      fileName: fileName ?? current.fileName,
      sourceUri: current.sourceUri,
      source: current.source,
      sharedVia: current.sharedVia,
      version: current.version + 1,
      embeddedTags: tagsAfterUpdate,
    );
    tracks[index] = updated;
    return updated;
  }

  @override
  Future<void> deleteTrack(String token, String trackId) async {
    if (deleteError != null) throw deleteError!;
    deleted.add(trackId);
    tracks.removeWhere((track) => track.id == trackId);
  }
}

class FakeUploader implements StorageUploader {
  Object? error;
  String? contentType;

  /// When set, the upload stalls halfway until it is cancelled.
  bool stall = false;
  int burstSize = 0;

  @override
  Future<void> upload(
    UploadTicket ticket,
    PickedAudio file, {
    required String contentType,
    required void Function(int sent, int total) onProgress,
    required Future<void> cancelled,
  }) async {
    this.contentType = contentType;
    onProgress(2, 4);
    for (var i = 0; i < burstSize; i++) {
      onProgress(i, burstSize + 1);
    }
    if (stall) {
      await cancelled;
      throw const UploadCancelled();
    }
    if (error != null) throw error!;
    onProgress(4, 4);
  }
}

PickedAudio _file(String name, {int size = 4, void Function()? onRelease}) =>
    PickedAudio(
      name: name,
      sizeBytes: size,
      openRead: () => Stream.value([1, 2, 3, 4]),
      release: () async => onRelease?.call(),
    );

void main() {
  late FakeTracksApi api;
  late FakeUploader uploader;
  late UploadController controller;
  late List<(UploadPhase, double)> seen;

  setUp(() {
    api = FakeTracksApi();
    uploader = FakeUploader();
    controller = UploadController(
      api: api,
      uploader: uploader,
      token: () => 'tok',
    );
    seen = [];
    controller
        .addListener(() => seen.add((controller.phase, controller.progress)));
  });

  test('uploads, reports progress and verifies', () async {
    var released = false;
    await controller
        .upload(_file('song.MP3', onRelease: () => released = true));

    expect(controller.phase, UploadPhase.done);
    expect(controller.uploaded?.title, 'Song');
    expect(uploader.contentType, 'audio/mpeg');
    expect(api.calls, ['create:tok:song.MP3:4', 'complete:t1']);
    expect(seen.map((s) => s.$1).toSet(), {
      UploadPhase.preparing,
      UploadPhase.uploading,
      UploadPhase.verifying,
      UploadPhase.done,
    });
    expect(seen, contains((UploadPhase.uploading, 0.5)));
    expect(released, isTrue,
        reason: 'the temporary picker copy must be released');
    expect(api.deleted, isEmpty);
  });

  test('a burst of upload chunks does not flood UI listeners', () async {
    uploader.burstSize = 10000;
    await controller.upload(_file('song.mp3'));
    final progress = seen.where((s) => s.$1 == UploadPhase.uploading);
    expect(progress.length, lessThan(20));
    expect(progress.last.$2, 1);
    expect(controller.phase, UploadPhase.done);
  });

  test('uploads a selected batch sequentially and reports its summary',
      () async {
    final released = <String>[];

    await controller.uploadAll([
      _file('first.mp3', onRelease: () => released.add('first')),
      _file('notes.txt', onRelease: () => released.add('notes')),
      _file('last.mp3', onRelease: () => released.add('last')),
    ]);

    expect(controller.phase, UploadPhase.failed);
    expect(controller.batchTotal, 3);
    expect(controller.batchIndex, 3);
    expect(controller.batchCompleted, 2);
    expect(controller.batchFailed, 1);
    expect(api.calls, [
      'create:tok:first.mp3:4',
      'complete:t1',
      'create:tok:last.mp3:4',
      'complete:t1',
    ]);
    expect(released, ['first', 'notes', 'last']);
  });

  test('rejects unsupported, empty and oversized files without calling the API',
      () async {
    for (final (file, error) in [
      (_file('notes.txt'), UploadError.unsupportedFormat),
      (_file('empty.mp3', size: 0), UploadError.emptyFile),
      (_file('huge.mp3', size: 300 * 1024 * 1024), UploadError.tooLarge),
    ]) {
      await controller.upload(file);
      expect(controller.phase, UploadPhase.failed);
      expect(controller.error, error);
    }
    expect(api.calls, isEmpty);
  });

  test('a failed storage upload removes the pending track', () async {
    uploader.error = const UploadFailed(403);
    var released = false;

    await controller
        .upload(_file('song.mp3', onRelease: () => released = true));

    expect(controller.error, UploadError.network);
    expect(api.deleted, ['t1']);
    expect(released, isTrue);
  });

  test('a file the server rejects is reported and not deleted twice', () async {
    api.completeError =
        const ApiException('422', statusCode: 422, code: 'invalid_audio');

    await controller.upload(_file('song.mp3'));

    expect(controller.error, UploadError.invalidAudio);
    expect(api.deleted, isEmpty);
  });

  test('a rejected reservation is reported without cleanup', () async {
    api.createError =
        const ApiException('413', statusCode: 413, code: 'invalid_size');

    await controller.upload(_file('song.mp3'));

    expect(controller.error, UploadError.tooLarge);
    expect(api.deleted, isEmpty);
  });

  test('reports server-side upload safety limits', () async {
    for (final (code, expected) in [
      ('quota_exceeded', UploadError.quotaExceeded),
      ('too_many_pending_uploads', UploadError.tooManyPending),
      ('uploads_disabled', UploadError.uploadsDisabled),
    ]) {
      api.createError = ApiException('rejected', statusCode: 429, code: code);
      await controller.upload(_file('song.mp3'));
      expect(controller.error, expected);
      expect(api.deleted, isEmpty);
    }
  });

  test('dismiss returns to idle after a result', () async {
    await controller.upload(_file('song.mp3'));
    controller.dismiss();
    expect(controller.phase, UploadPhase.idle);
  });

  test('cancelling mid-upload removes the pending track and goes idle',
      () async {
    uploader.stall = true;
    final done = controller.upload(_file('song.mp3'));
    await pumpEventQueue();
    expect(controller.phase, UploadPhase.uploading);
    expect(controller.canCancel, isTrue);

    controller.cancel();
    await done;

    expect(controller.phase, UploadPhase.idle);
    expect(controller.error, isNull);
    expect(api.deleted, ['t1']);
    expect(api.calls, isNot(contains('complete:t1')));
  });

  test('cancelling while the track is being reserved uploads nothing',
      () async {
    api.createGate = Completer();
    final done = controller.upload(_file('song.mp3'));
    await pumpEventQueue();
    expect(controller.phase, UploadPhase.preparing);

    controller.cancel();
    api.createGate!.complete();
    await done;

    expect(controller.phase, UploadPhase.idle);
    expect(uploader.contentType, isNull, reason: 'no bytes should be sent');
    expect(api.deleted, ['t1']);
  });

  test('reading state ends when the picker is closed without a file', () {
    controller.readingFile();
    expect(controller.phase, UploadPhase.reading);
    expect(controller.canCancel, isFalse);
    controller.pickCancelled();
    expect(controller.phase, UploadPhase.idle);
  });

  test('a picked file is uploaded after the reading state', () async {
    controller.readingFile();
    await controller.upload(_file('song.mp3'));
    expect(controller.phase, UploadPhase.done);
  });
}
