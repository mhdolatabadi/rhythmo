import 'package:flutter/material.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/social/data/social.dart';
import 'package:rhythmo/features/social/presentation/profile_avatar.dart';
import 'package:rhythmo/features/social/presentation/social_scope.dart';

enum _Load { loading, loaded, missing, failed }

/// Someone's public profile: name, bio, counts and public playlists, with
/// follow, block and report.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.handle, required this.social});

  final String handle;
  final Social social;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  _Load _state = _Load.loading;
  PublicProfile? _profile;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _state = _Load.loading);
    try {
      final profile =
          await widget.social.api.profile(widget.social.token(), widget.handle);
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _state = _Load.loaded;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() =>
          _state = error.statusCode == 404 ? _Load.missing : _Load.failed);
    } catch (_) {
      if (mounted) setState(() => _state = _Load.failed);
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Runs a change for a signed-in viewer, applying [optimistic] at once
  /// and undoing it when the server refuses.
  Future<void> _change(Future<void> Function(String token) call,
      PublicProfile optimistic, String failure) async {
    final token = widget.social.token();
    final before = _profile;
    if (token == null || before == null || _busy) {
      if (token == null) _message('برای این کار وارد حسابت شو.');
      return;
    }
    setState(() {
      _busy = true;
      _profile = optimistic;
    });
    try {
      await call(token);
    } catch (_) {
      if (mounted) setState(() => _profile = before);
      _message(failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggleFollow() {
    final p = _profile!;
    final follow = !p.isFollowing;
    _change(
      (token) => widget.social.api.setFollowing(token, p.handle, follow),
      p.copyWith(
          isFollowing: follow, followers: p.followers + (follow ? 1 : -1)),
      follow ? 'دنبال کردن ناموفق بود.' : 'لغو دنبال کردن ناموفق بود.',
    );
  }

  Future<void> _toggleBlock() async {
    final p = _profile!;
    final block = !p.isBlocked;
    if (block) {
      final sure = await showRhythmoConfirm(
        context,
        title: 'مسدود کردن @${p.handle}؟',
        message: 'دیگر نمایه‌ی تو را نمی‌بیند و هیچ‌کدام دیگری را دنبال '
            'نمی‌کنید. هر وقت بخواهی می‌توانی رفعش کنی.',
        confirmLabel: 'مسدود کن',
      );
      if (!sure) return;
    }
    await _change(
      (token) => widget.social.api.setBlocked(token, p.handle, block),
      p.copyWith(
          isBlocked: block,
          isFollowing: block ? false : p.isFollowing,
          followers: block && p.isFollowing ? p.followers - 1 : p.followers),
      'انجام نشد. دوباره امتحان کن.',
    );
  }

  Future<void> _report() async {
    final token = widget.social.token();
    if (token == null) {
      _message('برای گزارش وارد حسابت شو.');
      return;
    }
    final reason = await showDialog<ProfileReportReason>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('گزارش این نمایه'),
        children: [
          for (final reason in ProfileReportReason.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(reason),
              child: Text(reason.label),
            ),
        ],
      ),
    );
    if (reason == null) return;
    try {
      await widget.social.api.report(token, _profile!.handle, reason);
      _message('گزارشت فرستاده شد. ممنون.');
    } catch (_) {
      _message('فرستادن گزارش ناموفق بود.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return Scaffold(
      appBar: AppBar(
        title: Text('@${widget.handle}', textDirection: TextDirection.ltr),
        actions: [
          if (profile != null && !profile.isMe && widget.social.token() != null)
            PopupMenuButton<String>(
              icon: const Icon(RhythmoIcons.dotsThreeVertical),
              tooltip: 'بیشتر',
              onSelected: (action) => switch (action) {
                'block' => _toggleBlock(),
                _ => _report(),
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: 'block',
                    child: Text(profile.isBlocked ? 'رفع مسدودی' : 'مسدود کن')),
                const PopupMenuItem(value: 'report', child: Text('گزارش')),
              ],
            ),
        ],
      ),
      body: switch (_state) {
        _Load.loading =>
          const RhythmoStateView.loading(title: 'در حال باز کردن نمایه'),
        _Load.missing => const RhythmoStateView(
            icon: RhythmoIcons.userCircleMinus,
            title: 'این نمایه پیدا نشد',
            message: 'شاید خصوصی شده یا دیگر وجود ندارد.'),
        _Load.failed => RhythmoStateView.error(
            icon: RhythmoIcons.warningCircle,
            title: 'نمایه باز نشد',
            action: TextButton(onPressed: _load, child: const Text('دوباره')),
          ),
        _Load.loaded => _body(context, profile!),
      },
    );
  }

  Widget _body(BuildContext context, PublicProfile p) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final avatar =
        p.avatarUrl == null ? null : widget.social.api.resolve(p.avatarUrl!);
    return ListView(
      padding: const EdgeInsets.all(RhythmoSpace.lg),
      children: [
        Row(
          children: [
            ProfileAvatar(url: avatar, size: 64),
            const SizedBox(width: RhythmoSpace.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(p.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    if (p.verified) ...[
                      const SizedBox(width: RhythmoSpace.xs),
                      const Icon(RhythmoIcons.checkCircleFill,
                          size: 16,
                          color: RhythmoColors.verified,
                          semanticLabel: 'حساب تأییدشده'),
                    ],
                  ]),
                  Text(
                    '${persianDigits(p.followers)} دنبال‌کننده · '
                    '${persianDigits(p.following)} دنبال‌شده',
                    style: muted,
                  ),
                ],
              ),
            ),
          ],
        ),
        if (p.bio.isNotEmpty) ...[
          const SizedBox(height: RhythmoSpace.md),
          Text(p.bio, style: theme.textTheme.bodyMedium),
        ],
        const SizedBox(height: RhythmoSpace.lg),
        if (p.isBlocked)
          OutlinedButton(
            onPressed: _busy ? null : _toggleBlock,
            child: const Text('رفع مسدودی'),
          )
        else if (!p.isMe)
          p.isFollowing
              ? OutlinedButton.icon(
                  onPressed: _busy ? null : _toggleFollow,
                  icon: const Icon(RhythmoIcons.userMinus),
                  label: const Text('دنبال می‌کنی'),
                )
              : FilledButton.icon(
                  onPressed: _busy ? null : _toggleFollow,
                  icon: const Icon(RhythmoIcons.userPlus),
                  label: const Text('دنبال کن'),
                ),
        const SizedBox(height: RhythmoSpace.xl),
        RhythmoSectionHeader(
          title: 'فهرست‌های پخش عمومی',
          padding: EdgeInsets.zero,
        ),
        if (p.playlists.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: RhythmoSpace.lg),
            child: Text('هنوز فهرست پخش عمومی‌ای ندارد.', style: muted),
          )
        else
          for (final playlist in p.playlists)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(RhythmoIcons.playlist),
              title: Text(playlist.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${persianDigits(playlist.trackCount)} آهنگ'),
              onTap: () =>
                  widget.social.openPlaylist(context, playlist.shareToken),
            ),
      ],
    );
  }
}
