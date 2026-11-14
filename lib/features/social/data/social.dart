import 'dart:typed_data';

/// The signed-in account's own public profile (#228). It is off until the
/// owner turns it on; the email is never part of it.
class MyProfile {
  const MyProfile({
    this.handle = '',
    this.displayName = '',
    this.bio = '',
    this.public = false,
    this.review,
    this.hideActivity = false,
    this.hasAvatar = false,
    this.followers = 0,
    this.following = 0,
  });

  factory MyProfile.fromJson(Map<String, dynamic> json) => MyProfile(
        handle: json['handle'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        bio: json['bio'] as String? ?? '',
        public: json['public'] == true,
        review: json['review'] as String?,
        hideActivity: json['hideActivity'] == true,
        hasAvatar: json['hasAvatar'] == true,
        followers: (json['followers'] as num?)?.toInt() ?? 0,
        following: (json['following'] as num?)?.toInt() ?? 0,
      );

  final String handle;
  final String displayName;
  final String bio;
  final bool public;

  /// `pending` while an admin looks at it, `rejected` when one turned it
  /// down; null otherwise.
  final String? review;
  final bool hideActivity;
  final bool hasAvatar;
  final int followers;
  final int following;

  bool get pending => review == 'pending';
  bool get rejected => review == 'rejected';
}

/// A public playlist on a profile.
class ProfilePlaylist {
  const ProfilePlaylist(
      {required this.shareToken, required this.name, this.trackCount = 0});

  factory ProfilePlaylist.fromJson(Map<String, dynamic> json) =>
      ProfilePlaylist(
        shareToken: json['shareToken'] as String,
        name: json['name'] as String? ?? '',
        trackCount: (json['trackCount'] as num?)?.toInt() ?? 0,
      );

  final String shareToken;
  final String name;
  final int trackCount;
}

/// Someone's public profile as the viewer sees it.
class PublicProfile {
  const PublicProfile({
    required this.handle,
    required this.displayName,
    this.bio = '',
    this.verified = false,
    this.avatarUrl,
    this.followers = 0,
    this.following = 0,
    this.isFollowing = false,
    this.isBlocked = false,
    this.isMe = false,
    this.playlists = const [],
  });

  factory PublicProfile.fromJson(Map<String, dynamic> json) => PublicProfile(
        handle: json['handle'] as String,
        displayName: json['displayName'] as String? ?? '',
        bio: json['bio'] as String? ?? '',
        verified: json['verified'] == true,
        avatarUrl: json['avatarUrl'] as String?,
        followers: (json['followers'] as num?)?.toInt() ?? 0,
        following: (json['following'] as num?)?.toInt() ?? 0,
        isFollowing: json['isFollowing'] == true,
        isBlocked: json['isBlocked'] == true,
        isMe: json['isMe'] == true,
        playlists: [
          for (final p in json['playlists'] as List? ?? const [])
            ProfilePlaylist.fromJson(p as Map<String, dynamic>),
        ],
      );

  final String handle;
  final String displayName;
  final String bio;
  final bool verified;

  /// The avatar's address on the server, relative to it.
  final String? avatarUrl;
  final int followers;
  final int following;
  final bool isFollowing;
  final bool isBlocked;
  final bool isMe;
  final List<ProfilePlaylist> playlists;

  PublicProfile copyWith(
          {bool? isFollowing, bool? isBlocked, int? followers}) =>
      PublicProfile(
        handle: handle,
        displayName: displayName,
        bio: bio,
        verified: verified,
        avatarUrl: avatarUrl,
        followers: followers ?? this.followers,
        following: following,
        isFollowing: isFollowing ?? this.isFollowing,
        isBlocked: isBlocked ?? this.isBlocked,
        isMe: isMe,
        playlists: playlists,
      );
}

enum FeedKind { playlist, like }

/// One thing someone the viewer follows did.
class FeedItem {
  const FeedItem({
    required this.kind,
    required this.at,
    required this.actorHandle,
    required this.actorName,
    required this.name,
    this.shareToken,
    this.entryId,
    this.artist,
  });

  static FeedItem? fromJson(Map<String, dynamic> json) {
    final kind = switch (json['kind']) {
      'playlist' => FeedKind.playlist,
      'like' => FeedKind.like,
      _ => null,
    };
    if (kind == null) return null;
    return FeedItem(
      kind: kind,
      at: DateTime.parse(json['at'] as String),
      actorHandle: json['actorHandle'] as String,
      actorName: json['actorName'] as String? ?? '',
      name: json['name'] as String? ?? '',
      shareToken: json['shareToken'] as String?,
      entryId: json['entryId'] as String?,
      artist: json['artist'] as String?,
    );
  }

  final FeedKind kind;
  final DateTime at;
  final String actorHandle;
  final String actorName;

  /// The playlist's name or the liked song's title.
  final String name;
  final String? shareToken;

  /// The liked song's store entry.
  final String? entryId;
  final String? artist;
}

class FeedPage {
  const FeedPage(this.items, this.next);

  final List<FeedItem> items;

  /// Where the next page starts; null on the last one.
  final String? next;
}

/// Why someone reports a profile.
enum ProfileReportReason {
  spam('spam', 'هرزنامه یا تبلیغ'),
  offensive('offensive', 'محتوای توهین‌آمیز'),
  impersonation('impersonation', 'جعل هویت'),
  other('other', 'دلیل دیگر');

  const ProfileReportReason(this.code, this.label);

  final String code;
  final String label;
}

/// Public profiles, following and the feed on the server (#228).
abstract interface class SocialApi {
  Future<MyProfile> myProfile(String token);

  Future<MyProfile> updateProfile(
    String token, {
    required String handle,
    required String displayName,
    required String bio,
    required bool public,
    required bool hideActivity,
  });

  Future<MyProfile> setAvatar(String token, Uint8List image);
  Future<void> deleteAvatar(String token);

  /// [token] is null for a visitor.
  Future<PublicProfile> profile(String? token, String handle);
  Future<void> setFollowing(String token, String handle, bool follow);
  Future<void> setBlocked(String token, String handle, bool block);
  Future<void> report(String token, String handle, ProfileReportReason reason,
      {String? details});
  Future<List<({String handle, String displayName})>> blocked(String token);
  Future<FeedPage> feed(String token, {String? before});

  /// The full address of an avatar path the server gave.
  Uri resolve(String path);
}

/// What the server checks a handle against, so the form can say early.
final handlePattern = RegExp(r'^[a-z][a-z0-9_]{2,19}$');

/// The largest avatar the server takes.
const maxAvatarBytes = 256 * 1024;
const maxBioLength = 160;
