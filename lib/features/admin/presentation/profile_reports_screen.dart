import 'package:flutter/material.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/admin/data/admin_profile_reports.dart';

const _reasons = {
  'spam': 'هرزنامه یا تبلیغ',
  'offensive': 'توهین‌آمیز',
  'impersonation': 'جعل هویت',
  'other': 'دلیل دیگر',
};

/// Reported public profiles (#228): an admin keeps one, or takes it down.
class ProfileReportsScreen extends StatefulWidget {
  const ProfileReportsScreen(
      {super.key, required this.api, required this.token});

  final AdminProfileReportsApi api;
  final String? Function() token;

  @override
  State<ProfileReportsScreen> createState() => _ProfileReportsScreenState();
}

class _ProfileReportsScreenState extends State<ProfileReportsScreen> {
  List<ProfileReport> _reports = const [];
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
    if (token == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final reports = await widget.api.listProfileReports(token);
      if (mounted) setState(() => _reports = reports);
    } on ApiException catch (error) {
      if (mounted) {
        setState(() => _error = error.statusCode == 403
            ? 'دسترسی مدیریت نداری.'
            : 'دریافت گزارش‌ها ناموفق بود.');
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'دریافت گزارش‌ها ناموفق بود.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resolve(ProfileReport report, bool hide) async {
    final token = widget.token();
    if (token == null || _saving != null) return;
    if (hide) {
      final sure = await showRhythmoConfirm(context,
          title: 'پایین آوردن @${report.handle}؟',
          message: 'نمایه خصوصی می‌شود و صاحبش می‌بیند که تأیید نشده.',
          confirmLabel: 'پایین بیاور',
          destructive: true);
      if (!sure) return;
    }
    setState(() => _saving = report.userId);
    try {
      await widget.api.resolveProfileReports(token, report.userId, hide: hide);
      if (mounted) {
        setState(() => _reports = [
              for (final r in _reports)
                if (r.userId != report.userId) r
            ]);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('انجام نشد. دوباره امتحان کن.')));
      }
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('گزارش نمایه‌ها')),
      body: _loading
          ? const RhythmoStateView.loading(title: 'در حال دریافت گزارش‌ها')
          : _error != null
              ? RhythmoStateView.error(
                  icon: RhythmoIcons.warningCircle,
                  title: _error!,
                  action:
                      TextButton(onPressed: _load, child: const Text('دوباره')))
              : _reports.isEmpty
                  ? const RhythmoStateView(
                      icon: RhythmoIcons.checkCircle, title: 'گزارشی باز نیست.')
                  : ListView(
                      padding: const EdgeInsets.all(RhythmoSpace.lg),
                      children: [
                        for (final report in _reports)
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(RhythmoSpace.lg),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(report.displayName,
                                      style: theme.textTheme.titleMedium),
                                  Text('@${report.handle}',
                                      textDirection: TextDirection.ltr,
                                      textAlign: TextAlign.end),
                                  if (report.bio.isNotEmpty)
                                    Text(report.bio,
                                        maxLines: 4,
                                        overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: RhythmoSpace.sm),
                                  Text(
                                    '${_reasons[report.reason] ?? report.reason}'
                                    ' · ${persianDigits(report.reports)} گزارش',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  if ((report.details ?? '').isNotEmpty)
                                    Text(report.details!,
                                        style: theme.textTheme.bodySmall),
                                  const SizedBox(height: RhythmoSpace.md),
                                  Wrap(
                                    spacing: RhythmoSpace.sm,
                                    alignment: WrapAlignment.end,
                                    children: [
                                      OutlinedButton(
                                        onPressed: _saving != null
                                            ? null
                                            : () => _resolve(report, false),
                                        child: const Text('مشکلی ندارد'),
                                      ),
                                      FilledButton(
                                        onPressed: _saving != null
                                            ? null
                                            : () => _resolve(report, true),
                                        child: const Text('پایین بیاور'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
    );
  }
}
