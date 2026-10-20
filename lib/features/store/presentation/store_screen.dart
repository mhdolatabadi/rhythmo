import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/auth/presentation/sign_in_prompt.dart';
import 'package:rhythmo/features/identify/application/identify_controller.dart';
import 'package:rhythmo/features/identify/presentation/identify_screen.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/likes/presentation/liked_songs_screen.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/mini_player.dart';
import 'package:rhythmo/features/store/application/store_controller.dart';
import 'package:rhythmo/features/store/data/store_catalog.dart';
import 'package:rhythmo/features/store/presentation/store_carousel.dart';

/// How wide the store's search, tabs and lists grow on a wide screen: a
/// song's actions stay near its title instead of across the window.
const storeContentWidth = RhythmoSpace.listWidth;

/// «استور»: every song in rhythmo's public playlists, once, by title,
/// artist and album. Anyone can search and play; adding a song to the
/// library and reporting one need an account. Whose copy a song is is
/// never shown.
class StoreScreen extends StatefulWidget {
  const StoreScreen({
    super.key,
    required this.controller,
    required this.player,
    this.onSignIn,
    this.openSongId,
    this.identify,
  });

  final StoreController controller;
  final PlayerController player;

  /// «این آهنگ چیه؟», offered in the app bar; without an account it
  /// matches against the store. Null hides it.
  final IdentifyController? identify;

  /// Opens sign-in, for a guest who tries to add or report.
  final VoidCallback? onSignIn;

  /// A store song the app was opened with (`/app/?store=…`), offered on
  /// top at once.
  final String? openSongId;

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this)
    ..addListener(_loadTab);
  late final TextEditingController _search =
      TextEditingController(text: widget.controller.query);

  @override
  void initState() {
    super.initState();
    _loadTab();
    final id = widget.openSongId;
    if (id != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openSong(id);
      });
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  void _loadTab() {
    final controller = widget.controller;
    final listing = switch (_tabs.index) {
      1 => controller.artists,
      2 => controller.albums,
      _ => controller.songs,
    };
    listing.ensureLoaded();
  }

  Future<void> _openSong(String id) async {
    Track? song;
    try {
      song = await widget.controller.song(id);
    } catch (_) {
      if (mounted) _say('این آهنگ بارگذاری نشد. اتصال اینترنت را بررسی کن.');
      return;
    }
    if (!mounted) return;
    if (song == null) {
      _say('این آهنگ دیگر در استور نیست.');
      return;
    }
    final found = song;
    await showRhythmoSheet<void>(
      context,
      heightFactor: 0.6,
      builder: (context) => RhythmoSheetFrame(
        title: found.title,
        subtitle: found.artist,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
                  RhythmoSpace.xxl, RhythmoSpace.sm, RhythmoSpace.xxl, 0)
              .add(rhythmoListBottomPadding(context)),
          children: [
            Text(
              'این آهنگ در فهرست‌های پخش عمومی ریتمو هست و با کیفیت فایل '
              'اصلی پخش می‌شود.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: RhythmoSpace.xl),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                widget.player.play(found);
              },
              icon: const Icon(RhythmoIcons.playFill),
              label: const Text('پخش'),
            ),
            const SizedBox(height: RhythmoSpace.sm),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                _save(found);
              },
              icon: const Icon(RhythmoIcons.plusCircle),
              label: const Text('افزودن به کتابخانه‌ی من'),
            ),
          ],
        ),
      ),
    );
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save(Track song) =>
      saveStoreSong(context, widget.controller, song,
          onSignIn: widget.onSignIn);

  Future<void> _report(Track song) =>
      reportStoreSong(context, widget.controller, song,
          onSignIn: widget.onSignIn);

  void _openSongs(
      {required String title,
      String? subtitle,
      String? artist,
      String? album}) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => StoreSongsScreen(
        title: title,
        subtitle: subtitle,
        listing: widget.controller.songsOf(artist: artist, album: album),
        controller: widget.controller,
        player: widget.player,
        onSignIn: widget.onSignIn,
      ),
    ));
  }

  static final _searchBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(RhythmoRadii.pill),
    borderSide: const BorderSide(color: RhythmoColors.softBorder),
  );

  /// Three compact pills: they share a phone's width, and sit together at
  /// the start on a wide screen instead of spreading across it.
  Widget _tabBar(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= storeContentWidth;
    final text = Theme.of(context).textTheme;
    return TabBar(
      controller: _tabs,
      isScrollable: wide,
      tabAlignment: wide ? TabAlignment.start : TabAlignment.fill,
      labelStyle: text.titleSmall?.copyWith(fontWeight: FontWeight.w800),
      unselectedLabelStyle:
          text.titleSmall?.copyWith(fontWeight: FontWeight.w500),
      labelPadding: EdgeInsets.symmetric(
          horizontal: wide ? RhythmoSpace.xl : RhythmoSpace.xs),
      padding: const EdgeInsets.symmetric(horizontal: RhythmoSpace.lg),
      indicatorPadding: const EdgeInsets.symmetric(vertical: RhythmoSpace.sm),
      splashBorderRadius: BorderRadius.circular(RhythmoRadii.pill),
      dividerHeight: 0,
      tabs: const [
        Tab(height: RhythmoSpace.target, text: 'آهنگ‌ها'),
        Tab(height: RhythmoSpace.target, text: 'خواننده‌ها'),
        Tab(height: RhythmoSpace.target, text: 'آلبوم‌ها'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      extendBody: true,
      appBar: AppBar(
        title: const Text('استور'),
        actions: [
          if (widget.identify != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: RhythmoSpace.sm),
              child: IconButton(
                tooltip: 'این آهنگ چیه؟',
                onPressed: () => openIdentify(
                    context, widget.identify!, widget.player,
                    onSignIn: widget.onSignIn),
                icon: const Icon(RhythmoIcons.microphoneStage),
              ),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(
              RhythmoSpace.target * 2 + RhythmoSpace.md * 2),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: storeContentWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        RhythmoSpace.lg, 0, RhythmoSpace.lg, RhythmoSpace.md),
                    child: TextField(
                      controller: _search,
                      textInputAction: TextInputAction.search,
                      maxLength: 100,
                      decoration: InputDecoration(
                        hintText: 'نام آهنگ، خواننده یا آلبوم',
                        prefixIcon: const Icon(RhythmoIcons.magnifyingGlass),
                        counterText: '',
                        // A rounded search pill, like the tabs under it.
                        border: _searchBorder,
                        enabledBorder: _searchBorder,
                        focusedBorder: _searchBorder.copyWith(
                          borderSide: BorderSide(
                              color: Theme.of(context).colorScheme.primary,
                              width: 2),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: RhythmoSpace.xl,
                            vertical: RhythmoSpace.md + 2),
                        suffixIcon: ListenableBuilder(
                          listenable: _search,
                          builder: (context, _) => _search.text.isEmpty
                              ? const SizedBox.shrink()
                              : IconButton(
                                  tooltip: 'پاک کردن جستجو',
                                  onPressed: () {
                                    _search.clear();
                                    controller.search('');
                                  },
                                  icon: const Icon(RhythmoIcons.x),
                                ),
                        ),
                      ),
                      onChanged: controller.searchSoon,
                      onSubmitted: controller.search,
                    ),
                  ),
                  _tabBar(context),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: MiniPlayer(player: widget.player),
      body: RhythmoBackdrop(
        child: TabBarView(
          controller: _tabs,
          children: [
            _SongList(
              listing: controller.songs,
              controller: controller,
              player: widget.player,
              empty: () => controller.query.isEmpty
                  ? const _Empty(
                      icon: RhythmoIcons.storefront,
                      title: 'استور هنوز خالی است',
                      message: 'وقتی کسی فهرست پخشی را عمومی کند، '
                          'آهنگ‌هایش اینجا می‌آیند.',
                    )
                  : const _Empty(
                      icon: RhythmoIcons.magnifyingGlassMinus,
                      title: 'آهنگی پیدا نشد',
                      message: 'املای دیگری را امتحان کن یا نام خواننده را '
                          'بنویس.',
                    ),
              onSave: _save,
              onReport: _report,
              onSignIn: widget.onSignIn,
              header: ListenableBuilder(
                listenable: controller,
                builder: (context, _) => controller.query.isNotEmpty
                    ? const SizedBox.shrink()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final ranking in StoreRanking.values.reversed)
                            StoreCarousel(
                              controller: controller,
                              ranking: ranking,
                              player: widget.player,
                            ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                                RhythmoSpace.lg,
                                RhythmoSpace.lg,
                                RhythmoSpace.lg,
                                RhythmoSpace.xs),
                            child: Semantics(
                              header: true,
                              child: Text(
                                'همه‌ی آهنگ‌ها',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            _Listing<StoreArtist>(
              listing: controller.artists,
              emptyTitle: 'خواننده‌ای پیدا نشد',
              grid: true,
              row: (artist) => _IndexCard(
                icon: RhythmoIcons.microphoneStage,
                round: true,
                seed: 'artist:${artist.name}',
                title: artist.name,
                subtitle: '${persianDigits(artist.trackCount)} آهنگ',
                onTap: () =>
                    _openSongs(title: artist.name, artist: artist.name),
              ),
            ),
            _Listing<StoreAlbum>(
              listing: controller.albums,
              emptyTitle: 'آلبومی پیدا نشد',
              grid: true,
              row: (album) => _IndexCard(
                icon: RhythmoIcons.vinylRecord,
                seed: 'album:${album.name}:${album.artist}',
                title: album.name,
                subtitle: [
                  if (album.artist != null) album.artist!,
                  '${persianDigits(album.trackCount)} آهنگ',
                ].join(' · '),
                onTap: () => _openSongs(
                  title: album.name,
                  subtitle: album.artist,
                  album: album.name,
                  artist: album.artist,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One artist's or album's store songs.
class StoreSongsScreen extends StatefulWidget {
  const StoreSongsScreen({
    super.key,
    required this.title,
    this.subtitle,
    required this.listing,
    required this.controller,
    required this.player,
    this.onSignIn,
  });

  final String title;
  final String? subtitle;
  final StoreListing<Track> listing;
  final StoreController controller;
  final PlayerController player;
  final VoidCallback? onSignIn;

  @override
  State<StoreSongsScreen> createState() => _StoreSongsScreenState();
}

class _StoreSongsScreenState extends State<StoreSongsScreen> {
  @override
  void initState() {
    super.initState();
    widget.listing.ensureLoaded();
  }

  @override
  void dispose() {
    widget.listing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = widget.subtitle;
    return Scaffold(
      extendBody: true,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (subtitle != null)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
      bottomNavigationBar: MiniPlayer(player: widget.player),
      body: RhythmoBackdrop(
        child: _SongList(
          listing: widget.listing,
          controller: widget.controller,
          player: widget.player,
          empty: () => const _Empty(
            icon: RhythmoIcons.musicNotesMinus,
            title: 'آهنگی در استور نمانده',
            message: 'ممکن است از فهرست‌های پخش عمومی برداشته شده باشد.',
          ),
          onSave: (song) => saveStoreSong(context, widget.controller, song,
              onSignIn: widget.onSignIn),
          onReport: (song) => reportStoreSong(context, widget.controller, song,
              onSignIn: widget.onSignIn),
          onSignIn: widget.onSignIn,
        ),
      ),
    );
  }
}

/// Adds [song] to the listener's library, or asks a guest to sign in, and
/// says how it went.
Future<void> saveStoreSong(
    BuildContext context, StoreController controller, Track song,
    {VoidCallback? onSignIn}) async {
  if (!controller.signedIn) {
    askToSignIn(context, action: 'افزودن به کتابخانه', onSignIn: onSignIn);
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  final result = await controller.save(song);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(switch (result) {
        StoreSaveResult.saved =>
          '«${song.title}» به کتابخانه‌ات اضافه شد. این نسخه مال خودت است.',
        StoreSaveResult.alreadyYours => 'این آهنگ در کتابخانه‌ی خودت هست.',
        StoreSaveResult.noSpace =>
          'فضای کافی در حسابت نیست. چند آهنگ را حذف کن و دوباره امتحان کن.',
        StoreSaveResult.uploadsDisabled =>
          'افزودن آهنگ فعلاً غیرفعال است. کمی بعد دوباره امتحان کن.',
        StoreSaveResult.gone => 'این آهنگ دیگر در استور نیست.',
        StoreSaveResult.failed => 'افزودن ناموفق بود. دوباره تلاش کن.',
      }),
    ));
}

/// «گزارش تخلف»: asks what is wrong with [song] and sends it to the
/// admins, or asks a guest to sign in.
Future<void> reportStoreSong(
    BuildContext context, StoreController controller, Track song,
    {VoidCallback? onSignIn}) async {
  if (!controller.signedIn) {
    askToSignIn(context, action: 'گزارش تخلف', onSignIn: onSignIn);
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  final report = await showRhythmoSheet<_Report>(
    context,
    heightFactor: 0.85,
    builder: (context) => _ReportSheet(song: song),
  );
  if (report == null) return;
  final result =
      await controller.report(song, report.reason, details: report.details);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(switch (result) {
        StoreReportResult.sent =>
          'گزارشت فرستاده شد. مدیران ریتمو آن را بررسی می‌کنند.',
        StoreReportResult.gone => 'این آهنگ دیگر در استور نیست.',
        StoreReportResult.tooMany =>
          'امروز گزارش زیادی فرستاده‌ای. فردا دوباره امتحان کن.',
        StoreReportResult.failed => 'گزارش فرستاده نشد. دوباره تلاش کن.',
      }),
    ));
}

class _Report {
  const _Report(this.reason, this.details);

  final StoreReportReason reason;
  final String? details;
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.song});

  final Track song;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  StoreReportReason? _reason;
  final _details = TextEditingController();

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reason = _reason;
    return RhythmoSheetFrame(
      title: 'گزارش تخلف',
      subtitle: widget.song.title,
      child: ListView(
        padding:
            const EdgeInsets.fromLTRB(RhythmoSpace.lg, 0, RhythmoSpace.lg, 0)
                .add(rhythmoListBottomPadding(context)),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: RhythmoSpace.sm, vertical: RhythmoSpace.sm),
            child: Text(
              'چه مشکلی در این آهنگ هست؟ مدیران ریتمو گزارش را می‌بینند و '
              'ممکن است آهنگ را از استور پنهان کنند. نامت به کسی نشان داده '
              'نمی‌شود.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          RadioGroup<StoreReportReason>(
            groupValue: reason,
            onChanged: (value) => setState(() => _reason = value),
            child: Column(
              children: [
                for (final option in StoreReportReason.values)
                  RadioListTile<StoreReportReason>(
                    value: option,
                    title: Text(option.label),
                    minTileHeight: RhythmoSpace.target + RhythmoSpace.sm,
                  ),
              ],
            ),
          ),
          const SizedBox(height: RhythmoSpace.sm),
          TextField(
            controller: _details,
            maxLength: 1000,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'توضیح (اختیاری)',
              hintText: 'مثلاً صاحب اصلی اثر یا مشکل مشخصات',
            ),
          ),
          const SizedBox(height: RhythmoSpace.md),
          FilledButton.icon(
            onPressed: reason == null
                ? null
                : () => Navigator.of(context).pop(_Report(
                    reason,
                    _details.text.trim().isEmpty
                        ? null
                        : _details.text.trim())),
            icon: const Icon(RhythmoIcons.flag),
            label: const Text('فرستادن گزارش'),
          ),
        ],
      ),
    );
  }
}

class _SongList extends StatelessWidget {
  const _SongList({
    required this.listing,
    required this.controller,
    required this.player,
    required this.empty,
    required this.onSave,
    required this.onReport,
    this.onSignIn,
    this.header,
  });

  /// Shown above the first song.
  final Widget? header;

  final StoreListing<Track> listing;

  /// Opens sign-in, for a guest who likes a song.
  final VoidCallback? onSignIn;
  final StoreController controller;
  final PlayerController player;
  final Widget Function() empty;
  final void Function(Track) onSave;
  final void Function(Track) onReport;

  @override
  Widget build(BuildContext context) {
    return _Listing<Track>(
      listing: listing,
      emptyTitle: 'آهنگی پیدا نشد',
      empty: empty,
      header: header,
      row: (song) => ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          final songs = listing.items;
          return RhythmoTrackRow(
            seed: song.id,
            title: song.title,
            subtitle: song.artist ?? 'خواننده‌ی نامشخص',
            active: player.track?.id == song.id && player.track!.fromStore,
            onTap: () => player.playTapped(songs, songs.indexOf(song)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LikeButton(
                  track: song,
                  favorites: player.favorites,
                  showCount: true,
                  onSignIn: onSignIn,
                ),
                _SongMenu(
                  saving: controller.isSaving(song),
                  onSave: () => onSave(song),
                  onReport: () => onReport(song),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

enum _SongAction { save, report }

class _SongMenu extends StatelessWidget {
  const _SongMenu({
    required this.saving,
    required this.onSave,
    required this.onReport,
  });

  final bool saving;
  final VoidCallback onSave;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    if (saving) {
      return const SizedBox.square(
        dimension: RhythmoSpace.target,
        child: Center(
          child: SizedBox.square(
            dimension: RhythmoSpace.xl,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return PopupMenuButton<_SongAction>(
      tooltip: 'گزینه‌های آهنگ',
      icon: const Icon(RhythmoIcons.dotsThreeVertical),
      onSelected: (action) => switch (action) {
        _SongAction.save => onSave(),
        _SongAction.report => onReport(),
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _SongAction.save,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(RhythmoIcons.plusCircle),
            title: Text('افزودن به کتابخانه‌ی من'),
          ),
        ),
        PopupMenuItem(
          value: _SongAction.report,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(RhythmoIcons.flag),
            title: Text('گزارش تخلف'),
          ),
        ),
      ],
    );
  }
}

/// An artist or album in the store's grid: a large tinted cover (round
/// for an artist), its name and a count, all one tap target.
class _IndexCard extends StatelessWidget {
  const _IndexCard({
    required this.icon,
    required this.seed,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.round = false,
  });

  final IconData icon;
  final String seed;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool round;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tint = artworkTint(seed);
    return Semantics(
      button: true,
      label: '$title، $subtitle',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: RhythmoRadii.surface,
        child: Padding(
          padding: const EdgeInsets.all(RhythmoSpace.sm),
          child: Column(
            crossAxisAlignment:
                round ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: round ? BoxShape.circle : BoxShape.rectangle,
                    borderRadius: round ? null : RhythmoRadii.surface,
                    border: Border.all(color: RhythmoColors.softBorder),
                    gradient: LinearGradient(
                      begin: AlignmentDirectional.topStart,
                      end: AlignmentDirectional.bottomEnd,
                      colors: [
                        Color.lerp(tint, colors.onSurface, 0.14)!,
                        tint,
                        Color.lerp(tint, RhythmoColors.background, 0.45)!,
                      ],
                    ),
                  ),
                  child: LayoutBuilder(
                    builder: (context, box) => Icon(icon,
                        size: box.maxWidth * 0.32,
                        color: colors.onSurfaceVariant),
                  ),
                ),
              ),
              const SizedBox(height: RhythmoSpace.sm),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: round ? TextAlign.center : TextAlign.start,
                style: theme.textTheme.titleSmall,
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: round ? TextAlign.center : TextAlign.start,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A paged listing with its loading, error and empty states; the next
/// page loads as the end comes into view. The last row stays clear of the
/// mini player and the system insets.
class _Listing<T> extends StatelessWidget {
  const _Listing({
    required this.listing,
    required this.row,
    required this.emptyTitle,
    this.empty,
    this.header,
    this.grid = false,
  });

  /// Lays the items out as cards in a grid instead of rows.
  final bool grid;

  /// Shown above the first row, such as the carousels.
  final Widget? header;

  final StoreListing<T> listing;
  final Widget Function(T item) row;
  final String emptyTitle;
  final Widget Function()? empty;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: listing,
      builder: (context, _) {
        final items = listing.items;
        return switch (listing.status) {
          StoreStatus.idle ||
          StoreStatus.loading when items.isEmpty =>
            const RhythmoStateView.loading(title: 'در حال بارگذاری استور…'),
          StoreStatus.error when items.isEmpty => RhythmoStateView.error(
              icon: RhythmoIcons.cloudSlash,
              title: 'استور بارگذاری نشد',
              message: 'اتصال اینترنت را بررسی کن و دوباره تلاش کن.',
              action: FilledButton.icon(
                onPressed: listing.refresh,
                icon: const Icon(RhythmoIcons.arrowsClockwise),
                label: const Text('تلاش دوباره'),
              ),
            ),
          _ when items.isEmpty => empty?.call() ??
              _Empty(
                  icon: RhythmoIcons.magnifyingGlassMinus, title: emptyTitle),
          _ => RefreshIndicator(
              onRefresh: listing.refresh,
              child: Center(
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: storeContentWidth),
                  child: grid ? _grid(context, items) : _list(items),
                ),
              ),
            ),
        };
      },
    );
  }

  // extendBody puts the mini player's height in the bottom padding, with
  // the system inset.
  double _bottom(BuildContext context) =>
      MediaQuery.paddingOf(context).bottom + RhythmoSpace.lg;

  Widget _list(List<T> items) => Builder(
        builder: (context) => ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding:
              EdgeInsets.only(top: RhythmoSpace.sm, bottom: _bottom(context)),
          itemCount: items.length +
              (listing.hasMore ? 1 : 0) +
              (header == null ? 0 : 1),
          itemBuilder: (context, index) {
            if (header != null) {
              if (index == 0) return header!;
              index--;
            }
            if (index < items.length) {
              return _PanelRow(
                first: index == 0,
                last: index == items.length - 1,
                child: row(items[index]),
              );
            }
            return _MoreRow(listing: listing);
          },
        ),
      );

  Widget _grid(BuildContext context, List<T> items) {
    // Room under each square cover for a title and a count, at any text
    // size.
    final caption =
        MediaQuery.textScalerOf(context).scale(40) + RhythmoSpace.sm * 3;
    return LayoutBuilder(builder: (context, constraints) {
      const gutter = RhythmoSpace.sm;
      final width = constraints.maxWidth - gutter * 2;
      final columns = (width / 176).ceil().clamp(2, 6);
      final cell = width / columns;
      return CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding:
                const EdgeInsets.fromLTRB(gutter, RhythmoSpace.md, gutter, 0),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisExtent: cell + caption,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) => row(items[index]),
            ),
          ),
          if (listing.hasMore)
            SliverToBoxAdapter(child: _MoreRow(listing: listing)),
          SliverPadding(padding: EdgeInsets.only(bottom: _bottom(context))),
        ],
      );
    });
  }
}

/// One row of a list that reads as a single rounded panel: the first row
/// rounds its top, the last its bottom, and rows between are split by a
/// hairline.
class _PanelRow extends StatelessWidget {
  const _PanelRow({
    required this.first,
    required this.last,
    required this.child,
  });

  final bool first;
  final bool last;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const radius = Radius.circular(RhythmoRadii.lg);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: RhythmoSpace.lg),
      // A Material, so the rows' hover and ink still paint on the panel.
      child: Material(
        color: colors.surfaceContainerHigh.withValues(alpha: 0.42),
        borderRadius: BorderRadius.vertical(
          top: first ? radius : Radius.zero,
          bottom: last ? radius : Radius.zero,
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              RhythmoSpace.xs,
              first ? RhythmoSpace.xs : 0,
              RhythmoSpace.xs,
              last ? RhythmoSpace.xs : 0),
          child: Column(
            children: [
              child,
              if (!last)
                const Divider(
                  height: 1,
                  indent: RhythmoSpace.lg + 44 + RhythmoSpace.lg,
                  endIndent: RhythmoSpace.md,
                  color: RhythmoColors.divider,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The end of a listing with more to come: it asks for the next page as
/// it comes into view, and offers a retry when that failed.
class _MoreRow extends StatelessWidget {
  const _MoreRow({required this.listing});

  final StoreListing<Object?> listing;

  @override
  Widget build(BuildContext context) {
    if (listing.moreFailed) {
      return Padding(
        padding: const EdgeInsets.all(RhythmoSpace.lg),
        child: Center(
          child: OutlinedButton.icon(
            onPressed: listing.loadMore,
            icon: const Icon(RhythmoIcons.arrowsClockwise),
            label: const Text('بارگذاری بقیه'),
          ),
        ),
      );
    }
    if (!listing.loadingMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) => listing.loadMore());
    }
    return const Padding(
      padding: EdgeInsets.all(RhythmoSpace.lg),
      child: Center(
        child: SizedBox.square(
          dimension: RhythmoSpace.xxl,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, this.message});

  final IconData icon;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    // Scrollable, so pull to refresh still works on an empty listing.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: RhythmoStateView(icon: icon, title: title, message: message),
        ),
      ),
    );
  }
}
