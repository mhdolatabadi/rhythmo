import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';

/// How far the arrow keys seek.
const shortcutSeekStep = Duration(seconds: 5);

/// How much the up and down keys change the volume.
const shortcutVolumeStep = 0.1;

/// The keyboard shortcuts, in the order the «?» sheet lists them.
const playerShortcutHelp = <(String, String)>[
  ('Space', 'پخش / توقف'),
  ('→  ←', 'جلو / عقب، ۵ ثانیه'),
  ('Shift + →  ←', 'آهنگ بعدی / قبلی'),
  ('↑  ↓', 'بلندتر / آهسته‌تر'),
  ('M', 'بی‌صدا'),
  ('?', 'همین فهرست'),
];

class _PlayerIntent extends Intent {
  const _PlayerIntent(this.run,
      {this.yieldsToActivate = false, this.needsTrack = true});

  final void Function(PlayerController player, BuildContext context) run;

  /// Space also presses a focused button; then the button wins.
  final bool yieldsToActivate;

  /// Most keys act on the playing song; the help sheet opens without one.
  final bool needsTrack;
}

/// App-wide player keys for a keyboard (#381). Keys pass through untouched
/// while typing in a text field, and a focused control keeps its own keys:
/// Space presses a focused button, the arrows move a focused slider.
class PlayerShortcuts extends StatelessWidget {
  const PlayerShortcuts({super.key, required this.player, required this.child});

  final PlayerController player;
  final Widget child;

  static Future<void> _seekBy(PlayerController player, Duration by) {
    final duration = player.duration;
    var to = player.position + by;
    if (to < Duration.zero) to = Duration.zero;
    if (duration != null && to > duration) to = duration;
    return player.seek(to);
  }

  static final _shortcuts = <ShortcutActivator, Intent>{
    const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
        _PlayerIntent((p, _) => p.toggle(), yieldsToActivate: true),
    const SingleActivator(LogicalKeyboardKey.arrowRight):
        _PlayerIntent((p, _) => _seekBy(p, shortcutSeekStep)),
    const SingleActivator(LogicalKeyboardKey.arrowLeft):
        _PlayerIntent((p, _) => _seekBy(p, -shortcutSeekStep)),
    const SingleActivator(LogicalKeyboardKey.arrowRight,
        shift: true, includeRepeats: false): _PlayerIntent((p, _) => p.next()),
    const SingleActivator(LogicalKeyboardKey.arrowLeft,
        shift: true,
        includeRepeats: false): _PlayerIntent((p, _) => p.previous()),
    const SingleActivator(LogicalKeyboardKey.arrowUp):
        _PlayerIntent((p, _) => p.setVolume(p.volume + shortcutVolumeStep)),
    const SingleActivator(LogicalKeyboardKey.arrowDown):
        _PlayerIntent((p, _) => p.setVolume(p.volume - shortcutVolumeStep)),
    const SingleActivator(LogicalKeyboardKey.keyM, includeRepeats: false):
        _PlayerIntent((p, _) => p.toggleMute()),
    const CharacterActivator('?'): _PlayerIntent(
        (_, context) => showPlayerShortcutHelp(context),
        needsTrack: false),
  };

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: _shortcuts,
      child: Actions(
        actions: {_PlayerIntent: _PlayerAction(player)},
        child: child,
      ),
    );
  }
}

class _PlayerAction extends ContextAction<_PlayerIntent> {
  _PlayerAction(this.player);

  final PlayerController player;

  BuildContext? get _focused => FocusManager.instance.primaryFocus?.context;

  @override
  bool isEnabled(_PlayerIntent intent, [BuildContext? context]) {
    final focused = _focused;
    if (focused != null) {
      if (focused.widget is EditableText ||
          focused.findAncestorStateOfType<EditableTextState>() != null) {
        return false;
      }
      if (intent.yieldsToActivate &&
          Actions.maybeFind<ActivateIntent>(focused)
                  ?.isEnabled(const ActivateIntent()) ==
              true) {
        return false;
      }
    }
    return !intent.needsTrack || player.track != null;
  }

  @override
  Object? invoke(_PlayerIntent intent, [BuildContext? context]) {
    final at = _focused ?? context;
    if (at == null) return null;
    intent.run(player, at);
    return null;
  }
}

/// The «?» sheet: every player key in one short list.
Future<void> showPlayerShortcutHelp(BuildContext context) async {
  final navigator = Navigator.maybeOf(context);
  if (navigator == null) return;
  await showDialog<void>(
    context: navigator.context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        icon: const Icon(RhythmoIcons.keyboard),
        title: const Text('میان‌برهای صفحه‌کلید'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (keys, action) in playerShortcutHelp)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(child: Text(persianDigits(action))),
                      Directionality(
                        textDirection: TextDirection.ltr,
                        child: Text(
                          keys,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('بستن'),
          ),
        ],
      );
    },
  );
}
