import 'package:rhythmo/features/admin/data/admin_account.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:rhythmo/features/auth/data/auth_models.dart';
import 'package:rhythmo/features/bots/data/messenger_bot.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/link_import/data/link_import.dart';
import 'package:rhythmo/features/lyrics/data/lyrics.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';
import 'package:rhythmo/features/upload/data/upload_models.dart';
import 'package:rhythmo/features/store/data/store_catalog.dart';
import 'package:rhythmo/features/likes/data/likes.dart';

class ApiException implements Exception {
  const ApiException(this.message,
      {this.statusCode, this.code, this.details = const {}});

  final String message;
  final int? statusCode;

  /// Machine-readable error from the API body, for example `email_taken`.
  final String? code;

  /// The rest of the error body, for example the invalid `field`, or the
  /// latest `track` on a version conflict.
  final Map<String, dynamic> details;

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}

abstract interface class AuthApi {
  Future<AuthSession> register(String email, String password);
  Future<AuthSession> login(String email, String password);
  Future<AuthUser> me(String token);

  /// Deletes the signed-in account and everything in it for good. The
  /// password is checked again; a wrong one fails with `invalid_password`.
  Future<void> deleteAccount(String token, String password);

  /// Ends every session of the account, on every device, and returns a new
  /// session so this device stays signed in.
  Future<AuthSession> revokeSessions(String token);

  /// Mails a new email verification code, replacing the last one, and
  /// returns when it expires.
  Future<DateTime> sendEmailCode(String token);

  /// Confirms the account's address with the emailed [code].
  Future<AuthUser> verifyEmail(String token, String code);

  /// Corrects the address of an account that hasn't verified it yet; a new
  /// code goes to the new address unless [codeSent] is false.
  Future<({AuthUser user, bool codeSent})> changeEmail(
      String token, String email);
}

/// A short-lived URL that saves one cloud track as a file under its edited
/// name; the server sends `Content-Disposition` with [fileName].
class DownloadLink {
  const DownloadLink({
    required this.url,
    required this.expiresAt,
    required this.fileName,
    required this.version,
    required this.tagsUpToDate,
  });

  factory DownloadLink.fromJson(Map<String, dynamic> json) => DownloadLink(
        url: Uri.parse(json['url'] as String),
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        fileName: json['fileName'] as String,
        version: (json['version'] as num).toInt(),
        tagsUpToDate: json['tagsUpToDate'] == true,
      );

  final Uri url;
  final DateTime expiresAt;
  final String fileName;

  /// The track's metadata version the file is for; a saved copy for another
  /// version is out of date.
  final int version;

  /// False when the file's embedded tags cannot match the saved metadata
  /// (its format has no tag writer, or rewriting failed).
  final bool tagsUpToDate;
}

/// A short-lived URL for playing one track.
class StreamLink {
  const StreamLink(this.url, this.expiresAt);

  final Uri url;
  final DateTime expiresAt;
}

class TrackLibrary {
  const TrackLibrary({
    required this.tracks,
    required this.usedBytes,
    required this.limitBytes,
    this.importsInProgress = 0,
  });

  final List<Track> tracks;
  final int usedBytes;
  final int limitBytes;

  /// Bot imports not in [tracks] yet.
  final int importsInProgress;
}

abstract interface class TracksApi {
  Future<TrackLibrary> listTracks(String token);
  Future<StreamLink> streamLink(String token, String trackId);

  /// One of the user's own cloud tracks, as the server has it now.
  Future<Track> getTrack(String token, String trackId);

  /// A link to save a cloud track. While an edit's embedded tags are still
  /// being written this fails with HTTP 409 `tags_pending`; try again a few
  /// seconds later rather than saving the file with old tags.
  Future<DownloadLink> downloadLink(String token, String trackId);
  Future<UploadTicket> createUpload(
      String token, String fileName, int sizeBytes);
  Future<Track> completeUpload(String token, String trackId);
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
  });
  Future<void> deleteTrack(String token, String trackId);

  /// A playback link for a track in a playlist shared with [shareToken].
  Future<StreamLink> sharedStreamLink(
      String? token, String shareToken, String trackId);

  /// A playback link for a track another member added to a collaborative
  /// playlist the user belongs to.
  Future<StreamLink> playlistStreamLink(
      String token, String playlistId, String trackId);

  /// A playback link for a public store song; no account is needed.
  Future<StreamLink> storeStreamLink(String? token, String id);
}

abstract interface class PlaylistsApi {
  Future<List<Playlist>> listPlaylists(String token);
  Future<Playlist> getPlaylist(String token, String playlistId);
  Future<Playlist> createPlaylist(String token, String name);
  Future<Playlist> renamePlaylist(String token, String playlistId, String name);
  Future<Playlist> replacePlaylistTracks(
      String token, String playlistId, List<String> trackIds);
  Future<void> deletePlaylist(String token, String playlistId);

  /// Shares the playlist by link and returns its share token; sharing again
  /// returns the same one. [public] lists it among the popular playlists
  /// (true) or keeps it to people with the link (false); null keeps what
  /// it was.
  Future<PlaylistShare> sharePlaylist(String token, String playlistId,
      {bool? public});

  /// Stops sharing; the old link stops working.
  Future<void> unsharePlaylist(String token, String playlistId);
  Future<SharedPlaylist> getSharedPlaylist(String? token, String shareToken);

  /// Copies a shared playlist and its tracks into the caller's account.
  Future<Playlist> saveSharedPlaylist(String token, String shareToken);

  /// Likes or unlikes a shared playlist; doing it twice is the same as once.
  Future<PlaylistLikes> setPlaylistLike(
      String token, String shareToken, bool liked);

  /// Public playlists, most liked first.
  Future<List<PublicPlaylist>> listPublicPlaylists(String? token);

  /// An admin takes a public playlist out of the popular list, or puts it
  /// back. The playlist and its link stay as they are.
  Future<void> setPopularPlaylistHidden(
      String token, String shareToken, bool hidden);

  /// An admin deletes a shared playlist, whoever owns it. Its tracks stay
  /// in their owners' libraries.
  Future<void> deletePublicPlaylist(String token, String shareToken);

  /// Makes a new collaboration link and returns its token; the old link
  /// stops working.
  Future<String> createCollabLink(String token, String playlistId);

  /// Turns the collaboration link off; members stay.
  Future<void> revokeCollabLink(String token, String playlistId);

  /// Joins the playlist with this collaboration link.
  Future<Playlist> joinPlaylist(String token, String collabToken);

  /// The owner takes a member out, with the tracks they added.
  Future<void> removePlaylistMember(
      String token, String playlistId, String memberId);

  /// Leaves a collaborative playlist, taking one's tracks out of it.
  Future<void> leavePlaylist(String token, String playlistId);
}

/// A playlist's share link as its owner set it. [pending] is true while a
/// request to list it publicly waits for an admin (#322).
typedef PlaylistShare = ({String shareToken, bool isPublic, bool pending});

abstract interface class BotsApi {
  Future<List<MessengerBot>> listBots(String token);
  Future<BotLinkCode> createBotLinkCode(String token);

  /// Has the bot post a track into the account's linked chats.
  Future<void> sendTrackToBot(String token, String provider, String trackId);
}

/// Song lyrics, which the server looks up on LRCLIB; the app never calls
/// LRCLIB itself.
abstract interface class TranscriptionApi {
  Future<Map<String, dynamic>> transcription(String token, String trackId,
      {bool start = false});
}

abstract interface class LyricsApi {
  /// The lyrics of [track], asked for the way it is played: the user's own
  /// track, someone else's through its collaborative playlist, or through
  /// a shared link (where [token] may be null on a public playlist).
  /// [duration] is how long the track plays, which helps matching.
  Future<TrackLyrics> trackLyrics(String? token, Track track,
      {Duration? duration});

  /// Other LRCLIB entries the track's owner may pick: for the track itself,
  /// or for the free text in [query].
  Future<List<LyricsMatch>> lyricsCandidates(String token, String trackId,
      {String query = ''});

  /// Makes LRCLIB entry [lrclibId] the lyrics of the owner's track.
  Future<TrackLyrics> chooseLyrics(String token, String trackId, int lrclibId);
}

/// A song «این آهنگ چیه؟» recognised, among the tracks the listener may
/// play.
class SongMatch {
  const SongMatch({
    required this.track,
    required this.confidence,
    required this.source,
  });

  factory SongMatch.fromJson(Map<String, dynamic> json) {
    final storeTrack = json['storeTrack'];
    if (json['source'] == 'store' && storeTrack is Map<String, dynamic>) {
      return SongMatch(
        track: Track.fromStoreJson(storeTrack),
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
        source: SongMatchSource.store,
      );
    }
    final shareToken = json['shareToken'] as String?;
    return SongMatch(
      track: Track.fromJson(json['track'] as Map<String, dynamic>,
          sharedVia: shareToken, viaPlaylist: json['playlistId'] as String?),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      source: switch (json['source']) {
        'playlist' => SongMatchSource.playlist,
        'public' => SongMatchSource.public,
        _ => SongMatchSource.library,
      },
    );
  }

  /// The track, ready to play through the way it was found.
  final Track track;

  /// How sure the match is, from 0 to 1.
  final double confidence;
  final SongMatchSource source;

  /// Whether the song is someone else's and can be added to the library.
  bool get canSave => source != SongMatchSource.library;
}

/// Where a recognised song was found: the listener's own library, a
/// collaborative playlist they belong to, a public playlist, or (for a
/// listener without an account) the public store.
enum SongMatchSource { library, playlist, public, store }

/// «این آهنگ چیه؟»: recognises a recorded snippet among the songs in
/// rhythmo the listener may play.
abstract interface class IdentifyApi {
  /// The best match for [wav], or null when nothing matched. Without a
  /// [token] only the public store is searched.
  Future<SongMatch?> identifySong(String? token, Uint8List wav);

  /// Copies a song found in someone else's playlist into the library.
  Future<Track> saveIdentifiedSong(String token, SongMatch match);
}

/// The account's recently played tracks, the same on every device.
abstract interface class HistoryApi {
  /// Tracks the user played, most recent first, each once. Someone else's
  /// track in a collaborative playlist comes with that playlist, to be
  /// played through it.
  Future<List<Track>> listHistory(String token, {int? limit});

  /// Adds a play the app counted as a real listen.
  Future<void> recordPlay(String token, String trackId, {String? playlistId});

  /// Forgets everything the user played.
  Future<void> clearHistory(String token);
}

class ApiClient
    implements
        AuthApi,
        TracksApi,
        HistoryApi,
        PlaylistsApi,
        BotsApi,
        LinkImportsApi,
        LyricsApi,
        TranscriptionApi,
        IdentifyApi,
        StoreApi,
        LikesApi,
        AdminApi {
  ApiClient(this.baseUri, {http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  static const _timeout = Duration(seconds: 15);

  final Uri baseUri;
  final http.Client _httpClient;

  @override
  Future<List<PendingPublication>> listPendingPublications(String token) async {
    final body = await _send('GET', '/api/v1/admin/publications', token: token);
    return [
      for (final json in body['publications'] as List<dynamic>)
        PendingPublication.fromJson(json as Map<String, dynamic>),
    ];
  }

  @override
  Future<void> reviewPublication(
      String token, PendingPublication publication, bool approved) async {
    final kind =
        publication.kind == PublicationKind.playlist ? 'playlists' : 'tracks';
    await _send('PATCH',
        '/api/v1/admin/publications/$kind/${Uri.encodeComponent(publication.id)}',
        token: token, body: {'approved': approved});
  }

  @override
  Future<AdminAccountPage> listAccounts(String token,
      {String query = '', int offset = 0}) async {
    final body = await _send('GET',
        '/api/v1/admin/accounts?q=${Uri.encodeQueryComponent(query)}&offset=$offset',
        token: token);
    return (
      accounts: [
        for (final json in body['accounts'] as List<dynamic>)
          AdminAccount.fromJson(json as Map<String, dynamic>),
      ],
      hasMore: body['hasMore'] == true,
    );
  }

  @override
  Future<AdminAccount> setAccountVerification(
      String token, String accountId, bool verified) async {
    final body = await _send('PATCH',
        '/api/v1/admin/accounts/${Uri.encodeComponent(accountId)}/verification',
        token: token, body: {'verified': verified});
    return AdminAccount.fromJson(body);
  }

  Future<void> checkHealth() async {
    final body = await _send('GET', '/api/v1/health');
    if (body['status'] != 'ok') {
      throw const ApiException('Server returned an invalid health response.');
    }
  }

  @override
  Future<AuthSession> register(String email, String password) async {
    final body = await _send('POST', '/api/v1/auth/register',
        body: {'email': email, 'password': password});
    return AuthSession.fromJson(body);
  }

  @override
  Future<AuthSession> login(String email, String password) async {
    final body = await _send('POST', '/api/v1/auth/login',
        body: {'email': email, 'password': password});
    return AuthSession.fromJson(body);
  }

  @override
  Future<AuthUser> me(String token) async {
    final body = await _send('GET', '/api/v1/me', token: token);
    return AuthUser.fromJson(body);
  }

  @override
  Future<void> deleteAccount(String token, String password) async {
    await _send('DELETE', '/api/v1/me',
        token: token, body: {'password': password}, expectBody: false);
  }

  @override
  Future<AuthSession> revokeSessions(String token) async {
    final body =
        await _send('POST', '/api/v1/auth/sessions/revoke', token: token);
    return AuthSession.fromJson(body);
  }

  @override
  Future<DateTime> sendEmailCode(String token) async {
    final body = await _send('POST', '/api/v1/me/email/code', token: token);
    return DateTime.parse(body['expiresAt'] as String);
  }

  @override
  Future<AuthUser> verifyEmail(String token, String code) async {
    final body = await _send('POST', '/api/v1/me/email/verify',
        token: token, body: {'code': code});
    return AuthUser.fromJson(body);
  }

  @override
  Future<({AuthUser user, bool codeSent})> changeEmail(
      String token, String email) async {
    final body = await _send('PUT', '/api/v1/me/email',
        token: token, body: {'email': email});
    return (
      user: AuthUser.fromJson(body['user'] as Map<String, dynamic>),
      codeSent: body['codeSent'] == true,
    );
  }

  @override
  Future<TrackLibrary> listTracks(String token) async {
    final body = await _send('GET', '/api/v1/tracks', token: token);
    final storage = body['storage'] as Map<String, dynamic>;
    return TrackLibrary(
      tracks: (body['tracks'] as List<dynamic>)
          .map((json) => Track.fromJson(json as Map<String, dynamic>))
          .toList(),
      usedBytes: (storage['usedBytes'] as num).toInt(),
      limitBytes: (storage['limitBytes'] as num).toInt(),
      importsInProgress: (body['importsInProgress'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<Track> getTrack(String token, String trackId) async {
    final body = await _send(
        'GET', '/api/v1/tracks/${Uri.encodeComponent(trackId)}',
        token: token);
    return Track.fromJson(body);
  }

  @override
  Future<DownloadLink> downloadLink(String token, String trackId) async {
    final body = await _send(
        'GET', '/api/v1/tracks/${Uri.encodeComponent(trackId)}/download',
        token: token);
    return DownloadLink.fromJson(body);
  }

  @override
  Future<StreamLink> streamLink(String token, String trackId) async {
    final body =
        await _send('GET', '/api/v1/tracks/$trackId/stream', token: token);
    return StreamLink(
      Uri.parse(body['url'] as String),
      DateTime.parse(body['expiresAt'] as String),
    );
  }

  @override
  Future<UploadTicket> createUpload(
      String token, String fileName, int sizeBytes) async {
    final body = await _send('POST', '/api/v1/tracks/uploads',
        token: token, body: {'fileName': fileName, 'sizeBytes': sizeBytes});
    return UploadTicket.fromJson(body);
  }

  @override
  Future<Track> completeUpload(String token, String trackId) async {
    final body =
        await _send('POST', '/api/v1/tracks/$trackId/complete', token: token);
    return Track.fromJson(body);
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
    final body =
        await _send('PATCH', '/api/v1/tracks/$trackId', token: token, body: {
      'version': version,
      if (fileName != null) 'fileName': fileName,
      'title': title,
      'artist': artist,
      'album': album,
      'albumArtist': albumArtist,
      'composer': composer,
      'genre': genre,
      'year': year,
      'trackNumber': trackNumber,
      'discNumber': discNumber,
      'comment': comment,
    });
    return Track.fromJson(body);
  }

  @override
  Future<void> deleteTrack(String token, String trackId) async {
    await _send('DELETE', '/api/v1/tracks/$trackId',
        token: token, expectBody: false);
  }

  @override
  Future<List<Playlist>> listPlaylists(String token) async {
    final body = await _send('GET', '/api/v1/playlists', token: token);
    return (body['playlists'] as List<dynamic>)
        .map((json) => Playlist.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<PlaylistShare> sharePlaylist(String token, String playlistId,
      {bool? public}) async {
    final body = await _send(
        'POST', '/api/v1/playlists/${Uri.encodeComponent(playlistId)}/share',
        token: token, body: public == null ? null : {'public': public});
    return (
      shareToken: body['shareToken'] as String,
      isPublic: body['public'] == true,
      pending: body['publicReview'] == 'pending',
    );
  }

  @override
  Future<PlaylistLikes> setPlaylistLike(
      String token, String shareToken, bool liked) async {
    final body = await _send(liked ? 'PUT' : 'DELETE',
        '/api/v1/shared-playlists/${Uri.encodeComponent(shareToken)}/like',
        token: token);
    return PlaylistLikes.fromJson(body);
  }

  @override
  Future<List<PublicPlaylist>> listPublicPlaylists(String? token) async {
    final body = await _send('GET', '/api/v1/public-playlists', token: token);
    return [
      for (final json in body['playlists'] as List<dynamic>)
        PublicPlaylist.fromJson(json as Map<String, dynamic>),
    ];
  }

  @override
  Future<void> setPopularPlaylistHidden(
      String token, String shareToken, bool hidden) async {
    await _send('PATCH',
        '/api/v1/admin/public-playlists/${Uri.encodeComponent(shareToken)}',
        token: token, body: {'hidden': hidden});
  }

  @override
  Future<void> deletePublicPlaylist(String token, String shareToken) async {
    await _send('DELETE',
        '/api/v1/admin/public-playlists/${Uri.encodeComponent(shareToken)}',
        token: token, expectBody: false);
  }

  @override
  Future<void> unsharePlaylist(String token, String playlistId) async {
    await _send(
        'DELETE', '/api/v1/playlists/${Uri.encodeComponent(playlistId)}/share',
        token: token, expectBody: false);
  }

  @override
  Future<SharedPlaylist> getSharedPlaylist(
      String? token, String shareToken) async {
    final body = await _send(
        'GET', '/api/v1/shared-playlists/${Uri.encodeComponent(shareToken)}',
        token: token);
    return SharedPlaylist.fromJson(shareToken, body);
  }

  @override
  Future<Playlist> saveSharedPlaylist(String token, String shareToken) async {
    final body = await _send('POST',
        '/api/v1/shared-playlists/${Uri.encodeComponent(shareToken)}/save',
        token: token);
    return Playlist.fromJson(body);
  }

  @override
  Future<StreamLink> sharedStreamLink(
      String? token, String shareToken, String trackId) async {
    final body = await _send(
        'GET',
        '/api/v1/shared-playlists/${Uri.encodeComponent(shareToken)}'
            '/tracks/${Uri.encodeComponent(trackId)}/stream',
        token: token);
    return StreamLink(Uri.parse(body['url'] as String),
        DateTime.parse(body['expiresAt'] as String));
  }

  @override
  Future<StreamLink> playlistStreamLink(
      String token, String playlistId, String trackId) async {
    final body = await _send(
        'GET',
        '/api/v1/playlists/${Uri.encodeComponent(playlistId)}'
            '/tracks/${Uri.encodeComponent(trackId)}/stream',
        token: token);
    return StreamLink(Uri.parse(body['url'] as String),
        DateTime.parse(body['expiresAt'] as String));
  }

  @override
  Future<StreamLink> storeStreamLink(String? token, String id) async {
    final body = await _send(
        'GET', '/api/v1/store/tracks/${Uri.encodeComponent(id)}/stream',
        token: token);
    return StreamLink(Uri.parse(body['url'] as String),
        DateTime.parse(body['expiresAt'] as String));
  }

  /// [path] with the non-empty [query] parameters.
  static String _withQuery(String path, Map<String, String?> query) {
    final kept = {
      for (final entry in query.entries)
        if (entry.value != null && entry.value!.isNotEmpty)
          entry.key: entry.value!,
    };
    return kept.isEmpty ? path : '$path?${Uri(queryParameters: kept).query}';
  }

  @override
  Future<StorePage<Track>> storeTracks(
    String? token, {
    String query = '',
    String? artist,
    String? album,
    int offset = 0,
  }) async {
    final body = await _send(
        'GET',
        _withQuery('/api/v1/store/tracks', {
          'q': query.trim(),
          'artist': artist,
          'album': album,
          if (offset > 0) 'offset': '$offset',
        }),
        token: token);
    return StorePage(
      [
        for (final json in body['tracks'] as List<dynamic>)
          Track.fromStoreJson(json as Map<String, dynamic>),
      ],
      hasMore: body['hasMore'] == true,
    );
  }

  @override
  Future<StorePage<Track>> storeRanked(String? token, StoreRanking ranking,
      {int offset = 0}) async {
    final body = await _send(
        'GET',
        _withQuery('/api/v1/store/${ranking.wire}',
            {'limit': '20', if (offset > 0) 'offset': '$offset'}),
        token: token);
    return StorePage(
      [
        for (final json in body['tracks'] as List<dynamic>)
          Track.fromStoreJson(json as Map<String, dynamic>),
      ],
      hasMore: body['hasMore'] == true,
    );
  }

  @override
  Future<Track> storeTrack(String? token, String id) async {
    final body = await _send(
        'GET', '/api/v1/store/tracks/${Uri.encodeComponent(id)}',
        token: token);
    return Track.fromStoreJson(body);
  }

  @override
  Future<StorePage<StoreArtist>> storeArtists(String? token,
      {String query = '', int offset = 0}) async {
    final body = await _send(
        'GET',
        _withQuery('/api/v1/store/artists',
            {'q': query.trim(), if (offset > 0) 'offset': '$offset'}),
        token: token);
    return StorePage(
      [
        for (final json in body['artists'] as List<dynamic>)
          StoreArtist.fromJson(json as Map<String, dynamic>),
      ],
      hasMore: body['hasMore'] == true,
    );
  }

  @override
  Future<StorePage<StoreAlbum>> storeAlbums(String? token,
      {String query = '', String? artist, int offset = 0}) async {
    final body = await _send(
        'GET',
        _withQuery('/api/v1/store/albums', {
          'q': query.trim(),
          'artist': artist,
          if (offset > 0) 'offset': '$offset',
        }),
        token: token);
    return StorePage(
      [
        for (final json in body['albums'] as List<dynamic>)
          StoreAlbum.fromJson(json as Map<String, dynamic>),
      ],
      hasMore: body['hasMore'] == true,
    );
  }

  @override
  Future<Track> saveStoreTrack(String token, String id) async {
    final body = await _send(
        'POST', '/api/v1/store/tracks/${Uri.encodeComponent(id)}/save',
        token: token);
    return Track.fromJson(body);
  }

  @override
  Future<void> reportStoreTrack(
      String token, String id, StoreReportReason reason,
      {String? details}) async {
    await _send(
        'POST', '/api/v1/store/tracks/${Uri.encodeComponent(id)}/report',
        token: token,
        body: {
          'reason': reason.wire,
          if (details != null && details.trim().isNotEmpty)
            'details': details.trim(),
        },
        expectBody: false);
  }

  @override
  Future<LikeState> setLike(String token, Track track, bool liked) async {
    final id = Uri.encodeComponent(track.id);
    final body = await _send(
        liked ? 'PUT' : 'DELETE',
        track.fromStore
            ? '/api/v1/store/tracks/$id/like'
            : '/api/v1/tracks/$id/like',
        token: token);
    return LikeState.fromJson(body);
  }

  @override
  Future<List<LikedSong>> likedSongs(String token) async {
    final songs = <LikedSong>[];
    // A few pages at most; the server keeps the newest likes first.
    for (var page = 0; page < 20; page++) {
      final body = await _send(
          'GET', '/api/v1/likes?limit=100&offset=${songs.length}',
          token: token);
      songs.addAll([
        for (final json in body['songs'] as List<dynamic>)
          LikedSong.fromJson(json as Map<String, dynamic>),
      ]);
      if (body['hasMore'] != true) break;
    }
    return songs;
  }

  @override
  Future<PublishState> setPublished(
      String token, String trackId, bool published) async {
    final body = await _send(published ? 'PUT' : 'DELETE',
        '/api/v1/tracks/${Uri.encodeComponent(trackId)}/published',
        token: token);
    if (body['published'] == true) return PublishState.published;
    return switch (body['review']) {
      'pending' => PublishState.pending,
      'rejected' => PublishState.rejected,
      _ => PublishState.private,
    };
  }

  @override
  Future<String> createCollabLink(String token, String playlistId) async {
    final body = await _send(
        'POST', '/api/v1/playlists/${Uri.encodeComponent(playlistId)}/collab',
        token: token);
    return body['collabToken'] as String;
  }

  @override
  Future<void> revokeCollabLink(String token, String playlistId) async {
    await _send(
        'DELETE', '/api/v1/playlists/${Uri.encodeComponent(playlistId)}/collab',
        token: token, expectBody: false);
  }

  @override
  Future<Playlist> joinPlaylist(String token, String collabToken) async {
    final body = await _send(
        'POST', '/api/v1/collab/${Uri.encodeComponent(collabToken)}/join',
        token: token);
    return Playlist.fromJson(body);
  }

  @override
  Future<void> removePlaylistMember(
      String token, String playlistId, String memberId) async {
    await _send(
        'DELETE',
        '/api/v1/playlists/${Uri.encodeComponent(playlistId)}'
            '/members/${Uri.encodeComponent(memberId)}',
        token: token,
        expectBody: false);
  }

  @override
  Future<void> leavePlaylist(String token, String playlistId) async {
    await _send('DELETE',
        '/api/v1/playlists/${Uri.encodeComponent(playlistId)}/membership',
        token: token, expectBody: false);
  }

  @override
  Future<Playlist> getPlaylist(String token, String playlistId) async {
    final body =
        await _send('GET', '/api/v1/playlists/$playlistId', token: token);
    return Playlist.fromJson(body);
  }

  @override
  Future<Playlist> createPlaylist(String token, String name) async {
    final body = await _send('POST', '/api/v1/playlists',
        token: token, body: {'name': name});
    return Playlist.fromJson(body);
  }

  @override
  Future<Playlist> renamePlaylist(
      String token, String playlistId, String name) async {
    final body = await _send('PUT', '/api/v1/playlists/$playlistId',
        token: token, body: {'name': name});
    return Playlist.fromJson(body);
  }

  @override
  Future<Playlist> replacePlaylistTracks(
      String token, String playlistId, List<String> trackIds) async {
    final body = await _send('PUT', '/api/v1/playlists/$playlistId/tracks',
        token: token, body: {'trackIds': trackIds});
    return Playlist.fromJson(body);
  }

  @override
  Future<void> deletePlaylist(String token, String playlistId) async {
    await _send('DELETE', '/api/v1/playlists/$playlistId',
        token: token, expectBody: false);
  }

  @override
  Future<List<MessengerBot>> listBots(String token) async {
    final body = await _send('GET', '/api/v1/bots', token: token);
    return [
      for (final bot in body['bots'] as List<dynamic>)
        MessengerBot.fromJson(bot as Map<String, dynamic>),
    ];
  }

  @override
  Future<BotLinkCode> createBotLinkCode(String token) async {
    final body = await _send('POST', '/api/v1/bots/link-code', token: token);
    return BotLinkCode.fromJson(body);
  }

  @override
  Future<void> sendTrackToBot(
      String token, String provider, String trackId) async {
    await _send('POST', '/api/v1/bots/${Uri.encodeComponent(provider)}/send',
        token: token, body: {'trackId': trackId}, expectBody: false);
  }

  @override
  Future<List<LinkImportCandidate>> previewLink(
      String token, String url) async {
    final body = await _send('POST', '/api/v1/imports/link/preview',
        token: token,
        body: {'url': url},
        requestTimeout: const Duration(seconds: 90));
    return [
      for (final json in body['candidates'] as List<dynamic>)
        LinkImportCandidate.fromJson(json as Map<String, dynamic>),
    ];
  }

  @override
  Future<LinkImport> importFromLink(String token, String url) async {
    final body = await _send('POST', '/api/v1/imports/link',
        body: {'url': url},
        token: token,
        requestTimeout: const Duration(seconds: 90));
    return LinkImport.fromJson(body);
  }

  @override
  Future<List<LinkImport>> listLinkImports(String token) async {
    final body = await _send('GET', '/api/v1/imports/link', token: token);
    return [
      for (final json in body['imports'] as List<dynamic>)
        LinkImport.fromJson(json as Map<String, dynamic>),
    ];
  }

  @override
  Future<SpotifyImportResult> importSpotify(String token, String url) async {
    final body = await _send('POST', '/api/v1/imports/spotify',
        body: {'url': url}, token: token);
    return SpotifyImportResult.fromJson(body);
  }

  @override
  Future<List<Track>> listHistory(String token, {int? limit}) async {
    final body = await _send('GET',
        limit == null ? '/api/v1/history' : '/api/v1/history?limit=$limit',
        token: token);
    return [
      for (final entry in body['entries'] as List<dynamic>)
        Track.fromJson(
          (entry as Map<String, dynamic>)['track'] as Map<String, dynamic>,
          viaPlaylist: entry['playlistId'] as String?,
        ),
    ];
  }

  @override
  Future<void> recordPlay(String token, String trackId,
      {String? playlistId}) async {
    await _send('POST', '/api/v1/history',
        token: token,
        body: {
          'trackId': trackId,
          if (playlistId != null) 'playlistId': playlistId,
        },
        expectBody: false);
  }

  @override
  Future<void> clearHistory(String token) async {
    await _send('DELETE', '/api/v1/history', token: token, expectBody: false);
  }

  @override
  Future<Map<String, dynamic>> transcription(String token, String trackId,
          {bool start = false}) =>
      _send(start ? 'POST' : 'GET',
          '/api/v1/tracks/${Uri.encodeComponent(trackId)}/transcription',
          token: token);

  @override
  Future<TrackLyrics> trackLyrics(String? token, Track track,
      {Duration? duration}) async {
    final id = Uri.encodeComponent(track.id);
    final shareToken = track.sharedVia;
    final playlistId = track.viaPlaylist;
    final path = shareToken != null
        ? '/api/v1/shared-playlists/${Uri.encodeComponent(shareToken)}'
            '/tracks/$id/lyrics'
        : playlistId != null
            ? '/api/v1/playlists/${Uri.encodeComponent(playlistId)}'
                '/tracks/$id/lyrics'
            : '/api/v1/tracks/$id/lyrics';
    final query = duration == null || duration <= Duration.zero
        ? ''
        : '?durationMs=${duration.inMilliseconds}';
    final body = await _send('GET', '$path$query', token: token);
    return TrackLyrics.fromJson(body);
  }

  @override
  Future<List<LyricsMatch>> lyricsCandidates(String token, String trackId,
      {String query = ''}) async {
    final search = query.trim().isEmpty
        ? ''
        : '?q=${Uri.encodeQueryComponent(query.trim())}';
    final body = await _send('GET',
        '/api/v1/tracks/${Uri.encodeComponent(trackId)}/lyrics/candidates$search',
        token: token);
    return [
      for (final json in body['candidates'] as List<dynamic>)
        LyricsMatch.fromJson(json as Map<String, dynamic>),
    ];
  }

  @override
  Future<TrackLyrics> chooseLyrics(
      String token, String trackId, int lrclibId) async {
    final body = await _send(
        'PUT', '/api/v1/tracks/${Uri.encodeComponent(trackId)}/lyrics',
        token: token, body: {'lrclibId': lrclibId});
    return TrackLyrics.fromJson(body);
  }

  /// Snippets are larger than JSON calls and fingerprinting takes a moment.
  static const _identifyTimeout = Duration(seconds: 45);

  @override
  Future<SongMatch?> identifySong(String? token, Uint8List wav) async {
    final request = http.Request('POST', baseUri.resolve('/api/v1/identify'))
      ..headers['Content-Type'] = 'audio/wav'
      ..bodyBytes = wav;
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    final response = await http.Response.fromStream(
      await _httpClient.send(request).timeout(_identifyTimeout),
    );
    final decoded = _decode(response.body);
    if (response.statusCode != 200 || decoded == null) {
      final code = decoded?['error'];
      throw ApiException(
        'Server returned HTTP ${response.statusCode}.',
        statusCode: response.statusCode,
        code: code is String ? code : null,
        details: decoded ?? const {},
      );
    }
    return decoded['status'] == 'found' ? SongMatch.fromJson(decoded) : null;
  }

  @override
  Future<Track> saveIdentifiedSong(String token, SongMatch match) async {
    final track = match.track;
    if (match.source == SongMatchSource.store) {
      return saveStoreTrack(token, track.id);
    }
    final body =
        await _send('POST', '/api/v1/identify/save', token: token, body: {
      'trackId': track.id,
      if (track.sharedVia != null) 'shareToken': track.sharedVia,
      if (track.sharedVia == null) 'playlistId': track.viaPlaylist,
    });
    return Track.fromJson(body);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? token,
    bool expectBody = true,
    Duration? requestTimeout,
  }) async {
    final request = http.Request(method, baseUri.resolve(path));
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    if (token != null) request.headers['Authorization'] = 'Bearer $token';

    late http.Response response;
    try {
      response = await _httpClient
          .send(request)
          .then(http.Response.fromStream)
          .timeout(requestTimeout ?? _timeout);
    } on TimeoutException {
      if (requestTimeout != null) {
        throw const ApiException('Link import request timed out.',
            code: 'import_timeout');
      }
      rethrow;
    }
    final decoded = _decode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = decoded?['error'];
      throw ApiException(
        'Server returned HTTP ${response.statusCode}.',
        statusCode: response.statusCode,
        code: code is String ? code : null,
        details: decoded ?? const {},
      );
    }
    if (!expectBody) return const {};
    if (decoded == null) {
      throw const ApiException('Server returned an invalid response.');
    }
    return decoded;
  }

  static Map<String, dynamic>? _decode(String body) {
    try {
      final value = jsonDecode(body);
      return value is Map<String, dynamic> ? value : null;
    } on FormatException {
      return null;
    }
  }
}
