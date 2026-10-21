import 'package:rhythmo/features/feedback/feedback_api.dart';
import 'package:rhythmo/features/admin/data/admin_account.dart';
import 'package:rhythmo/features/admin/presentation/admin_screen.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/features/feedback/feedback_screen.dart';
import 'package:rhythmo/features/identify/application/identify_controller.dart';
import 'package:rhythmo/features/history/application/recently_played_controller.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/app/app_configuration.dart';
import 'package:rhythmo/core/widgets/app_loading_screen.dart';
import 'package:rhythmo/features/auth/application/auth_controller.dart';
import 'package:rhythmo/features/auth/presentation/email_verification_screen.dart';
import 'package:rhythmo/features/auth/presentation/sign_in_prompt.dart';
import 'package:rhythmo/features/auth/presentation/sign_in_screen.dart';
import 'package:rhythmo/features/library/application/library_controller.dart';
import 'package:rhythmo/features/library/application/library_sync_controller.dart';
import 'package:rhythmo/features/library/application/local_audio_controller.dart';
import 'package:rhythmo/features/library/presentation/library_screen.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/presentation/popular_playlists_screen.dart';
import 'package:rhythmo/features/bots/application/bot_link_controller.dart';
import 'package:rhythmo/features/link_import/application/link_import_controller.dart';
import 'package:rhythmo/features/settings/application/cache_controller.dart';
import 'package:rhythmo/features/upload/application/upload_controller.dart';
import 'package:rhythmo/features/upload/data/audio_picker.dart';
import 'package:rhythmo/features/store/application/store_controller.dart';
import 'package:rhythmo/features/store/presentation/store_screen.dart';

/// Restores the saved session once, then shows the library, or for a guest
/// the popular playlists, which they can play without an account.
class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.controller,
    required this.library,
    this.playlists,
    this.recent,
    this.adminApi,
    required this.localAudio,
    required this.uploads,
    required this.sync,
    required this.cache,
    this.botLinks,
    this.linkImports,
    this.identify,
    this.store,
    required this.picker,
    required this.player,
  });

  final AuthController controller;
  final AdminApi? adminApi;
  final PlayerController player;
  final LibraryController library;
  final PlaylistsController? playlists;

  /// The account's recently played tracks; null hides them.
  final RecentlyPlayedController? recent;
  final LocalAudioController localAudio;
  final UploadController uploads;
  final LibrarySyncController sync;
  final CacheController cache;
  final BotLinkController? botLinks;
  final LinkImportController? linkImports;

  /// «این آهنگ چیه؟»; null hides it.
  final IdentifyController? identify;

  /// The public store; null hides it.
  final StoreController? store;
  final AudioPicker picker;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  AuthStatus? _status;

  /// The shared link the app was opened with, for a guest; taken once.
  String? _guestShareToken;
  bool _guestShown = false;

  /// Whether the store song the app was opened with was looked at.
  bool _storeSongChecked = false;

  /// Opens the store on the song a store page linked to, once, signed in
  /// or not.
  void _openInitialStoreSong() {
    if (_storeSongChecked) return;
    _storeSongChecked = true;
    final store = widget.store;
    final id = AppConfiguration.takeInitialStoreSong();
    if (store == null || id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => StoreScreen(
          controller: store,
          player: widget.player,
          onSignIn: _openSignIn,
          openSongId: id,
          identify: widget.identify,
        ),
      ));
    });
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onAuthChanged);
    widget.controller.restore();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onAuthChanged);
    super.dispose();
  }

  /// Signing in from a guest screen lands in the library, not back on the
  /// sign-in or playlist page it was opened from. Signing out, or deleting
  /// the account from Settings, lands on the guest home with nothing of the
  /// account left behind.
  void _onAuthChanged() {
    final status = widget.controller.status;
    if (status == AuthStatus.signedIn && _status != AuthStatus.signedIn) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      // The account's likes follow it to this device.
      widget.player.favorites.refresh();
    }
    if (status == AuthStatus.signedOut && _status == AuthStatus.signedIn) {
      _forgetAccount();
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    _status = status;
  }

  /// Never show one account's tracks to the next one.
  void _forgetAccount() {
    widget.player.stop();
    widget.player.favorites.clearAccount();
    widget.library.clear();
    widget.playlists?.clear();
    widget.recent?.clear();
    widget.botLinks?.clear();
    widget.linkImports?.clear();
    widget.uploads.dismiss();
  }

  void _openSignIn() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SignInScreen(controller: widget.controller),
    ));
  }

  Widget _guestHome(PlaylistsController playlists) {
    if (!_guestShown) {
      _guestShown = true;
      _guestShareToken = AppConfiguration.takeInitialShareToken();
      // A collaboration link is joined once signed in; say so.
      if (AppConfiguration.peekInitialCollabToken() != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          askToSignIn(context,
              action: 'پیوستن به Playlist مشترک', onSignIn: _openSignIn);
        });
      }
    }
    return PopularPlaylistsScreen(
      controller: playlists,
      player: widget.player,
      onSignIn: _openSignIn,
      openShareToken: _guestShareToken,
      store: widget.store,
      identify: widget.identify,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        if (controller.status == AuthStatus.signedIn ||
            controller.status == AuthStatus.signedOut) {
          _openInitialStoreSong();
        }
        return switch (controller.status) {
          AuthStatus.restoring => const AppLoadingScreen(),
          AuthStatus.restoreFailed => _RestoreFailedScreen(
              onRetry: controller.restore,
            ),
          AuthStatus.signedOut => widget.playlists == null
              ? SignInScreen(controller: controller)
              : _guestHome(widget.playlists!),
          AuthStatus.signedIn => LibraryScreen(
              email: controller.user!.email,
              onFeedback: widget.adminApi is FeedbackApi
                  ? () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => FeedbackScreen(
                          api: widget.adminApi as FeedbackApi,
                          token: () => controller.token)))
                  : null,
              verified: controller.user!.verified,
              onVerifyEmail: controller.user!.emailVerified
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) =>
                            EmailVerificationScreen(controller: controller),
                      )),
              onAdmin: controller.user!.isAdmin && widget.adminApi != null
                  ? () async {
                      await Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => AdminScreen(
                          api: widget.adminApi!,
                          token: () => controller.token,
                        ),
                      ));
                      try {
                        await controller.refreshUser();
                      } catch (_) {
                        // A network failure keeps the current session intact.
                      }
                    }
                  : null,
              onLogout: () {
                // Never show one account's tracks to the next one.
                widget.player.stop();
                widget.library.clear();
                widget.playlists?.clear();
                widget.recent?.clear();
                widget.botLinks?.clear();
                widget.sync.clear();
                widget.linkImports?.clear();
                widget.uploads.dismiss();
                controller.logout();
              },
              onDeleteAccount: controller.deleteAccount,
              onSignOutEverywhere: controller.signOutEverywhere,
              library: widget.library,
              playlists: widget.playlists,
              recent: widget.recent,
              localAudio: widget.localAudio,
              player: widget.player,
              uploads: widget.uploads,
              sync: widget.sync,
              cache: widget.cache,
              botLinks: widget.botLinks,
              linkImports: widget.linkImports,
              identify: widget.identify,
              store: widget.store,
              picker: widget.picker,
            ),
        };
      },
    );
  }
}

class _RestoreFailedScreen extends StatelessWidget {
  const _RestoreFailedScreen({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('بازیابی ورود قبلی ممکن نشد'),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(RhythmoIcons.arrowsClockwise),
                label: const Text('تلاش دوباره'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
