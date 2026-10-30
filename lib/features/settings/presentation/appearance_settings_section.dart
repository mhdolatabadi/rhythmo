import 'package:rhythmo/core/design/design.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/app/app_preferences.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';

String themeModeLabel(ThemeMode mode) => switch (mode) {
      ThemeMode.system => 'همراه تنظیم دستگاه',
      ThemeMode.light => 'روشن',
      ThemeMode.dark => 'تیره',
    };

class AppearanceSettingsSection extends StatelessWidget {
  const AppearanceSettingsSection({super.key, required this.preferences});
  final AppPreferencesController preferences;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: preferences,
        builder: (context, _) => Center(
            child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding:
                          const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 8),
                      child: Text('ظاهر و موسیقی من',
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
                    ),
                    Card(
                        margin: EdgeInsets.zero,
                        clipBehavior: Clip.antiAlias,
                        child: Column(children: [
                          ListTile(
                              title: const Text('حالت نمایش'),
                              subtitle: Text(
                                  themeModeLabel(preferences.value.themeMode)),
                              onTap: () => showModalBottomSheet<void>(
                                  context: context,
                                  useSafeArea: true,
                                  builder: (sheetContext) => Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            for (final mode in ThemeMode.values)
                                              ListTile(
                                                  title: Text(
                                                      themeModeLabel(mode)),
                                                  selected: preferences
                                                          .value.themeMode ==
                                                      mode,
                                                  onTap: () {
                                                    preferences.update(
                                                        themeMode: mode);
                                                    Navigator.pop(sheetContext);
                                                  }),
                                          ]))),
                          const SizedBox(height: 4),
                          ListTile(
                              title: const Text('مدیریت تب‌ها'),
                              subtitle: const Text(
                                  'نمایش، پنهان‌کردن و جابه‌جایی بخش‌های «موسیقی من»'),
                              onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                      builder: (_) => ManageTabsScreen(
                                          preferences: preferences)))),
                        ])),
                  ])),
        )),
      );
}

class ManageTabsScreen extends StatelessWidget {
  const ManageTabsScreen({super.key, required this.preferences});
  final AppPreferencesController preferences;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('مدیریت تب‌ها')),
        body: RhythmoBackdrop(
            child: ListenableBuilder(
                listenable: preferences,
                builder: (context, _) {
                  final settings = preferences.value;
                  return ReorderableListView.builder(
                      padding: EdgeInsets.only(
                          bottom: 24 + MediaQuery.paddingOf(context).bottom),
                      buildDefaultDragHandles: false,
                      itemCount: settings.order.length,
                      onReorderItem: (oldIndex, newIndex) {
                        final order = [...settings.order];
                        order.insert(newIndex, order.removeAt(oldIndex));
                        preferences.update(order: order);
                      },
                      itemBuilder: (context, index) {
                        final tab = settings.order[index];
                        return ListTile(
                            key: ValueKey(tab),
                            title: Text(tab.label),
                            subtitle: switch (tab) {
                              LibraryTab.tracks =>
                                const Text('همیشه نمایش داده می‌شود'),
                              LibraryTab.newOnDevice =>
                                const Text('فقط در اپ اندروید'),
                              _ => null,
                            },
                            leading: Checkbox(
                                value: !settings.hidden.contains(tab),
                                onChanged: tab == LibraryTab.tracks
                                    ? null
                                    : (show) {
                                        final hidden = {...settings.hidden};
                                        if (show == true) {
                                          hidden.remove(tab);
                                        } else {
                                          hidden.add(tab);
                                        }
                                        preferences.update(hidden: hidden);
                                      }),
                            trailing: ReorderableDragStartListener(
                                index: index,
                                child: const Tooltip(
                                    message: 'برای جابه‌جایی بکش',
                                    child: SizedBox.square(
                                        dimension: 48,
                                        child: Icon(
                                            RhythmoIcons.dotsSixVertical)))));
                      });
                })),
      );
}
