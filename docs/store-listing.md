# Store listing and release checklist

Materials for publishing rhythmo (ریتمو) on **Google Play** (#94) and **Cafe Bazaar** (#95).
Everything below is based on the code as of this document. Re-check it whenever
permissions, data handling, or the release workflow change.

- Package ID: `ir.mhdolatabadi.nafir`
- Privacy policy URL: `https://<NAFIR_DOMAIN>/privacy` (production: `https://rhythmo.ir/privacy`)
- Account deletion URL: `https://<NAFIR_DOMAIN>/delete-account` (production: `https://rhythmo.ir/delete-account`)
- Both pages show the contact address only when `PRIVACY_CONTACT_EMAIL` is set on the server. **Set it before submitting**, because the deletion page's email route depends on it.

## Listing text (Persian)

**App title** (Play allows 30 characters; Bazaar allows a similar length):

> ریتمو: موسیقی ابری

**Short description** (66 of 80 characters):

> موسیقی‌هایت را با کیفیت اصلی در فضای ابری نگه دار و همه‌جا پخش کن.

**Long description:**

> ریتمو پخش‌کننده‌ی موسیقی شخصی توست: فایل‌هایت را یک بار بارگذاری کن و از گوشی یا مرورگر، هر جا که هستی، گوششان کن.
>
> • **کیفیت اصلی، بی‌کم‌وکاست:** فایل‌ها همان‌طور که هستند نگه داشته و پخش می‌شوند؛ هیچ فشرده‌سازی یا کاهش کیفیتی در کار نیست.
> • **کتابخانه‌ی مرتب:** آهنگ‌ها، آلبوم‌ها و هنرمندان، با جست‌وجو و مرتب‌سازی. نام آهنگ، خواننده و آلبوم را خودت ویرایش کن.
> • **موسیقی‌های گوشی و فضای ابری کنار هم:** موسیقی‌های روی گوشی را هم ببین و پخش کن و هر کدام را خواستی به فضای ابری بفرست.
> • **بارگذاری چندتایی:** چند فایل را با هم بارگذاری کن و پیشرفت هر کدام را جدا ببین.
> • **فهرست‌های پخش:** فهرست پخش بساز، با لینک به اشتراک بگذار، عمومی‌اش کن تا دیگران پیدایش کنند، یا با دوستانت فهرست پخش مشترک بساز.
> • **پخش در پس‌زمینه:** با صفحه‌ی خاموش و از اعلان و صفحه‌ی قفل پخش را کنترل کن. آهنگ‌هایی که گوش داده‌ای در کش می‌مانند تا دفعه‌ی بعد سریع‌تر و بدون اینترنت پخش شوند.
> • **بات بله و تلگرام:** آهنگ را برای بات ریتمو بفرست تا مستقیم به کتابخانه‌ات اضافه شود.
> • **حریم خصوصی:** موسیقی‌هایت خصوصی‌اند مگر خودت به اشتراک بگذاری. تبلیغات و ابزار ردیابی در کار نیست و هر وقت بخواهی حسابت را از داخل اپ کامل حذف می‌کنی.
>
> هر حساب ۱ گیگابایت فضای ابری رایگان دارد. فقط موسیقی‌ای را بارگذاری و به اشتراک بگذار که حق استفاده از آن را داری.

Before publishing, confirm the quota sentence matches the server's `STORAGE_QUOTA_BYTES` (the default is 1 GiB).

## Category

- **Google Play:** Music & Audio.
- **Cafe Bazaar:** the music and audio category (موسیقی و صدا, or whatever Pishkhan currently calls it).
- Tags or keywords: موسیقی، پخش‌کننده، فضای ابری، فهرست پخش، آهنگ

## Permissions (Bazaar asks for an explanation of each)

These are from `android/app/src/main/AndroidManifest.xml`.

| Permission | Why rhythmo needs it (Persian text for Pishkhan) |
|---|---|
| `INTERNET` | برای ورود به حساب، پخش موسیقی از فضای ابری و بارگذاری آهنگ‌ها. |
| `READ_MEDIA_AUDIO` (Android 13+) / `READ_EXTERNAL_STORAGE` (Android 12 and older, `maxSdkVersion=32`) | برای نمایش و پخش موسیقی‌های روی گوشی. این فایل‌ها فقط وقتی به سرور فرستاده می‌شوند که کاربر خودش بارگذاری‌شان کند. فقط به فایل‌های صوتی دسترسی داریم، نه عکس و فیلم. |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | برای ادامه‌ی پخش موسیقی وقتی اپ بسته یا صفحه خاموش است، و نمایش کنترل‌های پخش در اعلان و صفحه‌ی قفل. |
| `WAKE_LOCK` | تا پخش موسیقی با خاموش شدن صفحه قطع نشود. |
| `RECORD_AUDIO` | فقط برای «این آهنگ چیه؟»: وقتی کاربر خودش دکمه را می‌زند، ریتمو ۱۰ ثانیه صدای اطراف را ضبط می‌کند تا آهنگ در حال پخش را میان آهنگ‌های کتابخانه‌ی خودش و فهرست‌های پخش در دسترسش پیدا کند. صدای ضبط‌شده فقط برای همین جستجو به سرور فرستاده و بلافاصله پاک می‌شود؛ هیچ‌جا ذخیره نمی‌شود و در پس‌زمینه هرگز ضبطی انجام نمی‌شود. |

The app asks for the microphone only when the listener taps «گوش بده» on the «این آهنگ چیه؟» screen, after a Persian explanation of what is recorded and that it is deleted. Refusing it only disables song identification. On the web the browser asks the same way through `getUserMedia`.

On **Google Play**, the `FOREGROUND_SERVICE_MEDIA_PLAYBACK` type needs a foreground-service declaration under *App content → Foreground service permissions*. Choose **Media playback**, describe it as "Continues music playback the user started when the app is in the background, with media controls in the notification", and attach a short screen recording: start a track, leave the app, and control playback from the notification.

## Google Play Data safety answers

The answers are based on the API (`server/`), the app (`lib/`), and `pubspec.yaml`. The app has no ads, no analytics, and no crash-reporting SDK.

**Does the app collect or share user data?** Yes, it collects data. It does not share any.

| Data type (Play category) | Collected | Shared | Required? | Purposes | Source in code |
|---|---|---|---|---|---|
| Personal info → **Email address** | Yes | No | Required | Account management, App functionality | `users.email` |
| Personal info → **User IDs** | Yes | No | Required | Account management | the account UUID, plus the Bale/Telegram chat ID when the user links a bot (optional) |
| Audio → **Music files** | Yes | No | Optional (only what the user uploads) | App functionality | the MinIO objects under `users/<id>/` and the track metadata |
| App activity → **Other user-generated content** | Yes | No | Optional | App functionality | playlists, likes, collaborative memberships, and edited track metadata |
| Audio → **Voice or sound recordings** | Yes, processed ephemerally | No | Optional (only when the user taps «گوش بده») | App functionality | the «این آهنگ چیه؟» snippet: about 10 s sent to `POST /api/v1/identify`, held in a private temporary file while it is fingerprinted, then deleted. It is never stored or logged. |

These are **not** collected:
- Location (the client IP is used only in memory for rate limiting and is never stored).
- Contacts, photos and videos, messages, calendar, health, and financial info.
- App interactions and analytics, crash logs, diagnostics, and device or advertising IDs.
- Music already on the device: it is read on the device to play it and leaves only when the user uploads it.
- Microphone audio is never kept. Song identification snippets are processed ephemerally (see the table above), so in Play's form tick *Data is processed ephemerally* for **Voice or sound recordings**.

**Security practices**
- Data is encrypted in transit: yes, everything goes over HTTPS.
- Users can request deletion: yes, in the app (Settings → «حذف حساب کاربری») and on the web at `/delete-account`.
- Data deletion URL: `https://<NAFIR_DOMAIN>/delete-account`.
- Passwords are stored only as bcrypt hashes.

Sending a track to Bale or Telegram happens only at the user's own request, through a chat they linked themselves. Play counts user-initiated transfers as exempt from "sharing".

## Other Play Console declarations

- **Ads:** none.
- **App access:** sign-in is required for the library. A guest can still browse and play popular public playlists. Create a reviewer account with a few tracks and a playlist, and enter its email and password under *App access*.
- **Target audience:** 18 and over is the suggested choice. rhythmo hosts user-uploaded and publicly shared content and is not designed for children, so this keeps it out of the Families policy.
- **Content rating questionnaire:** a music player with user-generated content. Answer yes to "users can share content with each other" (public and shared playlists) and to "users can interact" (collaborative playlists). There is no violence, sexual content, gambling or purchases.
- **News app / COVID / government / financial:** no.

## Screenshot shot-list

Ready-made screenshots, the teaser video, the feature graphic and the 512 px icon are in [`store/listing`](../store/listing). [`store/README.md`](../store/README.md) explains how to regenerate them. The list below is the full shot-list for hand-taken screenshots on a real phone.


Take these on a phone at 1080×1920 or larger, in portrait. Use the release build against production with a reviewer account full of tracks you have the rights to (no commercial album art). Play accepts 2–8 phone screenshots and Bazaar accepts several. Use the same set in the same order for both stores.

1. **Library, Tracks tab:** the dark glass header, a full track list with artist and size, and the mini player playing.
2. **Albums or Artists tab:** the grouped grid or list.
3. **Upload in progress:** several files with per-file progress.
4. **فهرست پخشs tab:** a few playlists, one shared or public.
5. **Shared or collaborative playlist:** the members and the "add to my account" action.
6. **Popular playlists (guest home):** what people see before signing in.
7. **Settings:** cloud storage usage, cache, the bot link, and the account section with «حریم خصوصی» and «حذف حساب کاربری».
8. **Media notification or lock screen controls** while playing in the background.

Also needed:
- The high-resolution icon (512×512), rendered from `web/icons/icon.svg`.
- A feature graphic (Play needs 1024×500; Bazaar's header art needs its own size).

## Release checklist

1. [ ] `PRIVACY_CONTACT_EMAIL` is set in production. `/privacy` and `/delete-account` both load over HTTPS and show it.
2. [ ] Check deletion end to end on production with a throwaway account. Upload a track, delete the account in Settings, then confirm that signing in fails, that the API log shows `account deleted` and `deleted account objects removed`, and that the bucket has no `users/<id>/` prefix left.
3. [ ] The GitHub Actions secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, and `ANDROID_STORE_PASSWORD` hold the **production upload key**. Never commit the keystore or `key.properties`.
4. [ ] Take the APK and AAB **only from the GitHub Release** (`v0.1.<run>`) made by `.github/workflows/android-release.yml`. That workflow runs after *Quality checks* pass on `main` and publishes a Release only when the signing secrets are present. The files are named `nafir-v0.1.<run>-android-production-signed.{apk,aab}`.
5. [ ] **Never upload** `*-test-signed.*` files (built with the debug key when the secrets are missing; uploaded as workflow artifacts but never released) or the debug APK from the *Quality checks* workflow.
6. [ ] Check the signature before uploading: `apksigner verify --print-certs rhythmo-…-production-signed.apk` must show the upload certificate, not `CN=Android Debug`. For the AAB, use `jarsigner -verify -verbose -certs nafir-…-production-signed.aab`.
7. [ ] The version code (`GITHUB_RUN_NUMBER`) is higher than the last one uploaded to that store.
8. [ ] **Google Play:** upload the **AAB**. New personal developer accounts must first run a closed test with at least 12 testers for 14 days. Fill in Data safety, App access, Ads, Target audience, Content rating, and the foreground-service declaration as above.
9. [ ] **Cafe Bazaar:** in Pishkhan, upload the production-signed **APK** (or the AAB, if Pishkhan accepts it for this app). Add the permission explanations, privacy policy URL, listing text, and screenshots above. Automating later uploads is tracked separately in #95.
10. [ ] Install the store build on a real phone. Android's app info should name the store as the installer, playback should continue in the background, and Settings → «حذف حساب کاربری» should open.

Android's "unknown source" warning on a sideloaded APK is an OS prompt and does **not** mean the build is a debug build. Check the signature instead (step 6).

## Automatic Cafe Bazaar publication after deployment

After the server deployment succeeds, Deploy dispatches Android release with
that exact 40-character deployed commit SHA and waits for its result. Failed
server deployments never trigger an Android/Bazaar publication. Waiting keeps
automatic releases serialized by the production deployment concurrency group.
The release workflow keeps its own increasing run number as the Android version
code and tags the checked-out commit in the GitHub Release.

Required repository secrets: `CAFEBAZAAR_API_SECRET`,
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`,
`ANDROID_STORE_PASSWORD`. The keystore must match the app already in Bazaar.
Missing automatic-publication secrets fail explicitly before the build; they
never produce a test-signed store upload. Create the API secret in Pishkhan
for this app; never put it in repository files or logs.

The signed APK is uploaded and submitted for review with `auto_publish=true`:
it becomes available after Bazaar approves it. `CAFEBAZAAR_ROLLOUT_PERCENT`
controls rollout (1–100, default 100). `CAFEBAZAAR_AUTO_PUBLISH` and
`CAFEBAZAAR_PUBLISH_EVERY_RELEASE` variables are no longer used by this workflow.

Manual Android release remains available, with a `ref` and optional
`cafebazaar` submission. Avoid running a separate manual Bazaar submission
while an automatic submission is active, because Pishkhan uses one pending
draft per app. A failed Bazaar submission fails the Deploy workflow after the
server has already deployed; inspect the Android release log to distinguish
those outcomes. Retry the failed Android run to retain the same version code,
or start a new manual release for a new version code. A rollback APK also needs
a new version code; do not re-upload an older published version code.

The script tests exercise automatic publication, refusals, exact SHA dispatch,
publication failure propagation and keeping secrets out of output. They do not
call the real Bazaar API, so verify the first real submission in Pishkhan.
