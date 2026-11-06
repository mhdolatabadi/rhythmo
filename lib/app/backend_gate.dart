import 'package:rhythmo/core/design/design.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/network/network_status.dart';

/// Shows the app once a server is configured. The app opens at once, also
/// offline: whether the server answers only tells [network], and the app
/// works from what it kept on the device until it does.
class BackendGate extends StatefulWidget {
  const BackendGate(
      {super.key,
      required this.healthCheck,
      required this.child,
      this.network});

  final Future<void> Function()? healthCheck;

  /// Told whether the first check reached the server.
  final NetworkStatus? network;

  final Widget child;

  @override
  State<BackendGate> createState() => _BackendGateState();
}

class _BackendGateState extends State<BackendGate> {
  @override
  void initState() {
    super.initState();
    final check = widget.healthCheck;
    if (check == null) return;
    check().then((_) => widget.network?.reportSuccess(),
        onError: (Object _) => widget.network?.reportFailure());
  }

  @override
  Widget build(BuildContext context) {
    if (widget.healthCheck == null) return const _ConfigurationRequiredScreen();
    return widget.child;
  }
}

class _ConfigurationRequiredScreen extends StatelessWidget {
  const _ConfigurationRequiredScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: RhythmoBackdrop(
          child: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'برای اجرای rhythmo، آدرس سرور را با '
            '--dart-define=API_BASE_URL=https://music.example.com تنظیم کن.',
            textAlign: TextAlign.center,
          ),
        ),
      )),
    );
  }
}
