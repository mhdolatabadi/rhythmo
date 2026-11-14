import 'package:flutter/material.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/format_size.dart';
import 'package:rhythmo/features/settings/data/storage_request.dart';

/// Requests for more storage waiting for an admin (#208).
class StorageRequestsScreen extends StatefulWidget {
  const StorageRequestsScreen(
      {super.key, required this.api, required this.token});
  final StorageRequestApi api;
  final String? Function() token;

  @override
  State<StorageRequestsScreen> createState() => _StorageRequestsScreenState();
}

class _StorageRequestsScreenState extends State<StorageRequestsScreen> {
  List<PendingStorageRequest> _requests = [];
  bool _loading = true;
  String? _error;
  String? _saving;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = widget.token();
    if (token == null) {
      setState(() {
        _loading = false;
        _error = 'دسترسی مدیریت نداری.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final requests = await widget.api.pendingStorageRequests(token);
      if (mounted) setState(() => _requests = requests);
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is ApiException &&
                (error.statusCode == 401 || error.statusCode == 403)
            ? 'دسترسی مدیریت نداری.'
            : 'دریافت درخواست‌ها ناموفق بود.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _decide(PendingStorageRequest item, bool approve) async {
    final decision = await showDialog<(int, String)>(
      context: context,
      builder: (_) => _DecisionDialog(item: item, approve: approve),
    );
    final token = widget.token();
    if (decision == null || token == null || !mounted) return;
    setState(() => _saving = item.request.id);
    String message;
    try {
      await widget.api.decideStorageRequest(token, item.request.id,
          approved: approve, bytes: decision.$1, reason: decision.$2);
      message = approve ? 'فضای حساب بیشتر شد.' : 'درخواست رد شد.';
    } on ApiException catch (error) {
      message = switch (error.code) {
        'not_pending' => 'این درخواست پیش‌تر بررسی شده است.',
        'quota_decrease' => 'مقدار باید از فضای فعلی حساب بیشتر باشد.',
        _ => 'ثبت تصمیم ناموفق بود.',
      };
    } catch (_) {
      message = 'ثبت تصمیم ناموفق بود.';
    }
    if (!mounted) return;
    setState(() => _saving = null);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('درخواست‌های فضای بیشتر')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_loading) const LinearProgressIndicator(),
            if (_error case final error?)
              Text(error, style: TextStyle(color: theme.colorScheme.error)),
            if (!_loading && _error == null && _requests.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Text('درخواستی در انتظار نیست.',
                    textAlign: TextAlign.center),
              ),
            for (final item in _requests)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(item.email, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text(
                          'درخواست ${formatSize(item.request.requestedBytes)}، '
                          'مصرف ${formatSize(item.usedBytes)} از ${formatSize(item.quotaBytes)}'),
                      if (item.request.reason.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(item.request.reason,
                            style: theme.textTheme.bodySmall),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: _saving == null
                                ? () => _decide(item, false)
                                : null,
                            child: const Text('رد'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _saving == null
                                ? () => _decide(item, true)
                                : null,
                            child: const Text('پذیرفتن'),
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
    );
  }
}

/// Confirms a decision: the amount to grant, or why it is turned down.
class _DecisionDialog extends StatefulWidget {
  const _DecisionDialog({required this.item, required this.approve});
  final PendingStorageRequest item;
  final bool approve;

  @override
  State<_DecisionDialog> createState() => _DecisionDialogState();
}

class _DecisionDialogState extends State<_DecisionDialog> {
  static const _gib = 1 << 30;
  late final _amount = TextEditingController(
      text: '${(widget.item.request.requestedBytes / _gib).ceil()}');
  final _reason = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  int? get _bytes {
    final gib = int.tryParse(_amount.text.trim());
    if (gib == null || gib <= 0 || gib > 1024) return null;
    final bytes = gib * _gib;
    return bytes > widget.item.quotaBytes ? bytes : null;
  }

  @override
  Widget build(BuildContext context) {
    final approve = widget.approve;
    return AlertDialog(
      title: Text(approve ? 'پذیرفتن درخواست' : 'رد درخواست'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (approve)
            TextField(
              key: const ValueKey('storage-grant-gib'),
              controller: _amount,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'فضای کل حساب (گیگابایت)',
                errorText: _bytes == null
                    ? 'باید از ${formatSize(widget.item.quotaBytes)} بیشتر باشد.'
                    : null,
              ),
            )
          else
            TextField(
              key: const ValueKey('storage-reject-reason'),
              controller: _reason,
              maxLength: 300,
              decoration: const InputDecoration(
                  labelText: 'دلیل (به کاربر نشان داده می‌شود)'),
            ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('انصراف')),
        FilledButton(
          onPressed: approve && _bytes == null
              ? null
              : () => Navigator.pop(
                  context, (approve ? _bytes! : 0, _reason.text.trim())),
          child: Text(approve ? 'پذیرفتن' : 'رد درخواست'),
        ),
      ],
    );
  }
}
