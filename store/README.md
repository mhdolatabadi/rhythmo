# Store listing assets

Ready-to-upload graphics for Cafe Bazaar (and Google Play), made from the real app (#204).

| File | Size | Use |
|---|---|---|
| `listing/screenshot-1.png` … `screenshot-7.png` | 1080×1920 | Phone screenshots, in this order |
| `listing/rhythmo-teaser-1920x1080.mp4` | 1920×1080, 24 s, H.264 + AAC | Teaser video |
| `listing/feature-graphic-1024x500.png` | 1024×500 | Header / feature graphic |
| `listing/icon-512.png` | 512×512 | High-resolution icon |

The screenshots show the release web build, which looks the same as the Android app. The data in them is made up: no real artists, songs or album art appear, and the teaser's background audio is generated, so nothing needs a licence.

## Regenerating

Do this after UI changes. You need Flutter, node with Playwright, Chromium and an ffmpeg with libx264 on `PATH`. No server, database or real account is involved: the app runs against the test fakes with a seeded, made-up library.

1. Render the raw app screens (a 412×915 phone at 2.625×, into `tools/raw/`) and the README's desktop shots (1440×900, into `docs/screenshots/`):

   ```sh
   flutter test test/screenshots/app_screenshots_test.dart --dart-define=SCREENSHOTS=true
   ```

   `--dart-define=SIZE=phone` or `SIZE=desktop` renders only one set. The demo library and the screens to reach live in that test file.
2. Frame the screenshots and draw the graphics: `node store/tools/frames.js && node store/tools/misc.js`.
3. Render and encode the teaser (about 24 s): `store/tools/encode.sh`.

Headlines and captions live in `tools/frames.js` (screenshots) and `tools/teaser.html` (video).
