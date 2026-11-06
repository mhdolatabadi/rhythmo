import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/features/feedback/feedback_api.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/persian_digits.dart';

String feedbackKind(String value) => switch (value) {
      'bug' => 'گزارش باگ',
      'feature' => 'درخواست قابلیت',
      _ => 'پیام',
    };

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen(
      {super.key, required this.api, required this.token, this.admin = false});
  final FeedbackApi api;
  final String? Function() token;
  final bool admin;
  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final _form = GlobalKey<FormState>();
  final _subject = TextEditingController(), _body = TextEditingController();
  String _kind = 'bug';
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>> _items = [];
  @override
  void initState() {
    super.initState();
    if (widget.admin) _load();
  }

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function(String) action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = widget.token();
      if (token == null) throw StateError('signed out');
      await action(token);
    } catch (error) {
      if (mounted &&
          error is ApiException &&
          (error.statusCode == 401 || error.statusCode == 403)) {
        setState(() => _items = []);
      }
      if (mounted) {
        setState(() => _error =
            'انجام نشد. اتصال و دسترسی حساب را بررسی کن و دوباره تلاش کن.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run((token) async {
        final items = await widget.api.feedbackInbox(token);
        if (mounted) setState(() => _items = items);
      });
  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    await _run((token) async {
      await widget.api.submitFeedback(
          token, _kind, _subject.text.trim(), _body.text.trim());
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('پیامت برای مدیر ارسال شد.'),
          duration: Duration(seconds: 4)));
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          title: Text(widget.admin ? 'پیام‌های کاربران' : 'ارتباط با مدیر'),
          actions: [
            if (widget.admin)
              IconButton(
                  tooltip: 'تازه‌سازی',
                  onPressed: _busy ? null : _load,
                  icon: const Icon(Icons.refresh))
          ]),
      body: RhythmoBackdrop(
          child: SafeArea(
              child: Center(
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            if (_busy) const LinearProgressIndicator(),
                            if (_error != null)
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  child: Text(_error!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error))),
                            if (widget.admin) ...[
                              if (!_busy && _items.isEmpty && _error == null)
                                const Text('پیام بازی وجود ندارد.'),
                              for (final item in _items)
                                Padding(
                                    padding: const EdgeInsets.only(bottom: 24),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Text(
                                              '${feedbackKind(item['kind'] as String)} · ${item['subject']}',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium),
                                          SelectableText(
                                              item['email'] as String),
                                          Text(persianDigits((DateTime.tryParse(
                                                          item['created_at']
                                                              as String)
                                                      ?.toLocal()
                                                      .toString() ??
                                                  '')
                                              .split('.')
                                              .first)),
                                          const SizedBox(height: 8),
                                          SelectableText(
                                              item['body'] as String),
                                          Align(
                                              alignment: AlignmentDirectional
                                                  .centerEnd,
                                              child: TextButton(
                                                  onPressed: _busy
                                                      ? null
                                                      : () =>
                                                          _run((token) async {
                                                            await widget.api
                                                                .resolveFeedback(
                                                                    token,
                                                                    item['id']
                                                                        as String);
                                                            if (mounted) {
                                                              setState(() =>
                                                                  _items.remove(
                                                                      item));
                                                            }
                                                          }),
                                                  child:
                                                      const Text('رسیدگی شد'))),
                                        ])),
                            ] else
                              Form(
                                  key: _form,
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        const Text(
                                            'باگ دیدی، پیشنهادی داری یا می‌خواهی پیامی بفرستی؟'),
                                        const SizedBox(height: 16),
                                        DropdownButtonFormField<String>(
                                            initialValue: _kind,
                                            decoration: const InputDecoration(
                                                labelText: 'نوع پیام'),
                                            items: [
                                              for (final kind in [
                                                'bug',
                                                'feature',
                                                'message'
                                              ])
                                                DropdownMenuItem(
                                                    value: kind,
                                                    child: Text(
                                                        feedbackKind(kind)))
                                            ],
                                            onChanged: _busy
                                                ? null
                                                : (value) => setState(
                                                    () => _kind = value!)),
                                        const SizedBox(height: 12),
                                        TextFormField(
                                            controller: _subject,
                                            enabled: !_busy,
                                            maxLength: 160,
                                            decoration: const InputDecoration(
                                                labelText: 'موضوع'),
                                            validator: (v) =>
                                                v == null || v.trim().isEmpty
                                                    ? 'موضوع را بنویس.'
                                                    : null),
                                        const SizedBox(height: 12),
                                        TextFormField(
                                            controller: _body,
                                            enabled: !_busy,
                                            minLines: 5,
                                            maxLines: 12,
                                            maxLength: 5000,
                                            decoration: const InputDecoration(
                                                labelText: 'توضیحات'),
                                            validator: (v) =>
                                                v == null || v.trim().isEmpty
                                                    ? 'توضیحات را بنویس.'
                                                    : null),
                                        const SizedBox(height: 16),
                                        FilledButton(
                                            onPressed: _busy ? null : _submit,
                                            child:
                                                const Text('ارسال برای مدیر')),
                                      ])),
                          ]))))));
}
