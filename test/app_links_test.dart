import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_configuration.dart';

void main() {
  test('a public playlist page link opens the shared playlist once', () {
    final opened = AppConfiguration.linkOpened.value;
    AppConfiguration.openLink(
        Uri.parse('https://rhythmo.ir/p/AbCdEfGhIjKlMnOpQrStUv'));
    expect(AppConfiguration.linkOpened.value, opened + 1);
    expect(AppConfiguration.takeInitialShareToken(), 'AbCdEfGhIjKlMnOpQrStUv');
    expect(AppConfiguration.takeInitialShareToken(), isNull);
    expect(AppConfiguration.takeInitialCollabToken(), isNull);
    expect(AppConfiguration.takeInitialStoreSong(), isNull);
  });

  test('app links carry shared and collaboration tokens', () {
    AppConfiguration.openLink(
        Uri.parse('https://rhythmo.ir/app/?shared=tok1&collab=tok2'));
    expect(AppConfiguration.takeInitialShareToken(), 'tok1');
    expect(AppConfiguration.peekInitialCollabToken(), 'tok2');
    expect(AppConfiguration.takeInitialCollabToken(), 'tok2');
    expect(AppConfiguration.peekInitialCollabToken(), isNull);
  });

  test('a store song page opens that song, with or without its slug', () {
    AppConfiguration.openLink(Uri.parse('https://rhythmo.ir/store/t/42/baran'));
    expect(AppConfiguration.takeInitialStoreSong(), '42');
    AppConfiguration.openLink(Uri.parse('https://rhythmo.ir/store/t/7'));
    expect(AppConfiguration.takeInitialStoreSong(), '7');
  });

  test('other pages link to nothing in particular', () {
    AppConfiguration.openLink(Uri.parse('https://rhythmo.ir/store/artists/x'));
    expect(AppConfiguration.takeInitialStoreSong(), isNull);
    expect(AppConfiguration.takeInitialShareToken(), isNull);
  });
}
