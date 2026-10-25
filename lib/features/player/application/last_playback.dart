import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/play_queue.dart';

/// How many upcoming tracks are remembered with the last played one.
const lastPlaybackQueueLimit = 50;

/// What was playing when the app was last closed: shown again in the mini
/// player on the next launch, paused, ready to continue where it stopped.
class LastPlayback {
  const LastPlayback({
    required this.track,
    this.upcoming = const [],
    this.position = Duration.zero,
    this.duration,
    this.shuffle = false,
    this.repeat = QueueRepeat.off,
  });

  final Track track;

  /// The tracks queued after [track], in play order.
  final List<Track> upcoming;
  final Duration position;
  final Duration? duration;
  final bool shuffle;
  final QueueRepeat repeat;

  /// Reads a saved snapshot; null when it is missing or unreadable.
  static LastPlayback? fromJson(Object? json) {
    if (json is! Map) return null;
    final track = _trackFromJson(json['track']);
    if (track == null) return null;
    final upcoming = json['upcoming'];
    final positionMs = json['positionMs'];
    final durationMs = json['durationMs'];
    final duration = durationMs is int && durationMs > 0
        ? Duration(milliseconds: durationMs)
        : null;
    var position = positionMs is int && positionMs > 0
        ? Duration(milliseconds: positionMs)
        : Duration.zero;
    if (duration != null && position > duration) position = duration;
    return LastPlayback(
      track: track,
      upcoming: [
        if (upcoming is List)
          for (final item in upcoming.take(lastPlaybackQueueLimit))
            if (_trackFromJson(item) case final track?) track,
      ],
      position: position,
      duration: duration,
      shuffle: json['shuffle'] == true,
      repeat: QueueRepeat.values.firstWhere(
        (value) => value.name == json['repeat'],
        orElse: () => QueueRepeat.off,
      ),
    );
  }

  Map<String, Object?> toJson() => {
        'track': _trackToJson(track),
        'upcoming': [
          for (final track in upcoming.take(lastPlaybackQueueLimit))
            _trackToJson(track),
        ],
        'positionMs': position.inMilliseconds,
        'durationMs': duration?.inMilliseconds,
        'shuffle': shuffle,
        'repeat': repeat.name,
      };

  /// Whether [track] can be played again after a restart. A file the
  /// browser handed over is only reachable while the page stays open.
  static bool canRestore(Track track) {
    final scheme = track.sourceUri?.scheme;
    return scheme != 'blob' && scheme != 'data';
  }
}

Map<String, Object?> _trackToJson(Track track) => {
      'id': track.id,
      'title': track.title,
      'artist': track.artist,
      'album': track.album,
      'albumArtist': track.albumArtist,
      'contentType': track.contentType,
      'sizeBytes': track.sizeBytes,
      'fileName': track.fileName,
      'sourceUri': track.sourceUri?.toString(),
      'source': track.source,
      'sharedVia': track.sharedVia,
      'addedBy': track.addedBy,
      'viaPlaylist': track.viaPlaylist,
      'fromStore': track.fromStore,
      'version': track.version,
      'replayGain': switch (track.replayGain) {
        final gain? => {
            'trackGainDb': gain.trackGainDb,
            'trackPeak': gain.trackPeak,
            'albumGainDb': gain.albumGainDb,
            'albumPeak': gain.albumPeak,
          },
        null => null,
      },
    };

Track? _trackFromJson(Object? json) {
  if (json is! Map) return null;
  final id = json['id'];
  final title = json['title'];
  final contentType = json['contentType'];
  final sizeBytes = json['sizeBytes'];
  if (id is! String ||
      title is! String ||
      contentType is! String ||
      sizeBytes is! int) {
    return null;
  }
  String? text(String key) => json[key] is String ? json[key] as String : null;
  final sourceUri = text('sourceUri');
  final replayGain = json['replayGain'];
  final track = Track(
    id: id,
    title: title,
    artist: text('artist'),
    album: text('album'),
    albumArtist: text('albumArtist'),
    contentType: contentType,
    sizeBytes: sizeBytes,
    fileName: text('fileName'),
    sourceUri: sourceUri == null ? null : Uri.tryParse(sourceUri),
    source: text('source'),
    sharedVia: text('sharedVia'),
    addedBy: text('addedBy'),
    viaPlaylist: text('viaPlaylist'),
    fromStore: json['fromStore'] == true,
    version: json['version'] is int ? json['version'] as int : 1,
    replayGain: replayGain is Map
        ? ReplayGain.fromJson(replayGain.cast<String, dynamic>())
        : null,
  );
  return LastPlayback.canRestore(track) ? track : null;
}

/// Where the [LastPlayback] is kept between launches.
abstract interface class LastPlaybackStore {
  Future<LastPlayback?> read();

  /// Saves [playback], or forgets it when null.
  Future<void> write(LastPlayback? playback);
}

/// Keeps the last playback on this device, next to the session token.
class SecureLastPlaybackStore implements LastPlaybackStore {
  SecureLastPlaybackStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'rhythmo.last_playback';

  final FlutterSecureStorage _storage;

  @override
  Future<LastPlayback?> read() async {
    final raw = await _storage.read(key: _key);
    return raw == null ? null : LastPlayback.fromJson(jsonDecode(raw));
  }

  @override
  Future<void> write(LastPlayback? playback) => playback == null
      ? _storage.delete(key: _key)
      : _storage.write(key: _key, value: jsonEncode(playback.toJson()));
}

class MemoryLastPlaybackStore implements LastPlaybackStore {
  MemoryLastPlaybackStore([this.playback]);

  LastPlayback? playback;

  @override
  Future<LastPlayback?> read() async => playback;

  @override
  Future<void> write(LastPlayback? playback) async => this.playback = playback;
}
