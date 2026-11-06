# Redesign, November 2026 ("نسخهٔ تازه")

This is the handoff spec for the November 2026 redesign of the rhythmo app. It is written so another agent can pick up any part of the work without the design conversation.

- Source of truth for visuals: the design canvas https://claude.ai/artifact/CGhdmodViNDLjSRgfS7bUg, page «نسخهٔ تازه», boards N1–N10. It is private to the owner, so the screenshots in [`redesign-2026-11/`](redesign-2026-11/) are the copy every agent can see.
- Tracking issue: #442. Sub-issues: #443 backdrop, #444 shell, #445 موسیقی من, #446 now playing, #447 home and notifications, #448 search/گنجینه/channel, #449 settings, #450 logo (waiting for the owner).
- Everything here replaces the «شفق» (aurora) look from October 2026. Keep the behaviour fixes from #439, #440 and #441.

## Screens

| # | Screen | Screenshot | Existing code to change |
|---|--------|------------|--------------------------|
| 1 | موسیقی من, songs tab (the app opens here) | [01](redesign-2026-11/01-my-music.jpg) | `library_screen.dart` |
| 2 | موسیقی من, playlists tab | [02](redesign-2026-11/02-my-music-playlists.jpg) | `playlists_screen.dart` |
| 3 | خانه | [03](redesign-2026-11/03-home.jpg) | `home_view.dart` |
| 4 | اعلان‌ها | [04](redesign-2026-11/04-notifications.jpg) | `notifications_screen.dart` |
| 5 | حساب و تنظیمات | [05](redesign-2026-11/05-settings.jpg) | `settings_screen.dart` |
| 6 | جستجو | [06](redesign-2026-11/06-search.jpg) | search in `library_screen.dart` |
| 7 | گنجینه | [07](redesign-2026-11/07-ganjineh.jpg) | `store_screen.dart` |
| 8 | فهرست عمومی (channel) | [08](redesign-2026-11/08-public-playlist.jpg) | `shared_playlist_screen.dart` |
| 9 | پسندیده‌ها | [09](redesign-2026-11/09-liked.jpg) | `liked_songs_screen.dart` |
| 10 | در حال پخش | [10](redesign-2026-11/10-now-playing.jpg) | `now_playing_screen.dart` |

## Colour and background

The owner asked for the current rhythmo palette from `lib/core/design/tokens.dart`, with the background kept navy:

- Background: a still linear gradient from top-right `#11142A` to `#0A0C18` at 48% to `#070810` at the bottom-left. There is only a very faint coral glow, at 6% alpha, in the top corner and a violet glow at 8% in the middle of the opposite side. The owner said: «سورمه‌ای بمونه، خیلی خیلی کم متمایل بشه به قرمز». This means `RhythmoBackdrop` must get much weaker glows: today they are 26% and 20%.
- Surfaces: `surface` `#121522` for cards, setting groups and the mini player, and `surfaceStrong` `#191D2D`.
- Text: `onSurface` `#F5F1F7`, and `onSurfaceVariant` `#A9A1AE` for every secondary line.
- Coral `primary` `#FF626A` is used only for:
  - the main action (the round play button on a hero or channel),
  - the playing row's title and equaliser,
  - the mini player's progress line,
  - switches that are on,
  - the unread dot.
- Violet `secondary` `#8D7CFF` marks sync and privacy:
  - the cloud and lock icons,
  - the «فقط روی گوشی» label, on `secondaryContainer` `#2A2454` with text `#E5DFFF`.
- Covers are always the track's real artwork. Never draw aurora or mesh gradients as covers; the owner rejected them.

## Shell: bottom bar and mini player

- **Bottom bar:**
  - Four icon-only items, in RTL order: خانه, جستجو, پسندیده‌ها, موسیقی من. There are no labels on screen, but each item keeps a semantics label and tooltip.
  - Full width and 70 px tall. It has the same colour as the page (`#070810`), no pill and no border.
  - Icons are 24 px. Resting icons are muted (`#6F6878`). The selected icon is `onSurface`.
  - Targets stay at least 48 px.
  - The owner liked this exact bar on an earlier canvas: «هم کامل مفهوم رو می‌رسونه، هم ساده‌ست و خلوت».
- **Account:** «حساب» leaves the bar. The account avatar at the top of خانه opens حساب و تنظیمات.
- **Default destination:** موسیقی من («صفحه دیفالت باید اینجا باشه»).
- **Mini player:**
  - Full width and flush, directly above the bar. It is 60 px tall on `surface`.
  - A 2 px coral progress line runs on its top edge.
  - Contents: a 42 px cover with 6 px corners, title and artist, then play/pause.
  - It has **no like button**, is not a floating card and is not grey glass.
  - The playback error text from #441 keeps working.

## Lists and sync state

- **Track rows:** a 52 px cover, then the title, then the artist as the only secondary line. A row menu sits at the end.
  - The playing row has a `surface` background, a coral title and a small equaliser.
- **Sync label:** there is no «روی گوشی» filter chip any more. Each row says where the song lives:
  - Synced: a small cloud-with-check icon before the artist, with the semantics label «در فضای ابری».
  - Not synced: a small label «فقط روی گوشی» before the artist.
  - The owner asked how the app knows. The rule is that a track is synced when it has a cloud copy. Today `Track.isLocal` (`sourceUri != null`) is also true for a cloud track merged with its device file, so add an explicit getter for "has a cloud copy" and test it.
- **موسیقی من tabs:** two chips, «آهنگ‌ها» and «فهرست‌ها». The header is «موسیقی من» with a small muted count («۱۴۲ آهنگ» or «۶ فهرست») and a + button for upload or a new playlist. There are no stats cards and no big counts.
- **Playlists tab:** a «فهرست تازه» row first. Next come your playlists, each with:
  - a 2×2 mosaic cover, or one cover when there is a single track,
  - a globe icon with «عمومی» and its follower count, or a lock icon with «خصوصی»,
  - the track count.

  Below them is the section «فهرست‌هایی که دنبال می‌کنی», listing the channels you follow.

## Screens in detail

- **خانه:**
  - Header: «ریتمو», a bell with an unread dot that opens اعلان‌ها, and the avatar.
  - Then a hero card «ادامهٔ پخش» with the cover as background and a coral play button.
  - Then «تازه از کانال‌هایت», rows of new songs from channels you follow, with «همه» opening اعلان‌ها.
  - Then «اخیرا شنیدی», a rail of 148 px covers.
  - Leave out: greetings or question headings, mood or genre tiles, «continue listening» with time left (a podcast pattern) and listening-hour stats (an audiobook pattern).
- **اعلان‌ها:** a back header. One muted line explains that new songs from followed channels show here and as phone notifications, and that each channel is muted from its own page. Then the «تازه» and «قبلی» sections. Rows are a cover, one sentence with the channel name in bold, and a time. Unread rows have a coral dot.
- **حساب و تنظیمات:**
  - Account row: avatar, name, sign-in method, and an «ویرایش» pill.
  - Then grouped cards on `surface`:
    - فضای ابری: usage line and a thin violet-to-coral bar,
    - پخش: quality, gapless, loudness,
    - همگام‌سازی: auto-upload, Wi-Fi only, space used on the phone,
    - اعلان‌ها: new songs in channels, new followers,
    - پشتیبانی,
    - a separate card for «خروج از حساب».
  - Admin entries stay for admins.
- **جستجو:**
  - Title, then a 48 px pill field.
  - «داغ در گنجینه» is a rank rail with big thin numerals on the covers, and «همه» opens گنجینه.
  - «فهرست‌های عمومی» is a rail of 148 px playlist cards with follower counts.
  - No genre tiles («سبک‌ها» was rejected).
- **گنجینه:**
  - A back header with one muted line, then chips: «داغ این هفته», «تازه‌ها», «فهرست‌ها».
  - A ranked list: the number, a cover, title and artist, and the play count at the end.
  - Then «فهرست‌های عمومی پرطرفدار».
- **فهرست عمومی (channel):**
  - A 132 px cover beside «فهرست عمومی», the name, its admins and the counts.
  - Then the «دنبال می‌کنی» pill, the bell button (mute this channel) and the coral play button.
  - One muted line with the Telegram icon says posts sync from the Telegram channel.
  - Then the track rows with their dates.
- **پسندیده‌ها:** the title with a small count, then plain rows.
- **در حال پخش:**
  - The cover fills the whole screen, with a dark gradient over the bottom 66%.
  - At the top: close (chevron down) and like.
  - At the bottom: title (30 px, bold) and artist, a 2 px progress line with times, then previous, a white 72 px play/pause and next.
  - Last, three **icon** buttons with no text: lyrics, queue, more. The owner said text on buttons looks bad.
  - Every control sits in the bottom third, in thumb reach.

## Typography

Use Vazirmatn throughout, with the October scale (#437) kept:

- Page titles: 30 px, weight 700.
- Section titles: 18 px, weight 600.
- Rows: 15 px, weight 500 for the title, plus 13 px muted for the artist.
- Labels: 11 to 13 px.

## Logo

This part is not decided yet. The owner wants the word «ریتمو» itself to carry the mark. There are four concepts on the canvas page «لوگو», with a [screenshot](redesign-2026-11/11-logo-from-word.jpg):

- الف, beat dots: the dots of ت and ی become coral and violet beats.
- ب, pulsing kashida: the kashida between ت and م becomes a heartbeat line.
- ج, sound bars: the dots become equaliser bars.
- د, stamp: the whole word on a coral tile.

They are drawn from `assets/fonts/Vazirmatn-Bold.ttf`, with dotless ى and ٮ plus custom dots, shaped with HarfBuzz. Wait for the owner's pick before touching `rhythmo_mark.dart`, `rhythmo_brand.dart` or the app icon.

## Order of work

1. #443 Tokens and backdrop: the navy background and weaker glows.
2. #444 Shell: the bottom bar, the mini player, موسیقی من as the default, and the avatar opening settings.
3. #445 موسیقی من: the sync label, the tabs, and the playlists tab.
4. #446 Now playing.
5. #447 Home and notifications.
6. #448 Search, گنجینه and the public playlist.
7. #449 Settings.
8. #450 Logo and app icon, after the owner picks.

For every step, follow `AGENTS.md`:

- Add tests for any change in behaviour.
- Keep 48 px targets.
- Run `dart format`, `flutter analyze` and `flutter test`.
- Check a narrow screen so the mini player never covers the last row.
- Refresh screenshots with the golden-test recipe in project memory, which loads Vazirmatn and Phosphor with `FontLoader`.
