import 'package:rhythmo/features/journey/presentation/journey_widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/features/settings/presentation/device_settings_pages.dart';
import 'package:rhythmo/app/app_preferences.dart';
import 'package:rhythmo/features/settings/presentation/appearance_settings_section.dart';
import 'package:rhythmo/app/app_configuration.dart';
import 'package:rhythmo/core/links/open_link.dart';
import 'package:rhythmo/core/links/site_page.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/core/format_size.dart';
import 'package:rhythmo/features/bots/application/bot_link_controller.dart';
import 'package:rhythmo/features/bots/presentation/bot_link_section.dart';
import 'package:rhythmo/features/debug/presentation/design_gallery.dart';
import 'package:rhythmo/features/library/application/library_controller.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/settings/presentation/playback_settings_section.dart';
import 'package:rhythmo/features/settings/presentation/queue_settings_section.dart';
import 'package:rhythmo/features/settings/application/cache_controller.dart';
import 'package:rhythmo/features/settings/presentation/delete_account_screen.dart';
import 'package:rhythmo/features/settings/presentation/storage_usage_card.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.onFeedback,
    required this.cache,
    this.botLinks,
    this.library,
    this.player,
    this.onManagePlaylists,
    this.email,
    this.verified = false,
    this.onAdmin,
    this.onLogout,
    this.onDeleteAccount,
    this.onSignOutEverywhere,
    this.siteUri = AppConfiguration.sitePage,
    this.openLink = openExternalLink,
  });

  /// The signed-in account; null hides the account section.
  final VoidCallback? onFeedback;
  final String? email;
  final bool verified;

  /// Opens account management for admins; null hides it.
  final VoidCallback? onAdmin;

  /// Signs out of this device; null hides it.
  final VoidCallback? onLogout;

  /// Deletes the account; null hides the option.
  final Future<void> Function(String password)? onDeleteAccount;

  /// Ends the account's sessions on every other device; null hides it.
  final Future<void> Function()? onSignOutEverywhere;

  /// Where a page of the rhythmo site, such as `/privacy`, lives; null when
  /// there is no server.
  final SitePageResolver siteUri;

  final LinkOpener openLink;

  final CacheController cache;

  /// Reports the account's cloud storage use; null when there is none.
  final LibraryController? library;

  /// Playback preferences; null hides them.
  final PlayerController? player;
  final VoidCallback? onManagePlaylists;

  /// Null when the app has no API to ask about bots.
  final BotLinkController? botLinks;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.cache.isManaged) widget.cache.refresh();
  }

  Future<void> _clear() async {
    final confirmed = await showRhythmoConfirm(
      context,
      title: 'کش پاک شود؟',
      message: 'آهنگ‌های «موسیقی من» در فضای ابری می‌مانند و دفعه‌ی بعد دوباره '
          'از اینترنت پخش می‌شوند.',
      confirmLabel: 'پاک کن',
      destructive: false,
    );
    if (!confirmed) return;
    final ok = await widget.cache.clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'کش پاک شد.' : 'پاک کردن کش ناموفق بود.'),
    ));
  }

  Future<void> _signOutEverywhere(Future<void> Function() signOut) async {
    final confirmed = await showRhythmoConfirm(
      context,
      title: 'از همه‌ی دستگاه‌ها خارج شوی؟',
      message: 'روی همه‌ی گوشی‌ها و مرورگرهای دیگر از حسابت خارج می‌شوی و باید '
          'دوباره وارد شوی. این دستگاه وارد می‌ماند.',
      confirmLabel: 'خروج از بقیه',
      destructive: false,
    );
    if (!confirmed) return;
    var ok = true;
    try {
      await signOut();
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'از همه‌ی دستگاه‌های دیگر خارج شدی.'
          : 'خروج از دستگاه‌های دیگر ناموفق بود. دوباره امتحان کن.'),
    ));
  }

  Future<void> _openPage(String path) => openSitePage(context, path,
      siteUri: widget.siteUri, openLink: widget.openLink);

  void _openDeleteAccount(String email, Future<void> Function(String) delete) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DeleteAccountScreen(
        email: email,
        onDelete: delete,
        onOpenPage: _openPage,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Scaffold(
      appBar: AppBar(title: const Text('حساب و تنظیمات')),
      // Centred and capped on desktop, so rows never span the window.
      body: RhythmoBackdrop(
          child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: RhythmoSpace.listWidth),
          child: ListView(
            // System navigation never covers the last item.
            padding: EdgeInsets.only(
              bottom: 24 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              // The account first: «حساب» in the dock is the one way here.
              if (widget.email case final email?)
                ListTile(
                  leading: AccountAvatar(verified: widget.verified, size: 32),
                  title: Text(
                    email,
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle:
                      widget.verified ? const Text('حساب تأییدشده') : null,
                ),
              if (widget.onAdmin case final admin?)
                ListTile(
                  leading: const Icon(RhythmoIcons.usersFill),
                  title: const Text('مدیریت حساب‌ها'),
                  onTap: admin,
                ),
              if (widget.onFeedback != null)
                ListTile(
                    leading: const Icon(Icons.feedback_outlined),
                    title: const Text('ارتباط با مدیر'),
                    subtitle: const Text('گزارش باگ، درخواست قابلیت و پیام'),
                    onTap: widget.onFeedback),
              if (widget.player?.journey case final journey?)
                JourneySetting(journey: journey),
              if (widget.player case final player?)
                PlaybackSettingsSection(player: player),
              if (widget.player case final player?)
                QueueSettingsSection(player: player),
              if (AppPreferencesScope.maybeOf(context) case final preferences?)
                AppearanceSettingsSection(preferences: preferences),
              if (widget.onManagePlaylists case final manage?)
                ListTile(
                  leading: const Icon(RhythmoIcons.playlist),
                  title: const Text('مدیریت فهرست‌های پخش'),
                  onTap: manage,
                ),
              if (widget.library case final library?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: ListenableBuilder(
                    listenable: library,
                    builder: (context, _) => StorageUsageCard(
                      usedBytes: library.usedBytes,
                      limitBytes: library.limitBytes,
                    ),
                  ),
                ),
              const ListTile(
                title: Text('کش موسیقی'),
                subtitle: Text(
                  'آهنگ‌هایی که پخش کرده‌ای روی همین دستگاه نگه داشته می‌شوند تا '
                  'دفعه‌ی بعد سریع‌تر و بدون اینترنت پخش شوند.',
                ),
              ),
              if (widget.cache.isManaged)
                ListenableBuilder(
                  listenable: widget.cache,
                  builder: (context, _) {
                    final cache = widget.cache;
                    final size = cache.sizeBytes;
                    return ListTile(
                      leading: const Icon(RhythmoIcons.database),
                      title: Text(switch ((size, cache.failed)) {
                        (_, true) => 'حجم کش معلوم نشد',
                        (null, _) => 'در حال محاسبه…',
                        (final int bytes, _) => 'حجم کش: ${formatSize(bytes)}',
                      }),
                      trailing: OutlinedButton(
                        onPressed: cache.busy || size == 0 ? null : _clear,
                        child: const Text('پاک کردن کش'),
                      ),
                    );
                  },
                )
              else
                const ListTile(
                  leading: Icon(RhythmoIcons.globe),
                  title: Text('در نسخه‌ی وب، کش را خود مرورگر مدیریت می‌کند.'),
                ),
              if (widget.botLinks case final botLinks?)
                BotLinkSection(controller: botLinks),
              const Divider(),
              ListTile(
                title: const Text('دسترسی‌ها'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const PermissionsScreen())),
              ),
              ListTile(
                title: const Text('دربارهٔ ریتمو'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => AboutScreen(openPage: _openPage))),
              ),
              ListTile(
                leading: const Icon(RhythmoIcons.shieldCheck),
                title: const Text('حریم خصوصی'),
                subtitle:
                    const Text('چه چیزهایی نگه می‌داریم و چه کسی می‌بیند'),
                trailing: const Icon(RhythmoIcons.arrowSquareOut, size: 20),
                onTap: () => _openPage('/privacy'),
              ),
              if (widget.onLogout case final logout?)
                ListTile(
                  leading: const Icon(RhythmoIcons.signOut),
                  title: const Text('خروج از حساب'),
                  onTap: () {
                    Navigator.of(context).pop();
                    logout();
                  },
                ),
              if (widget.onSignOutEverywhere case final signOut?)
                ListTile(
                  leading: const Icon(RhythmoIcons.signOut),
                  title: const Text('خروج از همه‌ی دستگاه‌ها'),
                  subtitle: const Text(
                    'اگر گوشی یا رمزت دست کس دیگری افتاده، بقیه‌ی نشست‌ها را ببند',
                  ),
                  onTap: () => _signOutEverywhere(signOut),
                ),
              if ((widget.email, widget.onDeleteAccount)
                  case (final String email, final delete?))
                ListTile(
                  leading: Icon(RhythmoIcons.userCircleMinus, color: error),
                  iconColor: error,
                  textColor: error,
                  title: const Text('حذف حساب کاربری'),
                  subtitle: const Text(
                    'حساب، موسیقی‌های ابری و فهرست‌های پخشت برای همیشه پاک می‌شوند',
                  ),
                  trailing: const Icon(RhythmoIcons.caretLeft, size: 20),
                  onTap: () => _openDeleteAccount(email, delete),
                ),
              // Debug builds only: every token and component on one page.
              if (kDebugMode)
                ListTile(
                  leading: const Icon(RhythmoIcons.gauge),
                  title: const Text('سامانهٔ طراحی'),
                  subtitle: const Text('فقط در نسخهٔ آزمایشی'),
                  trailing: const Icon(RhythmoIcons.caretLeft, size: 20),
                  onTap: () => openDesignGallery(context),
                ),
            ],
          ),
        ),
      )),
    );
  }
}
