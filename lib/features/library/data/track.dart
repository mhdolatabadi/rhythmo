/// Whether the stored file itself carries a cloud track's metadata. After an
/// edit the server rewrites the file's embedded tags in the background.
class EmbeddedTags {
  const EmbeddedTags({
    this.status = EmbeddedTagStatus.original,
    this.version,
    this.unsupportedFields = const [],
  });

  factory EmbeddedTags.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const EmbeddedTags();
    return EmbeddedTags(
      status: switch (json['status']) {
        'pending' => EmbeddedTagStatus.pending,
        'written' => EmbeddedTagStatus.written,
        'failed' => EmbeddedTagStatus.failed,
        'unsupported' => EmbeddedTagStatus.unsupported,
        _ => EmbeddedTagStatus.original,
      },
      version: (json['version'] as num?)?.toInt(),
      unsupportedFields: [
        for (final field in json['unsupportedFields'] as List<dynamic>? ?? [])
          field as String,
      ],
    );
  }

  final EmbeddedTagStatus status;

  /// The metadata version written into the file, once [status] is written.
  final int? version;

  /// Fields the file's format cannot carry; edits to them stay in rhythmo.
  final List<String> unsupportedFields;
}

enum EmbeddedTagStatus { original, pending, written, failed, unsupported }

/// The ReplayGain a cloud track's own tags carry, read once by the server:
/// gains in dB relative to -18 LUFS, peaks as linear amplitude (1 is full
/// scale). Null fields are unknown.
class ReplayGain {
  const ReplayGain({
    this.trackGainDb,
    this.trackPeak,
    this.albumGainDb,
    this.albumPeak,
  });

  static ReplayGain? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    double? number(String key) => (json[key] as num?)?.toDouble();
    return ReplayGain(
      trackGainDb: number('trackGainDb'),
      trackPeak: number('trackPeak'),
      albumGainDb: number('albumGainDb'),
      albumPeak: number('albumPeak'),
    );
  }

  final double? trackGainDb;
  final double? trackPeak;
  final double? albumGainDb;
  final double? albumPeak;
}

class Track {
  const Track({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.composer,
    this.genre,
    this.year,
    this.trackNumber,
    this.discNumber,
    this.comment,
    required this.contentType,
    required this.sizeBytes,
    this.fileName,
    this.sourceUri,
    this.source,
    this.sharedVia,
    this.addedBy,
    this.viaPlaylist,
    this.fromStore = false,
    this.published = false,
    this.publishReview,
    this.likeCount = 0,
    this.liked = false,
    this.version = 1,
    this.embeddedTags = const EmbeddedTags(),
    this.replayGain,
  });

  /// A song in the public store (#243): [id] is the store's own id for it,
  /// it plays without an account, and whose copy it is is never known.
  factory Track.fromStoreJson(Map<String, dynamic> json) => Track(
        id: json['id'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String?,
        album: json['album'] as String?,
        albumArtist: json['albumArtist'] as String?,
        composer: json['composer'] as String?,
        genre: json['genre'] as String?,
        year: (json['year'] as num?)?.toInt(),
        trackNumber: (json['trackNumber'] as num?)?.toInt(),
        discNumber: (json['discNumber'] as num?)?.toInt(),
        contentType: json['contentType'] as String,
        sizeBytes: (json['sizeBytes'] as num).toInt(),
        fromStore: true,
        replayGain:
            ReplayGain.fromJson(json['replayGain'] as Map<String, dynamic>?),
        published: json['published'] == true,
        likeCount: (json['likeCount'] as num?)?.toInt() ?? 0,
        liked: json['liked'] == true,
      );

  /// [viaPlaylist] is the collaborative playlist a track someone else added
  /// was listed in; it is then played through that playlist.
  factory Track.fromJson(Map<String, dynamic> json,
          {String? sharedVia, String? viaPlaylist}) =>
      Track(
        id: json['id'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String?,
        album: json['album'] as String?,
        albumArtist: json['albumArtist'] as String?,
        composer: json['composer'] as String?,
        genre: json['genre'] as String?,
        year: (json['year'] as num?)?.toInt(),
        trackNumber: (json['trackNumber'] as num?)?.toInt(),
        discNumber: (json['discNumber'] as num?)?.toInt(),
        comment: json['comment'] as String?,
        contentType: json['contentType'] as String,
        sizeBytes: (json['sizeBytes'] as num).toInt(),
        fileName: json['fileName'] as String?,
        source: json['source'] as String?,
        sharedVia: sharedVia,
        addedBy: json['addedBy'] as String?,
        viaPlaylist: json['addedBy'] == null ? null : viaPlaylist,
        version: (json['version'] as num?)?.toInt() ?? 1,
        embeddedTags: EmbeddedTags.fromJson(
            json['embeddedTags'] as Map<String, dynamic>?),
        replayGain:
            ReplayGain.fromJson(json['replayGain'] as Map<String, dynamic>?),
        published: json['published'] == true,
        publishReview: json['publishReview'] as String?,
        likeCount: (json['likeCount'] as num?)?.toInt() ?? 0,
        liked: json['liked'] == true,
      );

  final String id;
  final String title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? composer;
  final String? genre;
  final int? year;
  final int? trackNumber;
  final int? discNumber;
  final String? comment;
  final String contentType;
  final int sizeBytes;

  /// The server's metadata version; an edit must be based on the latest one
  /// or the server rejects it as a conflict.
  final int version;

  /// Whether the stored file's own tags match this metadata yet.
  final EmbeddedTags embeddedTags;

  /// Loudness from the file's tags, for normalization; null when unknown.
  final ReplayGain? replayGain;

  /// This track with the shared-playlist context of [other] kept, for
  /// replacing a stale copy after the server returns fresh metadata.
  Track keepingContextOf(Track other) => Track(
        id: id,
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
        contentType: contentType,
        sizeBytes: sizeBytes,
        fileName: fileName,
        sourceUri: other.sourceUri ?? sourceUri,
        source: source,
        sharedVia: other.sharedVia,
        addedBy: other.addedBy,
        viaPlaylist: other.viaPlaylist,
        fromStore: other.fromStore,
        published: published,
        publishReview: publishReview,
        likeCount: likeCount,
        liked: liked,
        version: version,
        embeddedTags: embeddedTags,
        replayGain: replayGain,
      );

  /// Original filename when the platform exposes it. Local uploads use this
  /// to preserve the extension for format detection.
  final String? fileName;

  /// Present only for audio discovered on this device (usually content://).
  final Uri? sourceUri;

  bool get isLocal => sourceUri != null;

  /// Where a cloud track came from: `upload`, or the bot that imported it
  /// (`bale`, `telegram`).
  final String? source;

  /// The share token of the playlist this track was opened from, when it is
  /// someone else's track; it is then played through that link.
  final String? sharedVia;

  /// In a collaborative playlist, who added this track when it isn't the
  /// viewer's own (their email, masked); null for the viewer's own tracks.
  final String? addedBy;

  /// The playlist someone else's track is played through, see [addedBy].
  final String? viaPlaylist;

  /// Whether this is a public store song, played through the store.
  final bool fromStore;

  /// In the owner's library: whether they published it to the store (#284).
  final bool published;

  /// In the owner's library: `pending` while publishing waits for an
  /// admin's approval, `rejected` after an admin turned it down (#322).
  final String? publishReview;

  /// Where publishing this track stands, for its owner.
  PublishState get publishState => published
      ? PublishState.published
      : switch (publishReview) {
          'pending' => PublishState.pending,
          'rejected' => PublishState.rejected,
          _ => PublishState.private,
        };

  /// How many listeners like the song: shown to the owner on their own
  /// tracks, and to everyone on store songs.
  final int likeCount;

  /// Whether the listener likes it, as the server last said.
  final bool liked;

  /// Whether this plays without an account: a file on this device, a song
  /// from a shared playlist link, or a store song.
  bool get playsWithoutAccount => isLocal || sharedVia != null || fromStore;

  /// This cloud track, played from the identical file at [uri] on this
  /// device.
  Track withDeviceCopy(Uri uri) => Track(
        id: id,
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
        contentType: contentType,
        sizeBytes: sizeBytes,
        fileName: fileName,
        sourceUri: uri,
        source: source,
        sharedVia: sharedVia,
        addedBy: addedBy,
        viaPlaylist: viaPlaylist,
        fromStore: fromStore,
        published: published,
        publishReview: publishReview,
        likeCount: likeCount,
        liked: liked,
        version: version,
        // The same file, so the same loudness.
        replayGain: replayGain,
      );

  /// The messenger a bot imported this track from, for people; null for
  /// tracks uploaded in the app.
  String? get importedFrom => switch (source) {
        'bale' => 'بله',
        'telegram' => 'تلگرام',
        _ => null,
      };
}

/// Where publishing a track to the store stands (#322): accounts that are
/// not verified only ask, and an admin approves or rejects the request.
enum PublishState { private, pending, rejected, published }
