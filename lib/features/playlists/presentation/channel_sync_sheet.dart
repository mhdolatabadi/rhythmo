import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/bots/data/messenger_bot.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';

/// Lets the owner or an admin sync a Telegram or Bale channel into
/// [playlist]: they make rhythmo's bot an admin of the channel and post a
/// one-time code there. Then every audio posted in the channel joins the
/// playlist too.
Future<void> showChannelSyncSheet(
  BuildContext context, {
  required Playlist playlist,
  required PlaylistsController controller,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) =>
        _ChannelSyncSheet(playlist: playlist, controller: controller),
  );
}

class _ChannelSyncSheet extends StatefulWidget {
  const _ChannelSyncSheet({required this.playlist, required this.controller});

  final Playlist playlist;
  final PlaylistsController controller;

  @override
  State<_ChannelSyncSheet> createState() => _ChannelSyncSheetState();
}

class _ChannelSyncSheetState extends State<_ChannelSyncSheet> {
  BotLinkCode? _code;
  List<SyncedChannel>? _channels;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  Future<void> _loadChannels() async {
    final channels = await widget.controller.syncedChannels(widget.playlist.id);
    if (mounted) setState(() => _channels = channels ?? const []);
  }

  Future<void> _requestCode() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final code = await widget.controller.createChannelCode(widget.playlist.id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (code == null) {
        _error = 'گرفتن کد ناموفق بود. دوباره تلاش کن.';
      } else {
        _code = code;
      }
    });
  }

  Future<void> _remove(SyncedChannel channel) async {
    final confirmed = await showRhythmoConfirm(
      context,
      title: 'قطع همگام‌سازی؟',
      message:
          'آهنگ‌های تازه‌ی «${channel.title}» دیگر به این کانال نمی‌آیند. آهنگ‌هایی که تا حالا آمده‌اند می‌مانند.',
      confirmLabel: 'قطع',
      destructive: true,
    );
    if (!confirmed) return;
    setState(() => _busy = true);
    final ok = await widget.controller
        .removeSyncedChannel(widget.playlist.id, channel);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _channels = [
          for (final c in _channels ?? const <SyncedChannel>[])
            if (c.provider != channel.provider || c.chatId != channel.chatId) c
        ];
      } else {
        _error = 'قطع همگام‌سازی ناموفق بود. دوباره تلاش کن.';
      }
    });
  }

  Future<void> _copy(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('کد کپی شد.')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final code = _code;
    final channels = _channels;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('اتصال کانال تلگرام یا بله',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'هر آهنگی که در کانالت منتشر کنی به «${widget.playlist.name}» هم اضافه می‌شود و مشترک‌ها خبردار می‌شوند. آهنگ‌ها از فضای تو کم می‌شوند.',
            ),
            const SizedBox(height: 12),
            const _Step(
                number: 1,
                text: 'ربات ریتمو را به کانالت اضافه کن و ادمینش کن.'),
            const _Step(number: 2, text: 'کد را بگیر و در خود کانال بفرست.'),
            const SizedBox(height: 16),
            if (code == null)
              FilledButton.icon(
                onPressed: _busy ? null : _requestCode,
                icon: const Icon(RhythmoIcons.linkSimple),
                label: const Text('گرفتن کد اتصال'),
              )
            else
              _ChannelCode(code: code, onCopy: () => _copy(code.code)),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error,
                    style: TextStyle(color: theme.colorScheme.error)),
              ),
            const SizedBox(height: 20),
            Text('کانال‌های وصل', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            if (channels == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (channels.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('هنوز کانالی وصل نیست.', style: muted),
              )
            else
              for (final channel in channels)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(RhythmoIcons.paperPlaneTilt),
                  title: Text(
                    channel.title.isEmpty ? 'کانال بی‌نام' : channel.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(_messenger(channel.provider)),
                  trailing: IconButton(
                    tooltip: 'قطع همگام‌سازی',
                    onPressed: _busy ? null : () => _remove(channel),
                    icon: const Icon(RhythmoIcons.linkBreak),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

String _messenger(String provider) => switch (provider) {
      'telegram' => 'تلگرام',
      'bale' => 'بله',
      _ => provider,
    };

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${persianDigits(number)}.'),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
          ],
        ),
      );
}

class _ChannelCode extends StatelessWidget {
  const _ChannelCode({required this.code, required this.onCopy});

  final BotLinkCode code;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = code.code;
    final grouped = value.length == 8
        ? '${value.substring(0, 4)} ${value.substring(4)}'
        : value;
    final local = code.expiresAt.toLocal();
    final until = '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    return GlassSurface(
      padding: const EdgeInsets.all(16),
      radius: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Directionality(
            textDirection: TextDirection.ltr,
            child: SelectableText(
              grouped,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(letterSpacing: 4, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 8),
          for (final bot in code.bots)
            Text(
              bot.username == null
                  ? 'ربات ریتمو در ${bot.name} را ادمین کانال کن.'
                  : 'در ${bot.name}، \u2066@${bot.username}\u2069 را ادمین کانال کن.',
              textAlign: TextAlign.center,
            ),
          Text(
            'تا ساعت ${persianDigits(until)} معتبر است و فقط یک بار کار می‌کند.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Center(
            child: OutlinedButton.icon(
              onPressed: onCopy,
              icon: const Icon(RhythmoIcons.copy),
              label: const Text('کپی کد'),
            ),
          ),
        ],
      ),
    );
  }
}
