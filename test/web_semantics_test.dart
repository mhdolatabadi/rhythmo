import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/core/accessibility/web_semantics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(releaseWebSemantics);

  test('the web keeps the semantics tree on from start-up', () {
    expect(keepWebSemanticsOn(isWeb: true), isTrue);
    expect(SemanticsBinding.instance.semanticsEnabled, isTrue);
    // A second call does not take another handle.
    expect(keepWebSemanticsOn(isWeb: true), isFalse);
  });

  test('Android leaves semantics to the platform', () {
    expect(keepWebSemanticsOn(isWeb: false), isFalse);
  });
}
