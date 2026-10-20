import 'package:rhythmo/features/journey/presentation/journey_widgets.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/app/app_preferences.dart';
import 'package:flutter/services.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/core/widgets/rhythmo_mark.dart';
import 'package:rhythmo/app/app_configuration.dart';
import 'package:rhythmo/core/search_text.dart';
import 'package:rhythmo/features/auth/presentation/email_verification_screen.dart';
import 'package:rhythmo/features/history/application/recently_played_controller.dart';
import 'package:rhythmo/features/library/application/library_controller.dart';
import 'package:rhythmo/features/library/application/library_entries.dart';
import 'package:rhythmo/features/library/application/library_sync_controller.dart';
import 'package:rhythmo/features/library/application/recent_searches.dart';
import 'package:rhythmo/features/library/application/metadata_suggestions.dart';
import 'package:rhythmo/features/link_import/application/link_import_controller.dart';
import 'package:rhythmo/features/link_import/presentation/link_import_dialog.dart';
import 'package:rhythmo/features/library/application/track_groups.dart';
import 'package:rhythmo/features/library/application/track_sort.dart';
import 'package:rhythmo/features/library/application/local_audio_controller.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/library/presentation/track_metadata_editor.dart';
import 'package:rhythmo/features/player/application/favorite_tracks.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/mini_player.dart';
import 'package:rhythmo/features/playlists/presentation/shared_playlist_screen.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';
import 'package:rhythmo/features/playlists/presentation/playlists_screen.dart';
import 'package:rhythmo/features/playlists/presentation/popular_playlists_screen.dart';
import 'package:rhythmo/features/store/presentation/store_screen.dart';
import 'package:rhythmo/features/bots/application/bot_link_controller.dart';
import 'package:rhythmo/features/bots/data/messenger_bot.dart';
import 'package:rhythmo/features/identify/application/identify_controller.dart';
import 'package:rhythmo/features/identify/presentation/identify_screen.dart';
import 'package:rhythmo/features/settings/application/cache_controller.dart';
import 'package:rhythmo/features/settings/presentation/settings_screen.dart';
import 'package:rhythmo/features/upload/application/upload_controller.dart';
import 'package:rhythmo/features/upload/data/audio_picker.dart';
import 'package:rhythmo/features/upload/presentation/upload_status_card.dart';
import 'package:rhythmo/features/store/application/store_controller.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.email,
    this.verified = false,
    this.onVerifyEmail,
    this.onAdmin,
    required this.onLogout,
    this.onDeleteAccount,
    this.onSignOutEverywhere,
    required this.library,
    this.playlists,
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
    this.recent,
    this.recentSearches,
  });

  final String email;
  final bool verified;

  /// Opens email verification; set while the account's email is not
  /// verified, which shows a reminder above the tracks.
  final VoidCallback? onVerifyEmail;
  final VoidCallback? onAdmin;
  final VoidCallback onLogout;

  /// Deletes the account after checking [password]; null hides the option.
  final Future<void> Function(String password)? onDeleteAccount;

  /// Signs the account out on every other device; null hides the option.
  final Future<void> Function()? onSignOutEverywhere;
  final LibraryController library;
  final PlaylistsController? playlists;
  final LocalAudioController localAudio;
  final PlayerController player;
  final UploadController uploads;
  final LibrarySyncController sync;
  final CacheController cache;
  final BotLinkController? botLinks;

  /// Adds music from song pages and audio links; null hides the action.
  final LinkImportController? linkImports;

  /// «این آهنگ چیه؟»; null hides the action.
  final IdentifyController? identify;

  /// The public store; null hides it.
  final StoreController? store;
  final AudioPicker picker;

  /// The account's recently played tracks; null hides them.
  final RecentlyPlayedController? recent;

  /// The searches run from the search screen; kept in secure storage
  /// when null.
  final RecentSearchesController? recentSearches;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with TickerProviderStateMixin {
  UploadPhase _lastPhase = UploadPhase.idle;

  late TabController _tabs;
  List<LibraryTab> _visibleTabs = [];
  late final RecentSearchesController _recentSearches =
      widget.recentSearches ?? RecentSearchesController();

  void _configureTabs() {
    final settings =
        AppPreferencesScope.maybeOf(context)?.value ?? const AppPreferences();
    final visible = settings.order
        .where((tab) =>
            !settings.hidden.contains(tab) &&
            (tab != LibraryTab.playlists || widget.playlists != null))
        .toList();
    if (visible.length == _visibleTabs.length &&
        List.generate(visible.length, (i) => visible[i] == _visibleTabs[i])
            .every((same) => same)) {
      return;
    }
    LibraryTab? active;
    if (_visibleTabs.isNotEmpty) {
      active = _visibleTabs[_tabs.index];
      _tabs.removeListener(_onTabChanged);
      _tabs.dispose();
    }
    _visibleTabs = visible;
    final index = active == null ? 0 : visible.indexOf(active);
    _tabs = TabController(
        length: visible.length,
        initialIndex: index < 0 ? 0 : index,
        vsync: this)
      ..addListener(_onTabChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _configureTabs();
  }

  @override
  void didUpdateWidget(covariant LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _configureTabs();
  }

  /// Once nothing is being imported any more, finds out how this
  /// session's link imports ended.
  void _onLibraryChanged() {
    final links = widget.linkImports;
    if (links != null &&
        links.hasPending &&
        widget.library.importsInProgress == 0) {
      links.refresh();
    }
  }

  Future<void> _showAddMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              minVerticalPadding: 16,
              leading: const Icon(RhythmoIcons.uploadSimple),
              title: const Text('افزودن از فایل'),
              enabled: !widget.uploads.isBusy,
              onTap: widget.uploads.isBusy
                  ? null
                  : () => Navigator.pop(context, 'file'),
            ),
            if (widget.linkImports != null)
              ListTile(
                minVerticalPadding: 16,
                leading: const Icon(RhythmoIcons.link),
                title: const Text('افزودن از لینک'),
                onTap: () => Navigator.pop(context, 'link'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'file') await _pickAndUpload();
    if (choice == 'link') await _importFromLink();
  }

  Future<void> _importFromLink() async {
    final links = widget.linkImports;
    if (links == null) return;
    final message = await showLinkImportDialog(context, controller: links);
    if (message == null || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    // Shows the import in progress and follows it until it is done, and a
    // playlist a Spotify link made.
    await Future.wait([
      widget.library.load(),
      if (widget.playlists case final playlists?) playlists.load(),
    ]);
  }

  void _onTabChanged() {
    // The add-music button belongs to the tracks tab.
    if (!_tabs.indexIsChanging) setState(() {});
  }

  late final AppLifecycleListener _lifecycle;
  late final StreamSubscription<SyncOperation> _syncFinished;

  @override
  void initState() {
    super.initState();
    _syncFinished = widget.sync.finished.listen(_onSyncFinished);
    // Coming back from Bale or Telegram, show what was sent to the bot.
    _lifecycle = AppLifecycleListener(onResume: () {
      widget.library.load();
      widget.botLinks?.load();
      // What was played on another device meanwhile.
      widget.recent?.load();
    });
    widget.library.load();
    widget.botLinks?.load();
    widget.recent?.load();
    _recentSearches.load();
    widget.library.addListener(_onLibraryChanged);
    if (widget.localAudio.supported) widget.localAudio.load();
    // Opened from a shared playlist link: show it once signed in.
    final shareToken = AppConfiguration.takeInitialShareToken();
    final playlists = widget.playlists;
    if (shareToken != null && playlists != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => SharedPlaylistScreen(
            shareToken: shareToken,
            controller: playlists,
            player: widget.player,
            onSaved: widget.library.load,
          ),
        ));
      });
    }
    // Opened from a collaboration link: join it once signed in.
    final collabToken = AppConfiguration.takeInitialCollabToken();
    if (collabToken != null && playlists != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        joinCollabPlaylist(context,
            collabToken: collabToken,
            controller: playlists,
            libraryTracks: widget.library.tracks,
            player: widget.player);
      });
    }
    widget.uploads.addListener(_onUploadChanged);
  }

  @override
  void dispose() {
    if (widget.recentSearches == null) _recentSearches.dispose();
    _tabs.dispose();
    _lifecycle.dispose();
    widget.uploads.removeListener(_onUploadChanged);
    _syncFinished.cancel();
    widget.library.removeListener(_onLibraryChanged);
    super.dispose();
  }

  void _onUploadChanged() {
    final phase = widget.uploads.phase;
    if (phase == UploadPhase.done && _lastPhase != UploadPhase.done) {
      widget.library.load();
    }
    _lastPhase = phase;
  }

  Future<void> _pickAndUpload() async {
    final uploads = widget.uploads;
    final files = await widget.picker.pickMany(onReading: uploads.readingFile);
    if (files == null) return uploads.pickCancelled();
    await uploads.uploadAll(files);
  }

  void _onSyncFinished(SyncOperation operation) {
    if (!mounted) return;
    final title = operation.track.title;
    final error = operation.error;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(switch ((operation.kind, error)) {
        (SyncKind.upload, null) => '«$title» روی سرور آپلود شد.',
        (SyncKind.download, null) => widget.sync.downloadsToDevice
            ? '«$title» روی دستگاه ذخیره شد و بدون اینترنت پخش می‌شود.'
            : 'دانلود «$title» در مرورگر شروع شد.',
        (final kind, final error?) =>
          '${_syncVerb(kind)} «$title» ناموفق بود. ${syncErrorMessage(error)}',
      }),
    ));
  }

  Future<void> _confirmRemoveFromDevice(Track track) async {
    final synced = locationOf(track) == TrackLocation.synced;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(RhythmoIcons.deviceMobile),
        title: Text('حذف «${track.title}» از دستگاه؟'),
        content: Text(synced
            ? 'فایل از حافظهٔ دستگاه پاک می‌شود و نسخهٔ سرور می‌ماند.'
            : 'این آهنگ روی سرور نیست؛ با حذف از دستگاه برای همیشه پاک می‌شود.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            style: synced
                ? null
                : FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف از دستگاه'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await widget.localAudio.delete(track);
    if (!mounted) return;
    final message = switch (result) {
      DeviceDeleteResult.deleted => '«${track.title}» از دستگاه حذف شد.',
      DeviceDeleteResult.declined => null,
      DeviceDeleteResult.permissionDenied =>
        'ریتمو اجازهٔ تغییر حافظهٔ دستگاه را ندارد.',
      DeviceDeleteResult.failed => 'حذف از دستگاه ناموفق بود.',
    };
    if (result == DeviceDeleteResult.deleted && !synced) {
      await widget.player.removeTrack(track.id);
    }
    if (message == null || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Publishes [track] to the store, or makes it private again (#284).
  Future<void> _setPublished(Track track, bool published) async {
    final messenger = ScaffoldMessenger.of(context);
    final state = await widget.library.setPublished(track, published);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(switch (state) {
          null => 'تغییر انتشار ثبت نشد. دوباره تلاش کن.',
          PublishState.published =>
            '«${track.title}» در استور منتشر شد. بدون نام تو نمایش داده می‌شود.',
          PublishState.pending =>
            'درخواست انتشار «${track.title}» برای مدیر فرستاده شد. بعد از تأیید در استور می‌آید.',
          _ => published
              ? 'انتشار «${track.title}» ثبت نشد.'
              : '«${track.title}» دیگر منتشر نمی‌شود، مگر در یک فهرست پخش عمومی باشد.',
        }),
      ));
  }

  Future<void> _editTrackMetadata(Track track) async {
    final saved = await showTrackMetadataEditor(
      context,
      track: track,
      suggestions: MetadataSuggestions.fromTracks(widget.library.tracks),
      onSave: (draft, version) =>
          widget.library.saveTrackMetadata(track.id, draft, version: version),
    );
    if (saved == null) return;
    // The library already shows the saved copy; bring the player queue and
    // loaded playlists up to date too.
    widget.player.updateTrack(saved);
    widget.playlists?.updateTrack(saved);
    if (!mounted) return;
    final message = switch (saved.embeddedTags.status) {
      EmbeddedTagStatus.pending =>
        'ذخیره شد؛ اطلاعات تا چند لحظهٔ دیگر در خود فایل هم نوشته می‌شود.',
      EmbeddedTagStatus.unsupported =>
        'ذخیره شد؛ این قالب فایل برچسب داخلی قابل ویرایش ندارد.',
      _ => 'اطلاعات «${saved.title}» ذخیره شد.',
    };
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _confirmDeleteTrack(Track track) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(RhythmoIcons.trash),
        title: Text('حذف «${track.title}»؟'),
        content: Text(locationOf(track) == TrackLocation.synced
            ? 'نسخهٔ سرور برای همیشه از فضای ابری و فهرست‌های پخش حذف می‌شود؛ '
                'فایل روی دستگاه می‌ماند.'
            : 'این آهنگ برای همیشه از فضای ابری و فهرست‌های پخش حذف می‌شود. '
                'این کار قابل بازگشت نیست.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(locationOf(track) == TrackLocation.synced
                ? 'حذف از سرور'
                : 'حذف برای همیشه'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final deleted = await widget.library.deleteTrack(track.id);
    if (!mounted) return;
    if (!deleted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('حذف آهنگ ناموفق بود. دوباره تلاش کن.')),
      );
      return;
    }
    await widget.player.removeTrack(track.id);
    widget.recent?.remove(track.id);
    if (!mounted) return;
    widget.playlists?.load();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('«${track.title}» حذف شد.')),
    );
  }

  void _managePlaylists() {
    final playlists = widget.playlists;
    if (playlists == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
              appBar: AppBar(
                title: const Text('فهرست‌های پخش'),
                actions: [
                  if (widget.store != null)
                    IconButton(
                      tooltip: 'استور',
                      onPressed: _openStore,
                      icon: const Icon(RhythmoIcons.storefront),
                    ),
                  PopularPlaylistsButton(onOpen: _openPopular),
                ],
              ),
              bottomNavigationBar: MiniPlayer(player: widget.player),
              body: RhythmoBackdrop(
                  child: PlaylistsView(
                      controller: playlists,
                      libraryTracks: widget.library.tracks,
                      player: widget.player,
                      store: widget.store,
                      onSharedSaved: widget.library.load)),
            )));
  }

  Future<void> _openPopular() async {
    final playlists = widget.playlists;
    if (playlists == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PopularPlaylistsScreen(
        controller: playlists,
        player: widget.player,
        onSaved: widget.library.load,
      ),
    ));
    if (mounted) playlists.load();
  }

  void _openStore() {
    final store = widget.store;
    if (store == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => StoreScreen(
          controller: store, player: widget.player, identify: widget.identify),
    ));
  }

  void _openSettings() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
          builder: (_) => SettingsScreen(
            email: widget.email,
            onDeleteAccount: widget.onDeleteAccount,
            onSignOutEverywhere: widget.onSignOutEverywhere,
            cache: widget.cache,
            botLinks: widget.botLinks,
            library: widget.library,
            player: widget.player,
            onManagePlaylists:
                widget.playlists == null ? null : _managePlaylists,
          ),
        ))
        // A chat may have been linked meanwhile; offer sending to it.
        .then((_) => widget.botLinks?.load());
  }

  Future<void> _sendToBot(Track track, MessengerBot bot) async {
    final links = widget.botLinks;
    if (links == null) return;
    final result = await links.send(bot.provider, track.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(switch (result) {
        BotSendResult.queued =>
          'بات ریتمو «${track.title}» را در ${bot.name} برایت می‌فرستد.',
        BotSendResult.notLinked =>
          'گفتگوی ${bot.name} دیگر به حسابت وصل نیست. از تنظیمات دوباره وصلش کن.',
        BotSendResult.tooLarge =>
          '«${track.title}» برای فرستادن با بات ${bot.name} بزرگ است.',
        BotSendResult.failed =>
          'فرستادن به ${bot.name} ناموفق بود. دوباره تلاش کن.',
      }),
    ));
  }

  Future<void> _refreshLibrary() async {
    widget.botLinks?.load();
    widget.recent?.load();
    if (widget.localAudio.supported) widget.localAudio.load();
    final ok = await widget.library.load();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('به‌روزرسانی فهرست ناموفق بود.')),
      );
    }
  }

  /// Each file once: the account's tracks, matched with their copies on
  /// this device, then the device's other music.
  List<Track> _unifiedTracks() => [
        for (final entry
            in mergeLibrary(widget.library.tracks, widget.localAudio.tracks))
          entry.track,
      ];

  List<Widget> _accountActions(BuildContext context) {
    final wideActions = widget.onAdmin == null ? 720 : 960;
    final search = IconButton(
      tooltip: 'جست‌وجو در کتابخانه',
      onPressed: _openSearch,
      icon: const Icon(RhythmoIcons.magnifyingGlass),
    );
    final identify = widget.identify;
    final identifySong = identify == null
        ? null
        : IconButton(
            tooltip: 'این آهنگ چیه؟',
            onPressed: () => openIdentify(context, identify, widget.player),
            icon: const Icon(RhythmoIcons.microphoneStage),
          );
    final popular = widget.playlists == null
        ? null
        : PopularPlaylistsButton(onOpen: _openPopular);
    final storeButton = widget.store == null
        ? null
        : IconButton(
            tooltip: 'استور',
            onPressed: _openStore,
            icon: const Icon(RhythmoIcons.storefront),
          );
    if (MediaQuery.sizeOf(context).width >= wideActions) {
      return [
        if (popular != null) popular,
        if (storeButton != null) storeButton,
        if (identifySong != null) identifySong,
        search,
        const SizedBox(width: 8),
        _AccountChip(email: widget.email, verified: widget.verified),
        if (widget.onAdmin != null)
          IconButton(
            tooltip: 'مدیریت حساب‌ها',
            onPressed: widget.onAdmin,
            icon: const Icon(RhythmoIcons.usersFill),
          ),
        IconButton(
          tooltip: 'تنظیمات',
          onPressed: _openSettings,
          icon: const Icon(RhythmoIcons.gear),
        ),
        IconButton(
          tooltip: 'خروج',
          onPressed: widget.onLogout,
          icon: const Icon(RhythmoIcons.signOut),
        ),
        const SizedBox(width: 32),
      ];
    }
    return [
      if (popular != null) popular,
      if (storeButton != null) storeButton,
      if (identifySong != null) identifySong,
      search,
      PopupMenuButton<_HeaderAction>(
        tooltip: 'حساب و تنظیمات',
        icon: AccountAvatar(verified: widget.verified),
        onSelected: (action) {
          switch (action) {
            case _HeaderAction.settings:
              _openSettings();
            case _HeaderAction.admin:
              widget.onAdmin?.call();
            case _HeaderAction.logout:
              widget.onLogout();
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem<_HeaderAction>(
            enabled: false,
            child: Text(
              widget.email,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.verified)
            const PopupMenuItem<_HeaderAction>(
              enabled: false,
              child: Text('حساب تأییدشده'),
            ),
          if (widget.onAdmin != null)
            const PopupMenuItem(
              value: _HeaderAction.admin,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(RhythmoIcons.usersFill),
                title: Text('مدیریت حساب‌ها'),
              ),
            ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: _HeaderAction.settings,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(RhythmoIcons.gear),
              title: Text('تنظیمات'),
            ),
          ),
          const PopupMenuItem(
            value: _HeaderAction.logout,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(RhythmoIcons.signOut),
              title: Text('خروج از حساب'),
            ),
          ),
        ],
      ),
      const SizedBox(width: 8),
    ];
  }

  /// Brand and actions share one toolbar above the category tabs.
  Widget _header(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final tabs = TabBar(
      controller: _tabs,
      // On a phone the four short tabs share the width so all stay in view;
      // on wide screens they sit together at the start.
      isScrollable: wide || _visibleTabs.length > 4,
      tabAlignment: wide || _visibleTabs.length > 4
          ? TabAlignment.start
          : TabAlignment.fill,
      labelStyle: Theme.of(context)
          .textTheme
          .titleSmall
          ?.copyWith(fontWeight: FontWeight.w800),
      unselectedLabelStyle: Theme.of(context)
          .textTheme
          .titleSmall
          ?.copyWith(fontWeight: FontWeight.w500),
      // Phone tabs share a narrow width: tighter padding, and a label that
      // still does not fit shrinks a little instead of being clipped.
      labelPadding: wide
          ? const EdgeInsets.symmetric(horizontal: RhythmoSpace.lg)
          : const EdgeInsets.symmetric(horizontal: RhythmoSpace.xs),
      // Compact: the pill sits inside the page gutter and is shorter than
      // the 48 px row it lives in, which stays the touch target.
      padding: EdgeInsets.symmetric(
          horizontal: wide ? RhythmoSpace.xxl : RhythmoSpace.lg),
      indicatorPadding: const EdgeInsets.symmetric(vertical: RhythmoSpace.sm),
      dividerHeight: 0,
      // Keeps the focus tint rounded like the pill.
      splashBorderRadius: BorderRadius.circular(RhythmoRadii.pill),
      tabs: [for (final tab in _visibleTabs) _TabLabel(tab.label)],
    );
    final bar = wide
        ? SliverAppBar(
            pinned: true,
            toolbarHeight: 76,
            titleSpacing: 32,
            title: const _RhythmoBrand(compact: false),
            actions: _accountActions(context),
            bottom: tabs,
          )
        : SliverAppBar(
            pinned: true,
            titleSpacing: 16,
            title: const _RhythmoBrand(compact: true),
            // Opaque, because the lists scroll underneath it.
            backgroundColor: Theme.of(context).colorScheme.surface,
            actions: _accountActions(context),
            bottom: tabs,
          );
    return SliverOverlapAbsorber(
      handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
      sliver: bar,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      bottomNavigationBar: MiniPlayer(player: widget.player),
      floatingActionButtonLocation: const _LibraryAddButtonLocation(),
      floatingActionButton: _visibleTabs[_tabs.index] != LibraryTab.tracks
          ? null
          : FloatingActionButton(
              heroTag: 'add-music',
              tooltip: 'افزودن موسیقی',
              onPressed: _showAddMenu,
              child: const Icon(RhythmoIcons.plus),
            ),
      body: RhythmoBackdrop(
        child: NestedScrollView(
          headerSliverBuilder: (context, _) => [_header(context)],
          body: TabBarView(
            controller: _tabs,
            physics: libraryTabViewPhysics(),
            children: [
              for (final tab in _visibleTabs)
                _Tab(key: ValueKey(tab), child: _tabBody(tab))
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabBody(LibraryTab tab) => switch (tab) {
        LibraryTab.tracks => _unifiedLibrary(),
        LibraryTab.playlists => PlaylistsView(
            controller: widget.playlists!,
            libraryTracks: widget.library.tracks,
            player: widget.player,
            onSharedSaved: widget.library.load,
            store: widget.store,
            underHeader: true),
        LibraryTab.albums => _groupsTab(albums: true),
        LibraryTab.artists => _groupsTab(albums: false),
        LibraryTab.favorites => ListenableBuilder(
            listenable:
                Listenable.merge([_libraryChanges, widget.player.favorites]),
            builder: (context, _) {
              final tracks =
                  widget.player.favorites.likedFrom(_unifiedTracks());
              return tracks.isEmpty
                  ? const Center(child: Text('هنوز آهنگی را پسند نکرده‌ای'))
                  : _trackList(tracks);
            }),
      };

  Widget _groupsTab({required bool albums}) => ListenableBuilder(
        listenable: Listenable.merge([widget.library, widget.localAudio]),
        builder: (context, _) {
          final tracks = _unifiedTracks();
          return _GroupList(
            groups: albums ? groupByAlbum(tracks) : groupByArtist(tracks),
            albums: albums,
            onOpen: (group) => _openGroup(group, albums: albums),
          );
        },
      );

  void _openGroup(TrackGroup group, {required bool albums}) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _TrackGroupScreen(
        groupKey: group.key,
        albums: albums,
        library: Listenable.merge([widget.library, widget.localAudio]),
        tracks: _unifiedTracks,
        player: widget.player,
      ),
    ));
  }

  /// [tracks] with the library's row actions: playlists, bots, sync,
  /// editing and deleting.
  _TrackList _trackList(
    List<Track> tracks, {
    Widget? top,
    _DeviceNotice? deviceNotice,
    bool filterable = true,
    bool nested = true,
  }) =>
      _TrackList(
        top: top,
        tracks: tracks,
        player: widget.player,
        playlists: widget.playlists,
        onDelete: _confirmDeleteTrack,
        onEditMetadata: _editTrackMetadata,
        onSetPublished: widget.library.canPublish ? _setPublished : null,
        isDeleting: (trackId) =>
            widget.library.isDeleting(trackId) ||
            widget.library.isUpdating(trackId),
        linkedBots: widget.botLinks?.linkedBots ?? const [],
        onSendToBot: _sendToBot,
        sync: widget.sync,
        onRemoveFromDevice:
            widget.localAudio.supported ? _confirmRemoveFromDevice : null,
        deviceNotice: deviceNotice,
        filterable: filterable,
        nested: nested,
      );

  Listenable get _libraryChanges => Listenable.merge([
        widget.library,
        widget.localAudio,
        widget.sync,
        if (widget.botLinks != null) widget.botLinks,
      ]);

  void _openSearch() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LibrarySearchScreen(
        changes: _libraryChanges,
        tracks: _unifiedTracks,
        libraryTracks: () => widget.library.tracks,
        playlists: widget.playlists,
        player: widget.player,
        onSharedSaved: widget.library.load,
        recentSearches: _recentSearches,
      ),
    ));
  }

  Widget _unifiedLibrary() => ListenableBuilder(
        listenable: _libraryChanges,
        builder: (context, _) {
          final localStatus = widget.localAudio.status;
          final localLoading = widget.localAudio.supported &&
              (localStatus == LocalAudioViewStatus.idle ||
                  localStatus == LocalAudioViewStatus.loading);
          final tracks = _unifiedTracks();
          final top = Column(
            children: [
              if (widget.onVerifyEmail case final verify?)
                EmailVerificationBanner(onOpen: verify),
              if (widget.player.journey case final journey?)
                JourneyCard(
                  journey: journey,
                  tracks: tracks,
                  player: widget.player,
                ),
              UploadStatusCard(controller: widget.uploads),
              if (widget.linkImports case final links?)
                LinkImportFailures(controller: links),
              if (widget.library.importsInProgress case final n when n > 0)
                _ImportsInProgress(count: n),
            ],
          );
          Widget state(Widget child) => _TabScrollView(slivers: [
                SliverToBoxAdapter(child: top),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 56),
                    child: child,
                  ),
                ),
              ]);

          if (tracks.isEmpty &&
              (widget.library.status == LibraryStatus.loading ||
                  localLoading)) {
            return state(const Center(child: CircularProgressIndicator()));
          }
          if (widget.library.status == LibraryStatus.error && tracks.isEmpty) {
            return state(_LoadError(onRetry: widget.library.load));
          }
          final notice = _DeviceNotice.fromStatus(
            localStatus,
            widget.localAudio.supported,
          );
          return RefreshIndicator(
            onRefresh: _refreshLibrary,
            child: tracks.isEmpty
                ? state(_EmptyLibrary(deviceNotice: notice))
                : _trackList(tracks, top: top, deviceNotice: notice),
          );
        },
      );
}

/// «آپلود» or «دانلود», for a transfer's labels.
String _syncVerb(SyncKind kind) => switch (kind) {
      SyncKind.upload => 'آپلود',
      SyncKind.download => 'دانلود',
    };

enum _HeaderAction { settings, logout, admin }

enum _TrackAction {
  addToPlaylist,
  sendToBot,
  uploadToServer,
  downloadToDevice,
  removeFromDevice,
  retrySync,
  cancelSync,
  dismissSync,
  editMetadata,
  like,
  publish,
  delete,
}

class _RhythmoBrand extends StatelessWidget {
  const _RhythmoBrand({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showSubtitle = !compact && constraints.maxWidth >= 220;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RhythmoMark(size: compact ? 32 : 44),
            const SizedBox(width: 12),
            Flexible(
              child: showSubtitle
                  ? const Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'ریتمو',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'کتابخانهٔ موسیقی',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    )
                  : const Text(
                      'ریتمو',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _AccountChip extends StatelessWidget {
  const _AccountChip({required this.email, required this.verified});

  final String email;
  final bool verified;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: verified ? '$email · حساب تأییدشده' : email,
      child: GlassSurface(
        blur: 0,
        shadow: false,
        radius: 14,
        padding: const EdgeInsets.all(9),
        child: AccountAvatar(verified: verified, size: 22),
      ),
    );
  }
}

/// One library tab, kept alive so its scroll position survives switching
/// tabs.
class _Tab extends StatefulWidget {
  const _Tab({super.key, required this.child});

  final Widget child;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// Albums or artists, each played from its first track when tapped.
/// Albums as a grid of cards, or artists as a list; each opens its page.
class _GroupList extends StatelessWidget {
  const _GroupList({
    required this.groups,
    required this.albums,
    required this.onOpen,
  });

  final List<TrackGroup> groups;
  final bool albums;
  final void Function(TrackGroup group) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    if (groups.isEmpty) {
      return _TabScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(8, 56, 8, 0),
            sliver: SliverToBoxAdapter(
              child: _LibraryState(
                icon: albums ? RhythmoIcons.vinylRecord : RhythmoIcons.user,
                title: albums ? 'هنوز آلبومی نیست' : 'هنوز خواننده‌ای نیست',
                message: 'با افزودن موسیقی، آلبوم‌ها و خواننده‌ها اینجا '
                    'دسته‌بندی می‌شوند.',
              ),
            ),
          ),
        ],
      );
    }
    if (albums) {
      return _TabScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.only(top: 8),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                mainAxisSpacing: 16,
                crossAxisSpacing: 14,
                // The square cover plus two lines of text.
                childAspectRatio: 0.74,
              ),
              itemCount: groups.length,
              itemBuilder: (context, index) => _AlbumCard(
                group: groups[index],
                onTap: () => onOpen(groups[index]),
              ),
            ),
          ),
        ],
      );
    }
    return _TabScrollView(
      slivers: [
        SliverList.builder(
          itemCount: groups.length,
          itemBuilder: (context, index) {
            final group = groups[index];
            return ListTile(
              minTileHeight: 64,
              minVerticalPadding: 6,
              contentPadding:
                  const EdgeInsetsDirectional.only(start: 8, end: 8),
              leading: _GroupArt(albums: false, size: 48),
              title: Text(
                group.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: group.unknown ? colors.onSurfaceVariant : null,
                ),
              ),
              subtitle: Text(
                '${persianDigits(group.tracks.length)} آهنگ',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
              trailing: const Icon(RhythmoIcons.caretLeft),
              onTap: () => onOpen(group),
            );
          },
        ),
      ],
    );
  }
}

/// A rounded square for an album, a circle for an artist.
class _GroupArt extends StatelessWidget {
  const _GroupArt({required this.albums, required this.size});

  final bool albums;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(albums ? size * 0.16 : size / 2),
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [colors.surfaceContainerHighest, colors.primaryContainer],
        ),
      ),
      child: Icon(
        albums ? RhythmoIcons.vinylRecord : RhythmoIcons.user,
        size: size * 0.45,
        color: colors.onSurfaceVariant,
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.group, required this.onTap});

  final TrackGroup group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(RhythmoRadii.lg),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: LayoutBuilder(
              builder: (context, constraints) =>
                  _GroupArt(albums: true, size: constraints.maxWidth),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            group.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: group.unknown ? colors.onSurfaceVariant : null,
            ),
          ),
          Text(
            [
              if (group.artist case final artist?) artist,
              '${persianDigits(group.tracks.length)} آهنگ'
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// One album or artist: its tracks, with play-all and shuffle. It follows
/// the library, so edits and deletions show up while it is open.
class _TrackGroupScreen extends StatelessWidget {
  const _TrackGroupScreen({
    required this.groupKey,
    required this.albums,
    required this.library,
    required this.tracks,
    required this.player,
  });

  final String groupKey;
  final bool albums;
  final Listenable library;
  final List<Track> Function() tracks;
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([library, player]),
      builder: (context, _) {
        final all = tracks();
        final group = groupWithKey(
            albums ? groupByAlbum(all) : groupByArtist(all), groupKey);
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(
            title: Text(
              group?.name ?? (albums ? 'آلبوم' : 'خواننده'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          bottomNavigationBar: MiniPlayer(player: player),
          body: RhythmoBackdrop(
            child: group == null
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: _LibraryState(
                      icon: RhythmoIcons.musicNotesMinus,
                      title: 'آهنگی نمانده است',
                      message: 'آهنگ‌های این بخش حذف یا ویرایش شده‌اند.',
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final side = constraints.maxWidth >= 900
                          ? (constraints.maxWidth - 880) / 2
                          : 16.0;
                      final groupTracks = group.tracks;
                      return CustomScrollView(
                        slivers: [
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(side, 20, side, 8),
                            sliver: SliverToBoxAdapter(
                              child: Column(
                                children: [
                                  _GroupArt(albums: albums, size: 132),
                                  const SizedBox(height: 16),
                                  Text(
                                    group.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    [
                                      if (group.artist case final artist?)
                                        artist,
                                      '${persianDigits(groupTracks.length)} آهنگ',
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                        color:
                                            theme.colorScheme.onSurfaceVariant),
                                  ),
                                  const SizedBox(height: 16),
                                  Wrap(
                                    spacing: 12,
                                    runSpacing: 8,
                                    alignment: WrapAlignment.center,
                                    children: [
                                      FilledButton.icon(
                                        onPressed: () =>
                                            player.playFrom(groupTracks, 0),
                                        icon: const Icon(RhythmoIcons.playFill),
                                        label: const Text('پخش همه'),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed: () =>
                                            player.playShuffled(groupTracks),
                                        icon: const Icon(RhythmoIcons.shuffle),
                                        label: const Text('پخش تصادفی'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          SliverPadding(
                            // Room for the mini player under the last row.
                            padding: EdgeInsets.fromLTRB(side, 8, side, 128),
                            sliver: SliverList.builder(
                              itemCount: groupTracks.length,
                              itemBuilder: (context, index) {
                                final track = groupTracks[index];
                                return _TrackRow(
                                  track: track,
                                  current: player.track?.id == track.id,
                                  onTap: () =>
                                      player.playTapped(groupTracks, index),
                                  actions: null,
                                );
                              },
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        );
      },
    );
  }
}

class _TrackList extends StatefulWidget {
  const _TrackList({
    this.top,
    required this.tracks,
    required this.player,
    this.playlists,
    this.onDelete,
    this.onEditMetadata,
    this.onSetPublished,
    this.isDeleting,
    this.linkedBots = const [],
    this.onSendToBot,
    this.sync,
    this.onRemoveFromDevice,
    this.deviceNotice,
    this.filterable = true,
    this.nested = true,
  });

  /// Shown above the search, scrolling with the list.
  final Widget? top;
  final List<Track> tracks;
  final PlayerController player;
  final PlaylistsController? playlists;
  final Future<void> Function(Track track)? onDelete;
  final Future<void> Function(Track track)? onEditMetadata;

  /// Publishes the track to the store or makes it private (#284).
  final Future<void> Function(Track track, bool published)? onSetPublished;
  final bool Function(String trackId)? isDeleting;

  /// Bots with a linked chat, offered as «ارسال به …» for each track.
  final List<MessengerBot> linkedBots;
  final Future<void> Function(Track track, MessengerBot bot)? onSendToBot;

  /// Device and server copies: when set, rows show transfers and offer
  /// uploading, retrying and cancelling.
  final LibrarySyncController? sync;
  final Future<void> Function(Track track)? onRemoveFromDevice;
  final _DeviceNotice? deviceNotice;

  /// Whether the list can be searched and sorted; otherwise it keeps its
  /// order, as the recently played list does, with play-all on top.
  final bool filterable;

  /// Whether it is a tab under the library's collapsing header.
  final bool nested;

  @override
  State<_TrackList> createState() => _TrackListState();
}

class _TrackListState extends State<_TrackList> {
  static const _createPlaylistAction = '__create_playlist__';

  final Set<String> _selectedIds = {};

  @override
  void didUpdateWidget(covariant _TrackList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selectedIds.retainAll(widget.tracks.map((track) => track.id));
  }

  void _toggleSelection(Track track) => setState(() {
        if (!_selectedIds.remove(track.id)) _selectedIds.add(track.id);
      });

  Widget _selectionBar(List<Track> visible) {
    final selected = widget.tracks
        .where((track) => _selectedIds.contains(track.id))
        .toList();
    final allVisible = visible.isNotEmpty &&
        visible.every((track) => _selectedIds.contains(track.id));
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        IconButton(
          tooltip: 'لغو انتخاب',
          onPressed: () => setState(_selectedIds.clear),
          icon: const Icon(RhythmoIcons.x),
        ),
        Semantics(
          liveRegion: true,
          child: Text('${persianDigits(selected.length)} آهنگ انتخاب‌شده'),
        ),
        TextButton(
          onPressed: visible.isEmpty
              ? null
              : () => setState(() {
                    final ids = visible.map((track) => track.id);
                    if (allVisible) {
                      _selectedIds.removeAll(ids);
                    } else {
                      _selectedIds.addAll(ids);
                    }
                  }),
          child: Text(allVisible ? 'لغو انتخاب همه' : 'انتخاب همه'),
        ),
        IconButton(
          tooltip: 'پخش انتخاب‌شده‌ها',
          onPressed: selected.isEmpty
              ? null
              : () {
                  widget.player.playFrom(selected, 0);
                  setState(_selectedIds.clear);
                },
          icon: const Icon(RhythmoIcons.playFill),
        ),
        if (selected.length == 1)
          if (_actionsFor(context, selected.single) case final actions?)
            actions,
      ],
    );
  }

  /// Kept for the whole session, whichever screen shows the list.
  static TrackSort _sessionSort = TrackSort.recent;
  TrackSort _sort = _sessionSort;

  /// Searching happens on its own screen, from the header's search button.
  List<Track> get _sortedTracks =>
      widget.filterable ? sortTracks(widget.tracks, _sort) : widget.tracks;

  void _setSort(TrackSort sort) => setState(() {
        _sort = sort;
        _sessionSort = sort;
      });

  /// The track's «اقدامات آهنگ» menu, or null when there is nothing to offer.
  Widget? _actionsFor(BuildContext context, Track track) {
    // Someone else's track, from a collaborative playlist, is theirs to
    // manage.
    // A store song is nobody's to manage here either.
    if (track.addedBy != null || track.fromStore) return null;
    final sync = widget.sync;
    final location = locationOf(track);
    final onServer = location != TrackLocation.device;
    final onDevice = location != TrackLocation.server;
    final operation = sync?.operationFor(track.id);
    if (widget.isDeleting?.call(track.id) == true) {
      return const SizedBox.square(
        dimension: 48,
        child: Padding(
          padding: EdgeInsets.all(12),
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    final error = Theme.of(context).colorScheme.error;
    PopupMenuItem<(_TrackAction, MessengerBot?)> item(
      _TrackAction action,
      IconData icon,
      String label, {
      bool destructive = false,
      bool enabled = true,
    }) =>
        PopupMenuItem(
          value: (action, null),
          enabled: enabled,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(icon, color: destructive ? error : null),
            title: Text(
              label,
              style: destructive ? TextStyle(color: error) : null,
            ),
          ),
        );

    final items = <PopupMenuEntry<(_TrackAction, MessengerBot?)>>[
      if (operation != null && operation.active)
        item(
          _TrackAction.cancelSync,
          RhythmoIcons.x,
          'لغو ${_syncVerb(operation.kind)}',
          enabled: sync!.canCancel(track.id),
        ),
      if (operation != null && !operation.active) ...[
        item(_TrackAction.retrySync, RhythmoIcons.arrowsClockwise,
            'تلاش دوباره برای ${_syncVerb(operation.kind)}'),
        item(_TrackAction.dismissSync, RhythmoIcons.x, 'بستن خطا'),
      ],
      if (sync != null && operation == null && location == TrackLocation.device)
        item(_TrackAction.uploadToServer, RhythmoIcons.cloudArrowUp,
            'آپلود به سرور'),
      if (sync != null && operation == null && location == TrackLocation.server)
        item(
          _TrackAction.downloadToDevice,
          RhythmoIcons.cloudArrowDown,
          sync.downloadsToDevice ? 'دانلود روی دستگاه' : 'دانلود فایل',
        ),
      item(
        _TrackAction.like,
        widget.player.favorites.contains(track.id)
            ? RhythmoIcons.heartFill
            : RhythmoIcons.heart,
        widget.player.favorites.contains(track.id) ? 'نپسندیدن' : 'پسندیدن',
      ),
      if (onServer) ...[
        item(_TrackAction.editMetadata, RhythmoIcons.pencilSimple,
            'ویرایش اطلاعات آهنگ'),
        if (widget.onSetPublished != null)
          item(
            _TrackAction.publish,
            RhythmoIcons.globe,
            switch (track.publishState) {
              PublishState.published => 'لغو انتشار در استور',
              PublishState.pending => 'لغو درخواست انتشار',
              PublishState.rejected => 'درخواست دوباره‌ی انتشار',
              PublishState.private => 'انتشار در استور',
            },
          ),
        if (widget.playlists != null)
          item(_TrackAction.addToPlaylist, RhythmoIcons.listPlus,
              'افزودن به فهرست پخش'),
        for (final bot in widget.linkedBots)
          PopupMenuItem(
            value: (_TrackAction.sendToBot, bot),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(RhythmoIcons.paperPlaneTilt),
              title: Text('ارسال به ${bot.name}'),
            ),
          ),
      ],
      if (onDevice && widget.onRemoveFromDevice != null && operation == null)
        item(_TrackAction.removeFromDevice, RhythmoIcons.deviceMobile,
            'حذف از دستگاه',
            destructive: location == TrackLocation.device),
      if (onServer && widget.onDelete != null)
        item(
          _TrackAction.delete,
          RhythmoIcons.trash,
          location == TrackLocation.synced ? 'حذف از سرور' : 'حذف آهنگ',
          destructive: true,
        ),
    ];
    if (items.isEmpty) return null;
    return PopupMenuButton<(_TrackAction, MessengerBot?)>(
      tooltip: 'اقدامات آهنگ',
      onSelected: (choice) {
        switch (choice) {
          case (_TrackAction.addToPlaylist, _):
            _addToPlaylist(context, track);
          case (_TrackAction.sendToBot, final bot?):
            widget.onSendToBot?.call(track, bot);
          case (_TrackAction.delete, _):
            widget.onDelete?.call(track);
          case (_TrackAction.editMetadata, _):
            widget.onEditMetadata?.call(track);
          case (_TrackAction.like, _):
            _like(context, track);
          case (_TrackAction.publish, _):
            final state = track.publishState;
            widget.onSetPublished?.call(
                track,
                state != PublishState.published &&
                    state != PublishState.pending);
          case (_TrackAction.uploadToServer, _):
            sync?.upload(track);
          case (_TrackAction.downloadToDevice, _):
            sync?.download(track);
          case (_TrackAction.removeFromDevice, _):
            widget.onRemoveFromDevice?.call(track);
          case (_TrackAction.retrySync, _):
            sync?.retry(track.id);
          case (_TrackAction.cancelSync, _):
            sync?.cancel(track.id);
          case (_TrackAction.dismissSync, _):
            sync?.dismiss(track.id);
          case (_TrackAction.sendToBot, null):
            break;
        }
      },
      itemBuilder: (context) => items,
    );
  }

  Future<void> _like(BuildContext context, Track track) async {
    final messenger = ScaffoldMessenger.of(context);
    if (await widget.player.favorites.toggleTrack(track) ==
        TrackLikeResult.failed) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
            const SnackBar(content: Text('پسندیدن ثبت نشد. دوباره تلاش کن.')));
    }
  }

  Future<void> _addToPlaylist(BuildContext context, Track track) async {
    final controller = widget.playlists;
    if (controller == null) return;
    final loaded = await controller.load();
    if (!context.mounted) return;
    if (!loaded) {
      _message(context, 'دریافت فهرست‌های پخش ناموفق بود.');
      return;
    }

    var playlistId = controller.playlists.isEmpty
        ? await _createPlaylist(context, controller)
        : await showDialog<String>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const Text('افزودن به فهرست پخش'),
              children: [
                SimpleDialogOption(
                  onPressed: () =>
                      Navigator.pop(context, _createPlaylistAction),
                  child: const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(RhythmoIcons.plus),
                    title: Text('فهرست پخش جدید'),
                  ),
                ),
                const Divider(height: 1),
                for (final playlist in controller.playlists)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, playlist.id),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(RhythmoIcons.playlist),
                      title: Text(playlist.name),
                      subtitle: Text(
                          '${persianDigits(playlist.displayTrackCount)} قطعه موسیقی'),
                    ),
                  ),
              ],
            ),
          );

    if (!context.mounted || playlistId == null) return;
    if (playlistId == _createPlaylistAction) {
      playlistId = await _createPlaylist(context, controller);
      if (!context.mounted || playlistId == null) return;
    }

    final result = await controller.addTrack(playlistId, track.id);
    if (!context.mounted) return;
    switch (result) {
      case AddTrackResult.added:
        _message(context, 'آهنگ به فهرست پخش اضافه شد.');
      case AddTrackResult.alreadyPresent:
        _message(context, 'این آهنگ از قبل در فهرست پخش است.');
      case AddTrackResult.failure:
        _message(context, 'افزودن آهنگ به فهرست پخش ناموفق بود.');
    }
  }

  Future<String?> _createPlaylist(
    BuildContext context,
    PlaylistsController controller,
  ) async {
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('فهرست پخش جدید'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'نام فهرست پخش'),
          onSubmitted: (value) {
            final name = value.trim();
            if (name.isNotEmpty) Navigator.pop(context, name);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isNotEmpty) Navigator.pop(context, name);
            },
            child: const Text('ساخت'),
          ),
        ],
      ),
    );
    if (!context.mounted || name == null) return null;

    final playlist = await controller.create(name);
    if (!context.mounted) return null;
    if (playlist == null) {
      _message(context, 'ساخت فهرست پخش ناموفق بود.');
      return null;
    }
    return playlist.id;
  }

  void _message(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final tracks = _sortedTracks;
    return _TabScrollView(
      nested: widget.nested,
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            children: [
              if (_selectedIds.isNotEmpty) _selectionBar(tracks),
              if (widget.top case final top?) top,
              if (widget.deviceNotice case final notice?)
                _DeviceStatusBanner(notice: notice),
              if (!widget.filterable)
                _PlayAllHeader(
                  count: tracks.length,
                  onPlay: () => widget.player.playFrom(tracks, 0),
                  onShuffle: () => widget.player.playShuffled(tracks),
                )
              else ...[
                _TrackListHeader(
                  total: widget.tracks.length,
                  sort: _sort,
                  onSort: _setSort,
                  onShuffle: tracks.isEmpty
                      ? null
                      : () => widget.player.playShuffled(tracks),
                ),
              ],
            ],
          ),
        ),
        ListenableBuilder(
          listenable:
              Listenable.merge([widget.player, widget.player.favorites]),
          builder: (context, _) => SliverList.separated(
            itemCount: tracks.length,
            separatorBuilder: (_, __) => const _RowHairline(),
            itemBuilder: (context, index) {
              final track = tracks[index];
              return _TrackRow(
                track: track,
                current: widget.player.track?.id == track.id,
                selected: _selectedIds.contains(track.id),
                selecting: _selectedIds.isNotEmpty,
                onLongPress: () => _toggleSelection(track),
                onTap: () => _selectedIds.isNotEmpty
                    ? _toggleSelection(track)
                    : widget.player.playTapped(tracks, index),
                actions: _actionsFor(context, track),
                sync: widget.sync?.operationFor(track.id),
                liked: widget.player.favorites.contains(track.id),
                likeCount: widget.player.favorites.countFor(track),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The scrolling body of a library tab: below the pinned header's overlap,
/// centered at most 880 px wide, with room at the end for the add button
/// and the mini player so they never cover the last row.
class _TabScrollView extends StatelessWidget {
  const _TabScrollView({required this.slivers, this.nested = true});

  static const double _maxWidth = 880;
  final List<Widget> slivers;

  /// Under the library's NestedScrollView header; a screen of its own
  /// has nothing to inject.
  final bool nested;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.maxWidth >= 900
            ? ((constraints.maxWidth - _maxWidth) / 2).clamp(40.0, 10000.0)
            : 16.0;
        return CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (nested)
              SliverOverlapInjector(
                handle:
                    NestedScrollView.sliverOverlapAbsorberHandleFor(context),
              ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(side, 12, side, 128),
              sliver: SliverMainAxisGroup(slivers: slivers),
            ),
          ],
        );
      },
    );
  }
}

/// «N آهنگ» with sorting and shuffle, above the track list.
class _TrackListHeader extends StatelessWidget {
  const _TrackListHeader({
    required this.total,
    required this.sort,
    required this.onSort,
    required this.onShuffle,
  });

  final int total;
  final TrackSort sort;
  final ValueChanged<TrackSort> onSort;
  final VoidCallback? onShuffle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(8, 0, 0, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${persianDigits(total)} آهنگ',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          PopupMenuButton<TrackSort>(
            tooltip: 'مرتب‌سازی: ${sort.label}',
            onSelected: onSort,
            icon: const Icon(RhythmoIcons.sortAscending),
            itemBuilder: (context) => [
              for (final option in TrackSort.values)
                CheckedPopupMenuItem(
                  value: option,
                  checked: option == sort,
                  child: Text(option.label),
                ),
            ],
          ),
          TextButton.icon(
            onPressed: onShuffle,
            icon: const Icon(RhythmoIcons.shuffle, size: 20),
            label: const Text('پخش تصادفی'),
          ),
        ],
      ),
    );
  }
}

/// One track: artwork, title, then the artist.
class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.track,
    required this.current,
    required this.onTap,
    required this.actions,
    this.sync,
    this.selected = false,
    this.selecting = false,
    this.onLongPress,
    this.liked = false,
    this.likeCount = 0,
  });

  final Track track;

  /// Whether the listener likes it, and how many listeners do; shown with
  /// whether it is published (#284).
  final bool liked;
  final int likeCount;

  /// The track's upload, while queued, running or failed.
  final SyncOperation? sync;

  /// Whether this is the track in the player.
  final bool current;
  final VoidCallback onTap;
  final Widget? actions;
  final bool selected;
  final bool selecting;
  final VoidCallback? onLongPress;

  Future<void> _openContextMenu(BuildContext context, Offset position) async {
    final menu = actions;
    if (menu is! PopupMenuButton<(_TrackAction, MessengerBot?)>) return;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(position);
    final choice = await showMenu<(_TrackAction, MessengerBot?)>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(point.dx, point.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: menu.itemBuilder(context),
    );
    if (!context.mounted) return;
    if (choice != null) menu.onSelected?.call(choice);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final artist = track.artist?.trim();
    final secondary = theme.textTheme.bodySmall
        ?.copyWith(color: colors.onSurfaceVariant, height: 1.3);
    return CallbackShortcuts(
      bindings: {
        if (onLongPress != null)
          const SingleActivator(LogicalKeyboardKey.space): onLongPress!,
      },
      child: GestureDetector(
        onSecondaryTapUp: (details) =>
            _openContextMenu(context, details.globalPosition),
        child: Semantics(
          selected: selected,
          child: ListTile(
            selected: selecting ? selected : current,
            onTap: onTap,
            onLongPress: onLongPress,
            minTileHeight: 64,
            // Keep the two text lines compact while allowing larger text to grow.
            minVerticalPadding: 6,
            contentPadding: const EdgeInsetsDirectional.only(start: 8, end: 0),
            horizontalTitleGap: 12,
            leading: selecting
                ? SizedBox.square(
                    dimension: 48,
                    child: Checkbox(
                        value: selected, onChanged: (_) => onLongPress?.call()),
                  )
                : _TrackArtwork(track: track, current: current, sync: sync),
            title: Row(
              children: [
                if (current) ...[
                  Semantics(
                    label: 'در حال پخش',
                    child: Icon(RhythmoIcons.waveformFill,
                        size: 18, color: colors.primary),
                  ),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: current ? FontWeight.w700 : FontWeight.w600,
                      color: current ? colors.primary : colors.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            subtitle: switch (sync) {
              SyncOperation(phase: SyncPhase.failed, :final error?) => Text(
                  syncErrorMessage(error),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: secondary?.copyWith(color: colors.error),
                ),
              SyncOperation(preparing: true) => Text(
                  'در حال آماده‌سازی فایل…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: secondary?.copyWith(color: colors.primary),
                ),
              SyncOperation(:final kind, :final phase, :final progress) => Text(
                  phase == SyncPhase.queued
                      ? 'در صف ${_syncVerb(kind)}'
                      : 'در حال ${_syncVerb(kind)} ${persianDigits((progress * 100).round())}٪',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: secondary?.copyWith(color: colors.primary),
                ),
              null => Row(
                  children: [
                    Expanded(
                      child: Text(
                        artist == null || artist.isEmpty
                            ? 'خواننده نامشخص'
                            : artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: secondary,
                      ),
                    ),
                    _LikeBadges(
                      published: track.published,
                      pending: track.publishState == PublishState.pending,
                      liked: liked,
                      likeCount: likeCount,
                      style: secondary,
                    ),
                  ],
                ),
            },
            trailing: actions,
          ),
        ),
      ),
    );
  }
}

/// Small marks after the artist: published to the store, and the heart
/// with how many listeners like the song (filled when the listener does).
class _LikeBadges extends StatelessWidget {
  const _LikeBadges({
    required this.published,
    this.pending = false,
    required this.liked,
    required this.likeCount,
    this.style,
  });

  final bool published;

  /// Publishing waits for an admin's approval (#322).
  final bool pending;
  final bool liked;
  final int likeCount;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    if (!published && !pending && !liked && likeCount == 0) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).colorScheme;
    final labels = [
      if (published) 'منتشرشده',
      if (pending) 'در انتظار تأیید مدیر',
      if (liked) 'پسندیده‌ای',
      if (likeCount > 0) '${persianDigits(likeCount)} پسند',
    ];
    return Semantics(
      label: labels.join('، '),
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (published) ...[
            const SizedBox(width: RhythmoSpace.sm),
            Icon(RhythmoIcons.globe, size: 14, color: colors.secondary),
          ],
          if (pending) ...[
            const SizedBox(width: RhythmoSpace.sm),
            Tooltip(
              message: 'در انتظار تأیید مدیر',
              child: Icon(RhythmoIcons.clockCounterClockwise,
                  size: 14, color: style?.color),
            ),
          ],
          if (liked || likeCount > 0) ...[
            const SizedBox(width: RhythmoSpace.sm),
            Icon(liked ? RhythmoIcons.heartFill : RhythmoIcons.heart,
                size: 14, color: liked ? colors.primary : style?.color),
            if (likeCount > 0) ...[
              const SizedBox(width: RhythmoSpace.xxs),
              Text(persianDigits(likeCount), style: style),
            ],
          ],
        ],
      ),
    );
  }
}

/// A rounded artwork square with a small badge saying where the track is:
/// on the device, on the server, on both, being transferred, or failed.
class _TrackArtwork extends StatelessWidget {
  const _TrackArtwork({required this.track, required this.current, this.sync});

  final Track track;
  final bool current;
  final SyncOperation? sync;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final location = locationOf(track);
    final (where, Widget badge) = switch (sync) {
      SyncOperation(:final kind, phase: SyncPhase.failed) => (
          '${_syncVerb(kind)} ناموفق',
          Icon(RhythmoIcons.warningCircle, size: 13, color: colors.error),
        ),
      SyncOperation(:final kind, :final phase, :final progress) => (
          phase == SyncPhase.queued
              ? 'در صف ${_syncVerb(kind)}'
              : 'در حال ${_syncVerb(kind)}',
          SizedBox.square(
            dimension: 13,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value:
                  phase == SyncPhase.running && progress > 0 ? progress : null,
            ),
          ),
        ),
      null => switch ((location, track.importedFrom)) {
          (TrackLocation.device, _) => (
              'فقط روی دستگاه',
              Icon(RhythmoIcons.deviceMobile,
                  size: 13, color: colors.onSurfaceVariant),
            ),
          (TrackLocation.synced, _) => (
              'روی دستگاه و سرور',
              Icon(RhythmoIcons.checkCircle, size: 13, color: colors.primary),
            ),
          (TrackLocation.server, final String from) => (
              'از $from',
              Icon(RhythmoIcons.robot,
                  size: 13, color: colors.onSurfaceVariant),
            ),
          (TrackLocation.server, _) => (
              'روی سرور',
              Icon(RhythmoIcons.cloud,
                  size: 13, color: colors.onSurfaceVariant),
            ),
        },
    };
    return SizedBox.square(
      dimension: 48,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: current
                  ? colors.primaryContainer
                  : colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(RhythmoRadii.sm),
            ),
            child: Icon(
              RhythmoIcons.musicNote,
              color:
                  current ? colors.onPrimaryContainer : colors.onSurfaceVariant,
            ),
          ),
          PositionedDirectional(
            end: -4,
            bottom: -4,
            child: Tooltip(
              message: where,
              child: Semantics(
                label: where,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    shape: BoxShape.circle,
                  ),
                  child: badge,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceNotice {
  const _DeviceNotice({
    required this.icon,
    required this.message,
    required this.actionLabel,
  });

  final IconData icon;
  final String message;
  final String actionLabel;

  static _DeviceNotice? fromStatus(
    LocalAudioViewStatus status,
    bool supported,
  ) {
    if (!supported || status == LocalAudioViewStatus.loaded) return null;
    return switch (status) {
      LocalAudioViewStatus.permissionDenied => const _DeviceNotice(
          icon: RhythmoIcons.folderSimpleDashed,
          message: 'برای نمایش آهنگ‌های دستگاه، اجازهٔ دسترسی صوتی لازم است.',
          actionLabel: 'از تنظیمات دستگاه اجازه بده',
        ),
      LocalAudioViewStatus.error => const _DeviceNotice(
          icon: RhythmoIcons.warningCircle,
          message:
              'خواندن آهنگ‌های دستگاه ناموفق بود؛ آهنگ‌های سرور همچنان دیده می‌شوند.',
          actionLabel: 'صفحه را پایین بکش',
        ),
      LocalAudioViewStatus.unsupported => null,
      LocalAudioViewStatus.idle ||
      LocalAudioViewStatus.loading =>
        const _DeviceNotice(
          icon: RhythmoIcons.arrowsClockwise,
          message: 'در حال بررسی آهنگ‌های روی دستگاه…',
          actionLabel: 'Library یکپارچه می‌ماند',
        ),
      LocalAudioViewStatus.loaded => null,
    };
  }
}

class _DeviceStatusBanner extends StatelessWidget {
  const _DeviceStatusBanner({required this.notice});

  final _DeviceNotice notice;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
      child: GlassSurface(
        blur: 8,
        radius: 16,
        shadow: false,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(notice.icon, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                notice.message,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              notice.actionLabel,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportsInProgress extends StatelessWidget {
  const _ImportsInProgress({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              count == 1
                  ? 'یک فایل در حال اضافه شدن است…'
                  : '${persianDigits(count)} فایل در حال اضافه شدن است…',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// An empty or failed state of a library list, drawn as the shared
/// [RhythmoStateView]; a cloud or warning icon makes it an error.
class _LibraryState extends StatelessWidget {
  const _LibraryState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) =>
      icon == RhythmoIcons.cloudSlash || icon == RhythmoIcons.warningCircle
          ? RhythmoStateView.error(
              icon: icon, title: title, message: message, action: action)
          : RhythmoStateView(
              icon: icon, title: title, message: message, action: action);
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({this.deviceNotice});

  final _DeviceNotice? deviceNotice;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (deviceNotice case final notice?) ...[
          _DeviceStatusBanner(notice: notice),
          const SizedBox(height: 16),
        ],
        const _LibraryState(
          icon: RhythmoIcons.musicNotes,
          title: 'کتابخانهٔ شما خالی است',
          message:
              'با «افزودن موسیقی» آهنگ آپلود کن یا اجازه بده ریتمو آهنگ‌های دستگاه را هم همین‌جا نشان بدهد.',
        ),
      ],
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: _LibraryState(
        icon: RhythmoIcons.cloudSlash,
        title: 'کتابخانه دریافت نشد',
        message: 'اتصال اینترنت را بررسی کن و دوباره تلاش کن.',
        action: FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(RhythmoIcons.arrowsClockwise),
          label: const Text('تلاش دوباره'),
        ),
      ),
    );
  }
}

/// What a track is found by: its title, artist, album and filename.
List<String?> _searchFields(Track track) => [
      track.title,
      track.artist,
      track.album,
      track.albumArtist,
      track.fileName,
    ];

/// «N آهنگ» with play-all and shuffle, above a list kept in its order.
class _PlayAllHeader extends StatelessWidget {
  const _PlayAllHeader({
    required this.count,
    required this.onPlay,
    required this.onShuffle,
  });

  final int count;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 0, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${persianDigits(count)} آهنگ',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          FilledButton.icon(
            onPressed: count == 0 ? null : onPlay,
            icon: const Icon(RhythmoIcons.playFill),
            label: const Text('پخش همه'),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'پخش تصادفی',
            onPressed: count == 0 ? null : onShuffle,
            icon: const Icon(RhythmoIcons.shuffle),
          ),
        ],
      ),
    );
  }
}

/// «اخیراً پخش‌شده»: what the account played on any device, most recent
/// first, with the library's row actions.
class RecentlyPlayedScreen extends StatelessWidget {
  const RecentlyPlayedScreen({
    super.key,
    required this.recent,
    required this.changes,
    required this.tracks,
    required this.player,
    required this.list,
  });

  final RecentlyPlayedController recent;

  /// The library's changes, which the rows reflect.
  final Listenable changes;
  final List<Track> Function() tracks;
  final PlayerController player;

  /// The rows, given the tracks to show.
  final Widget Function(List<Track> tracks) list;

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(RhythmoIcons.clockCounterClockwise),
        title: const Text('پاک کردن تاریخچهٔ پخش؟'),
        content: const Text(
            'فهرست «اخیراً پخش‌شده» روی همهٔ دستگاه‌هایت خالی می‌شود. آهنگ‌ها سر جایشان می‌مانند.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('پاک کردن'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final cleared = await recent.clearAll();
    if (cleared || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('پاک کردن تاریخچه ناموفق بود. دوباره تلاش کن.')));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([recent, changes]),
      builder: (context, _) {
        final shown = tracks();
        Widget state(Widget child) => RefreshIndicator(
              onRefresh: recent.load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(24, 56, 24, 128),
                children: [child],
              ),
            );
        final Widget body;
        if (shown.isNotEmpty) {
          body = RefreshIndicator(
            onRefresh: recent.load,
            child: list(shown),
          );
        } else {
          body = switch (recent.status) {
            RecentlyPlayedStatus.loading => const Center(
                child: CircularProgressIndicator(
                    semanticsLabel: 'در حال دریافت تاریخچه'),
              ),
            RecentlyPlayedStatus.error => state(_LibraryState(
                icon: RhythmoIcons.cloudSlash,
                title: 'تاریخچه دریافت نشد',
                message: 'اتصال اینترنت را بررسی کن و دوباره تلاش کن.',
                action: FilledButton.icon(
                  onPressed: recent.load,
                  icon: const Icon(RhythmoIcons.arrowsClockwise),
                  label: const Text('تلاش دوباره'),
                ),
              )),
            RecentlyPlayedStatus.loaded => state(const _LibraryState(
                icon: RhythmoIcons.clockCounterClockwise,
                title: 'هنوز آهنگی پخش نشده',
                message:
                    'هر آهنگی که دست‌کم نیم دقیقه بشنوی این‌جا می‌آید؛ روی وب و اندروید یکسان.',
              )),
          };
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('اخیراً پخش‌شده'),
            actions: [
              if (shown.isNotEmpty)
                IconButton(
                  tooltip: 'پاک کردن تاریخچه',
                  onPressed: () => _confirmClear(context),
                  icon: const Icon(RhythmoIcons.trash),
                ),
              const SizedBox(width: 8),
            ],
          ),
          bottomNavigationBar: MiniPlayer(player: player),
          body: RhythmoBackdrop(child: body),
        );
      },
    );
  }
}

/// One search over the whole library: the account's tracks (title, artist,
/// album and filename), its playlists and the public popular playlists,
/// grouped. Matching ignores case, diacritics, ZWNJ and the Arabic forms of
/// Persian letters, see [normalizeForSearch]. It runs on the lists the app
/// already has, so results appear as you type, even offline.
class LibrarySearchScreen extends StatefulWidget {
  const LibrarySearchScreen({
    super.key,
    required this.changes,
    required this.tracks,
    required this.libraryTracks,
    required this.player,
    this.playlists,
    this.onSharedSaved,
    this.recentSearches,
  });

  /// Changes to the tracks, which the results follow.
  final Listenable changes;

  /// The unified library: the account's tracks and the device's music.
  final List<Track> Function() tracks;

  /// The account's own tracks, for adding to a playlist opened from here.
  final List<Track> Function() libraryTracks;
  final PlayerController player;

  /// Null without playlists, which then aren't searched.
  final PlaylistsController? playlists;
  final VoidCallback? onSharedSaved;

  /// Shown while the field is empty; null remembers nothing.
  final RecentSearchesController? recentSearches;

  @override
  State<LibrarySearchScreen> createState() => _LibrarySearchScreenState();
}

class _LibrarySearchScreenState extends State<LibrarySearchScreen> {
  final TextEditingController _field = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    final playlists = widget.playlists;
    if (playlists == null) return;
    // After the first frame: loading notifies the playlists tab, which
    // must not rebuild while this screen is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (playlists.status != PlaylistsStatus.loaded) playlists.load();
      if (playlists.popularStatus != PlaylistsStatus.loaded) {
        playlists.loadPopular();
      }
    });
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _clear() {
    _field.clear();
    setState(() => _query = '');
  }

  /// Remembers the current search once it led somewhere.
  void _remember() => widget.recentSearches?.add(_query);

  void _runRecent(String query) {
    _field.text = query;
    _field.selection = TextSelection.collapsed(offset: query.length);
    setState(() => _query = query);
    _remember();
  }

  Future<void> _openPlaylist(Playlist playlist) async {
    _remember();
    final controller = widget.playlists!;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlaylistDetailScreen(
        playlistId: playlist.id,
        controller: controller,
        libraryTracks: widget.libraryTracks(),
        player: widget.player,
      ),
    ));
    if (mounted) controller.load();
  }

  Future<void> _openPopular(PublicPlaylist playlist) async {
    _remember();
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SharedPlaylistScreen(
        shareToken: playlist.shareToken,
        controller: widget.playlists!,
        player: widget.player,
        onSaved: widget.onSharedSaved,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final playlists = widget.playlists;
    return Scaffold(
      appBar: AppBar(title: const Text('جست‌وجو')),
      bottomNavigationBar: MiniPlayer(player: widget.player),
      body: RhythmoBackdrop(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final side = constraints.maxWidth >= 900
                ? ((constraints.maxWidth - 880) / 2).clamp(40.0, 10000.0)
                : 16.0;
            return Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(side, 8, side, 8),
                  child: SearchBar(
                    constraints: const BoxConstraints(minHeight: 48),
                    controller: _field,
                    autoFocus: true,
                    hintText: 'آهنگ، خواننده، آلبوم یا فهرست پخش',
                    leading: const Icon(RhythmoIcons.magnifyingGlass),
                    textInputAction: TextInputAction.search,
                    trailing: [
                      if (_query.isNotEmpty)
                        IconButton(
                          tooltip: 'پاک کردن جست‌وجو',
                          onPressed: _clear,
                          icon: const Icon(RhythmoIcons.x),
                        ),
                    ],
                    onChanged: (value) => setState(() => _query = value),
                    onSubmitted: (_) => _remember(),
                  ),
                ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: Listenable.merge([
                      widget.changes,
                      widget.player,
                      if (playlists != null) playlists,
                      if (widget.recentSearches case final recent?) recent,
                    ]),
                    builder: (context, _) => _results(context, side),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _results(BuildContext context, double side) {
    Widget centered(Widget child) => ListView(
          padding: EdgeInsets.fromLTRB(side + 8, 48, side + 8, 128),
          children: [child],
        );
    if (normalizeForSearch(_query).isEmpty) {
      final recent = widget.recentSearches?.items ?? const <String>[];
      if (recent.isNotEmpty) {
        return _RecentSearches(
          searches: recent,
          side: side,
          onRun: _runRecent,
          onRemove: widget.recentSearches!.remove,
          onClear: widget.recentSearches!.clear,
        );
      }
      return centered(const _LibraryState(
        icon: RhythmoIcons.magnifyingGlass,
        title: 'در همهٔ کتابخانه بگرد',
        message:
            'آهنگ‌ها، فهرست‌های پخش خودت و فهرست‌های محبوب، همه با یک جست‌وجو.',
      ));
    }

    final playlists = widget.playlists;
    final tracks = widget
        .tracks()
        .where((track) => matchesSearch(_query, _searchFields(track)))
        .toList(growable: false);
    final mine = [
      for (final playlist in playlists?.playlists ?? const <Playlist>[])
        if (matchesSearch(_query, [playlist.name])) playlist,
    ];
    final popular = [
      for (final playlist in playlists?.popular ?? const <PublicPlaylist>[])
        // The user's own public playlists are already among theirs.
        if (!playlist.isOwner &&
            matchesSearch(_query, [playlist.name, playlist.owner]))
          playlist,
    ];
    final mineState = playlists == null
        ? PlaylistsStatus.loaded
        : (playlists.playlists.isEmpty
            ? playlists.status
            : PlaylistsStatus.loaded);
    final popularState = playlists == null
        ? PlaylistsStatus.loaded
        : (playlists.popular.isEmpty
            ? playlists.popularStatus
            : PlaylistsStatus.loaded);

    if (tracks.isEmpty &&
        mine.isEmpty &&
        popular.isEmpty &&
        mineState == PlaylistsStatus.loaded &&
        popularState == PlaylistsStatus.loaded) {
      return centered(_LibraryState(
        icon: RhythmoIcons.magnifyingGlassMinus,
        title: 'نتیجه‌ای پیدا نشد',
        message: 'عبارت دیگری را امتحان کن یا جست‌وجو را پاک کن.',
        action: OutlinedButton.icon(
          onPressed: _clear,
          icon: const Icon(RhythmoIcons.x),
          label: const Text('پاک کردن جست‌وجو'),
        ),
      ));
    }

    return CustomScrollView(
      slivers: [
        SliverPadding(
          // Room for the mini player under the last result.
          padding: EdgeInsets.fromLTRB(side, 4, side, 128),
          sliver: SliverMainAxisGroup(slivers: [
            if (tracks.isNotEmpty) ...[
              _ResultsHeader(
                title: 'آهنگ‌ها',
                count: tracks.length,
                onShuffle: () {
                  _remember();
                  widget.player.playShuffled(tracks);
                },
              ),
              SliverList.separated(
                itemCount: tracks.length,
                separatorBuilder: (_, __) => const _RowHairline(),
                itemBuilder: (context, index) {
                  final track = tracks[index];
                  return _TrackRow(
                    track: track,
                    current: widget.player.track?.id == track.id,
                    onTap: () {
                      _remember();
                      widget.player.playTapped(tracks, index);
                    },
                    actions: null,
                  );
                },
              ),
            ],
            if (playlists != null) ...[
              if (mine.isNotEmpty || mineState != PlaylistsStatus.loaded)
                _ResultsHeader(title: 'فهرست‌های پخش من', count: mine.length),
              if (mine.isEmpty && mineState != PlaylistsStatus.loaded)
                _GroupStatus(
                  status: mineState,
                  failed: 'فهرست‌های پخش دریافت نشد.',
                  onRetry: playlists.load,
                ),
              SliverList.builder(
                itemCount: mine.length,
                itemBuilder: (context, index) {
                  final playlist = mine[index];
                  return _PlaylistResult(
                    icon: RhythmoIcons.playlist,
                    title: playlist.name,
                    subtitle: [
                      '${persianDigits(playlist.displayTrackCount)} قطعه موسیقی',
                      if (!playlist.isOwner) 'مشترک',
                    ].join(' · '),
                    onTap: () => _openPlaylist(playlist),
                  );
                },
              ),
              if (popular.isNotEmpty || popularState != PlaylistsStatus.loaded)
                _ResultsHeader(
                    title: 'فهرست‌های پخش محبوب', count: popular.length),
              if (popular.isEmpty && popularState != PlaylistsStatus.loaded)
                _GroupStatus(
                  status: popularState,
                  failed: 'فهرست‌های محبوب دریافت نشد.',
                  onRetry: playlists.loadPopular,
                ),
              SliverList.builder(
                itemCount: popular.length,
                itemBuilder: (context, index) {
                  final playlist = popular[index];
                  return _PlaylistResult(
                    icon: RhythmoIcons.fire,
                    title: playlist.name,
                    // Owners stay private: no email, even masked.
                    subtitle: [
                      '${persianDigits(playlist.trackCount)} آهنگ',
                      '${persianDigits(playlist.likes.likeCount)} پسند',
                    ].join(' · '),
                    onTap: () => _openPopular(playlist),
                  );
                },
              ),
            ],
          ]),
        ),
      ],
    );
  }
}

/// The searches run before, newest first, while the field is empty.
class _RecentSearches extends StatelessWidget {
  const _RecentSearches({
    required this.searches,
    required this.side,
    required this.onRun,
    required this.onRemove,
    required this.onClear,
  });

  final List<String> searches;
  final double side;
  final ValueChanged<String> onRun;
  final ValueChanged<String> onRemove;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      // Room for the mini player under the last search.
      padding: EdgeInsets.fromLTRB(side, RhythmoSpace.xs, side, 128),
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(
              RhythmoSpace.sm, RhythmoSpace.md, 0, RhythmoSpace.xs),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'جست‌وجوهای اخیر',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              TextButton(
                onPressed: onClear,
                child: const Text('پاک کردن همه'),
              ),
            ],
          ),
        ),
        for (final (index, search) in searches.indexed) ...[
          if (index > 0) const _Hairline(indent: 56),
          ListTile(
            minTileHeight: 52,
            contentPadding: const EdgeInsetsDirectional.only(
                start: RhythmoSpace.lg, end: 0),
            leading: Icon(RhythmoIcons.clockCounterClockwise,
                color: theme.colorScheme.onSurfaceVariant),
            title: Text(search, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => onRun(search),
            trailing: IconButton(
              tooltip: 'حذف از جست‌وجوهای اخیر',
              onPressed: () => onRemove(search),
              icon: const Icon(RhythmoIcons.x, size: 18),
            ),
          ),
        ],
      ],
    );
  }
}

/// A faint line between rows, inset from the start so it begins where the
/// text does and leaves the artwork column clear.
class _Hairline extends StatelessWidget {
  const _Hairline({required this.indent});

  final double indent;

  @override
  Widget build(BuildContext context) => Divider(
        height: 1,
        thickness: 1,
        indent: indent,
        endIndent: RhythmoSpace.lg,
        color: Theme.of(context).colorScheme.outlineVariant.withValues(
              alpha: 0.45,
            ),
      );
}

/// The hairline between track rows: from the title's start edge.
class _RowHairline extends StatelessWidget {
  const _RowHairline();

  // Row padding, the 48 px artwork and the gap before the title.
  static const indent = 8.0 + 48 + 12;

  @override
  Widget build(BuildContext context) => const _Hairline(indent: indent);
}

/// A group's title in the search results, with how many it found.
class _ResultsHeader extends StatelessWidget {
  const _ResultsHeader(
      {required this.title, required this.count, this.onShuffle});

  final String title;
  final int count;

  /// Plays these results shuffled; null offers no shuffle.
  final VoidCallback? onShuffle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(8, 20, 8, 6),
        child: Semantics(
          header: true,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              if (count > 0)
                Text(
                  persianDigits(count),
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              if (onShuffle case final shuffle?) ...[
                const SizedBox(width: RhythmoSpace.xs),
                // A phone has no room for the label beside the count.
                if (MediaQuery.sizeOf(context).width < 480)
                  IconButton(
                    tooltip: 'پخش تصادفی نتایج',
                    onPressed: shuffle,
                    icon: const Icon(RhythmoIcons.shuffle),
                  )
                else
                  TextButton.icon(
                    onPressed: shuffle,
                    icon: const Icon(RhythmoIcons.shuffle, size: 18),
                    label: const Text('پخش تصادفی نتایج'),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A group still loading, or failed, in the search results.
class _GroupStatus extends StatelessWidget {
  const _GroupStatus({
    required this.status,
    required this.failed,
    required this.onRetry,
  });

  final PlaylistsStatus status;
  final String failed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 0, 4),
        child: status == PlaylistsStatus.error
            ? Row(
                children: [
                  Icon(RhythmoIcons.warningCircle,
                      size: 20, color: colors.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text(failed)),
                  TextButton(
                    onPressed: onRetry,
                    child: const Text('تلاش دوباره'),
                  ),
                ],
              )
            : const SizedBox(
                height: 48,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      semanticsLabel: 'در حال دریافت',
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

/// A playlist found by the search.
class _PlaylistResult extends StatelessWidget {
  const _PlaylistResult({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ListTile(
      onTap: onTap,
      minTileHeight: 64,
      minVerticalPadding: 6,
      contentPadding: const EdgeInsetsDirectional.only(start: 8, end: 8),
      horizontalTitleGap: 12,
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: colors.secondaryContainer,
          borderRadius: BorderRadius.circular(RhythmoRadii.sm),
        ),
        child: Icon(icon, color: colors.onSecondaryContainer),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style:
            theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: colors.onSurfaceVariant, height: 1.3),
      ),
      trailing: Icon(RhythmoIcons.caretLeft, color: colors.onSurfaceVariant),
    );
  }
}

/// A library tab whose label is always shown in full.
class _TabLabel extends StatelessWidget {
  const _TabLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Tab(
        // A full touch target, a little taller than Material's default.
        height: 48,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(text, maxLines: 1, softWrap: false),
        ),
      );
}

/// Keep Scaffold's vertical safe-area/player clearance, but share the
/// scrolling content's horizontal gutter instead of the viewport edge.
class _LibraryAddButtonLocation extends FloatingActionButtonLocation {
  const _LibraryAddButtonLocation();

  @override
  Offset getOffset(ScaffoldPrelayoutGeometry scaffoldGeometry) {
    final offset =
        FloatingActionButtonLocation.endFloat.getOffset(scaffoldGeometry);
    final width = scaffoldGeometry.scaffoldSize.width;
    final gutter =
        width >= 900 ? ((width - 880) / 2).clamp(40.0, 10000.0) : 16.0;
    final shift = gutter - 16;
    return offset.translate(
      scaffoldGeometry.textDirection == TextDirection.rtl ? shift : -shift,
      0,
    );
  }
}

/// On the web a trackpad or shift-wheel horizontal scroll must not switch
/// library tabs; there the tab bar is the only way across. Phones keep the
/// swipe.
@visibleForTesting
ScrollPhysics? libraryTabViewPhysics({bool isWeb = kIsWeb}) =>
    isWeb ? const NeverScrollableScrollPhysics() : null;
