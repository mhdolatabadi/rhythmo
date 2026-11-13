# rhythmo

Cross-platform personal cloud music player. Music is stored on the user's self-hosted server and streamed to Android and the web with a bounded, disposable device cache.

## Screenshots

| موسیقی من | در حال پخش |
|---|---|
| ![موسیقی من on desktop](docs/screenshots/desktop-my-music.png) | ![Playing on desktop](docs/screenshots/desktop-playing.png) |
| **جست‌وجو** | **خانه** |
| ![Search on desktop](docs/screenshots/desktop-search.png) | ![Home on desktop](docs/screenshots/desktop-home.png) |

Phone screenshots and the teaser are in [`store/listing/`](store/listing/). All of them are rendered from the app with made-up data; see [`store/README.md`](store/README.md) to regenerate them.

## Stack

- Flutter client for Android and Web/PWA
- Go HTTP API
- PostgreSQL for accounts and track metadata
- MinIO for private audio object storage
- Caddy for automatic HTTPS
- Docker Compose for Ubuntu deployment

## Product principles

- Private by default: users can access only their own tracks.
- Stream first: no automatic permanent download to the phone.
- Familiar playback: queue, seek, shuffle, repeat, background playback and media controls.
- Cache is bounded and can be cleared without deleting cloud files.

## Run the API locally

The API needs PostgreSQL, MinIO and a token secret. It applies its database
migrations on startup.

```bash
docker run -d --name rhythmo-db -p 5432:5432 \
  -e POSTGRES_USER=rhythmo -e POSTGRES_PASSWORD=rhythmo -e POSTGRES_DB=rhythmo postgres:16-alpine
docker run -d --name rhythmo-minio -p 9000:9000 minio/minio server /data
cd server
export DATABASE_URL='postgres://rhythmo:rhythmo@localhost:5432/rhythmo?sslmode=disable'
export AUTH_TOKEN_SECRET="$(openssl rand -hex 32)"
export STORAGE_ENDPOINT=localhost:9000 STORAGE_PUBLIC_URL=http://localhost:9000
export STORAGE_BUCKET=nafir-music STORAGE_ACCESS_KEY=minioadmin STORAGE_SECRET_KEY=minioadmin
TEST_DATABASE_URL="$DATABASE_URL" go test ./...
go run ./cmd/api
```

Then open `http://localhost:8080/api/v1/health`. `AUTH_TOKEN_TTL` (default
`720h`) sets how long a login lasts. The store tests drop and recreate tables in
`TEST_DATABASE_URL`, so point it at a disposable database.

| Endpoint | Purpose |
| --- | --- |
| `POST /api/v1/auth/register` | Create an account from `{"email", "password"}` and return a session |
| `POST /api/v1/auth/login` | Return a session for valid credentials |
| `GET /api/v1/me` | Return the user for `Authorization: Bearer <token>` |
| `GET /api/v1/tracks` | List the caller's tracks, newest first |
| `GET /api/v1/tracks/{id}` | One of the caller's tracks; another user's track is `404` |
| `GET /api/v1/tracks/{id}/stream` | A short-lived presigned URL for the caller's track |
| `POST /api/v1/tracks/uploads` | Reserve a track from `{"fileName", "sizeBytes", "title"?, "artist"?, "album"?}` and return a presigned upload form |
| `POST /api/v1/tracks/{id}/complete` | Verify the uploaded file and make the track playable |
| `DELETE /api/v1/tracks/{id}` | Delete one of the caller's tracks and its file |

Passwords must be 8–72 characters and are stored only as bcrypt hashes.
Uploads accept MP3, M4A, AAC, FLAC, OGG, OPUS, WAV and WEBM up to
`MAX_UPLOAD_BYTES` (default 200 MiB).

## Run the Flutter app

Start the Go API, then run Flutter with its public base URL:

```bash
flutter pub get
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080
```

`10.0.2.2` points to the host machine from the Android emulator. For a real
device or production build, use the HTTPS domain served by Caddy:

```bash
flutter run --dart-define=API_BASE_URL=https://music.example.com
```

The app checks `/api/v1/health` on startup and offers a retry action when the
server is unavailable. It then restores the saved session, or asks the user to
sign in or register. The access token is kept in Android Keystore or encrypted
browser storage on the web.

Every push to `main` also builds a debug Android APK. Download the
`rhythmo-android-debug` artifact from the corresponding **Quality checks** run in
GitHub Actions. The Android application ID is `ir.mhdolatabadi.nafir`, and the
artifact is retained for 14 days. The APK talks to `https://rhythmo.ir`;
set the repository variable `NAFIR_API_BASE_URL` to point it elsewhere.

The rhythmo icon combines a waveform and a play mark on a dark background.
The single vector geometry in `tool/generate_icons.py` generates the web SVG,
192/512 px PWA PNGs, all five Android launcher sizes, the monochrome notification
icon and the 288 px loading/artwork image. The mark fits the maskable safe circle.
Existing asset filenames remain stable for compatibility.

```bash
python3 -m pip install -r tool/icon-requirements.txt
python3 tool/generate_icons.py
```

The Android project lives in `android/`. Build it locally with:

```bash
flutter build apk --debug --dart-define=API_BASE_URL=https://rhythmo.ir
```

## Publish an Android release

The `Android release` workflow publishes a signed APK when a semantic version
tag such as `v0.2.0` is pushed. Configure these GitHub Actions secrets first:

- `ANDROID_KEYSTORE_BASE64`: base64-encoded production JKS file
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`
- `ANDROID_STORE_PASSWORD`

For example, encode a keystore on macOS with
`base64 -i release.jks | pbcopy`, then add the copied value as the first
secret. Keep the keystore and passwords backed up: future updates must be
signed with the same key. The workflow derives the app version from the tag,
builds `ir.mhdolatabadi.nafir`, generates release notes and attaches
`rhythmo-vX.Y.Z-android.apk` to the GitHub Release.

## Deploy


See [deploy/README.md](deploy/README.md). Do not commit deployment secrets or `.env`.

## Account administration

Set `ADMIN_EMAILS` in the server environment (or `deploy/.env`) to a comma-separated list of existing account emails. Restart/redeploy the API, then sign in again to refresh the account menu. Leave it empty to disable admin access. Register the intended accounts before configuring the allowlist.

Admins can search the account directory, confirm account verification and revoke it. Every API request resolves the current account from the database and checks the server-managed allowlist. Verification is independent of admin privileges and does not verify email ownership. Real verification changes and the acting admin are recorded atomically in `account_verification_audit`.

Migration 013 adds verification columns and the audit table. Removing an email from the allowlist revokes administrative API access immediately after the API reloads; no token rotation is needed. To roll back the feature, deploy the previous API/client and clear `ADMIN_EMAILS`; leave the additive database migration in place.
