# rhythmo server deployment

## One-time setup

1. Point an A/AAAA DNS record for your chosen subdomain (for example, `music.example.com`) to the Ubuntu server.
2. Open inbound TCP ports 80 and 443 in the server firewall/provider firewall.
3. Clone this repository on the server.
4. Copy the environment template and replace every placeholder with a long random value:

   ```bash
   cd deploy
   cp .env.example .env
   chmod 600 .env
   ```

5. Start the stack:

   ```bash
   docker compose up -d --build
   ```

Caddy automatically obtains and renews the TLS certificate after DNS resolves to the server. Verify with:

```bash
curl https://music.example.com/api/v1/health
```

Expected response: `{"status":"ok"}`.

Caddy splits the domain between three services:

| Path | Served by |
|---|---|
| `/`, `/p/{token}`, `/privacy`, `/delete-account`, `/sitemap.xml`, `/robots.txt` | the API's public pages: popular public playlists, store/legal pages, readable by anyone and by search engines |
| `/app/` | the Flutter web app (also installable as a PWA); it calls the API on its own origin |
| `/api/*` | the Go API |

`/app` redirects to `/app/`, and share links from before the move
(`/?shared=…`) redirect to `/app/?shared=…`. Both the API and the public pages
receive the visitor's IP in `X-Nafir-Client-IP` for rate limiting.

The Compose project is named `nafir` (set in `compose.yaml`), so its
containers and networks don't collide with other projects on the server. Its
volumes keep the names they got under the old default project name
(`deploy_postgres-data`, `deploy_minio-data`, `deploy_caddy-data`,
`deploy_caddy-config`), and `deploy.sh` replaces this checkout's old
`deploy-*` containers once on the first deploy after the rename.

Audio objects under `/nafir-music/*` deliberately bypass Caddy response
compression and are served with `Cache-Control: private, no-transform`. This
keeps byte ranges and cached media identical to the object stored in MinIO.

## Images

The **Images** workflow builds the `api` and `web` images on every push to `main`
and publishes them to GitHub Container Registry as
`ghcr.io/mhdolatabadi/nafir/{api,web}`, tagged with the commit SHA and `latest`.
The server only pulls them, so it never needs the multi-gigabyte Flutter SDK.

If `docker compose pull` returns `unauthorized`, open each package under the
repository's **Packages** and set its visibility to public, or run
`docker login ghcr.io` on the server with a token that has `read:packages`.

To build locally instead, run `docker compose up -d --build`.

## Updates

On the server, `deploy/deploy.sh` pulls `main`, pulls the images built for that
exact commit, restarts the stack and waits for the health check. Run it after
the **Images** workflow for that commit has finished; otherwise the pull fails
and nothing is restarted.

To deploy from GitHub instead, open **Actions → Deploy → Run workflow**. It needs these secrets in the `production` environment:

| Secret | Value |
| --- | --- |
| `DEPLOY_HOST` | Server IP or hostname |
| `DEPLOY_USER` | SSH user that can run `docker` |
| `DEPLOY_PATH` | Absolute path of the repository clone, for example `/opt/nafir` |
| `DEPLOY_SSH_KEY` | Private key of a dedicated deploy key pair; add the public key to the user's `~/.ssh/authorized_keys` |
| `DEPLOY_KNOWN_HOSTS` | Output of `ssh-keyscan <host>`, verified against the server's fingerprint |

## Adding authentication to an existing server

The API now refuses to start without `AUTH_TOKEN_SECRET`. Add it to `deploy/.env` before deploying:

```bash
echo "AUTH_TOKEN_SECRET=$(openssl rand -hex 32)" >> deploy/.env
```

Changing it later signs every user out.

## Upgrading from SOT

The infrastructure identifiers (database, role, containers) were renamed from SOT to `nafir`, which they still use; the display brand is rhythmo. On a server deployed before that rename:

1. In `deploy/.env`, rename `SOT_DOMAIN` to `NAFIR_DOMAIN` and add `NAFIR_IMAGE_REPO` from `.env.example`.
2. PostgreSQL only reads `POSTGRES_DB` and `POSTGRES_USER` when its volume is first created, so the
   existing `sot` database and role stay as they are. Pick one:
   - The volume holds no data yet: `docker compose down && docker volume rm deploy_postgres-data`,
     then deploy again and a fresh `nafir` database is created.
   - Keep the data: add a `nafir` superuser and rename the database. The old `sot` role created the
     cluster, so PostgreSQL keeps it; it simply stops being used.

     ```bash
     docker compose exec postgres psql -U sot -d postgres \
       -c "CREATE ROLE nafir WITH SUPERUSER LOGIN PASSWORD '<POSTGRES_PASSWORD from .env>';"
     docker compose exec postgres psql -U nafir -d postgres \
       -c 'ALTER DATABASE sot RENAME TO nafir;' \
       -c 'ALTER DATABASE nafir OWNER TO nafir;'
     ```

## Behind a shared nginx (proxynet)

On a server where a shared nginx already owns ports 80 and 443, rhythmo runs
without its Caddy container and that nginx reaches the stack over the
external `proxynet` network. It must route exactly like `deploy/Caddyfile`:

| Path | Goes to |
| --- | --- |
| `/api/` | `rhythmo-api:8080` |
| `/nafir-music` | `nafir-minio:9000`, byte-for-byte: no gzip, no buffering, `Host` unchanged |
| `/app/` | `nafir-web:80` (the Flutter app) |
| `/?shared=…` | redirect to `/app/?shared=…` |
| `/privacy`, `/delete-account` | `rhythmo-api:8080` explicitly, never the Flutter app |
| everything else: `/`, `/p/…`, `sitemap.xml`, `robots.txt` | `rhythmo-api:8080`, with `X-Nafir-Client-IP` |

`deploy/front-proxy.nginx.conf` has these routes ready. Copy it next to the
nginx config and include it inside the rhythmo `server { }` block:

```sh
sudo cp deploy/front-proxy.nginx.conf /etc/nginx/snippets/nafir.conf   # or the nginx container's config folder
# in the rhythmo server block:  include /etc/nginx/snippets/nafir.conf;
sudo nginx -t && sudo nginx -s reload                                  # or: docker exec <nginx> nginx -t / nginx -s reload
curl -sI https://$NAFIR_DOMAIN/ | head -3                              # 200 from the API, not nginx's page
```

If `/` shows «Welcome to nginx», the front nginx still sends `/` to the web
container from before the app moved to `/app/` (#137); since #153 the web
container answers such requests with a redirect to `/app/`, but the public
pages only appear once `/` goes to the API. Roll back by restoring the
previous nginx file and reloading.

## Moving to a new domain

Production moved from `nafir.mhdolatabadi.ir` to `rhythmo.ir` (#180). For a
move like that:

1. Set `NAFIR_DOMAIN=rhythmo.ir` in `deploy/.env` and deploy. Presigned audio
   links, the web origin and the bot webhooks follow it; the bots register
   their new webhook on start.
2. Give the new domain the routes in `deploy/front-proxy.nginx.conf`.
3. Keep the old domain's certificate and add `deploy/legacy-domain.nginx.conf`
   to its server block: the API keeps answering there for apps built with the
   old address, and every page redirects permanently to the new domain.
4. Release a new Android build. Release builds take the API address from the
   `NAFIR_API_BASE_URL` repository variable, or `https://rhythmo.ir` when it
   is not set.
5. Retire the old domain only once installed apps have updated.

## Search engines

The public pages (`/`, `/p/{token}`, `/store/…`, `/privacy`, `/delete-account`) are server-rendered for crawlers. Every canonical, Open Graph and sitemap URL uses `WEB_ORIGIN` (`https://${NAFIR_DOMAIN}`), so the site is indexed under one host only.

- `https://<domain>/robots.txt` points crawlers at `sitemap.xml`. It keeps them out of `/app/` and `/api/`.
- **Google Search Console:** add the domain as a URL-prefix property and choose the *HTML tag* method. Put only the `content` value in `GOOGLE_SITE_VERIFICATION`.
- **Bing Webmaster Tools:** do the same with `BING_SITE_VERIFICATION`.
- After `docker compose up -d`, verify the site in each console, then submit `https://<domain>/sitemap.xml`. It is a sitemap index: `/sitemaps/pages.xml`, `/sitemaps/playlists.xml`, and paged `/sitemaps/songs-N.xml`, `artists-N.xml` and `albums-N.xml` files of up to 5,000 URLs each.
- **IndexNow (optional):** set `INDEXNOW_KEY` to a random string such as `openssl rand -hex 16`. The API serves it at `/<key>.txt` and, every 15 minutes, announces public pages that appeared or went away since the last check. The first check after a restart only records the pages. It needs `WEB_ORIGIN`; with either unset, nothing is sent.
- Unknown paths answer with a 404 page that is never indexed.

## Email verification

New accounts confirm their address with a 6-digit code before they can
upload, import from links, list a playlist publicly, save a shared playlist
or use the bots. They can still sign in and listen meanwhile.

Set these in `.env` to turn it on:

| Variable | Meaning |
| --- | --- |
| `SMTP_HOST`, `SMTP_PORT` | The relay. Port 465 uses TLS from the start; other ports (587 by default) must offer STARTTLS before the password is sent. |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | The relay login; leave both empty for a relay that needs none. |
| `MAIL_FROM` | The sender, for example `ریتمو <no-reply@music.example.com>`. |

- With `SMTP_HOST` empty, verification is off. The API logs a warning at start-up and every account counts as verified, so local and development setups need no mail server.
- Accounts that existed before migration `016_email_verification.sql` count as verified. Accounts created while verification was off are asked to verify once it is turned on.
- A code is stored only as a keyed hash, lasts 15 minutes and allows 5 wrong attempts. Codes are never logged.
- Sending is limited per account and per IP (`EMAIL_CODE_USER_RATE_*`, `EMAIL_CODE_IP_RATE_*`: 5 and 30 per hour), and so are code checks (`EMAIL_VERIFY_USER_RATE_*`, `EMAIL_VERIFY_IP_RATE_*`: 20 and 100 per 15 minutes).
- An unverified user can correct a mistyped address from the app; a new code goes to the new address.
- The admin's manual verification badge (#172) is separate and unchanged. An address in `ADMIN_EMAILS` gets admin access only once it is verified.
- If the relay fails, sign-up still succeeds and the API logs `verification email not sent`; the user can ask for another code. To turn verification off again, empty `SMTP_HOST` and restart the API.

## Storage, quotas and abuse controls

Every way music gets in (app uploads, bot imports and link imports) goes
through one reservation that holds a per-account lock, so concurrent
requests can't get past these limits:

| Limit | Variable | Default |
| --- | --- | --- |
| File size | `MAX_UPLOAD_BYTES` | 200 MiB |
| Storage per account (ready + pending) | `STORAGE_QUOTA_BYTES` | 1 GiB |
| Unfinished uploads per account | `MAX_PENDING_UPLOADS` | 3 |
| Upload reservations per account / per IP | `UPLOAD_RESERVATION_USER_RATE_*` / `UPLOAD_RESERVATION_IP_RATE_*` | 120 / 240 per 10 min |
| Registrations / logins per IP | `REGISTER_RATE_*` / `LOGIN_RATE_*` | 5 per hour / 30 per 15 min |
| Login attempts per email, from any IP | `LOGIN_ACCOUNT_RATE_*` | 10 per 15 min |
| Link imports per account | `LINK_IMPORT_USER_RATE_*` | 20 per 10 min |
| YouTube/Instagram video length | `YTDLP_MAX_DURATION` | 30m |
| yt-dlp processes at once (server-wide) | `YTDLP_MAX_CONCURRENT` | 2 |

Refused requests get `413 quota_exceeded`, `429 rate_limited` (with
`Retry-After`) or `429 too_many_pending_uploads`. Uploads that are never
finished expire after `PENDING_UPLOAD_TTL` (2h), and a cleaner removes their
rows and objects every `PENDING_CLEANUP_INTERVAL` (10m).

Per-IP limits count an IPv6 client by its /64, since one host usually holds a
whole /64. Registration also refuses the most common passwords and the
account's own email (`400 weak_password`).

### The API's own MinIO user

The API should not hold the MinIO root credentials (#217). Give it a user
that can only read, write, list and delete objects in `nafir-music`:

```bash
cd deploy
# In .env: STORAGE_ACCESS_KEY=rhythmo-api and STORAGE_SECRET_KEY=$(openssl rand -hex 32)
./minio-api-user.sh          # creates the user and the rhythmo-api policy, idempotent
docker compose up -d api     # the API switches to the new user
docker compose logs --tail=20 api   # no "storage" errors
```

The policy is `deploy/minio-api-policy.json`. Until `STORAGE_ACCESS_KEY` is
set, the API keeps using the root account, so nothing breaks before the
user exists. Rollback: empty both variables in `.env` and run
`docker compose up -d api`.

At start the API refuses to run if the bucket has an anonymous policy,
because audio must only ever be reachable through presigned links. Remove
such a policy with `mc anonymous set none <alias>/nafir-music`.

### MinIO image

`MINIO_IMAGE` (default `minio/minio:latest`) chooses the MinIO image. Pin it
to what the server already runs, so a moving tag never changes the storage
engine under the data:

```bash
docker inspect --format '{{index .RepoDigests 0}}' "$(docker compose images -q minio)"
# put the result in .env, e.g. MINIO_IMAGE=minio/minio@sha256:…
```

`minio/minio` may no longer be pullable from Docker Hub (it could not be
pulled while #217 was written). Keep the pinned image in the server's cache
(do not `docker image prune -a`) until a maintained source is chosen, and
test any new image against a copy of the data first.

### YouTube, Instagram and Spotify links

Link imports also accept a YouTube video or Shorts link and an Instagram reel
or post link. The API runs `yt-dlp` with fixed arguments (never through a
shell) on a link rebuilt from the video ID, keeps the best audio-only stream
as is, or copies the audio out of the video with ffmpeg without re-encoding.
Size, duration, quota and rate limits apply as for any other import, and the
download's temporary directory is removed whether it succeeds or fails.

- `yt-dlp` is pinned by version and hash in `server/ytdlp-requirements.txt`
  and installed with Python, ffmpeg and Node.js (for YouTube's JavaScript
  challenges) into the API image.
- **Updating yt-dlp:** when YouTube or Instagram imports start failing with
  `unreachable`, bump `yt-dlp` (and the `yt-dlp-ejs` version its `default`
  extra names) in that file with the wheels' sha256 from PyPI, open a PR, and
  after CI and the deploy, smoke-test one YouTube and one Instagram link:
  `docker compose exec api yt-dlp --version`.
- `YTDLP_PROXY_URL` (optional, `http://`, `https://`, `socks5://` or
  `socks5h://`) sends yt-dlp's traffic through a proxy for servers that
  can't reach the sites. It may hold credentials: keep it in `.env` only.
- No cookies are used, and none may be committed. Set `YTDLP_ENABLED=false`
  to turn these imports off.

A Spotify track, album or playlist link is never downloaded. The API reads
the public embed page (through the same public-address checks as other
link fetches), finds each title in the user's library, and makes a playlist
of the matches; the app lists the titles it didn't find.

### Watching disk space

MinIO and Postgres share the server's disk. Check it after deploys and when
usage grows:

```sh
df -h /var/lib/docker
docker system df -v | grep -E 'deploy_(minio|postgres)-data'
```

- **Above 70% full:** look at who is growing (`SELECT owner_id, sum(size_bytes) FROM tracks GROUP BY 1 ORDER BY 2 DESC LIMIT 10;`) and plan more disk or a lower quota.
- **Above 85% full:** stop new uploads (below) until there is room.
- **Above 95% full:** Postgres and MinIO may fail writes; act immediately.

### Emergency: stop new music coming in

Set `UPLOADS_ENABLED=false` in `deploy/.env` and run `./deploy.sh`. App
uploads, bot imports and link imports are then refused with
`503 uploads_disabled`, while existing tracks keep playing and nothing is
deleted. To slow down signups instead, lower `REGISTER_RATE_REQUESTS`.
Undo by setting it back to `true` and deploying again.

## Bale and Telegram bots

People can send audio to rhythmo's Bale or Telegram bot and it lands in their
library. To link a chat to their account, they open **Settings → اتصال به بات**
in the rhythmo app (web or Android), get a one-time 8-digit code, and send it to
the bot. Proving who they are happens in the app they are already signed in to,
so the bots need no email and never ask for a password.

Each bot is optional and stays off while its token is empty.

1. Create the bot with **@BotFather** in Bale and/or Telegram. Copy its token
   and username.
2. In `deploy/.env`, set:
   - `BOT_WEBHOOK_SECRET` to `openssl rand -hex 32`. It is part of each
     webhook URL, so only the messenger knows where to post updates; Telegram
     also sends it back in a header, which the API checks.
   - `BALE_BOT_TOKEN` and `BALE_BOT_USERNAME` for Bale.
   - `TELEGRAM_BOT_TOKEN` and `TELEGRAM_BOT_USERNAME` for Telegram.
   - The usernames let the app name each bot and offer a link that opens it
     with the code filled in.
3. **Telegram from a server in Iran:** `api.telegram.org` is filtered there, so
   set `TELEGRAM_PROXY_URL` to a proxy outside Iran (`socks5://…` or
   `http://…`). Telegram must also be able to reach
   `https://<NAFIR_DOMAIN>` to deliver updates. Bale has a matching
   `BALE_PROXY_URL`, which it normally does not need.
4. Deploy. On start the API registers
   `https://<NAFIR_DOMAIN>/api/v1/bots/<bale|telegram>/webhook/<secret>` with
   each messenger, and logs `bot webhook registered provider=<name>`. If a
   messenger is unreachable it keeps retrying and logs each failure.

Link codes last ten minutes and work once. A chat that sends five wrong codes
in an hour is locked out for the rest of that hour, and each account can
request ten codes an hour (`BOT_LINK_RATE_REQUESTS`, `BOT_LINK_RATE_WINDOW`).
One code links a chat in whichever bot it is sent to.

Bot imports follow the same rules as uploads from the app: the file size
limit, the storage quota, the pending-upload limit and `UPLOADS_ENABLED`.
Both Bot APIs serve bots files up to 20 MB by default
(`BALE_MAX_DOWNLOAD_BYTES`, `TELEGRAM_MAX_DOWNLOAD_BYTES`); larger files get a
message explaining the limit.

Once a chat is linked, each track's menu in the app offers «ارسال به بله» or
«ارسال به تلگرام»: the bot posts that audio into the chat, where it can be
played or forwarded. Bots upload files up to 50 MB by default
(`BALE_MAX_UPLOAD_BYTES`, `TELEGRAM_MAX_UPLOAD_BYTES`), each account can send
thirty tracks an hour (`BOT_SEND_RATE_REQUESTS`, `BOT_SEND_RATE_WINDOW`), and
a track sent once is sent again instantly without another upload.

To turn a bot off, clear its token and deploy. A chat can be unlinked from
the bot with `/logout`.

## Operating the bots

### Secrets
Bot tokens, `BOT_WEBHOOK_SECRET` and `OPS_TOKEN` live only in `deploy/.env` on
the server. The GitHub deploy workflow never sees them: it runs `deploy.sh`
over SSH, and the API reads them at start. They are not baked into images,
and the API never logs them. Errors are stripped of bot tokens, and the
webhook secret is never printed.

### Health
- `deploy.sh` checks the bots after every deploy when `OPS_TOKEN` is set. It
  prints the report and warns if a bot needs attention. The site is up either
  way, so a warning does not fail the deploy.
- Any time:

  ```bash
  curl -s -H "Authorization: Bearer $OPS_TOKEN" https://<NAFIR_DOMAIN>/api/v1/ops/bots
  ```

  For each bot this shows:
  - whether its webhook is registered at the right URL
  - how many updates the messenger is still holding, and its last delivery
    error
  - the import queue (queued, downloading, done and failed in the last hour,
    oldest waiting)
  - counters since the API started: updates, duplicates, links, imports and
    sends, and their failures

  `problems` lists anything that needs attention, and `healthy` is false when
  any bot has a problem.
- Every five minutes the API logs a `bot health` line per bot, at warning
  level when there is a problem:

  ```bash
  docker compose logs api | grep "bot health"
  ```

  Warnings mean one of these:
  - the messenger's API is unreachable
  - the webhook is not registered, or points elsewhere
  - more than 100 updates are waiting
  - a delivery error in the last 15 minutes
  - an import waiting over 15 minutes
  - more than 10 failed imports in an hour

### Smoke test after changing bot settings
1. The deploy output shows `Bot health: {"healthy":true,...}`.
2. In the app: **Settings → اتصال به بات → دریافت کد اتصال**. Send the code to
   the bot; it replies that the chat is linked.
3. Send an mp3 to the bot. It replies «… به کتابخانهٔ ریتمو اضافه شد.», and the
   track appears in the app with «از بله» or «از تلگرام».
4. From the track's menu choose «ارسال به …»; the audio arrives in the chat.
5. `/logout` in the bot, then send another file: the bot asks to link again.

### Rotating a bot token
1. In @BotFather, revoke the token and copy the new one.
2. Replace `BALE_BOT_TOKEN` or `TELEGRAM_BOT_TOKEN` in `deploy/.env` and run
   `deploy/deploy.sh`. On start, the API registers the webhook again with the
   new token.

Linked chats, imports and sent-file IDs all survive the rotation.

### Rotating the webhook secret
Set a new `BOT_WEBHOOK_SECRET` (`openssl rand -hex 32`) and deploy. Each bot's
webhook is re-registered with the new URL (and, for Telegram, the new header
secret). Updates still addressed to the old URL get 404, and the messenger
retries them at the new one.

### When a messenger or the network is down
- **Updates:** Telegram and Bale keep undelivered updates and retry them.
  rhythmo ignores updates it has already handled, so retries are safe. When all
  16 update workers are busy, the webhook answers 503 so the messenger retries
  later.
- **Imports:** a failed download is retried three times with growing delays.
  Imports interrupted by a restart resume when the API starts, and a failed
  import removes its half-stored track and object.
- **Webhook registration:** if the messenger is unreachable at start, the API
  keeps retrying with growing delays up to five minutes.
- **Telegram from Iran:** if Telegram becomes unreachable, check
  `TELEGRAM_PROXY_URL` first.

### Turning a bot off or rolling back
- **Turn a bot off:** clear its token and deploy. Its webhook stays registered
  with the messenger, which then gets 404s. To stop that too:

  ```bash
  curl -s "https://tapi.bale.ai/bot<token>/deleteWebhook"      # Bale
  curl -s "https://api.telegram.org/bot<token>/deleteWebhook"  # Telegram
  ```
- **Roll back:** run `deploy/deploy.sh <previous-commit>`. Bot tables only gain
  columns and tables, so an older API keeps working with them.

## Security rules

- Never commit `.env`.
- Keep MinIO and PostgreSQL on the internal Docker network; do not expose their ports.
- Back up the named Docker volumes before upgrades.
- The API will create private music objects and issue short-lived playback links in the next feature.

## Self-hosted audio transcription

LRCLIB finds existing lyrics; it does not transcribe recordings. Owners can separately
request «استخراج متن از صدا» for their uploaded tracks. This uses a private
faster-whisper container on the same server, defaults to Persian, and stores timed
and plain text in PostgreSQL. Machine transcripts may contain mistakes, especially
with chanting, backing music and crowds. Original audio is never rewritten.
Generated text is currently available to the owner, not shared playlist visitors.

Provision and measure resources before enabling: the default CPU/int8 `small` model
container is limited to 2 CPUs and 4 GiB RAM. Quality and processing time must be
verified against real Persian recitations; these limits are not performance guarantees.
For mostly Arabic recordings set `TRANSCRIPTION_LANGUAGE=auto` or `ar`. A larger
model may need increased memory in `compose.yaml`.

Set a random `TRANSCRIPTION_TOKEN` of at least 32 characters in `deploy/.env`, then
`TRANSCRIPTION_ENABLED=true`. The normal deployment script enables the optional
Compose profile, pulls the immutable transcriber image and starts it. No port is
published; the API streams original audio directly over the internal container
network using the token. The initial model download needs outbound access; subsequent
loads reuse `transcription-models`. Recordings are never sent to a third party.

One job runs at a time, with at most two active jobs per owner. Limits are 200 MiB
and 2 hours of decoded audio. Status persists through app closure. Temporary audio
is deleted after each inference; transcripts are deleted with their track/account.
Failed jobs can be retried. After a worker crash its lease is recovered after
2 hours; stale workers cannot overwrite a newer result. Jobs time out after
110 minutes. Disabling the feature leaves stored results in the database, and
reenabling recovers the queue. To roll back, set `TRANSCRIPTION_ENABLED=false` and
run the normal deployment workflow; do not delete the model volume or user data.
