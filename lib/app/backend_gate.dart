import 'package:rhythmo/core/design/design.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/core/widgets/app_loading_screen.dart';

class BackendGate extends StatefulWidget {
  const BackendGate(
      {super.key, required this.healthCheck, required this.child});

  final Future<void> Function()? healthCheck;

  /// Shown once the API is reachable.
  final Widget child;

  @override
  State<BackendGate> createState() => _BackendGateState();
}

class _BackendGateState extends State<BackendGate> {
  late Future<void>? _connection;

  @override
  void initState() {
    super.initState();
    _connection = widget.healthCheck?.call();
  }

  void _retry() {
    setState(() => _connection = widget.healthCheck?.call());
  }

  @override
  Widget build(BuildContext context) {
    if (_connection == null) return const _ConfigurationRequiredScreen();

    return FutureBuilder<void>(
      future: _connection,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const AppLoadingScreen();
        }
        if (snapshot.hasError) {
          return _BackendUnavailableScreen(onRetry: _retry);
        }
        return widget.child;
      },
    );
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

class _BackendUnavailableScreen extends StatelessWidget {
  const _BackendUnavailableScreen({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RhythmoBackdrop(
          child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                RhythmoIcons.cloudSlash,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              const Text('اتصال به سرور برقرار نشد'),
              const SizedBox(height: 8),
              const Text(
                'اتصال اینترنت و آدرس سرور را بررسی کن.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(RhythmoIcons.arrowsClockwise),
                label: const Text('تلاش دوباره'),
              ),
            ],
          ),
        ),
      )),
    );
  }
}
