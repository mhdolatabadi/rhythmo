import 'package:flutter/material.dart';
import 'package:rhythmo/app/app_configuration.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/links/open_link.dart';
import 'package:rhythmo/core/links/site_page.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/core/widgets/rhythmo_mark.dart';
import 'package:rhythmo/features/auth/application/auth_controller.dart';

const _minPasswordLength = 8;

class SignInScreen extends StatefulWidget {
  const SignInScreen({
    super.key,
    required this.controller,
    this.siteUri = AppConfiguration.sitePage,
    this.openLink = openExternalLink,
  });

  final AuthController controller;

  /// Where the privacy policy link points.
  final SitePageResolver siteUri;

  final LinkOpener openLink;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _isRegistering = false;
  bool _isBusy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isBusy = true;
      _error = null;
    });
    try {
      if (_isRegistering) {
        await widget.controller.register(_email.text, _password.text);
      } else {
        await widget.controller.login(_email.text, _password.text);
      }
    } catch (error) {
      if (mounted) setState(() => _error = _messageFor(error));
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  static String _messageFor(Object error) {
    if (error is! ApiException) return 'اتصال به سرور برقرار نشد.';
    return switch (error.code) {
      'invalid_credentials' => 'ایمیل یا رمز عبور درست نیست.',
      'email_taken' => 'با این ایمیل قبلاً حساب ساخته شده است.',
      'invalid_email' => 'ایمیل معتبر نیست.',
      'invalid_password' => 'رمز عبور باید ۸ تا ۷۲ کاراکتر باشد.',
      'weak_password' =>
        'این رمز عبور خیلی رایج یا قابل حدس است. رمز دیگری انتخاب کن.',
      'rate_limited' => 'تلاش‌ها زیاد بود. چند دقیقه بعد دوباره امتحان کن.',
      _ => 'خطایی رخ داد. دوباره تلاش کن.',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Opened from the guest home, it can go back to browsing.
      appBar: Navigator.canPop(context) ? AppBar() : null,
      // The same brand and aurora as the app it opens onto.
      body: RhythmoBackdrop(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(RhythmoSpace.xxl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: _formKey,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: RhythmoMark(size: 56)),
                      const SizedBox(height: RhythmoSpace.lg),
                      Text(
                        _isRegistering ? 'ساخت حساب ریتمو' : 'ورود به ریتمو',
                        style: Theme.of(context).textTheme.headlineSmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: RhythmoSpace.xs),
                      Text(
                        'موسیقی خودت، با کیفیت اصلی، روی همهٔ دستگاه‌هایت.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: RhythmoSpace.xl),
                      GlassSurface(
                        radius: RhythmoRadii.lg,
                        blur: 0,
                        shadow: false,
                        padding: const EdgeInsets.all(RhythmoSpace.lg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextFormField(
                              controller: _email,
                              decoration:
                                  const InputDecoration(labelText: 'ایمیل'),
                              keyboardType: TextInputType.emailAddress,
                              autofillHints: const [AutofillHints.email],
                              textDirection: TextDirection.ltr,
                              validator: (value) =>
                                  value == null || !value.contains('@')
                                      ? 'ایمیل معتبر وارد کن.'
                                      : null,
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _password,
                              decoration:
                                  const InputDecoration(labelText: 'رمز عبور'),
                              obscureText: true,
                              autofillHints: [
                                _isRegistering
                                    ? AutofillHints.newPassword
                                    : AutofillHints.password,
                              ],
                              textDirection: TextDirection.ltr,
                              onFieldSubmitted: (_) => _submit(),
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return 'رمز عبور را وارد کن.';
                                }
                                if (_isRegistering &&
                                    value.length < _minPasswordLength) {
                                  return 'رمز عبور باید حداقل ۸ کاراکتر باشد.';
                                }
                                return null;
                              },
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: 12),
                              Text(
                                _error!,
                                style: TextStyle(
                                    color: Theme.of(context).colorScheme.error),
                              ),
                            ],
                            const SizedBox(height: RhythmoSpace.lg),
                            FilledButton(
                              onPressed: _isBusy ? null : _submit,
                              child:
                                  Text(_isRegistering ? 'ساخت حساب' : 'ورود'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: RhythmoSpace.sm),
                      TextButton(
                        onPressed: _isBusy
                            ? null
                            : () => setState(() {
                                  _isRegistering = !_isRegistering;
                                  _error = null;
                                }),
                        child: Text(_isRegistering
                            ? 'حساب داری؟ وارد شو'
                            : 'حساب نداری؟ ثبت‌نام کن'),
                      ),
                      // Readable before signing up, as the stores expect.
                      TextButton.icon(
                        onPressed: () => openSitePage(context, '/privacy',
                            siteUri: widget.siteUri, openLink: widget.openLink),
                        icon: const Icon(RhythmoIcons.shieldCheck, size: 20),
                        label: const Text('حریم خصوصی'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
