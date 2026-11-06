import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/mini_player.dart';

/// One place in a dock's pill: its name and its resting and selected icons.
class DockItem {
  const DockItem(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Where the signed-in dock takes the listener, in reading order. Each
/// place in the app has this one way in; the account opens from the avatar
/// in the header.
enum DockDestination {
  home('خانه', RhythmoIcons.house, RhythmoIcons.houseFill),
  search('جست‌وجو', RhythmoIcons.magnifyingGlass, RhythmoIcons.magnifyingGlass),
  liked('پسندیده‌ها', RhythmoIcons.heart, RhythmoIcons.heartFill),
  library('موسیقی من', RhythmoIcons.books, RhythmoIcons.booksFill);

  const DockDestination(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  DockItem get item => DockItem(label, icon, selectedIcon);
}

/// The widest the dock's navigation row grows; on wide windows the icons
/// stay together in the middle instead of spreading to the edges.
const dockNavWidth = 520.0;

/// The height of the dock's navigation row, above the system inset.
const dockNavHeight = 58.0;

/// The signed-in app's dock: the [DockDestination]s.
class RhythmoDock extends StatelessWidget {
  const RhythmoDock({
    super.key,
    required this.player,
    required this.selected,
    required this.onSelect,
  });

  final PlayerController player;
  final DockDestination selected;
  final ValueChanged<DockDestination> onSelect;

  @override
  Widget build(BuildContext context) => RhythmoDockBar(
        player: player,
        items: [for (final d in DockDestination.values) d.item],
        selected: selected.index,
        onSelect: (index) => onSelect(DockDestination.values[index]),
      );
}

/// The bottom of the main screens, signed in or not: the mini player,
/// flush above a full-width row of icons on the page's own colour. Icons
/// carry no visible names; each keeps its name for tooltips and screen
/// readers. The selected icon is filled and bright, the rest are muted.
class RhythmoDockBar extends StatelessWidget {
  const RhythmoDockBar({
    super.key,
    required this.player,
    required this.items,
    required this.selected,
    required this.onSelect,
  });

  final PlayerController player;
  final List<DockItem> items;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The navigation row below takes the system inset, not the player.
        MediaQuery.removePadding(
          context: context,
          removeBottom: true,
          child: MiniPlayer(player: player),
        ),
        ColoredBox(
          color: dark
              ? RhythmoColors.background
              : Theme.of(context).colorScheme.surface,
          child: SafeArea(
            top: false,
            child: Center(
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: dockNavWidth),
                child: SizedBox(
                  height: dockNavHeight,
                  child: Row(
                    children: [
                      for (final (index, item) in items.indexed)
                        Expanded(
                          child: Center(
                            child: _DockItem(
                              item: item,
                              selected: index == selected,
                              onTap: () => onSelect(index),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final DockItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: item.label,
        excludeFromSemantics: true,
        child: InkResponse(
          onTap: onTap,
          radius: 28,
          child: SizedBox.square(
            dimension: 48,
            child: Icon(
              selected ? item.selectedIcon : item.icon,
              size: 24,
              color: selected ? colors.onSurface : colors.outline,
            ),
          ),
        ),
      ),
    );
  }
}
