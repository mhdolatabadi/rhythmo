import 'package:rhythmo/features/bale_archive/bale_archive.dart';
import 'package:rhythmo/features/bale_archive/bale_archive_screen.dart';
import 'package:rhythmo/features/feedback/feedback_api.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/features/feedback/feedback_screen.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/widgets/glass_surface.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/admin/data/admin_account.dart';
import 'package:rhythmo/features/admin/presentation/publication_review_screen.dart';
import 'package:rhythmo/features/admin/data/admin_song_reports.dart';
import 'package:rhythmo/features/admin/presentation/song_reports_screen.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key, required this.api, required this.token});

  final AdminApi api;
  final String? Function() token;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  final _search = TextEditingController();
  List<AdminAccount> _accounts = [];
  bool _loading = false;
  bool _more = false;
  bool _forbidden = false;
  String? _error;
  String? _saving;
  String _query = '';
  int _offset = 0;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool next = false}) async {
    if (_saving != null || _forbidden) return;
    final token = widget.token();
    if (token == null) return;
    final request = ++_request;
    final query = next ? _query : _search.text.trim();
    final offset = next ? _offset + 50 : 0;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.api.listAccounts(
        token,
        query: query,
        offset: offset,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _accounts = next ? [..._accounts, ...page.accounts] : page.accounts;
        _query = query;
        _offset = offset;
        _more = page.hasMore;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _forbidden = error is ApiException &&
            (error.statusCode == 401 || error.statusCode == 403);
        _error = _forbidden
            ? 'دسترسی مدیریت نداری. دوباره وارد حساب مدیر شو.'
            : 'دریافت حساب‌ها ممکن نشد. دوباره تلاش کن.';
        if (_forbidden) _accounts = [];
      });
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  static int? _quotaBytes(String input) {
    const persian = '۰۱۲۳۴۵۶۷۸۹';
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    final latin = input.trim().split('').map((c) {
      final p = persian.indexOf(c), a = arabic.indexOf(c);
      return p >= 0
          ? '$p'
          : a >= 0
              ? '$a'
              : c;
    }).join();
    final gib = int.tryParse(latin);
    return gib == null || gib < 1 || gib > 1024 ? null : gib * (1 << 30);
  }

  Future<void> _increaseQuota(AdminAccount account) async {
    final api = widget.api;
    if (api is! AdminQuotaApi) return;
    var value = '${(account.storageQuotaBytes / (1 << 30)).ceil() + 1}';
    final form = GlobalKey<FormState>();
    final bytes = await showDialog<int>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('افزایش ظرفیت آپلود'),
                content: Form(
                    key: form,
                    child: TextFormField(
                        initialValue: value,
                        onChanged: (text) => value = text,
                        keyboardType: TextInputType.number,
                        textDirection: TextDirection.ltr,
                        decoration: const InputDecoration(
                            labelText: 'ظرفیت جدید (گیگابایت)'),
                        validator: (text) {
                          final bytes = _quotaBytes(text ?? '');
                          if (bytes == null) {
                            return 'عددی بین ۱ تا ۱۰۲۴ وارد کن.';
                          }
                          if (bytes <= account.storageQuotaBytes) {
                            return 'ظرفیت جدید باید بیشتر از ظرفیت فعلی باشد.';
                          }
                          return null;
                        })),
                actions: [
                  if (widget.api is FeedbackApi)
                    IconButton(
                        tooltip: 'پیام‌های کاربران',
                        icon: const Icon(Icons.inbox_outlined),
                        onPressed: _forbidden
                            ? null
                            : () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                    builder: (_) => FeedbackScreen(
                                        api: widget.api as FeedbackApi,
                                        token: widget.token,
                                        admin: true)))),
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('انصراف')),
                  FilledButton(
                      onPressed: () {
                        if (form.currentState!.validate()) {
                          Navigator.pop(context, _quotaBytes(value));
                        }
                      },
                      child: const Text('افزایش ظرفیت'))
                ]));
    if (bytes == null || !mounted) return;
    final token = widget.token();
    if (token == null) return;
    setState(() => _saving = account.user.id);
    try {
      final updated = await (api as AdminQuotaApi)
          .increaseStorageQuota(token, account.user.id, bytes);
      if (mounted) {
        setState(() => _accounts = [
              for (final item in _accounts)
                if (item.user.id == updated.user.id) updated else item
            ]);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('ظرفیت آپلود افزایش یافت.')));
      }
    } catch (error) {
      if (mounted) {
        final denied = error is ApiException &&
            (error.statusCode == 401 || error.statusCode == 403);
        if (denied) {
          setState(() {
            _forbidden = true;
            _accounts = [];
          });
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(denied
                ? 'دسترسی مدیریت نداری.'
                : 'افزایش ظرفیت ذخیره نشد. دوباره تلاش کن.')));
      }
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  Future<void> _verify(AdminAccount account) async {
    final verified = !account.user.verified;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(verified ? 'تأیید این حساب؟' : 'لغو تأیید این حساب؟'),
        content: Text(account.user.email, textDirection: TextDirection.ltr),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(verified ? 'تأیید حساب' : 'لغو تأیید'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final token = widget.token();
    if (token == null) return;
    setState(() => _saving = account.user.id);
    try {
      final updated = await widget.api.setAccountVerification(
        token,
        account.user.id,
        verified,
      );
      if (!mounted) return;
      setState(() {
        _accounts = [
          for (final item in _accounts)
            if (item.user.id == updated.user.id) updated else item,
        ];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(verified ? 'حساب تأیید شد.' : 'تأیید حساب لغو شد.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      final denied = error is ApiException &&
          (error.statusCode == 401 || error.statusCode == 403);
      if (denied) {
        setState(() {
          _forbidden = true;
          _accounts = [];
          _error = 'دسترسی مدیریت نداری. دوباره وارد حساب مدیر شو.';
        });
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            denied
                ? 'دسترسی مدیریت نداری.'
                : 'تغییر ذخیره نشد. دوباره تلاش کن.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مدیریت حساب‌ها'),
        actions: [
          if (widget.api is BaleTopicCatalogApi)
            IconButton(
              tooltip: 'آرشیو حامد کاشانی',
              icon: const Icon(Icons.library_music_outlined),
              onPressed: _forbidden
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => BaleArchiveScreen(
                          api: widget.api as BaleTopicCatalogApi,
                          token: widget.token))),
            ),
          if (widget.api is AdminSongReportsApi)
            IconButton(
                tooltip: 'گزارش آهنگ‌ها',
                icon: const Icon(RhythmoIcons.flag),
                onPressed: _forbidden
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => SongReportsScreen(
                            api: widget.api as AdminSongReportsApi,
                            token: widget.token)))),
          IconButton(
            tooltip: 'درخواست‌های انتشار',
            icon: const Icon(RhythmoIcons.shieldCheck),
            onPressed: _forbidden
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => PublicationReviewScreen(
                          api: widget.api,
                          token: widget.token,
                        ),
                      ),
                    ),
          ),
        ],
      ),
      body: RhythmoBackdrop(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  GlassSurface(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'حساب‌های ریتمو',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'حساب‌ها را پیدا کن و نشان تأییدشان را مدیریت کن. حساب‌های تأییدشده بدون تأیید مدیر فهرست پخش و آهنگ عمومی می‌کنند.',
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _search,
                          enabled: !_forbidden && _saving == null,
                          textDirection: TextDirection.ltr,
                          textInputAction: TextInputAction.search,
                          decoration: const InputDecoration(
                            labelText: 'جست‌وجو با ایمیل',
                            prefixIcon: Icon(RhythmoIcons.userCircle),
                          ),
                          onSubmitted: (_) => _load(),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _loading || _forbidden || _saving != null
                              ? null
                              : () => _load(),
                          child: const Text('جست‌وجو'),
                        ),
                      ],
                    ),
                  ),
                  if (_loading) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, textAlign: TextAlign.center),
                    if (!_forbidden)
                      TextButton(
                        onPressed: _loading ? null : () => _load(),
                        child: const Text('تلاش دوباره'),
                      ),
                  ],
                  if (!_loading && _error == null && _accounts.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'حسابی پیدا نشد.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  const SizedBox(height: 16),
                  for (final account in _accounts)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GlassSurface(
                        blur: 0,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        shadow: false,
                        radius: 16,
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    account.user.email,
                                    textDirection: TextDirection.ltr,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    account.user.verified
                                        ? 'حساب تأییدشده'
                                        : 'تأیید نشده',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: account.user.verified
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                        ),
                                  ),
                                  Text(
                                    'ظرفیت آپلود: ${persianDigits((account.storageQuotaBytes / (1 << 30)).toStringAsFixed(2))} گیگابایت',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (widget.api is AdminQuotaApi)
                                    TextButton.icon(
                                      onPressed: _saving != null || _loading
                                          ? null
                                          : () => _increaseQuota(account),
                                      icon:
                                          const Icon(RhythmoIcons.cloudArrowUp),
                                      label: const Text('افزایش ظرفیت آپلود'),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: _saving != null || _loading
                                  ? null
                                  : () => _verify(account),
                              icon: Icon(
                                account.user.verified
                                    ? RhythmoIcons.checkCircle
                                    : RhythmoIcons.check,
                              ),
                              label: Text(
                                _saving == account.user.id
                                    ? 'در حال ذخیره…'
                                    : account.user.verified
                                        ? 'لغو تأیید'
                                        : 'تأیید حساب',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_more && !_forbidden)
                    OutlinedButton(
                      onPressed: _loading || _saving != null
                          ? null
                          : () => _load(next: true),
                      child: const Text('نمایش حساب‌های بیشتر'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
