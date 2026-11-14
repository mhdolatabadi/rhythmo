import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/auth/application/auth_controller.dart';
import 'package:rhythmo/features/auth/data/token_store.dart';
import 'package:rhythmo/features/settings/presentation/display_name_tile.dart';

import 'widget_test.dart' show FakeAuthApi;

void main() {
  test('the controller saves the trimmed public name', () async {
    final api = FakeAuthApi();
    final controller = AuthController(api: api, tokenStore: MemoryTokenStore());
    await controller.login('listener@example.com', 'correct horse');
    await controller.setDisplayName('  نیما ');
    expect(api.displayNames, ['نیما']);
    expect(controller.user!.displayName, 'نیما');
  });

  testWidgets('the tile edits the public name at 360 px', (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final saved = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: DisplayNameTile(
            name: '',
            onSave: (name) async => saved.add(name),
          ),
        ),
      ),
    ));
    expect(find.textContaining(anonymousOwnerName), findsOneWidget);

    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();
    expect(find.textContaining('ایمیلت هیچ‌جا'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'me@example.com');
    await tester.tap(find.text('ذخیره'));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);

    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), ' نیما ');
    await tester.tap(find.text('ذخیره'));
    await tester.pumpAndSettle();
    expect(saved, ['نیما']);
    expect(find.text('نیما'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
