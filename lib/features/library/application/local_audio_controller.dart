import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rhythmo/features/library/data/local_audio_library.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/library/data/track_metadata.dart';
import 'package:rhythmo/features/library/data/local_track_metadata_store.dart';
import 'package:rhythmo/features/library/data/local_audio_metadata_writer.dart';

enum DeviceDeleteResult { deleted, declined, permissionDenied, failed }

enum LocalAudioViewStatus {
  idle,
  loading,
  loaded,
  permissionDenied,
  error,
  unsupported,
}

class LocalAudioController extends ChangeNotifier {
  LocalAudioController(this._library,
      {LocalTrackMetadataStore? metadataStore,
      LocalAudioMetadataWriter? metadataWriter})
      : _metadataStore = metadataStore ?? SecureLocalTrackMetadataStore(),
        _metadataWriter = metadataWriter ?? AndroidLocalAudioMetadataWriter();

  final LocalTrackMetadataStore _metadataStore;
  final LocalAudioMetadataWriter _metadataWriter;
  Map<String, Map<String, dynamic>> _metadata = {};
  Future<void>? _metadataLoading;
  Future<void> _saves = Future<void>.value();

  Future<void> _loadMetadata() => _metadataLoading ??= () async {
        try {
          _metadata = await _metadataStore.read();
        } catch (_) {
          // A storage failure must not hide otherwise playable device music.
          _metadata = {};
        }
      }();

  static String _key(Track track) => track.sourceUri?.toString() ?? track.id;

  Track _withMetadata(Track original) {
    final values = _metadata[_key(original)];
    if (values == null) return original;
    return Track.fromJson({
      ...values,
      'id': original.id,
      'contentType': original.contentType,
      'sizeBytes': values['sizeBytes'] ?? original.sizeBytes,
    }).keepingContextOf(original);
  }

  /// Reads embedded fields on demand so saving one field cannot erase fields
  /// MediaStore did not expose during the initial library scan.
  Future<Track?> metadataForEditing(Track track) async {
    try {
      final values = await _metadataWriter.read(track);
      final normalized = <String, dynamic>{...values};
      for (final key in ['year', 'trackNumber', 'discNumber']) {
        normalized[key] = int.tryParse('${values[key] ?? ''}'.split('/').first);
      }
      return Track.fromJson({
        ...normalized,
        'id': track.id,
        'title': values['title']?.toString().isNotEmpty == true
            ? values['title']
            : track.title,
        'fileName': track.fileName,
        'contentType': track.contentType,
        'sizeBytes': track.sizeBytes,
        'version': track.version,
      }).keepingContextOf(track);
    } catch (_) {
      return null;
    }
  }

  /// Rewrites and verifies the original file before updating the UI/cache.
  Future<MetadataSaveResult> saveTrackMetadata(
      Track track, TrackMetadataDraft draft,
      {required int version}) async {
    MetadataSaveResult result = const MetadataSaveFailed();
    final save = _saves.then((_) async {
      await _loadMetadata();
      if (!track.isLocal) return;
      final index = _tracks.indexWhere((t) => _key(t) == _key(track));
      if (index == -1) return;
      final current = _tracks[index];
      if (current.version != version) {
        result = MetadataConflict(current);
        return;
      }
      if (draft.title.trim().isEmpty) {
        result = const MetadataInvalid('title');
        return;
      }
      final values = <String, dynamic>{
        'title': draft.title.trim(),
        'fileName': draft.fileName.trim(),
        'artist': draft.artist.trim(),
        'album': draft.album.trim(),
        'albumArtist': draft.albumArtist.trim(),
        'composer': draft.composer.trim(),
        'genre': draft.genre.trim(),
        'comment': draft.comment.trim(),
        'year': draft.year,
        'trackNumber': draft.trackNumber,
        'discNumber': draft.discNumber,
        'version': version + 1,
      };
      try {
        values['sizeBytes'] = await _metadataWriter.write(track, draft);
      } catch (_) {
        return; // Cancellation, unsupported tags or failed writes are not saved.
      }
      final next = {..._metadata, _key(track): values};
      try {
        await _metadataStore.write(next);
      } catch (_) {
        // The original file was already verified. The cache is expendable.
      }
      _metadata = next;
      final updated = _withMetadata(current);
      _tracks = List.unmodifiable([..._tracks]..[index] = updated);
      result = MetadataSaved(updated);
      notifyListeners();
    });
    _saves = save;
    await save;
    return result;
  }

  final LocalAudioLibrary _library;
  LocalAudioViewStatus _status = LocalAudioViewStatus.idle;
  List<Track> _tracks = const [];

  bool get supported => _library.supported;
  LocalAudioViewStatus get status => _status;
  List<Track> get tracks => _tracks;

  Future<void> load() async {
    if (!supported) {
      _status = LocalAudioViewStatus.unsupported;
      notifyListeners();
      return;
    }
    _status = LocalAudioViewStatus.loading;
    notifyListeners();
    try {
      final result = await _library.load();
      await _loadMetadata();
      _tracks = List.unmodifiable(result.tracks.map(_withMetadata));
      _status = switch (result.status) {
        LocalAudioStatus.loaded => LocalAudioViewStatus.loaded,
        LocalAudioStatus.permissionDenied =>
          LocalAudioViewStatus.permissionDenied,
        LocalAudioStatus.unsupported => LocalAudioViewStatus.unsupported,
      };
    } catch (_) {
      _status = LocalAudioViewStatus.error;
    }
    notifyListeners();
  }

  /// Deletes a device track's file and drops it from the list. Android may
  /// ask the user to confirm first.
  Future<DeviceDeleteResult> delete(Track track) async {
    if (!supported || !track.isLocal) return DeviceDeleteResult.failed;
    try {
      if (!await _library.delete(track)) return DeviceDeleteResult.declined;
    } on PlatformException catch (error) {
      return error.code == 'PERMISSION_DENIED'
          ? DeviceDeleteResult.permissionDenied
          : DeviceDeleteResult.failed;
    } catch (_) {
      return DeviceDeleteResult.failed;
    }
    _tracks = List.unmodifiable(
      _tracks.where((t) => t.sourceUri != track.sourceUri),
    );
    notifyListeners();
    return DeviceDeleteResult.deleted;
  }
}
