import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/data/local_audio_upload.dart';
import 'package:rhythmo/features/library/data/track_download.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/upload/application/upload_controller.dart';
import 'package:rhythmo/core/quiet_after_dispose.dart';

/// Which way a track's file is being copied.
enum SyncKind {
  /// From this device's music to the account.
  upload,

  /// From the account to this device's music (or, on the web, a browser
  /// download).
  download,
}

enum SyncPhase {
  /// Waiting for an earlier transfer to finish.
  queued,
  running,
  failed,
}

/// Why a transfer failed, for a short Persian explanation.
enum SyncError {
  permission,
  quota,
  offline,
  tooLarge,
  unsupportedFormat,
  invalidAudio,
  notFound,

  /// The file is already on this device.
  duplicate,

  /// Not enough free space on the device.
  storageFull,

  /// The download stopped before every byte arrived.
  incomplete,

  /// This platform cannot save downloads.
  unsupported,

  /// The server kept rewriting the file's embedded tags for too long.
  tagsPending,
  unknown,
}

/// A transfer of one track's file, shown on its row.
@immutable
class SyncOperation {
  const SyncOperation({
    required this.kind,
    required this.track,
    this.phase = SyncPhase.queued,
    this.progress = 0,
    this.preparing = false,
    this.error,
  });

  final SyncKind kind;

  /// The copy being transferred: the device track for an upload, the cloud
  /// track for a download.
  final Track track;
  final SyncPhase phase;

  /// 0..1 while running.
  final double progress;

  /// Running, but waiting for the server to finish writing the file's
  /// edited tags before the download starts.
  final bool preparing;
  final SyncError? error;

  bool get active => phase != SyncPhase.failed;

  SyncOperation _copy({
    SyncPhase? phase,
    double? progress,
    bool preparing = false,
    SyncError? error,
  }) =>
      SyncOperation(
        kind: kind,
        track: track,
        phase: phase ?? this.phase,
        progress: progress ?? this.progress,
        preparing: preparing,
        error: error,
      );
}

/// Copies tracks between this device and the account and remembers each
/// one's state for its row in the library: queued, running with progress,
/// or failed with a reason until retried or dismissed. Uploads run one at a
/// time, and so do downloads, but an upload and a download can run at once.
///
/// Uploads go through [UploadController], so quota, size and format checks,
/// per-file progress and the cleanup of failed uploads are the same as for
/// picked files. Downloads save the stored original through a short-lived
/// link. Files are copied as they are, never transcoded.
class LibrarySyncController extends ChangeNotifier with QuietAfterDispose {
  LibrarySyncController({
    required UploadController uploads,
    required LocalAudioUploadSource uploadSource,
    required Future<void> Function() onUploaded,
    required TracksApi api,
    required String? Function() token,
    required TrackDownloader downloader,
    required Future<void> Function() onDownloaded,
    this.tagsPendingDelay = const Duration(seconds: 5),
    this.tagsPendingAttempts = 12,
    Future<void> Function(Duration delay)? wait,
  })  : _wait = wait ?? Future<void>.delayed,
        _uploads = uploads,
        _uploadSource = uploadSource,
        _onUploaded = onUploaded,
        _api = api,
        _token = token,
        _downloader = downloader,
        _onDownloaded = onDownloaded;

  final UploadController _uploads;
  final LocalAudioUploadSource _uploadSource;
  final Future<void> Function() _onUploaded;
  final TracksApi _api;
  final String? Function() _token;
  final TrackDownloader _downloader;
  final Future<void> Function() _onDownloaded;
  final Future<void> Function(Duration delay) _wait;

  /// How long to wait before asking again while the server rewrites a
  /// track's tags, and how many times to ask (about a minute in all).
  final Duration tagsPendingDelay;
  final int tagsPendingAttempts;

  /// By the transferred copy's track ID, in the order they were started.
  final Map<String, SyncOperation> _operations = {};

  /// The running transfer of each kind.
  final Map<SyncKind, String> _running = {};
  final Set<SyncKind> _draining = {};

  /// Stops the running download.
  Completer<void>? _cancelDownload;

  /// Whether downloads are saved into this device's music, with progress,
  /// to play offline; on the web the browser saves them instead.
  bool get downloadsToDevice => _downloader.savesToDevice;

  final _finished = StreamController<SyncOperation>.broadcast(sync: true);

  /// Each transfer as it completes or fails, to tell the user; a completed
  /// one has no error and is no longer listed.
  Stream<SyncOperation> get finished => _finished.stream;

  /// The transfer of the copy with [trackId], if any.
  SyncOperation? operationFor(String trackId) => _operations[trackId];
  Iterable<SyncOperation> get operations => _operations.values;

  /// Uploads a device track to the account. Started again when it already
  /// failed; ignored while it is queued or running.
  void upload(Track local) {
    if (!local.isLocal) return;
    final existing = _operations[local.id];
    if (existing != null && existing.active) return;
    _operations[local.id] = SyncOperation(kind: SyncKind.upload, track: local);
    notifyListeners();
    _drain(SyncKind.upload);
  }

  /// Downloads a cloud track's original file. A track already on this
  /// device is not downloaded again; started again when it already failed;
  /// ignored while it is queued or running.
  void download(Track cloud) {
    if (cloud.id.startsWith('device:')) return;
    final existing = _operations[cloud.id];
    if (existing != null && existing.active) return;
    final operation = SyncOperation(kind: SyncKind.download, track: cloud);
    if (cloud.isLocal) {
      _operations[cloud.id] = operation;
      return _fail(cloud.id, SyncError.duplicate);
    }
    _operations[cloud.id] = operation;
    notifyListeners();
    _drain(SyncKind.download);
  }

  /// Starts a failed transfer again.
  void retry(String trackId) {
    final operation = _operations[trackId];
    if (operation == null || operation.active) return;
    _operations.remove(trackId);
    switch (operation.kind) {
      case SyncKind.upload:
        upload(operation.track);
      case SyncKind.download:
        download(operation.track);
    }
  }

  /// Stops a queued or running transfer; nothing is left behind.
  void cancel(String trackId) {
    final operation = _operations[trackId];
    if (operation == null || !operation.active) return;
    if (_running[operation.kind] == trackId) {
      switch (operation.kind) {
        case SyncKind.upload:
          if (_uploads.canCancel) _uploads.cancel();
        case SyncKind.download:
          final cancel = _cancelDownload;
          if (cancel != null && !cancel.isCompleted) cancel.complete();
      }
      return;
    }
    _operations.remove(trackId);
    notifyListeners();
  }

  /// Hides a failed transfer's error.
  void dismiss(String trackId) {
    final operation = _operations[trackId];
    if (operation == null || operation.active) return;
    _operations.remove(trackId);
    notifyListeners();
  }

  /// Whether a running transfer of [trackId] can be cancelled right now.
  bool canCancel(String trackId) {
    final operation = _operations[trackId];
    if (operation == null || !operation.active) return false;
    if (_running[operation.kind] != trackId) return true;
    return switch (operation.kind) {
      SyncKind.upload => _uploads.canCancel,
      SyncKind.download => _cancelDownload != null,
    };
  }

  Future<void> _drain(SyncKind kind) async {
    if (!_draining.add(kind)) return;
    try {
      while (true) {
        final next = _operations.entries
            .where((e) =>
                e.value.kind == kind && e.value.phase == SyncPhase.queued)
            .firstOrNull;
        if (next == null) return;
        // A picked file may still be uploading; wait for it.
        if (kind == SyncKind.upload && _uploads.isBusy) {
          await _idle(_uploads);
          continue;
        }
        _running[kind] = next.key;
        _set(next.key, next.value._copy(phase: SyncPhase.running));
        switch (kind) {
          case SyncKind.upload:
            await _runUpload(next.key, next.value.track);
          case SyncKind.download:
            await _runDownload(next.key, next.value.track);
        }
        _running.remove(kind);
      }
    } finally {
      _draining.remove(kind);
    }
  }

  Future<void> _runDownload(String id, Track cloud) async {
    final token = _token();
    if (token == null) return _fail(id, SyncError.unknown);
    final cancel = _cancelDownload = Completer<void>();
    try {
      DownloadLink? link;
      // Right after an edit the server is still writing the new tags into
      // the file; wait for it rather than saving the old tags.
      for (var attempt = 1; link == null; attempt++) {
        try {
          link = await _api.downloadLink(token, id);
        } on ApiException catch (error) {
          if (error.code != 'tags_pending') {
            return _fail(
                id,
                error.statusCode == 404
                    ? SyncError.notFound
                    : SyncError.unknown);
          }
          if (attempt >= tagsPendingAttempts) {
            return _fail(id, SyncError.tagsPending);
          }
          final operation = _operations[id];
          if (operation != null && !operation.preparing) {
            _set(id, operation._copy(preparing: true));
          }
          await Future.any([_wait(tagsPendingDelay), cancel.future]);
          if (cancel.isCompleted) return _forget(id);
        } catch (_) {
          return _fail(id, SyncError.offline);
        }
      }
      if (cancel.isCompleted) return _forget(id);
      final preparing = _operations[id];
      if (preparing != null && preparing.preparing) _set(id, preparing._copy());
      await _downloader.download(
        link,
        contentType: cloud.contentType,
        sizeBytes: cloud.sizeBytes,
        onProgress: (received, total) {
          final operation = _operations[id];
          if (operation == null || total <= 0 || cancel.isCompleted) return;
          _set(id, operation._copy(progress: (received / total).clamp(0, 1)));
        },
        cancelled: cancel.future,
      );
      // Kept as running until the device list shows the file, so the row
      // goes straight from downloading to synced.
      if (_downloader.savesToDevice) await _onDownloaded();
      final operation = _operations.remove(id);
      notifyListeners();
      if (operation != null) _finished.add(operation._copy(progress: 1));
    } on DownloadCancelled {
      _forget(id);
    } on DownloadException catch (error) {
      _fail(
          id,
          switch (error.reason) {
            DownloadFailure.offline => SyncError.offline,
            DownloadFailure.storageFull => SyncError.storageFull,
            DownloadFailure.permission => SyncError.permission,
            DownloadFailure.incomplete => SyncError.incomplete,
            DownloadFailure.duplicate => SyncError.duplicate,
            DownloadFailure.unsupported => SyncError.unsupported,
            DownloadFailure.unknown => SyncError.unknown,
          });
    } catch (_) {
      _fail(id, SyncError.unknown);
    } finally {
      _cancelDownload = null;
    }
  }

  void _forget(String id) {
    _operations.remove(id);
    notifyListeners();
  }

  Future<void> _runUpload(String id, Track local) async {
    void follow() {
      final operation = _operations[id];
      if (operation == null || operation.phase != SyncPhase.running) return;
      if (_uploads.phase == UploadPhase.uploading) {
        _set(id, operation._copy(progress: _uploads.progress));
      }
    }

    _uploads.readingFile();
    try {
      final file = await _uploadSource.prepare(local);
      _uploads.addListener(follow);
      try {
        await _uploads.upload(file);
      } finally {
        _uploads.removeListener(follow);
      }
    } on PlatformException catch (error) {
      _uploads.pickCancelled();
      return _fail(
        id,
        error.code == 'PERMISSION_DENIED'
            ? SyncError.permission
            : error.code == 'NOT_FOUND'
                ? SyncError.notFound
                : SyncError.unknown,
      );
    } catch (_) {
      _uploads.pickCancelled();
      return _fail(id, SyncError.unknown);
    }

    switch (_uploads.phase) {
      case UploadPhase.done:
        // Kept as running until the list shows the server copy, so the row
        // goes straight from uploading to synced.
        await _onUploaded();
        final operation = _operations.remove(id);
        notifyListeners();
        if (operation != null) _finished.add(operation._copy(progress: 1));
      case UploadPhase.failed:
        _fail(id, _fromUpload(_uploads.error));
      default:
        // Cancelled.
        _operations.remove(id);
        notifyListeners();
    }
  }

  static SyncError _fromUpload(UploadError? error) => switch (error) {
        UploadError.quotaExceeded => SyncError.quota,
        UploadError.network => SyncError.offline,
        UploadError.tooLarge => SyncError.tooLarge,
        UploadError.unsupportedFormat => SyncError.unsupportedFormat,
        UploadError.invalidAudio ||
        UploadError.emptyFile =>
          SyncError.invalidAudio,
        _ => SyncError.unknown,
      };

  void _fail(String id, SyncError error) {
    final operation = _operations[id];
    if (operation == null) return;
    final failed = operation._copy(phase: SyncPhase.failed, error: error);
    _set(id, failed);
    _finished.add(failed);
  }

  void _set(String id, SyncOperation operation) {
    _operations[id] = operation;
    notifyListeners();
  }

  static Future<void> _idle(UploadController uploads) {
    final done = Completer<void>();
    void check() {
      if (!uploads.isBusy && !done.isCompleted) done.complete();
    }

    uploads.addListener(check);
    return done.future.whenComplete(() => uploads.removeListener(check));
  }

  /// Forgets every transfer, for example on logout. Running ones are
  /// cancelled.
  void clear() {
    if (_uploads.canCancel) _uploads.cancel();
    final cancel = _cancelDownload;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
    _operations.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _finished.close();
    super.dispose();
  }
}

/// A short Persian explanation of [error], for a snackbar or a row.
String syncErrorMessage(SyncError error) => switch (error) {
      SyncError.permission =>
        'ریتمو اجازهٔ دسترسی به موسیقی دستگاه را ندارد. از تنظیمات اندروید اجازه بده.',
      SyncError.quota => 'فضای ابری حسابت پر است. چند آهنگ را حذف کن.',
      SyncError.offline =>
        'اتصال اینترنت برقرار نیست. وصل شو و دوباره تلاش کن.',
      SyncError.tooLarge => 'این فایل از حداکثر اندازهٔ مجاز بزرگ‌تر است.',
      SyncError.unsupportedFormat => 'قالب این فایل پشتیبانی نمی‌شود.',
      SyncError.invalidAudio => 'این فایل صوتی سالم نیست.',
      SyncError.notFound => 'فایل پیدا نشد؛ شاید حذف شده باشد.',
      SyncError.duplicate => 'این آهنگ از قبل روی دستگاه هست.',
      SyncError.storageFull =>
        'فضای خالی دستگاه کافی نیست. کمی جا باز کن و دوباره تلاش کن.',
      SyncError.incomplete => 'فایل کامل دریافت نشد. دوباره تلاش کن.',
      SyncError.unsupported => 'ذخیره روی این دستگاه پشتیبانی نمی‌شود.',
      SyncError.tagsPending =>
        'آماده‌سازی فایل بیش از حد طول کشید. کمی بعد دوباره تلاش کن.',
      SyncError.unknown => 'کار ناتمام ماند. دوباره تلاش کن.',
    };
