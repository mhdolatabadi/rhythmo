import 'dart:async';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/glass_surface.dart';
import 'bale_archive.dart';

class BaleArchiveScreen extends StatefulWidget {
  const BaleArchiveScreen({super.key, required this.api, required this.token});
  final BaleTopicCatalogApi api;
  final String? Function() token;
  @override
  State<BaleArchiveScreen> createState() => _BaleArchiveScreenState();
}

class _BaleArchiveScreenState extends State<BaleArchiveScreen> {
  BaleTopicCatalog? _catalog;
  String? _error, _sending;
  String _query = '';
  bool _loading = false;
  DateTime? _retryAt;
  Timer? _timer;
  int get _seconds {
    final n = _retryAt?.difference(DateTime.now()).inMilliseconds ?? 0;
    return n > 0 ? (n / 1000).ceil() : 0;
  }

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (timer.tick % 6 == 0) _load(background: true);
      if (_retryAt != null && mounted)
        setState(() {
          if (_seconds == 0) _retryAt = null;
        });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _fail(Object error) {
    if (error is ApiException && error.code == 'rate_limited') {
      final value = error.details['retryAfterSeconds'];
      final seconds = value is num ? value.toInt() : 30;
      _retryAt =
          DateTime.now().add(Duration(seconds: seconds.clamp(1, 3600).toInt()));
      _error = 'محدودیت درخواست؛ کمی صبر کن و دوباره تلاش کن.';
    } else if (error is ApiException &&
        (error.statusCode == 401 || error.statusCode == 403)) {
      _error = 'برای مشاهدهٔ آرشیو باید وارد حساب مدیر شوی.';
    } else {
      _error = 'دریافت موضوع‌ها ممکن نشد. دوباره تلاش کن.';
    }
  }

  Future<void> _load({bool background = false}) async {
    final token = widget.token();
    if (_loading || token == null) return;
    if (_seconds > 0) return;
    _loading = true;
    if (!background && mounted) setState(() => _error = null);
    try {
      final data = await widget.api.baleTopics(token);
      if (mounted)
        setState(() {
          _catalog = data;
          if (_seconds == 0) _error = null;
        });
    } catch (error) {
      if (mounted) setState(() => _fail(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    final token = widget.token();
    if (token == null || _sending != null || _seconds > 0) return;
    setState(() {
      _sending = '';
      _error = null;
    });
    try {
      await widget.api.refreshBaleTopics(token);
      await _load();
    } catch (error) {
      if (mounted) setState(() => _fail(error));
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  Future<void> _import(BaleTopic topic) async {
    final token = widget.token();
    if (token == null || _sending != null || _seconds > 0) return;
    setState(() {
      _sending = topic.key;
      _error = null;
    });
    try {
      await widget.api.importBaleTopic(token, topic.key);
      await _load();
    } catch (error) {
      if (mounted) setState(() => _fail(error));
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  String _status(BaleTopic t) => switch (t.state) {
        'imported' => 'قبلاً کامل وارد شده',
        'importing' => 'در حال واردکردن کامل موضوع',
        'partial' => 'بخشی از موضوع قبلاً وارد شده',
        'failed' => switch (t.error) {
            'quota_exceeded' =>
              'ظرفیت حساب کافی نیست؛ پس از افزایش ظرفیت دوباره تلاش کن.',
            'uploads_disabled' => 'واردکردن فایل فعلاً غیرفعال است.',
            'too_large' => 'حجم یکی از جلسه‌ها از سقف مجاز بیشتر است.',
            _ => 'واردکردن متوقف شد؛ جلسه‌های موفق حفظ شده‌اند.',
          },
        _ => 'آمادهٔ واردکردن',
      };
  Widget _topic(BaleTopic topic) {
    final active = topic.state == 'importing';
    final complete = topic.state == 'imported';
    return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: GlassSurface(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(topic.name, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(persianDigits(
                '${topic.total} جلسه · ${topic.imported} واردشده${topic.pending > 0 ? ' · ${topic.pending} در صف' : ''}')),
            const SizedBox(height: 4),
            Text(_status(topic)),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: active || complete || _sending != null || _seconds > 0
                  ? null
                  : () => _import(topic),
              child: Text(_sending == topic.key
                  ? 'در حال ثبت درخواست…'
                  : complete
                      ? 'وارد شده'
                      : active
                          ? 'واردکردن در پس‌زمینه ادامه دارد'
                          : topic.state == 'failed'
                              ? 'تلاش دوباره برای کامل‌کردن موضوع'
                              : topic.imported > 0
                                  ? 'واردکردن جلسه‌های باقی‌مانده'
                                  : 'واردکردن کامل موضوع'),
            ),
          ]),
        ));
  }

  @override
  Widget build(BuildContext context) {
    final data = _catalog;
    final topics =
        data?.topics.where((t) => t.name.contains(_query.trim())).toList() ??
            <BaleTopic>[];
    return Scaffold(
        appBar: AppBar(title: const Text('موضوع‌های حامد کاشانی'), actions: [
          IconButton(
              tooltip: 'به‌روزرسانی کل موضوع‌ها',
              onPressed: _sending != null || _seconds > 0 ? null : _refresh,
              icon: const Icon(Icons.refresh)),
        ]),
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
                      'یک موضوع را انتخاب کن؛ تمام سخنرانی‌های کامل آن در یک فهرست پخش جدا وارد می‌شوند. با بستن این صفحه هم کار در سرور ادامه دارد و جلسه‌های قبلی تکرار نمی‌شوند.')),
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(_error!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error)),
                          TextButton(
                              onPressed: _seconds > 0 ? null : () => _load(),
                              child: Text(_seconds > 0
                                  ? 'تلاش دوباره در ${persianDigits(_seconds)} ثانیه'
                                  : 'تلاش دوباره')),
                        ])),
              if (data == null && _loading)
                const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator())),
              if (data != null) ...[
                const SizedBox(height: 16),
                Text(data.complete
                    ? 'فهرست موضوع‌ها کامل است · ${persianDigits(data.topics.length)} موضوع'
                    : 'در حال بررسی کل تاریخچه · ${persianDigits(data.scannedPosts)} پست · ${persianDigits(data.topics.length)} موضوع پیدا شده'),
                if (!data.complete)
                  const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                          'موضوع‌های جدید به‌تدریج ظاهر می‌شوند. واردکردن هر موضوع، جلسه‌های بعدیِ پیدا‌شده را هم شامل می‌شود.')),
                if (data.scanError != null)
                  const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                          'ارتباط با بله موقتاً برقرار نیست؛ اسکن از محل توقف دوباره تلاش می‌شود.')),
                if (data.unclassified > 0)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                          '${persianDigits(data.unclassified)} سخنرانی عنوان موضوع مشخصی ندارد و نیازمند بررسی است.')),
                const SizedBox(height: 16),
                TextField(
                    onChanged: (v) => setState(() => _query = v),
                    decoration: const InputDecoration(
                        labelText: 'جست‌وجوی موضوع',
                        prefixIcon: Icon(Icons.search))),
                for (final topic in topics) _topic(topic),
                if (topics.isEmpty && _error == null)
                  Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_query.isNotEmpty
                          ? 'موضوعی با این نام پیدا نشد.'
                          : data.complete
                              ? 'در تاریخچهٔ عمومی موضوعی پیدا نشد.'
                              : 'اسکن در حال انجام است؛ هنوز موضوعی پیدا نشده.')),
              ],
            ],
          ),
        )))));
  }
}
