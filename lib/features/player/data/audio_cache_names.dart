import 'package:rhythmo/features/library/data/track.dart';

const _extensions = {
  'audio/mpeg': 'mp3',
  'audio/mp4': 'm4a',
  'audio/aac': 'aac',
  'audio/flac': 'flac',
  'audio/ogg': 'ogg',
  'audio/wav': 'wav',
  'audio/webm': 'webm',
};

/// The cache file name of [track]'s stored file: its ID plus the revision of
/// the bytes, never the presigned URL, which changes on every request. A
/// metadata edit rewrites the stored file's tags into a new revision, so the
/// edited track is fetched again instead of playing stale bytes (#252).
String cacheFileName(Track track) {
  final extension = _extensions[track.contentType] ?? 'audio';
  return '${track.id}.r${track.embeddedTags.version ?? 0}.$extension';
}
