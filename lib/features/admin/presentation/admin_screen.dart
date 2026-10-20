import 'package:flutter/material.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/widgets/glass_surface.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/admin/data/admin_account.dart';
import 'package:rhythmo/features/admin/presentation/publication_review_screen.dart';

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
      final page =
          await widget.api.listAccounts(token, query: query, offset: offset);
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
      final updated = await widget.api
          .setAccountVerification(token, account.user.id, verified);
      if (!mounted) return;
      setState(() {
        _accounts = [
          for (final item in _accounts)
            if (item.user.id == updated.user.id) updated else item,
        ];
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(verified ? 'حساب تأیید شد.' : 'تأیید حساب لغو شد.'),
      ));
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(denied
            ? 'دسترسی مدیریت نداری.'
            : 'تغییر ذخیره نشد. دوباره تلاش کن.'),
      ));
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
          IconButton(
            tooltip: 'درخواست‌های انتشار',
            icon: const Icon(RhythmoIcons.shieldCheck),
            onPressed: _forbidden
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => PublicationReviewScreen(
                            api: widget.api, token: widget.token),
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
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                children: [
                  GlassSurface(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('حساب‌های ریتمو',
                            style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 8),
                        const Text(
                            'حساب‌ها را پیدا کن و نشان تأییدشان را مدیریت کن. حساب‌های تأییدشده بدون تأیید مدیر فهرست پخش و آهنگ عمومی می‌کنند.'),
                        const SizedBox(height: 20),
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
                      child:
                          Text('حسابی پیدا نشد.', textAlign: TextAlign.center),
                    ),
                  const SizedBox(height: 16),
                  for (final account in _accounts)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: GlassSurface(
                        blur: 0,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(account.user.email,
                                textDirection: TextDirection.ltr,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 8),
                            Text(account.user.verified
                                ? 'حساب تأییدشده'
                                : 'تأیید نشده'),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: _saving != null || _loading
                                  ? null
                                  : () => _verify(account),
                              icon: Icon(account.user.verified
                                  ? RhythmoIcons.checkCircle
                                  : RhythmoIcons.check),
                              label: Text(_saving == account.user.id
                                  ? 'در حال ذخیره…'
                                  : account.user.verified
                                      ? 'لغو تأیید'
                                      : 'تأیید حساب'),
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
