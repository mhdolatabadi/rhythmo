import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/social/data/social.dart';
import 'package:rhythmo/features/social/presentation/profile_avatar.dart';
import 'package:rhythmo/features/social/presentation/social_scope.dart';

/// Picks a small image for the avatar; null when the listener cancelled.
typedef AvatarPicker = Future<Uint8List?> Function();

Future<Uint8List?> pickAvatarImage() async {
  final file = await FilePicker.pickFile(type: FileType.image);
  if (file == null) return null;
  // Larger files are refused before they are read.
  if (await file.xFile.length() > maxAvatarBytes) {
    return Uint8List(maxAvatarBytes + 1);
  }
  return file.xFile.readAsBytes();
}

/// The account's public profile: off until turned on, with a handle,
/// name, bio and picture, and whether followers see its activity.
class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({
    super.key,
    required this.social,
    this.pickAvatar = pickAvatarImage,
    this.onSaved,
  });

  final Social social;
  final AvatarPicker pickAvatar;

  /// Told the saved profile, for example to update the public name shown
  /// in settings.
  final ValueChanged<MyProfile>? onSaved;

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  final _handle = TextEditingController();
  final _name = TextEditingController();
  final _bio = TextEditingController();
  MyProfile? _profile;
  bool _public = false;
  bool _hideActivity = false;
  bool _saving = false;
  bool _failed = false;
  String? _handleError;
  int _avatarVersion = 0;
  List<({String handle, String displayName})> _blocked = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _handle.dispose();
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  String? get _token => widget.social.token();

  Future<void> _load() async {
    final token = _token;
    if (token == null) return;
    setState(() => _failed = false);
    try {
      final profile = await widget.social.api.myProfile(token);
      if (!mounted) return;
      _apply(profile);
      final blocked = await widget.social.api.blocked(token);
      if (mounted) setState(() => _blocked = blocked);
    } catch (_) {
      if (mounted && _profile == null) setState(() => _failed = true);
    }
  }

  void _apply(MyProfile profile) {
    setState(() {
      _profile = profile;
      _handle.text = profile.handle;
      _name.text = profile.displayName;
      _bio.text = profile.bio;
      _public = profile.public;
      _hideActivity = profile.hideActivity;
    });
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// The handle as the server keeps it, or null with the form's error set.
  String? _checkedHandle() {
    final handle = _handle.text.trim().replaceFirst('@', '').toLowerCase();
    String? error;
    if (handle.isEmpty) {
      if (_public) error = 'برای نمایه‌ی عمومی یک شناسه لازم است.';
    } else if (!handlePattern.hasMatch(handle)) {
      error = '۳ تا ۲۰ حرف انگلیسی کوچک، رقم یا _؛ با حرف شروع شود.';
    }
    setState(() => _handleError = error);
    return error == null ? handle : null;
  }

  Future<void> _save() async {
    final token = _token;
    final handle = _checkedHandle();
    if (token == null || handle == null || _saving) return;
    setState(() => _saving = true);
    try {
      final saved = await widget.social.api.updateProfile(token,
          handle: handle,
          displayName: _name.text.trim(),
          bio: _bio.text.trim(),
          public: _public,
          hideActivity: _hideActivity);
      if (!mounted) return;
      _apply(saved);
      widget.onSaved?.call(saved);
      _message(saved.pending
          ? 'ذخیره شد. نمایه‌ات پس از بررسی، عمومی می‌شود.'
          : 'نمایه ذخیره شد.');
    } on ApiException catch (error) {
      switch (error.code) {
        case 'handle_taken':
          setState(() => _handleError = 'این شناسه را کس دیگری برداشته.');
        case 'invalid_handle':
          setState(() => _handleError = 'این شناسه قابل استفاده نیست.');
        case 'invalid_bio':
          _message('معرفی نباید ایمیل یا نویسه‌ی نامعتبر داشته باشد.');
        case 'invalid_display_name':
          _message('نام عمومی نمی‌تواند ایمیل یا بیش از ۴۰ نویسه باشد.');
        default:
          _message('ذخیره ناموفق بود. دوباره امتحان کن.');
      }
    } catch (_) {
      _message('ذخیره ناموفق بود. دوباره امتحان کن.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickAvatar() async {
    final token = _token;
    if (token == null) return;
    final image = await widget.pickAvatar();
    if (image == null || !mounted) return;
    if (image.length > maxAvatarBytes) {
      _message('عکس باید کمتر از ۲۵۶ کیلوبایت باشد.');
      return;
    }
    try {
      final saved = await widget.social.api.setAvatar(token, image);
      if (!mounted) return;
      setState(() {
        _profile = saved;
        _avatarVersion++;
      });
    } on ApiException catch (error) {
      _message(error.code == 'unsupported_avatar'
          ? 'فقط عکس JPEG، PNG یا WebP.'
          : 'عکس ذخیره نشد.');
    } catch (_) {
      _message('عکس ذخیره نشد.');
    }
  }

  Future<void> _removeAvatar() async {
    final token = _token;
    if (token == null) return;
    try {
      await widget.social.api.deleteAvatar(token);
      if (mounted) await _load();
    } catch (_) {
      _message('عکس حذف نشد.');
    }
  }

  Future<void> _unblock(String handle) async {
    final token = _token;
    if (token == null) return;
    try {
      await widget.social.api.setBlocked(token, handle, false);
      if (mounted) {
        setState(() => _blocked = [
              for (final b in _blocked)
                if (b.handle != handle) b
            ]);
      }
    } catch (_) {
      _message('رفع مسدودی ناموفق بود.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return Scaffold(
      appBar: AppBar(
        title: const Text('نمایه‌ی عمومی'),
        actions: [
          TextButton(
            onPressed: profile == null || _saving ? null : _save,
            child: const Text('ذخیره'),
          ),
        ],
      ),
      body: profile == null
          ? (_failed
              ? RhythmoStateView.error(
                  icon: RhythmoIcons.warningCircle,
                  title: 'نمایه باز نشد',
                  action:
                      TextButton(onPressed: _load, child: const Text('دوباره')),
                )
              : const RhythmoStateView.loading(title: 'در حال باز کردن نمایه'))
          : _form(context, profile),
    );
  }

  Widget _form(BuildContext context, MyProfile profile) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final handle = profile.handle;
    final avatar = profile.hasAvatar && handle.isNotEmpty
        ? widget.social.api
            .resolve('/api/v1/users/$handle/avatar?e=$_avatarVersion')
        : null;
    return ListView(
      padding: const EdgeInsets.all(RhythmoSpace.lg),
      children: [
        if (profile.pending)
          _Notice(
              icon: RhythmoIcons.clockCounterClockwise,
              text: 'در انتظار بررسی؛ پس از تأیید برای همه دیده می‌شود.'),
        if (profile.rejected)
          _Notice(
              icon: RhythmoIcons.warningCircle,
              text: 'نمایه‌ات تأیید نشد. آن را اصلاح کن و دوباره عمومی کن.'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('نمایه‌ی عمومی'),
          subtitle: const Text(
              'دیگران نام، معرفی و فهرست‌های پخش عمومی‌ات را می‌بینند. ایمیلت هیچ‌جا نمایش داده نمی‌شود.'),
          value: _public,
          onChanged: (value) => setState(() => _public = value),
        ),
        const SizedBox(height: RhythmoSpace.md),
        Row(
          children: [
            ProfileAvatar(url: avatar, size: 56),
            const SizedBox(width: RhythmoSpace.md),
            TextButton(
              onPressed: handle.isEmpty ? null : _pickAvatar,
              child: Text(profile.hasAvatar ? 'تغییر عکس' : 'افزودن عکس'),
            ),
            if (profile.hasAvatar)
              TextButton(onPressed: _removeAvatar, child: const Text('حذف')),
          ],
        ),
        if (handle.isEmpty)
          Text('اول یک شناسه انتخاب و ذخیره کن.', style: muted),
        const SizedBox(height: RhythmoSpace.lg),
        TextField(
          controller: _handle,
          textDirection: TextDirection.ltr,
          autocorrect: false,
          maxLength: 21,
          decoration: InputDecoration(
            labelText: 'شناسه',
            prefixText: '@',
            helperText: 'نشانی نمایه‌ات: rhythmo.ir/u/شناسه',
            errorText: _handleError,
          ),
        ),
        const SizedBox(height: RhythmoSpace.sm),
        TextField(
          controller: _name,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'نام عمومی'),
        ),
        const SizedBox(height: RhythmoSpace.sm),
        TextField(
          controller: _bio,
          maxLength: maxBioLength,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'معرفی کوتاه'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('پنهان کردن فعالیت'),
          subtitle: const Text(
              'پسندها و فهرست‌های تازه‌ات در «فعالیت دوستان» دیگران نمی‌آید.'),
          value: _hideActivity,
          onChanged: (value) => setState(() => _hideActivity = value),
        ),
        if (_blocked.isNotEmpty) ...[
          const RhythmoSectionHeader(
              title: 'مسدودشده‌ها', padding: EdgeInsets.zero),
          for (final b in _blocked)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(b.displayName),
              subtitle: Text('@${b.handle}', textDirection: TextDirection.ltr),
              trailing: TextButton(
                onPressed: () => _unblock(b.handle),
                child: const Text('رفع'),
              ),
            ),
        ],
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: RhythmoSpace.md),
      child: ListTile(
        leading: Icon(icon, color: colors.secondary),
        title: Text(text, style: Theme.of(context).textTheme.bodyMedium),
      ),
    );
  }
}
