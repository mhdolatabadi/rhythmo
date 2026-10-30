import 'package:flutter/material.dart';

/// A quiet group of settings: a small muted label over one card, with
/// space rather than lines between the rows inside.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, this.label, required this.children});

  final String? label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (label case final label?)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 8),
              child: Text(
                label,
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: ListTileTheme(
              data: const ListTileThemeData(
                minTileHeight: 56,
                minVerticalPadding: 4,
                horizontalTitleGap: 12,
                contentPadding: EdgeInsets.symmetric(horizontal: 12),
              ),
              child: Column(children: children),
            ),
          ),
        ],
      ),
    );
  }
}
