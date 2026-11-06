import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';

/// Full-screen loading state that matches the web splash in web/index.html,
/// so startup looks like one continuous screen.
class AppLoadingScreen extends StatelessWidget {
  const AppLoadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: RhythmoBackdrop(
          child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The app icon.
            ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(RhythmoRadii.lg)),
              child: Image(
                image: AssetImage('assets/icon/rhythmo.png'),
                width: 72,
                height: 72,
              ),
            ),
            SizedBox(height: 24),
            SizedBox.square(
              dimension: 32,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          ],
        ),
      )),
    );
  }
}
