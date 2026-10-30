import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/features/settings/application/cache_controller.dart';
import 'package:rhythmo/features/settings/presentation/settings_group.dart';
import 'package:rhythmo/features/settings/presentation/settings_screen.dart';

import 'cache_controller_test.dart' show FakeAudioCache;

void main() {
  testWidgets('settings read as labelled groups: account first, exits last',
      (tester) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('fa'),
      supportedLocales: const [Locale('fa')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: RhythmoTheme.dark(),
      home: SettingsScreen(
        cache: CacheController(cache: FakeAudioCache(), playing: () => null),
        email: 'a@example.com',
        onLogout: () {},
        onDeleteAccount: (_) async {},
        onFeedback: () {},
        siteUri: (_) => null,
        openLink: (_) async => true,
      ),
    ));
    await tester.pumpAndSettle();

    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    // Who you are, then this device, then help, then the ways out.
    expect(top('a@example.com'), lessThan(top('کش موسیقی')));
    expect(top('کش موسیقی'), lessThan(top('دسترسی‌ها')));
    expect(top('دسترسی‌ها'), lessThan(top('ارتباط با مدیر')));
    expect(top('حریم خصوصی'), lessThan(top('خروج از حساب')));
    expect(top('خروج از حساب'), lessThan(top('حذف حساب کاربری')));

    expect(find.byType(SettingsGroup), findsNWidgets(4));
    for (final label in ['این دستگاه', 'پشتیبانی']) {
      expect(find.text(label), findsOneWidget);
    }
    // Space, not lines, between rows.
    expect(find.byType(Divider), findsNothing);
  });
}
