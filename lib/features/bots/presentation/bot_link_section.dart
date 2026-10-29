import 'package:rhythmo/core/persian_digits.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:flutter/services.dart';
import 'package:rhythmo/features/bots/application/bot_link_controller.dart';
import 'package:rhythmo/features/bots/data/messenger_bot.dart';

/// Settings section for linking a messenger bot chat to this account. It
/// shows nothing when the server runs no bots.
class BotLinkSection extends StatefulWidget {
  const BotLinkSection({super.key, required this.controller});

  final BotLinkController controller;

  @override
  State<BotLinkSection> createState() => _BotLinkSectionState();
}

class _BotLinkSectionState extends State<BotLinkSection> {
  @override
  void initState() {
    super.initState();
    // After this frame: other screens listen to the same controller, and
    // must not be told to rebuild while this one is being built.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => widget.controller.load());
  }

  Future<void> _copy(String text, String done) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final bots = controller.bots;
        if (bots.isEmpty) return const SizedBox.shrink();
        final names = bots.map((b) => b.name).join(' و ');
        final code = controller.code;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(),
            ListTile(
              title: const Text('اتصال به بات'),
              subtitle: Text(
                'آهنگ‌ها را در $names برای بات ریتمو بفرستید تا مستقیم به '
                '«موسیقی من» اضافه شوند. برای اتصال، کد بگیرید و برای بات بفرستید.',
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.tonalIcon(
                  onPressed:
                      controller.requesting ? null : controller.requestCode,
                  icon: const Icon(RhythmoIcons.linkSimple),
                  label: Text(code == null ? 'دریافت کد اتصال' : 'کد تازه'),
                ),
              ),
            ),
            if (controller.error case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (code != null)
              _CodeCard(
                code: code.code,
                expiresAt: code.expiresAt,
                bots: code.bots,
                onCopy: _copy,
              ),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({
    required this.code,
    required this.expiresAt,
    required this.bots,
    required this.onCopy,
  });

  final String code;
  final DateTime expiresAt;
  final List<MessengerBot> bots;
  final Future<void> Function(String text, String done) onCopy;

  @override
  Widget build(BuildContext context) {
    final local = expiresAt.toLocal();
    final until = '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    final grouped = code.length == 8
        ? '${code.substring(0, 4)} ${code.substring(4)}'
        : code;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Directionality(
              textDirection: TextDirection.ltr,
              child: SelectableText(
                grouped,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      letterSpacing: 4,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            const SizedBox(height: 8),
            for (final bot in bots)
              Text(
                bot.username == null
                    ? 'این کد را در ${bot.name} برای بات ریتمو بفرستید.'
                    : 'این کد را در ${bot.name} برای @${bot.username} بفرستید.',
                textAlign: TextAlign.center,
              ),
            Text(
              'تا ساعت ${persianDigits(until)} معتبر است و فقط یک بار کار می‌کند.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => onCopy(code, 'کد کپی شد.'),
                  icon: const Icon(RhythmoIcons.copy),
                  label: const Text('کپی کد'),
                ),
                for (final bot in bots)
                  if (bot.linkUrl case final url?)
                    OutlinedButton.icon(
                      onPressed: () => onCopy(url, 'لینک کپی شد.'),
                      icon: const Icon(RhythmoIcons.arrowSquareOut),
                      label: Text('کپی لینک بات ${bot.name}'),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
