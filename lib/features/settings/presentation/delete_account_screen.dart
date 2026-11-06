import 'package:flutter/material.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/widgets/glass_surface.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';

/// Explains what deleting the account removes and deletes it once the
/// password is entered again. On success the app signs out on its own.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({
    super.key,
    required this.email,
    required this.onDelete,
    this.onOpenPage,
  });

  final String email;

  /// Deletes the account; throws when the server refuses.
  final Future<void> Function(String password) onDelete;

  /// Opens a page of the rhythmo site, such as `/privacy`; null hides the
  /// links.
  final void Function(String path)? onOpenPage;

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  bool _obscured = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    // Success signs out and closes this screen, so keep the messenger.
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onDelete(_password.text);
      messenger.showSnackBar(const SnackBar(
        content: Text('حساب کاربری‌ات و همه‌ی اطلاعاتش حذف شد.'),
      ));
    } catch (error) {
      if (mounted) setState(() => _error = _messageFor(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _messageFor(Object error) {
    if (error is! ApiException) {
      return 'اتصال به سرور برقرار نشد. اینترنت را بررسی کن و دوباره تلاش کن.';
    }
    return switch (error.code) {
      'invalid_password' => 'رمز عبور درست نیست.',
      'rate_limited' =>
        'چند بار پشت سر هم تلاش کردی. کمی بعد دوباره امتحان کن.',
      'unauthorized' => 'نشستت تمام شده است. یک بار خارج شو و دوباره وارد شو.',
      _ => 'حذف حساب ناموفق بود. کمی بعد دوباره تلاش کن.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      appBar: AppBar(title: const Text('حذف حساب کاربری')),
      body: RhythmoBackdrop(
          child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + bottomInset),
              children: [
                GlassSurface(
                  padding: const EdgeInsets.all(20),
                  tint: scheme.error,
                  borderColor: scheme.error.withValues(alpha: 0.45),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(RhythmoIcons.warning, color: scheme.error),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'این کار قابل بازگشت نیست',
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text.rich(
                        TextSpan(children: [
                          const TextSpan(text: 'حساب '),
                          TextSpan(
                            text: '\u2068${widget.email}\u2069',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const TextSpan(
                            text: ' همین حالا و برای همیشه حذف می‌شود، با:',
                          ),
                        ]),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const _Removed(
                  icon: RhythmoIcons.cloud,
                  text: 'همه‌ی موسیقی‌هایی که در فضای ابری بارگذاری کرده‌ای',
                ),
                const _Removed(
                  icon: RhythmoIcons.playlist,
                  text: 'فهرست‌های پخشت، با لینک‌های اشتراک و پسندهایشان',
                ),
                const _Removed(
                  icon: RhythmoIcons.musicNotesMinus,
                  text: 'عضویتت در فهرست‌های پخش مشترک و آهنگ‌هایی که به آن‌ها '
                      'اضافه کرده‌ای',
                ),
                const _Removed(
                  icon: RhythmoIcons.robot,
                  text: 'پسندهایت و اتصال به بات‌های بله و تلگرام',
                ),
                const _Removed(
                  icon: RhythmoIcons.userCircle,
                  text: 'خود حساب: ایمیل و رمز عبور',
                ),
                const SizedBox(height: 8),
                Text(
                  'موسیقی‌های روی همین دستگاه و کش پخش دست نمی‌خورند.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _password,
                  obscureText: _obscured,
                  enabled: !_busy,
                  autofillHints: const [AutofillHints.password],
                  textDirection: TextDirection.ltr,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _delete(),
                  decoration: InputDecoration(
                    labelText: 'رمز عبور',
                    helperText: 'برای تأیید، رمز عبور حسابت را وارد کن.',
                    helperMaxLines: 2,
                    suffixIcon: IconButton(
                      tooltip:
                          _obscured ? 'نمایش رمز عبور' : 'پنهان کردن رمز عبور',
                      icon: Icon(
                          _obscured ? RhythmoIcons.eye : RhythmoIcons.eyeSlash),
                      onPressed: () => setState(() => _obscured = !_obscured),
                    ),
                  ),
                  validator: (value) => value == null || value.isEmpty
                      ? 'رمز عبور را وارد کن.'
                      : null,
                ),
                if (_error case final error?) ...[
                  const SizedBox(height: 12),
                  Text(
                    error,
                    style: TextStyle(color: scheme.error),
                    semanticsLabel: error,
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: _busy ? null : _delete,
                  icon: _busy
                      ? SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.onSurface,
                          ),
                        )
                      : const Icon(RhythmoIcons.trash),
                  label: Text(_busy ? 'در حال حذف…' : 'حذف حساب برای همیشه'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('انصراف'),
                ),
                if (widget.onOpenPage case final openPage?) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: () => openPage('/privacy'),
                        icon: const Icon(RhythmoIcons.shieldCheck),
                        label: const Text('حریم خصوصی'),
                      ),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: () => openPage('/delete-account'),
                        icon: const Icon(RhythmoIcons.arrowSquareOut),
                        label: const Text('راهنمای حذف حساب'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      )),
    );
  }
}

class _Removed extends StatelessWidget {
  const _Removed({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
