/// A public playlist's subscriber count and whether this account is
/// subscribed, the way a channel shows its members.
class PlaylistSubscription {
  const PlaylistSubscription(
      {required this.subscribed,
      required this.subscriberCount,
      this.muted = false});

  factory PlaylistSubscription.fromJson(Map<String, dynamic> json) =>
      PlaylistSubscription(
        subscribed: json['subscribed'] == true,
        subscriberCount: json['subscriberCount'] as int? ?? 0,
        muted: json['muted'] == true,
      );

  final bool subscribed;
  final int subscriberCount;

  /// Whether this account muted the channel: its notices stay in the list
  /// but don't count as new and aren't sent to the linked bots.
  final bool muted;

  /// The subscription after pressing the button, before the server answers.
  /// Leaving a channel forgets that it was muted.
  PlaylistSubscription toggled() => PlaylistSubscription(
        subscribed: !subscribed,
        subscriberCount: subscriberCount + (subscribed ? -1 : 1),
      );

  /// The subscription after pressing mute or unmute.
  PlaylistSubscription withMuted(bool muted) => PlaylistSubscription(
        subscribed: subscribed,
        subscriberCount: subscriberCount,
        muted: muted,
      );

  @override
  bool operator ==(Object other) =>
      other is PlaylistSubscription &&
      other.subscribed == subscribed &&
      other.subscriberCount == subscriberCount &&
      other.muted == muted;

  @override
  int get hashCode => Object.hash(subscribed, subscriberCount, muted);
}

/// Tells a subscriber that [trackCount] audio files were added to a public
/// playlist; [trackTitle] is the latest one's.
class PlaylistNotification {
  const PlaylistNotification({
    required this.id,
    required this.shareToken,
    required this.playlistName,
    required this.trackCount,
    required this.read,
    required this.updatedAt,
    this.trackTitle,
  });

  factory PlaylistNotification.fromJson(Map<String, dynamic> json) =>
      PlaylistNotification(
        id: json['id'] as String,
        shareToken: json['shareToken'] as String,
        playlistName: json['playlistName'] as String,
        trackTitle: json['trackTitle'] as String?,
        trackCount: json['trackCount'] as int? ?? 1,
        read: json['read'] == true,
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  final String id;
  final String shareToken;
  final String playlistName;
  final String? trackTitle;
  final int trackCount;
  final bool read;
  final DateTime updatedAt;

  PlaylistNotification asRead() => PlaylistNotification(
        id: id,
        shareToken: shareToken,
        playlistName: playlistName,
        trackTitle: trackTitle,
        trackCount: trackCount,
        read: true,
        updatedAt: updatedAt,
      );
}

/// A public playlist this account subscribed to, with how many audio files
/// were added since its notice was last read.
class SubscribedPlaylist {
  const SubscribedPlaylist({
    required this.shareToken,
    required this.name,
    required this.owner,
    required this.trackCount,
    required this.unreadCount,
    this.muted = false,
  });

  factory SubscribedPlaylist.fromJson(Map<String, dynamic> json) =>
      SubscribedPlaylist(
        shareToken: json['shareToken'] as String,
        name: json['name'] as String,
        owner: json['owner'] as String? ?? '',
        trackCount: json['trackCount'] as int? ?? 0,
        unreadCount: json['unreadCount'] as int? ?? 0,
        muted: json['muted'] == true,
      );

  final String shareToken;
  final String name;

  /// The owner's email, masked.
  final String owner;
  final int trackCount;
  final int unreadCount;

  /// Whether this account muted it.
  final bool muted;
}
