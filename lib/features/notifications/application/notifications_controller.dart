import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/notifications/data/notifications.dart';

enum NotificationsStatus { loading, loaded, error }

/// The notices of audio added to the public playlists this account
/// subscribed to, and those playlists, like a messenger's channels. The
/// unread count is checked every [pollEvery] while [startPolling] runs.
class NotificationsController extends ChangeNotifier {
  NotificationsController({
    required NotificationsApi api,
    required String? Function() token,
    this.pollEvery = const Duration(minutes: 2),
  })  : _api = api,
        _token = token;

  final NotificationsApi _api;
  final String? Function() _token;
  final Duration pollEvery;
  Timer? _poll;

  int unreadCount = 0;
  NotificationsStatus status = NotificationsStatus.loading;
  List<PlaylistNotification> notifications = const [];
  NotificationsStatus subscriptionsStatus = NotificationsStatus.loading;
  List<SubscribedPlaylist> subscriptions = const [];

  /// Checks the unread count now and then every [pollEvery].
  void startPolling() {
    _poll?.cancel();
    refreshUnread();
    _poll = Timer.periodic(pollEvery, (_) => refreshUnread());
  }

  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> refreshUnread() async {
    final token = _token();
    if (token == null) return;
    try {
      final count = await _api.unreadNotificationCount(token);
      if (count != unreadCount) {
        unreadCount = count;
        notifyListeners();
      }
    } catch (_) {
      // Offline; the badge keeps what it showed.
    }
  }

  Future<void> load() async {
    final token = _token();
    if (token == null) return;
    status = NotificationsStatus.loading;
    notifyListeners();
    try {
      final result = await _api.listNotifications(token);
      notifications = result.notifications;
      unreadCount = result.unread;
      status = NotificationsStatus.loaded;
    } catch (_) {
      status = NotificationsStatus.error;
    }
    notifyListeners();
  }

  Future<void> loadSubscriptions() async {
    final token = _token();
    if (token == null) return;
    subscriptionsStatus = NotificationsStatus.loading;
    notifyListeners();
    try {
      subscriptions = await _api.listSubscriptions(token);
      subscriptionsStatus = NotificationsStatus.loaded;
    } catch (_) {
      subscriptionsStatus = NotificationsStatus.error;
    }
    notifyListeners();
  }

  /// Marks every notice read. The list shows it at once; if the server
  /// refuses, the next load shows the truth again.
  Future<void> markAllRead() async {
    final token = _token();
    if (token == null || unreadCount == 0) return;
    notifications = [for (final n in notifications) n.asRead()];
    unreadCount = 0;
    notifyListeners();
    try {
      await _api.markNotificationsRead(token);
    } catch (_) {
      await refreshUnread();
    }
  }

  /// Marks one notice read, as opening its playlist does on the server.
  void markOpened(PlaylistNotification notice) {
    if (notice.read) return;
    notifications = [
      for (final n in notifications) n.id == notice.id ? n.asRead() : n,
    ];
    unreadCount = unreadCount > 0 ? unreadCount - 1 : 0;
    notifyListeners();
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}
