import 'package:flutter/material.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/admin/data/admin_song_reports.dart';

class SongReportsScreen extends StatefulWidget {
  const SongReportsScreen({super.key, required this.api, required this.token});
  final AdminSongReportsApi api;
  final String? Function() token;
  @override
  State<SongReportsScreen> createState() => _SongReportsScreenState();
}

class _SongReportsScreenState extends State<SongReportsScreen> {
  List<AdminSongReport> _reports = [];
  bool _loading = true;
  bool _denied = false;
  String? _error;
  String? _saving;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = widget.token();
    if (token == null || _denied) {
      if (mounted) {
        setState(() {
          _denied = true;
          _loading = false;
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final reports = await widget.api.songReports(token);
      if (mounted) setState(() => _reports = reports);
    } catch (error) {
      if (mounted) {
        setState(() {
          _denied = error is ApiException &&
              (error.statusCode == 401 || error.statusCode == 403);
          _error =
              _denied ? 'دسترسی مدیریت نداری.' : 'دریافت گزارش‌ها ناموفق بود.';
          if (_denied) _reports = [];
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _decide(AdminSongReport report, bool remove) async {
    if (remove) {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('حذف آهنگ از استور و فهرست‌ها؟'),
                  content: Text(
                      '«${report.track.title}» و همهٔ نسخه‌های گروه‌بندی‌شدهٔ آن از استور و تمام فهرست‌های پخش حذف می‌شوند. فایل خصوصی صاحب آهنگ باقی می‌ماند.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('انصراف')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('حذف از استور و فهرست‌ها'))
                  ]));
      if (confirmed != true || !mounted) return;
    }
    final token = widget.token();
    if (token == null) return;
    setState(() => _saving = report.track.id);
    try {
      await widget.api.moderateSong(token, report.track.id, remove: remove);
      if (mounted) {
        setState(() => _reports =
            _reports.where((r) => r.track.id != report.track.id).toList());
      }
    } catch (error) {
      if (mounted) {
        if (error is ApiException &&
            (error.statusCode == 401 || error.statusCode == 403)) {
          setState(() {
            _denied = true;
            _reports = [];
          });
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_denied
                ? 'دسترسی مدیریت نداری.'
                : 'تغییر ذخیره نشد. دوباره تلاش کن.')));
      }
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('گزارش آهنگ‌ها'), actions: [
        IconButton(
            tooltip: 'تازه‌سازی گزارش‌ها',
            onPressed: _loading || _saving != null || _denied ? null : _load,
            icon: const Icon(RhythmoIcons.arrowsClockwise))
      ]),
      body: SafeArea(
          child: Center(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : ListView(padding: const EdgeInsets.all(16), children: [
                          if (_error != null || _denied)
                            Text(_error ?? 'دسترسی مدیریت نداری.'),
                          if (_error != null && !_denied)
                            TextButton(
                                onPressed: _load,
                                child: const Text('تلاش دوباره')),
                          if (_reports.isEmpty && _error == null && !_denied)
                            const Text('گزارش بازی وجود ندارد.'),
                          for (final report in _reports)
                            Padding(
                                padding: const EdgeInsets.only(bottom: 24),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(report.track.title,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium),
                                      if (report.track.artist != null)
                                        Text(report.track.artist!),
                                      Text(
                                          '${_reason(report.reason)} · ${persianDigits(report.count)} گزارش'),
                                      if (report.details?.isNotEmpty == true)
                                        Padding(
                                            padding: const EdgeInsets.symmetric(
                                                vertical: 8),
                                            child: Text(report.details!)),
                                      Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            OutlinedButton(
                                                onPressed: _saving != null ||
                                                        _denied
                                                    ? null
                                                    : () =>
                                                        _decide(report, false),
                                                child: const Text(
                                                    'بستن گزارش‌ها')),
                                            TextButton.icon(
                                                onPressed: _saving != null ||
                                                        _denied
                                                    ? null
                                                    : () =>
                                                        _decide(report, true),
                                                icon: const Icon(
                                                    RhythmoIcons.trash),
                                                label: const Text(
                                                    'حذف از استور و فهرست‌ها'))
                                          ]),
                                      if (_saving == report.track.id)
                                        const LinearProgressIndicator(),
                                    ])),
                        ])))));
}

String _reason(String reason) => switch (reason) {
      'copyright' => 'حق نشر',
      'broken' => 'مشکل پخش',
      'offensive' => 'محتوای نامناسب',
      'wrong_info' => 'اطلاعات نادرست',
      _ => 'سایر مشکلات',
    };
