import 'package:flutter/material.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';

/// What public playlists show for an owner who has not picked a name.
const anonymousOwnerName = 'کاربر ریتمو';

/// The longest public name the server accepts.
const maxDisplayNameLength = 40;

/// The account's public name: shown on its public playlists instead of the
/// email, which is never published.
class DisplayNameTile extends StatefulWidget {
  const DisplayNameTile({super.key, required this.name, required this.onSave});

  final String name;
  final Future<void> Function(String name) onSave;

  @override
  State<DisplayNameTile> createState() => _DisplayNameTileState();
}

class _DisplayNameTileState extends State<DisplayNameTile> {
  late String _name = widget.name;

  Future<void> _edit() async {
    final input = await showDialog<String>(
      context: context,
      builder: (context) => _DisplayNameDialog(name: _name),
    );
    if (input == null || !mounted) return;
    final name = input.trim();
    if (name.contains('@')) {
      _message('نام عمومی نمی‌تواند ایمیل باشد.');
      return;
    }
    try {
      await widget.onSave(name);
      if (mounted) setState(() => _name = name);
    } catch (_) {
      _message('ذخیره‌ی نام ناموفق بود. دوباره امتحان کن.');
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(RhythmoIcons.user),
      title: const Text('نام عمومی'),
      subtitle: Text(
        _name.isEmpty
            ? 'انتخاب نشده · «$anonymousOwnerName» نمایش داده می‌شود'
            : _name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(RhythmoIcons.pencilSimple),
      onTap: _edit,
    );
  }
}

/// Owns its text controller, so it is disposed only after the dialog's
/// closing animation.
class _DisplayNameDialog extends StatefulWidget {
  const _DisplayNameDialog({required this.name});

  final String name;

  @override
  State<_DisplayNameDialog> createState() => _DisplayNameDialogState();
}

class _DisplayNameDialogState extends State<_DisplayNameDialog> {
  late final _field = TextEditingController(text: widget.name);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('نام عمومی'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'این نام کنار فهرست‌های پخش عمومی‌ات دیده می‌شود. ایمیلت هیچ‌جا '
              'نمایش داده نمی‌شود. اگر خالی بماند «$anonymousOwnerName» '
              'نوشته می‌شود.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _field,
              autofocus: true,
              maxLength: maxDisplayNameLength,
              decoration: const InputDecoration(hintText: 'مثلاً «نیما»'),
              onSubmitted: (value) => Navigator.pop(context, value),
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
          onPressed: () => Navigator.pop(context, _field.text),
          child: const Text('ذخیره'),
        ),
      ],
    );
  }
}
