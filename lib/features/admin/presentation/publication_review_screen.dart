import 'package:flutter/material.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/glass_surface.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/admin/data/admin_account.dart';

/// The admin's review queue (#322): playlists and tracks that accounts
/// which aren't verified asked to make public. Nothing is listed for
/// everyone until it is approved here.
class PublicationReviewScreen extends StatefulWidget {
  const PublicationReviewScreen(
      {super.key, required this.api, required this.token});

  final AdminApi api;
  final String? Function() token;

  @override
  State<PublicationReviewScreen> createState() =>
      _PublicationReviewScreenState();
}

class _PublicationReviewScreenState extends State<PublicationReviewScreen> {
  List<PendingPublication> _pending = [];
  bool _loading = false;
  bool _forbidden = false;
  String? _error;
  String? _saving;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = widget.token();
    if (token == null || _forbidden) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final pending = await widget.api.listPendingPublications(token);
      if (!mounted) return;
      setState(() => _pending = pending);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _forbidden = _denied(error);
        _error = _forbidden
            ? 'دسترسی مدیریت نداری. دوباره وارد حساب مدیر شو.'
            : 'دریافت درخواست‌ها ممکن نشد. دوباره تلاش کن.';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static bool _denied(Object error) =>
      error is ApiException &&
      (error.statusCode == 401 || error.statusCode == 403);

  Future<void> _review(PendingPublication item, bool approved) async {
    final token = widget.token();
    if (token == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = item.id);
    String message;
    try {
      await widget.api.reviewPublication(token, item, approved);
      message = approved ? '«${item.title}» عمومی شد.' : 'درخواست رد شد.';
      if (mounted) {
        setState(() => _pending = [
              for (final other in _pending)
                if (other.id != item.id) other,
            ]);
      }
    } catch (error) {
      if (error is ApiException && error.statusCode == 409) {
        message = 'این درخواست دیگر در انتظار نیست.';
        if (mounted) {
          setState(() => _pending = [
                for (final other in _pending)
                  if (other.id != item.id) other,
              ]);
        }
      } else if (_denied(error)) {
        message = 'دسترسی مدیریت نداری.';
        if (mounted) setState(() => _forbidden = true);
      } else {
        message = 'تصمیم ذخیره نشد. دوباره تلاش کن.';
      }
    } finally {
      if (mounted) setState(() => _saving = null);
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('درخواست‌های انتشار')),
      body: RhythmoBackdrop(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                  children: [
                    const Text(
                        'فهرست‌های پخش و آهنگ‌هایی که حساب‌های تأییدنشده خواسته‌اند عمومی شوند. تا تأیید نکنی، برای کسی نمایش داده نمی‌شوند.'),
                    if (_loading) ...[
                      const SizedBox(height: 16),
                      const LinearProgressIndicator(),
                    ],
                    if (_error case final error?) ...[
                      const SizedBox(height: 16),
                      Text(error, textAlign: TextAlign.center),
                      if (!_forbidden)
                        TextButton(
                          onPressed: _loading ? null : _load,
                          child: const Text('تلاش دوباره'),
                        ),
                    ],
                    if (!_loading && _error == null && _pending.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Text('درخواستی در انتظار نیست.',
                            textAlign: TextAlign.center),
                      ),
                    const SizedBox(height: 16),
                    for (final item in _pending)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: GlassSurface(
                          blur: 0,
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    item.kind == PublicationKind.playlist
                                        ? RhythmoIcons.listPlus
                                        : RhythmoIcons.globe,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(item.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleMedium),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                item.kind == PublicationKind.playlist
                                    ? 'فهرست پخش · ${persianDigits(item.trackCount)} آهنگ'
                                    : [
                                        'آهنگ',
                                        if (item.artist case final artist?
                                            when artist.isNotEmpty)
                                          artist,
                                      ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(item.ownerEmail,
                                  textDirection: TextDirection.ltr,
                                  textAlign: TextAlign.end,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                alignment: WrapAlignment.end,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: _saving != null || _forbidden
                                        ? null
                                        : () => _review(item, false),
                                    icon: const Icon(RhythmoIcons.x),
                                    label: const Text('رد'),
                                    style: OutlinedButton.styleFrom(
                                        minimumSize: const Size(96, 48)),
                                  ),
                                  FilledButton.icon(
                                    onPressed: _saving != null || _forbidden
                                        ? null
                                        : () => _review(item, true),
                                    icon: const Icon(RhythmoIcons.check),
                                    label: Text(_saving == item.id
                                        ? 'در حال ذخیره…'
                                        : 'تأیید و عمومی کردن'),
                                    style: FilledButton.styleFrom(
                                        minimumSize: const Size(96, 48)),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
