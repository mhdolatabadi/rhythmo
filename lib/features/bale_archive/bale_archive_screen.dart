import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/glass_surface.dart';

import 'bale_archive.dart';

class BaleArchiveScreen extends StatefulWidget {
  const BaleArchiveScreen({super.key, required this.api, required this.token});
  final BaleArchiveApi api;
  final String? Function() token;
  @override
  State<BaleArchiveScreen> createState() => _BaleArchiveScreenState();
}

class _BaleArchiveScreenState extends State<BaleArchiveScreen> {
  final Map<String, BaleLecture> _entries = {};
  final Map<String, String> _submitted = {};
  List<BaleArchiveJob> _jobs = [];
  int? _before;
  bool _done = false, _loading = false, _importing = false, _polling = false;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshJobs();
    _timer = Timer.periodic(const Duration(seconds: 6), (_) => _refreshJobs());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _message(Object error) {
    if (error is ApiException) {
      switch (error.code) {
        case 'admin_required':
          return 'دسترسی مدیریت لازم است.';
        case 'too_many_imports':
          return 'صف پر است؛ بعد از پایان دانلودها دوباره تلاش کن.';
        case 'topic_required':
          return 'موضوع این سخنرانی را مشخص کن.';
        case 'session_required':
          return 'شمارهٔ جلسه را مشخص کن.';
        case 'too_large':
          return 'حجم این فایل از سقف مجاز بیشتر است.';
        case 'uploads_disabled':
          return 'آپلود در حال حاضر غیرفعال است.';
        case 'rate_limited':
          return 'کمی صبر کن و دوباره تلاش کن.';
      }
    }
    return 'ارتباط با آرشیو ممکن نشد. دوباره تلاش کن.';
  }

  Future<void> _load({bool restart = false}) async {
    if (_loading || _importing) return;
    final token = widget.token();
    if (token == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.api.previewBaleArchive(
        token,
        before: restart ? null : _before,
      );
      if (!mounted) return;
      setState(() {
        for (final entry in page.entries) {
          _entries.putIfAbsent(entry.id, () => entry);
        }
        _before = page.nextBefore == 0 ? null : page.nextBefore;
        _done = page.done;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshJobs() async {
    final token = widget.token();
    if (_polling || token == null) return;
    _polling = true;
    try {
      final jobs = await widget.api.baleArchiveJobs(token);
      if (mounted) setState(() => _jobs = jobs);
    } catch (_) {
      // A transient status failure must not discard a successful submission.
    } finally {
      _polling = false;
    }
  }

  Future<void> _import(List<BaleLecture> entries) async {
    final token = widget.token();
    if (token == null || _importing || _loading) return;
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      for (final entry in entries) {
        if (!mounted) return;
        final job = await widget.api.importBaleLecture(token, entry);
        if (!mounted) return;
        setState(() {
          _submitted[entry.id] = job.id;
        });
      }
      await _refreshJobs();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _review(BaleLecture entry) async {
    var topic = entry.topic;
    var session = entry.session > 0 ? '${entry.session}' : '';
    final form = GlobalKey<FormState>();
    final result = await showDialog<BaleLecture>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('موضوع و جلسه'),
        content: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: topic,
                onChanged: (value) => topic = value,
                maxLength: 180,
                decoration: const InputDecoration(labelText: 'موضوع مجموعه'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'موضوع را بنویس.' : null,
              ),
              TextFormField(
                initialValue: session,
                onChanged: (value) => session = value,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'شمارهٔ جلسه'),
                validator: (v) => _number(v) == null
                    ? 'شماره‌ای بین ۱ تا ۱۰۰۰۰ بنویس.'
                    : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(
                  context,
                  entry.reviewed(topic.trim(), _number(session)!),
                );
              }
            },
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    if (mounted && result != null) setState(() => _entries[entry.id] = result);
  }

  static int? _number(String? value) {
    const fa = '۰۱۲۳۴۵۶۷۸۹', ar = '٠١٢٣٤٥٦٧٨٩';
    final text = (value ?? '').trim().split('').map((c) {
      final f = fa.indexOf(c), a = ar.indexOf(c);
      return f >= 0
          ? '$f'
          : a >= 0
              ? '$a'
              : c;
    }).join();
    final n = int.tryParse(text);
    return n != null && n > 0 && n <= 10000 ? n : null;
  }

  BaleArchiveJob? _jobFor(BaleLecture entry) {
    final id = _submitted[entry.id];
    for (final job in _jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  String _state(BaleArchiveJob job) => switch (job.state) {
        'done' => 'وارد شد',
        'failed' => switch (job.error) {
            'quota_exceeded' => 'ظرفیت حساب کافی نیست',
            'too_large' => 'حجم بیش از حد مجاز',
            'invalid_audio' => 'فایل صوتی معتبر نیست',
            _ => 'ناموفق؛ دوباره تلاش کن',
          },
        'downloading' => 'در حال دانلود',
        _ => 'در صف',
      };

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<BaleLecture>>{};
    for (final entry in _entries.values) {
      groups
          .putIfAbsent(
            entry.topic.isEmpty ? 'نیازمند بررسی' : entry.topic,
            () => [],
          )
          .add(entry);
    }
    for (final entries in groups.values) {
      entries.sort((a, b) => a.session.compareTo(b.session));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('آرشیو حامد کاشانی'),
        actions: [
          IconButton(
            tooltip: 'بررسی پست‌های جدید',
            onPressed:
                _loading || _importing ? null : () => _load(restart: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RhythmoBackdrop(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                children: [
                  const GlassSurface(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'فقط صوت‌های دارای 🎙 و #سخنرانی_کامل از کانال @kashani1395 انتخاب می‌شوند. هر موضوع، فهرست پخش جدا دارد. فایل‌ها با کیفیت اصلی در حساب تو ذخیره می‌شوند؛ انتشار با خودت است.',
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (!_loading && _entries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'در پست‌های بررسی‌شده سخنرانی کاملی نبود. پست‌های قدیمی‌تر را بررسی کن.',
                      ),
                    ),
                  for (final group in groups.entries)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: GlassSurface(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              group.key,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Text(persianDigits('${group.value.length} جلسه')),
                            for (final entry in group.value) _lectureRow(entry),
                            if (group.value.any(
                              (e) =>
                                  !e.needsReview &&
                                  (!_submitted.containsKey(e.id) ||
                                      _jobFor(e)?.state == 'failed'),
                            ))
                              TextButton(
                                onPressed: _loading || _importing
                                    ? null
                                    : () => _import(
                                          group.value
                                              .where(
                                                (e) =>
                                                    !e.needsReview &&
                                                    (!_submitted.containsKey(
                                                          e.id,
                                                        ) ||
                                                        _jobFor(e)?.state ==
                                                            'failed'),
                                              )
                                              .toList(),
                                        ),
                                child: const Text(
                                  'واردکردن جلسه‌های آمادهٔ این موضوع',
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  if (!_done)
                    OutlinedButton(
                      onPressed: _loading || _importing ? null : () => _load(),
                      child: const Text('بررسی پست‌های قدیمی‌تر'),
                    ),
                  if (_done) const Text('به پایان تاریخچهٔ عمومی رسیدیم.'),
                  if (_jobs.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      'وضعیت واردکردن',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    for (final job in _jobs)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          job.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(_state(job)),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _lectureRow(BaleLecture entry) {
    final job = _jobFor(entry);
    final submitted =
        _submitted.containsKey(entry.id) && job?.state != 'failed';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            entry.title.isEmpty ? 'عنوان نیازمند بررسی' : entry.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                entry.needsReview
                    ? 'موضوع یا جلسه را بررسی کن'
                    : persianDigits('جلسهٔ ${entry.session}'),
              ),
              if (job != null) Text(_state(job)),
              if (!submitted)
                TextButton(
                  onPressed: _importing ? null : () => _review(entry),
                  child: const Text('اصلاح'),
                ),
              FilledButton.tonal(
                onPressed:
                    _loading || _importing || entry.needsReview || submitted
                        ? null
                        : () => _import([entry]),
                child: Text(
                  submitted
                      ? 'ثبت شد'
                      : job?.state == 'failed'
                          ? 'تلاش دوباره'
                          : 'واردکردن',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
