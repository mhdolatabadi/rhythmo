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

  test('«موسیقی من» opens with songs and playlists only (#445)', () {
    expect(const AppPreferences().order.take(2),
        [LibraryTab.tracks, LibraryTab.playlists]);
    expect(const AppPreferences().hidden,
        {LibraryTab.newOnDevice, LibraryTab.albums, LibraryTab.artists});
    // Liked songs have their own dock entry: an old saved «favorites» tab
    // is dropped rather than failing.
    final old = AppPreferences.fromJson({
      'tabs': ['favorites', 'tracks'],
      'hidden': ['favorites', 'albums']
    });
    expect(old.order.first, LibraryTab.tracks);
    expect(old.hidden, {LibraryTab.albums});
    // A listener's own choice of tabs survives a save.
    const chosen = AppPreferences(hidden: {LibraryTab.artists});
    expect(
        AppPreferences.fromJson(chosen.toJson()).hidden, {LibraryTab.artists});
  });

  test('appearance and tab choices survive a controller restart', () async {
    final store = MemoryAppPreferencesStore();
    final first = AppPreferencesController(store: store);
    await first.update(
        themeMode: ThemeMode.system,
        order: [LibraryTab.albums, LibraryTab.tracks],
        hidden: {LibraryTab.artists});
    first.dispose();
    final next = AppPreferencesController(store: store);
    await next.load();
    expect(next.value.themeMode, ThemeMode.system);
    expect(next.value.order.first, LibraryTab.albums);
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
