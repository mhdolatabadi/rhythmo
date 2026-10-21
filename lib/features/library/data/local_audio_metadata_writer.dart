import 'package:flutter/services.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/library/data/track_metadata.dart';

abstract interface class LocalAudioMetadataWriter {
  Future<Map<String, dynamic>> read(Track track);
  Future<int> write(Track track, TrackMetadataDraft draft);
}

class AndroidLocalAudioMetadataWriter implements LocalAudioMetadataWriter {
  static const _channel = MethodChannel('ir.mhdolatabadi.nafir/local_audio');

  @override
  Future<Map<String, dynamic>> read(Track track) async {
    await _channel.invokeMethod<Object?>('recoverAudioMetadata');
    return Map<String, dynamic>.from(await _channel.invokeMethod<Map>(
            'readAudioMetadata',
            {'uri': track.sourceUri.toString(), 'fileName': track.fileName}) ??
        const {});
  }

  @override
  Future<int> write(Track track, TrackMetadataDraft draft) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'writeAudioMetadata',
      {
        'uri': track.sourceUri.toString(),
        'fileName': draft.fileName.trim(),
        'metadata': {
          'title': draft.title.trim(),
          'artist': draft.artist.trim(),
          'album': draft.album.trim(),
          'albumArtist': draft.albumArtist.trim(),
          'composer': draft.composer.trim(),
          'genre': draft.genre.trim(),
          'year': draft.year,
          'trackNumber': draft.trackNumber,
          'discNumber': draft.discNumber,
          'comment': draft.comment.trim(),
        },
      },
    );
    final size = result?['sizeBytes'] as num?;
    if (size == null || size <= 0)
      throw StateError('Audio write was not verified.');
    return size.toInt();
  }
}
