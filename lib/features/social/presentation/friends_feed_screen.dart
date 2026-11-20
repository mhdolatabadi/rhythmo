import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/social/data/social.dart';
import 'package:rhythmo/features/social/presentation/social_scope.dart';

/// «فعالیت دوستان»: playlists the people you follow made public and store
/// songs they liked, newest first.
class FriendsFeedScreen extends StatefulWidget {
  const FriendsFeedScreen({super.key, required this.social});

  final Social social;

  @override
  State<FriendsFeedScreen> createState() => _FriendsFeedScreenState();
}

class _FriendsFeedScreenState extends State<FriendsFeedScreen> {
  final _items = <FeedItem>[];
  String? _next;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    final token = widget.social.token();
    if (token == null) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page =
          await widget.social.api.feed(token, before: reset ? null : _next);
      if (!mounted) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(page.items);
        _next = page.next;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _findPerson() async {
    final controller = TextEditingController();
    final handle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('پیدا کردن با شناسه'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.ltr,
          autocorrect: false,
          decoration: const InputDecoration(prefixText: '@', hintText: 'sara'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('انصراف')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('باز کن')),
        ],
      ),
    );
    controller.dispose();
    final cleaned = handle?.trim().replaceFirst('@', '').toLowerCase();
    if (cleaned == null || cleaned.isEmpty || !mounted) return;
    await widget.social.openProfile(context, cleaned);
  }

  void _open(FeedItem item) {
    switch (item.kind) {
      case FeedKind.playlist:
        if (item.shareToken case final token?) {
          widget.social.openPlaylist(context, token);
        }
      case FeedKind.like:
        final open = widget.social.openSong;
        if (open != null && item.entryId != null) open(context, item.entryId!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('فعالیت دوستان'),
        actions: [
          IconButton(
            tooltip: 'پیدا کردن با شناسه',
            icon: const Icon(RhythmoIcons.userPlus),
            onPressed: _findPerson,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(reset: true),
        child: _content(context),
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (_items.isEmpty) {
      final view = _loading
          ? const RhythmoStateView.loading(title: 'در حال باز کردن')
          : _failed
              ? RhythmoStateView.error(
                  icon: RhythmoIcons.warningCircle,
                  title: 'باز نشد',
                  action: TextButton(
                      onPressed: () => _load(reset: true),
                      child: const Text('دوباره')),
                )
              : RhythmoStateView(
                  icon: RhythmoIcons.users,
                  title: 'هنوز خبری نیست',
                  message: 'کسی را دنبال کن تا فهرست‌های تازه و آهنگ‌هایی که '
                      'می‌پسندد اینجا بیاید.',
                  action: TextButton(
                      onPressed: _findPerson,
                      child: const Text('پیدا کردن با شناسه')),
                );
      // Scrollable, so pull to refresh works on the empty state too.
      return ListView(children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.6, child: view),
      ]);
    }
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ListView.builder(
      itemCount: _items.length + 1,
      itemBuilder: (context, index) {
        if (index == _items.length) {
          if (_next == null) return const SizedBox(height: RhythmoSpace.xl);
          return Padding(
            padding: const EdgeInsets.all(RhythmoSpace.lg),
            child: Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : TextButton(onPressed: _load, child: const Text('بیشتر')),
            ),
          );
        }
        final item = _items[index];
        final playlist = item.kind == FeedKind.playlist;
        return ListTile(
          leading: Icon(playlist ? RhythmoIcons.playlist : RhythmoIcons.heart),
          title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            playlist
                ? '${item.actorName} فهرست پخش عمومی ساخت'
                : '${item.actorName} پسندید'
                    '${(item.artist ?? '').isEmpty ? '' : ' · ${item.artist}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
          trailing: IconButton(
            tooltip: 'نمایه‌ی ${item.actorName}',
            icon: const Icon(RhythmoIcons.userCircle),
            onPressed: () =>
                widget.social.openProfile(context, item.actorHandle),
          ),
          onTap: () => _open(item),
        );
      },
    );
  }
}
