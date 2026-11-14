import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/widgets/rhythmo_mark.dart';
import 'package:rhythmo/features/auth/application/auth_controller.dart';

const _minPasswordLength = 8;

/// The message for a failed code or reset request.
String accountCodeMessage(Object error) {
  if (error is! ApiException) return 'اتصال به سرور برقرار نشد.';
  return switch (error.code) {
    'invalid_code' =>
      'کد درست نیست یا منقضی شده. اگر چند بار اشتباه زدی، کد تازه بگیر.',
    'email_taken' => 'با این ایمیل همین حالا حساب ساخته شده است. وارد شو.',
    'invalid_email' => 'ایمیل معتبر نیست.',
    'invalid_password' => 'رمز عبور باید ۸ تا ۷۲ کاراکتر باشد.',
    'weak_password' =>
      'این رمز عبور خیلی رایج یا قابل حدس است. رمز دیگری انتخاب کن.',
    'rate_limited' => 'تلاش‌ها زیاد بود. چند دقیقه بعد دوباره امتحان کن.',
    _ => 'خطایی رخ داد. دوباره تلاش کن.',
  };
}

/// Goes back to the screen under the sign-in flow once it signed in, so
/// the app the auth gate now shows is not covered.
void _closeSignIn(BuildContext context) {
  Navigator.of(context).popUntil((route) => route.isFirst);
}

class _CodeField extends StatelessWidget {
  const _CodeField({required this.controller, this.onSubmitted});

  final TextEditingController controller;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      decoration: const InputDecoration(labelText: 'کد ۶ رقمی'),
      keyboardType: TextInputType.number,
      autofillHints: const [AutofillHints.oneTimeCode],
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      inputFormatters: [LengthLimitingTextInputFormatter(7)],
      onFieldSubmitted: onSubmitted,
      validator: (value) => value == null || value.trim().length < 6
          ? 'کد ۶ رقمی ایمیل را وارد کن.'
          : null,
    );
  }
}

/// A password field with a show/hide toggle.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    this.label = 'رمز عبور',
    this.isNew = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;

  /// Whether this sets a password, which then needs eight characters.
  final bool isNew;
  final ValueChanged<String>? onSubmitted;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      decoration: InputDecoration(
        labelText: widget.label,
        suffixIcon: IconButton(
          tooltip: _visible ? 'پنهان کردن رمز' : 'نمایش رمز',
          icon: Icon(_visible
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined),
          onPressed: () => setState(() => _visible = !_visible),
        ),
      ),
      obscureText: !_visible,
      autofillHints: [
        widget.isNew ? AutofillHints.newPassword : AutofillHints.password
      ],
      textDirection: TextDirection.ltr,
      onFieldSubmitted: widget.onSubmitted,
      validator: (value) {
        if (value == null || value.isEmpty) return 'رمز عبور را وارد کن.';
        if (widget.isNew && value.length < _minPasswordLength) {
          return 'رمز عبور باید حداقل ۸ کاراکتر باشد.';
        }
        return null;
      },
    );
  }
}

/// The frame every sign-in step shares: the mark, a title, a line of
/// explanation and a glass card.
class _AuthStep extends StatelessWidget {
  const _AuthStep(
      {required this.title, required this.message, required this.children});

  final String title;
  final String message;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(),
      body: RhythmoBackdrop(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(RhythmoSpace.xxl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: RhythmoMark(size: 48)),
                  const SizedBox(height: RhythmoSpace.lg),
                  Text(title,
                      style: theme.textTheme.headlineSmall,
                      textAlign: TextAlign.center),
                  const SizedBox(height: RhythmoSpace.xs),
                  Text(
                    message,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
                      children: children,
                    ),
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

Widget _errorLine(BuildContext context, String? error) => error == null
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(error,
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );

/// Finishes a sign-up with the code mailed to [email] (#219).
class SignupCodeScreen extends StatefulWidget {
  const SignupCodeScreen(
      {super.key,
      required this.controller,
      required this.email,
      required this.password});

  final AuthController controller;
  final String email;

  /// Kept to mail a fresh code by registering again.
  final String password;

  @override
  State<SignupCodeScreen> createState() => _SignupCodeScreenState();
}

class _SignupCodeScreenState extends State<SignupCodeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = accountCodeMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    if (!_formKey.currentState!.validate()) return;
    await _run(() async {
      await widget.controller.confirmRegistration(widget.email, _code.text);
      if (mounted) _closeSignIn(context);
    });
  }

  Future<void> _resend() => _run(() async {
        await widget.controller.register(widget.email, widget.password);
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('کد تازه فرستاده شد.')));
      });

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: _AuthStep(
        title: 'تأیید ایمیل',
        message: 'کدی را که به ${widget.email} فرستادیم وارد کن. اگر این ایمیل '
            'از قبل حساب داشته باشد، به‌جای کد راهنمای ورود برایش می‌فرستیم.',
        children: [
          _CodeField(controller: _code, onSubmitted: (_) => _confirm()),
          _errorLine(context, _error),
          const SizedBox(height: RhythmoSpace.lg),
          FilledButton(
            onPressed: _busy ? null : _confirm,
            child: const Text('ساخت حساب'),
          ),
          TextButton(
            onPressed: _busy ? null : _resend,
            child: const Text('کد را دوباره بفرست'),
          ),
        ],
      ),
    );
  }
}

/// Sets a new password with an emailed code (#380).
class PasswordResetScreen extends StatefulWidget {
  const PasswordResetScreen(
      {super.key, required this.controller, this.email = ''});

  final AuthController controller;
  final String email;

  @override
  State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}

class _PasswordResetScreenState extends State<PasswordResetScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.email);
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_codeSent) {
        await widget.controller
            .resetPassword(_email.text, _code.text, _password.text);
        if (mounted) _closeSignIn(context);
      } else {
        await widget.controller.forgotPassword(_email.text);
        if (mounted) setState(() => _codeSent = true);
      }
    } catch (error) {
      if (mounted) setState(() => _error = accountCodeMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: _AuthStep(
        title: 'بازیابی رمز عبور',
        message: _codeSent
            ? 'اگر این ایمیل در ریتمو حساب داشته باشد، کدی برایش فرستادیم. کد و '
                'رمز تازه را وارد کن. بعد از تغییر رمز، از بقیه‌ی دستگاه‌ها خارج '
                'می‌شوی.'
            : 'ایمیل حسابت را وارد کن تا کد تغییر رمز را برایت بفرستیم.',
        children: [
          TextFormField(
            controller: _email,
            enabled: !_codeSent,
            decoration: const InputDecoration(labelText: 'ایمیل'),
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            textDirection: TextDirection.ltr,
            validator: (value) => value == null || !value.contains('@')
                ? 'ایمیل معتبر وارد کن.'
                : null,
          ),
          if (_codeSent) ...[
            const SizedBox(height: 12),
            _CodeField(controller: _code),
            const SizedBox(height: 12),
            PasswordField(
              controller: _password,
              label: 'رمز عبور تازه',
              isNew: true,
              onSubmitted: (_) => _submit(),
            ),
          ],
          _errorLine(context, _error),
          const SizedBox(height: RhythmoSpace.lg),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(_codeSent ? 'تغییر رمز و ورود' : 'فرستادن کد'),
          ),
          if (_codeSent)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _codeSent = false;
                        _error = null;
                      }),
              child: const Text('کد نرسید؟ دوباره بفرست'),
            ),
        ],
      ),
    );
  }
}
