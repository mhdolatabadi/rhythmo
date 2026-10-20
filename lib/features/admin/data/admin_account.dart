import 'package:rhythmo/features/auth/data/auth_models.dart';

class AdminAccount {
  const AdminAccount({required this.user, required this.createdAt});

  factory AdminAccount.fromJson(Map<String, dynamic> json) => AdminAccount(
        user: AuthUser.fromJson(json),
        createdAt: DateTime.parse(json['createdAt'] as String),
      );

  final AuthUser user;
  final DateTime createdAt;
}

typedef AdminAccountPage = ({List<AdminAccount> accounts, bool hasMore});

/// What a pending publication request is for (#322).
enum PublicationKind { playlist, track }

/// A request from an account that isn't verified to list a playlist
/// publicly or publish a track, waiting for an admin.
class PendingPublication {
  const PendingPublication({
    required this.kind,
    required this.id,
    required this.title,
    required this.ownerEmail,
    required this.requestedAt,
    this.artist,
    this.shareToken,
    this.trackCount = 0,
  });

  factory PendingPublication.fromJson(Map<String, dynamic> json) =>
      PendingPublication(
        kind: json['kind'] == 'playlist'
            ? PublicationKind.playlist
            : PublicationKind.track,
        id: json['id'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String?,
        shareToken: json['shareToken'] as String?,
        trackCount: (json['trackCount'] as num?)?.toInt() ?? 0,
        ownerEmail: json['ownerEmail'] as String,
        requestedAt: DateTime.parse(json['requestedAt'] as String),
      );

  final PublicationKind kind;
  final String id;

  /// The playlist's name or the track's title.
  final String title;
  final String? artist;
  final String? shareToken;
  final int trackCount;
  final String ownerEmail;
  final DateTime requestedAt;
}

abstract interface class AdminApi {
  Future<AdminAccountPage> listAccounts(String token,
      {String query = '', int offset = 0});
  Future<AdminAccount> setAccountVerification(
      String token, String accountId, bool verified);

  /// Requests waiting for review, oldest first.
  Future<List<PendingPublication>> listPendingPublications(String token);

  /// Approves or rejects a request. Throws [ApiException] 409 when it is
  /// no longer pending (withdrawn, or decided by another admin).
  Future<void> reviewPublication(
      String token, PendingPublication publication, bool approved);
}
