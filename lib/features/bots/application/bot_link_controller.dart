import 'package:flutter/foundation.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/bots/data/messenger_bot.dart';
import 'package:rhythmo/core/quiet_after_dispose.dart';

enum BotLinkStatus { idle, loading, ready, failed }

enum BotSendResult { queued, notLinked, tooLarge, failed }

/// Which messenger bots exist, and the one-time code that links one of their
/// chats to this account.
class BotLinkController extends ChangeNotifier with QuietAfterDispose {
  BotLinkController({
    required BotsApi api,
    required String? Function() token,
    DateTime Function()? now,
  })  : _api = api,
        _token = token,
        _now = now ?? DateTime.now;

  final BotsApi _api;
  final String? Function() _token;
  final DateTime Function() _now;

  BotLinkStatus _status = BotLinkStatus.idle;
  List<MessengerBot> _bots = const [];
  BotLinkCode? _code;
  bool _requesting = false;
  String? _error;

  BotLinkStatus get status => _status;
  List<MessengerBot> get bots => _bots;

  /// Bots this account can send tracks to.
  List<MessengerBot> get linkedBots => [
        for (final bot in _bots)
          if (bot.linked) bot
      ];
  bool get requesting => _requesting;

  /// Why the last code request failed, for people.
  String? get error => _error;

  /// The current code, or null once it has expired.
  BotLinkCode? get code {
    final code = _code;
    return code == null || !code.expiresAt.isAfter(_now()) ? null : code;
  }

  Future<void> load() async {
    final token = _token();
    if (token == null) return;
    _status = BotLinkStatus.loading;
    notifyListeners();
    try {
      _bots = await _api.listBots(token);
      _status = BotLinkStatus.ready;
    } catch (_) {
      _status = BotLinkStatus.failed;
    }
    notifyListeners();
  }

  Future<void> requestCode() async {
    final token = _token();
    if (token == null || _requesting) return;
    _requesting = true;
    _error = null;
    notifyListeners();
    try {
      _code = await _api.createBotLinkCode(token);
    } on ApiException catch (e) {
      _error = switch (e) {
        ApiException(statusCode: 429) =>
          'کد زیادی درخواست شده است. کمی بعد دوباره امتحان کنید.',
        ApiException(code: 'email_unverified') =>
          'برای اتصال بات، اول ایمیلت را تأیید کن.',
        _ => 'دریافت کد ناموفق بود. دوباره امتحان کنید.',
      };
    } catch (_) {
      _error = 'دریافت کد ناموفق بود. اتصال اینترنت را بررسی کنید.';
    }
    _requesting = false;
    notifyListeners();
  }

  /// Asks [provider]'s bot to post the track in the linked chat. The bot
  /// uploads it in the background.
  Future<BotSendResult> send(String provider, String trackId) async {
    final token = _token();
    if (token == null) return BotSendResult.failed;
    try {
      await _api.sendTrackToBot(token, provider, trackId);
      return BotSendResult.queued;
    } on ApiException catch (e) {
      if (e.statusCode == 409) {
        // The chat was unlinked from the bot; refresh what the app offers.
        load();
        return BotSendResult.notLinked;
      }
      if (e.statusCode == 413) return BotSendResult.tooLarge;
      return BotSendResult.failed;
    } catch (_) {
      return BotSendResult.failed;
    }
  }

  /// Forgets the code, for example when the account signs out.
  void clear() {
    _code = null;
    _error = null;
    _bots = const [];
    _status = BotLinkStatus.idle;
    notifyListeners();
  }
}
