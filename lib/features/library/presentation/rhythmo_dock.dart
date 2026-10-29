import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/mini_player.dart';

/// Where the dock's pill takes the listener.
enum DockDestination {
  home('خانه', RhythmoIcons.house, RhythmoIcons.houseFill),
  library('کتابخانه', RhythmoIcons.books, RhythmoIcons.booksFill),
  liked('پسندیده‌ها', RhythmoIcons.heart, RhythmoIcons.heartFill),
  account('حساب', RhythmoIcons.user, RhythmoIcons.userFill);

  const DockDestination(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// The widest the dock's navigation row grows; it stays a phone-sized pill
/// in the middle of wide windows.
const dockNavWidth = 520.0;

/// The bottom of the main screens: the mini player above a pill of
/// destinations and, apart from it, the search bubble. The selected
/// destination is a white pill with its name; the others show their icon.
class RhythmoDock extends StatelessWidget {
  const RhythmoDock({
    super.key,
    required this.player,
    required this.selected,
    required this.onSelect,
    required this.onSearch,
  });

  final PlayerController player;
  final DockDestination selected;
  final ValueChanged<DockDestination> onSelect;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The navigation row below takes the system inset, not the player.
        MediaQuery.removePadding(
          context: context,
          removeBottom: true,
          child: MiniPlayer(player: player),
        ),
        SafeArea(
          top: false,
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: dockNavWidth),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                    RhythmoSpace.md, 0, RhythmoSpace.md, RhythmoSpace.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: _DockPill(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            for (final destination in DockDestination.values)
                              // The selected name gives way on a narrow
                              // phone, so every icon stays in the pill.
                              Flexible(
                                flex: destination == selected ? 1 : 0,
                                child: _DockItem(
                                  destination: destination,
                                  selected: destination == selected,
                                  onTap: () => onSelect(destination),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: RhythmoSpace.sm),
                    _DockPill(
                      child: IconButton(
                        tooltip: 'جست‌وجو در کتابخانه',
                        onPressed: onSearch,
                        icon: const Icon(RhythmoIcons.magnifyingGlass),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A flat, nearly opaque pill: the dock stays calm and unblurred, so the
/// mini player above it keeps the screen's blur budget.
class _DockPill extends StatelessWidget {
  const _DockPill({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: StadiumBorder(side: BorderSide(color: colors.outlineVariant)),
        color: (Theme.of(context).brightness == Brightness.dark
                ? RhythmoColors.surface
                : colors.surfaceContainerLow)
            .withValues(alpha: 0.88),
      ),
      child: Padding(
        padding: const EdgeInsets.all(RhythmoSpace.xs),
        child: child,
      ),
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final DockDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // White with dark text when selected, as the play button is.
    final foreground = selected ? colors.surface : colors.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: destination.label,
        excludeFromSemantics: true,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            padding: EdgeInsets.symmetric(
                horizontal: selected ? RhythmoSpace.md : RhythmoSpace.sm),
            decoration: ShapeDecoration(
              shape: const StadiumBorder(),
              color: selected ? colors.onSurface : RhythmoColors.transparent,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? destination.selectedIcon : destination.icon,
                  size: 20,
                  color: foreground,
                ),
                if (selected) ...[
                  const SizedBox(width: RhythmoSpace.xs),
                  Flexible(
                    child: Text(
                      destination.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
