import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_preferences.dart';
import 'package:rhythmo/app/app_theme.dart';

void main() {
  test('invalid saved tabs are normalized and tracks cannot be hidden', () {
    final saved = AppPreferences.fromJson({
      'theme': 'invalid',
      'tabs': ['artists', 'artists', 'unknown'],
      'hidden': ['tracks', 'albums'],
    });
    expect(saved.themeMode, ThemeMode.dark);
    expect(saved.order.first, LibraryTab.artists);
    expect(saved.order.toSet(), LibraryTab.values.toSet());
    expect(saved.order.length, LibraryTab.values.length);
    expect(saved.hidden, {LibraryTab.albums});
  });

  test('liked songs are a visible second tab, and come back once if hidden',
      () {
    expect(const AppPreferences().order.take(2),
        [LibraryTab.tracks, LibraryTab.favorites]);
    expect(const AppPreferences().hidden, isEmpty);
    // Hidden by the old default, before the dock lost its liked entry.
    expect(
        AppPreferences.fromJson({
          'hidden': ['favorites', 'albums']
        }).hidden,
        {LibraryTab.albums});
    // Hidden by the listener's own choice since then: it stays hidden.
    final chosen = AppPreferences(hidden: {LibraryTab.favorites});
    expect(AppPreferences.fromJson(chosen.toJson()).hidden,
        {LibraryTab.favorites});
  });

  test('appearance and tab choices survive a controller restart', () async {
    final store = MemoryAppPreferencesStore();
    final first = AppPreferencesController(store: store);
    await first.update(
        themeMode: ThemeMode.system,
        order: [LibraryTab.favorites, LibraryTab.tracks],
        hidden: {LibraryTab.artists});
    first.dispose();
    final next = AppPreferencesController(store: store);
    await next.load();
    expect(next.value.themeMode, ThemeMode.system);
    expect(next.value.order.first, LibraryTab.favorites);
    expect(next.value.hidden, {LibraryTab.artists});
    next.dispose();
  });

  test('light theme keeps readable text on its primary surfaces', () {
    final theme = RhythmoTheme.light();
    final colors = theme.colorScheme;
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
    }

    expect(theme.brightness, Brightness.light);
    expect(
        contrast(colors.onSurface, colors.surface), greaterThanOrEqualTo(4.5));
    expect(contrast(colors.onSurfaceVariant, colors.surfaceContainerLow),
        greaterThanOrEqualTo(4.5));
    expect(
        contrast(colors.onPrimary, colors.primary), greaterThanOrEqualTo(4.5));
  });
}
