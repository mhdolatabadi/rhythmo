# AGENTS.md

This file defines the standing rules for every contributor and coding agent working on rhythmo.

## Product identity and scope

- The product name is **rhythmo** (ریتمو). Do not introduce the old name `sot` in code, copy, package names, artifacts, infrastructure, or documentation.
- The supported clients are **Web and Android**. Do not add, restore, build, test, or maintain iOS-specific code or workflows unless the owner explicitly changes this rule.
- Code, packages, docs, artifacts and user-facing copy use **rhythmo**; do not introduce `nafir` in new code or copy.
- Remaining `nafir` names are compatibility identifiers only and stay until a dedicated migration: the Android application ID and namespace `ir.mhdolatabadi.nafir` (changing it would orphan installs), platform channel names, on-device storage keys, the `nafir-music` bucket, database names, `NAFIR_*` server variables and the `NafirBot` account.
- Keep Web and Android behavior consistent where platform capabilities allow it.
- User-facing copy is Persian and the primary layout direction is RTL.

## Issue-first delivery

- Every independently deliverable change starts with a GitHub issue before implementation.
- Break broad requests into focused issues with a clear outcome and acceptance criteria.
- Use a dedicated branch and pull request for each issue. Reference and close the issue from the pull request.
- Do not mix unrelated cleanup or features into the same pull request.
- Keep the issue and pull request updated when scope, risks, or rollout requirements change.

## UI and UX

- rhythmo uses a polished, dark, glass-like visual language. Glass effects must preserve contrast, legibility, and performance.
- Mobile layouts need generous breathing room, safe-area awareness, and touch targets of at least 48 logical pixels.
- Floating controls, the mini player, browser chrome, and system insets must never cover the last list item or a primary action.
- Track rows show the artist as their only secondary detail; file size belongs in track details, not in list rows.
- Long Persian, Arabic, and Latin titles must truncate gracefully without overflow.
- Desktop content must use a centered maximum width and must not stick to the viewport edges.
- Preserve accessibility semantics, visible focus, useful tooltips, and adequate contrast.
- Before making substantial UI changes, inspect and follow the relevant guidance stored under `.skills/`.

## Music and file behavior

- Preserve uploaded audio quality. Do not transcode or reduce bitrate unless a requirement explicitly asks for it.
- Multi-file upload must report per-file progress and failure without losing successful uploads.
- Android must discover supported local audio files and keep local and cloud sources understandable.
- Track title, artist, album, filename, and embedded metadata must stay consistent when edited or downloaded.
- Downloaded files must use the user-edited filename safely.
- Shuffle, queue, deletion, playlists, and playback changes must behave consistently in the main library and playlist views.

## Backend, storage, and abuse protection

- Treat the per-user storage quota as a server-enforced invariant; the current product limit is 1 GiB unless configuration says otherwise.
- Enforce upload size, quota, rate, and concurrent-upload limits on the server. Client checks are only supplementary.
- Clean up failed, cancelled, expired, and incomplete object uploads.
- Deleting tracks or users must keep PostgreSQL records and MinIO objects consistent and auditable.
- Stream original media efficiently and support byte ranges. Avoid response encoding or buffering that damages playback quality.
- Never log credentials, tokens, signing material, private media URLs, or sensitive user data.

## Testing and quality gates

- Add or update tests for every behavior change and regression fix.
- At minimum, run formatting, static analysis, unit/widget tests, the web release build, and the Android build checks relevant to the change.
- Mobile UI changes must include a narrow-screen regression check and must verify that controls do not obscure content.
- API and storage changes require tests for authorization, ownership, quota boundaries, cleanup, and failure recovery.
- Do not merge while required CI checks are failing.

## Deployment and releases

- Production deployment happens through the repository workflow after CI succeeds; avoid undocumented manual server mutations.
- Keep secrets in GitHub Actions secrets or the server environment. Never commit them.
- Validate Docker Compose and Caddy changes before deployment and preserve the external `proxynet` network contract.
- Android releases must be signed **release** builds, never debug/test APKs.
- The Android release workflow must publish installable APK and store-ready AAB artifacts with an unambiguous version.
- Sideloaded APKs may still trigger Android's unknown-source confirmation; do not confuse that OS warning with a debug build.
- Cafe Bazaar and other stores are separate distribution targets and require an explicit issue and rollout plan.

## Safe collaboration

- Preserve unrelated user changes and the current repository state.
- Prefer small, reversible changes and migrations.
- Diagnose production incidents with read-only checks first.
- Confirm exact destructive targets before deleting database rows, MinIO prefixes, Docker data, or user content.
- Document operational commands and rollback notes in the relevant issue or pull request.
