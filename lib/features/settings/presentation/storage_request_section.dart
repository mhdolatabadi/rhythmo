import 'package:flutter/material.dart';
import 'package:rhythmo/core/format_size.dart';
import 'package:rhythmo/features/settings/application/storage_request_controller.dart';

const _gib = 1 << 30;

/// The amounts people can ask for, in all.
const storageRequestChoices = [2 * _gib, 5 * _gib, 10 * _gib];

/// Under the storage card: ask for more space, or see how the last ask went
/// (#208).
class StorageRequestSection extends StatefulWidget {
  const StorageRequestSection(
      {super.key, required this.controller, required this.limitBytes});

  final StorageRequestController controller;

  /// The account's quota now; choices at or below it are not offered.
  final int limitBytes;

  @override
  State<StorageRequestSection> createState() => _StorageRequestSectionState();
}

class _StorageRequestSectionState extends State<StorageRequestSection> {
  @override
  void initState() {
    super.initState();
    widget.controller.load();
  }

  Future<void> _ask() async {
    final choices = [
      for (final bytes in storageRequestChoices)
        if (bytes > widget.limitBytes) bytes
    ];
    final asked = await showDialog<(int, String)>(
      context: context,
      builder: (_) => _StorageRequestDialog(choices: choices),
    );
    if (asked == null || !mounted) return;
    final sent = await widget.controller.request(asked.$1, reason: asked.$2);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(sent
          ? 'درخواستت فرستاده شد. نتیجه را همین‌جا می‌بینی.'
          : widget.controller.error ?? 'فرستادن درخواست ناموفق بود.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        final muted = theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        final latest = widget.controller.latest;
        final canAsk = storageRequestChoices.any((b) => b > widget.limitBytes);
        final String? note = switch (latest) {
          final r? when r.pending =>
            'درخواست ${formatSize(r.requestedBytes)} فرستاده شده و در حال بررسی است.',
          final r? when r.rejected => (r.decisionReason ?? '').isEmpty
              ? 'درخواست فضای بیشتر پذیرفته نشد.'
              : 'درخواست فضای بیشتر پذیرفته نشد: ${r.decisionReason}',
          final r?
              when r.approved && (r.grantedBytes ?? 0) >= widget.limitBytes =>
            'درخواستت پذیرفته شد. فضای حسابت ${formatSize(r.grantedBytes!)} است.',
          _ => null,
        };
        final pending = latest?.pending ?? false;
        if (note == null && (!canAsk || !widget.controller.loaded)) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Expanded(child: Text(note ?? '', style: muted)),
              if (canAsk && !pending)
                TextButton(
                  onPressed: widget.controller.sending ? null : _ask,
                  child: const Text('درخواست فضای بیشتر'),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _StorageRequestDialog extends StatefulWidget {
  const _StorageRequestDialog({required this.choices});
  final List<int> choices;

  @override
  State<_StorageRequestDialog> createState() => _StorageRequestDialogState();
}

class _StorageRequestDialogState extends State<_StorageRequestDialog> {
  late int _bytes = widget.choices.first;
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('درخواست فضای بیشتر'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
              'چقدر فضا لازم داری؟ مدیران ریتمو درخواستت را بررسی می‌کنند.'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final bytes in widget.choices)
                ChoiceChip(
                  label: Text(formatSize(bytes)),
                  selected: bytes == _bytes,
                  onSelected: (_) => setState(() => _bytes = bytes),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            maxLength: 300,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'برای چه؟ (اختیاری)',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('انصراف')),
        FilledButton(
            onPressed: () => Navigator.pop(context, (_bytes, _reason.text)),
            child: const Text('فرستادن درخواست')),
      ],
    );
  }
}
