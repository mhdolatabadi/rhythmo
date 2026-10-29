import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/notifications/application/notifications_controller.dart';
import 'package:rhythmo/features/notifications/data/notifications.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/mini_player.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/presentation/shared_playlist_screen.dart';

/// The bell in the app bar: opens the notifications and shows how many are
/// unread, in words for screen readers too.
class NotificationsButton extends StatelessWidget {
  const NotificationsButton(
      {super.key, required this.controller, required this.onOpen});

  final NotificationsController controller;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final unread = controller.unreadCount;
        return IconButton(
          tooltip: unread == 0
              ? 'اعلان‌ها'
              : 'اعلان‌ها، ${persianDigits(unread)} خوانده‌نشده',
          onPressed: onOpen,
          icon: Badge(
            isLabelVisible: unread > 0,
            label: Text(persianDigits(unread > 99 ? 99 : unread)),
            child: Icon(unread > 0 ? RhythmoIcons.bellFill : RhythmoIcons.bell),
          ),
        );
      },
    );
  }
}

/// Notices of audio added to subscribed public playlists, and those
/// playlists, like a messenger's channels.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({
    super.key,
    required this.controller,
    required this.playlists,
    required this.player,
    this.onSaved,
  });

  final NotificationsController controller;
  final PlaylistsController playlists;
  final PlayerController player;

  /// Passed on to a playlist opened from here, for when it is saved.
  final VoidCallback? onSaved;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      widget.controller.load();
      widget.controller.loadSubscriptions();
    });
  }

  Future<void> _open(String shareToken) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SharedPlaylistScreen(
        shareToken: shareToken,
        controller: widget.playlists,
        player: widget.player,
        onSaved: widget.onSaved,
      ),
    ));
    if (!mounted) return;
    // Opening it read its notice, and may have unsubscribed.
    widget.controller.load();
    widget.controller.loadSubscriptions();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        extendBody: true,
        appBar: AppBar(
          title: const Text('اعلان‌ها'),
          actions: [
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) => controller.unreadCount == 0
                  ? const SizedBox.shrink()
                  : IconButton(
                      tooltip: 'خواندن همه',
                      onPressed: controller.markAllRead,
                      icon: const Icon(RhythmoIcons.checkCircle),
                    ),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'تازه‌ها'),
              Tab(text: 'کانال‌های من'),
            ],
          ),
        ),
        bottomNavigationBar: MiniPlayer(player: widget.player),
        body: RhythmoBackdrop(
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => TabBarView(
              children: [
                _NoticeList(controller: controller, onOpen: _open),
                _ChannelList(controller: controller, onOpen: _open),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NoticeList extends StatelessWidget {
  const _NoticeList({required this.controller, required this.onOpen});

  final NotificationsController controller;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final notices = controller.notifications;
    return switch (controller.status) {
      NotificationsStatus.loading when notices.isEmpty =>
        const RhythmoStateView.loading(title: 'در حال دریافت اعلان‌ها…'),
      NotificationsStatus.error when notices.isEmpty => RhythmoStateView.error(
          icon: RhythmoIcons.cloudSlash,
          title: 'اعلان‌ها بارگذاری نشد.',
          message: 'اتصال را بررسی کن و دوباره تلاش کن.',
          action: FilledButton.icon(
            onPressed: controller.load,
            icon: const Icon(RhythmoIcons.arrowsClockwise),
            label: const Text('تلاش دوباره'),
          ),
        ),
      _ when notices.isEmpty => const RhythmoStateView(
          icon: RhythmoIcons.bell,
          title: 'اعلانی نداری',
          message: 'در فهرست‌های پخش عمومی «عضویت» را بزن تا هر صوت '
              'تازه‌ای که اضافه می‌شود اینجا خبرت کنیم.',
        ),
      _ => RefreshIndicator(
          onRefresh: controller.load,
          child: _Rows(
            count: notices.length,
            builder: (context, index) {
              final notice = notices[index];
              return _Row(
                key: ValueKey(notice.id),
                title: notice.playlistName,
                subtitle: _describe(notice),
                trailing: _ago(notice.updatedAt),
                unread: !notice.read,
                onTap: () {
                  controller.markOpened(notice);
                  onOpen(notice.shareToken);
                },
              );
            },
          ),
        ),
    };
  }

  static String _describe(PlaylistNotification notice) =>
      notice.trackCount == 1 && notice.trackTitle != null
          ? '«${notice.trackTitle}» اضافه شد'
          : '${persianDigits(notice.trackCount)} صوت تازه اضافه شد';

  static String _ago(DateTime at) {
    final elapsed = DateTime.now().difference(at);
    if (elapsed.inMinutes < 1) return 'همین حالا';
    if (elapsed.inHours < 1) {
      return '${persianDigits(elapsed.inMinutes)} دقیقه پیش';
    }
    if (elapsed.inDays < 1) return '${persianDigits(elapsed.inHours)} ساعت پیش';
    return '${persianDigits(elapsed.inDays)} روز پیش';
  }
}

class _ChannelList extends StatelessWidget {
  const _ChannelList({required this.controller, required this.onOpen});

  final NotificationsController controller;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final channels = controller.subscriptions;
    return switch (controller.subscriptionsStatus) {
      NotificationsStatus.loading when channels.isEmpty =>
        const RhythmoStateView.loading(title: 'در حال دریافت کانال‌ها…'),
      NotificationsStatus.error when channels.isEmpty => RhythmoStateView.error(
          icon: RhythmoIcons.cloudSlash,
          title: 'کانال‌ها بارگذاری نشد.',
          message: 'اتصال را بررسی کن و دوباره تلاش کن.',
          action: FilledButton.icon(
            onPressed: controller.loadSubscriptions,
            icon: const Icon(RhythmoIcons.arrowsClockwise),
            label: const Text('تلاش دوباره'),
          ),
        ),
      _ when channels.isEmpty => const RhythmoStateView(
          icon: RhythmoIcons.playlist,
          title: 'هنوز عضو فهرست پخشی نشده‌ای',
          message: 'فهرست‌های پخش عمومی مثل کانال‌اند: عضو شو تا '
              'صوت‌های تازه‌شان را از دست ندهی.',
        ),
      _ => RefreshIndicator(
          onRefresh: controller.loadSubscriptions,
          child: _Rows(
            count: channels.length,
            builder: (context, index) {
              final channel = channels[index];
              return _Row(
                key: ValueKey(channel.shareToken),
                title: channel.name,
                subtitle: [
                  '${persianDigits(channel.trackCount)} آهنگ',
                  if (channel.muted) 'بی‌صدا',
                ].join(' · '),
                muted: channel.muted,
                unread: channel.unreadCount > 0,
                badge: channel.unreadCount > 0
                    ? persianDigits(channel.unreadCount)
                    : null,
                onTap: () => onOpen(channel.shareToken),
              );
            },
          ),
        ),
    };
  }
}

/// The rows in a centred column that clears the mini player.
class _Rows extends StatelessWidget {
  const _Rows({required this.count, required this.builder});

  final int count;
  final IndexedWidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom + RhythmoSpace.xxl;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(8, 8, 8, bottom),
          itemCount: count,
          itemBuilder: builder,
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.title,
    required this.subtitle,
    required this.unread,
    required this.onTap,
    this.trailing,
    this.badge,
    this.muted = false,
  });

  /// A muted channel's badge is grey, as in a messenger.
  final bool muted;
  final String title;
  final String subtitle;
  final bool unread;
  final VoidCallback onTap;
  final String? trailing;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: scheme.surface.withValues(alpha: unread ? 0.75 : 0.5),
        borderRadius: BorderRadius.circular(RhythmoRadii.sm),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          minTileHeight: 64,
          onTap: onTap,
          leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: RhythmoRadii.surface,
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [scheme.primary, scheme.secondary],
              ),
            ),
            child: const Icon(RhythmoIcons.playlist),
          ),
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: unread ? const TextStyle(fontWeight: FontWeight.w800) : null,
          ),
          subtitle:
              Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: badge != null
              ? Semantics(
                  label: '$badge صوت خوانده‌نشده',
                  excludeSemantics: true,
                  child: Badge(
                    label: Text(badge!),
                    backgroundColor:
                        muted ? scheme.surfaceContainerHighest : null,
                    textColor: muted ? scheme.onSurfaceVariant : null,
                  ),
                )
              : trailing == null
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(trailing!, style: theme.textTheme.bodySmall),
                        if (unread) ...[
                          const SizedBox(width: 8),
                          Semantics(
                            label: 'خوانده‌نشده',
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
        ),
      ),
    );
  }
}
