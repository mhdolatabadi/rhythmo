/// A messenger bot the account can be linked to, such as rhythmo's Bale bot.
class MessengerBot {
  const MessengerBot({
    required this.provider,
    required this.name,
    this.username,
    this.linkUrl,
    this.linked = false,
  });

  factory MessengerBot.fromJson(Map<String, dynamic> json) => MessengerBot(
        provider: json['provider'] as String,
        name: json['name'] as String,
        username: json['username'] as String?,
        linkUrl: json['linkUrl'] as String?,
        linked: json['linked'] == true,
      );

  final String provider;

  /// The messenger's name for people, for example «بله».
  final String name;
  final String? username;

  /// Opens the bot with a link code filled in; only set alongside a code.
  final String? linkUrl;

  /// Whether this account has a chat linked with the bot, so tracks can be
  /// sent to it.
  final bool linked;
}

/// A one-time code that links a bot chat to the signed-in account.
class BotLinkCode {
  const BotLinkCode({
    required this.code,
    required this.expiresAt,
    required this.bots,
  });

  factory BotLinkCode.fromJson(Map<String, dynamic> json) => BotLinkCode(
        code: json['code'] as String,
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        bots: [
          for (final bot in json['bots'] as List<dynamic>)
            MessengerBot.fromJson(bot as Map<String, dynamic>),
        ],
      );

  final String code;
  final DateTime expiresAt;
  final List<MessengerBot> bots;
}

/// A Telegram or Bale channel whose audio posts are synced into a rhythmo
/// channel.
class SyncedChannel {
  const SyncedChannel({
    required this.provider,
    required this.chatId,
    required this.title,
  });

  factory SyncedChannel.fromJson(Map<String, dynamic> json) => SyncedChannel(
        provider: json['provider'] as String,
        chatId: json['chatId'] as String,
        title: json['title'] as String? ?? '',
      );

  final String provider;
  final String chatId;

  /// The channel's name in the messenger.
  final String title;
}
