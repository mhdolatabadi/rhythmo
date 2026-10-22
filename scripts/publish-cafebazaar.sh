#!/usr/bin/env bash
# Uploads a signed release APK to Cafe Bazaar through the Pishkhan API and
# submits it for review (#95). The flow follows the Pishkhan release API:
# reuse or create an uncommitted release, upload the package, commit it.
#
#   CAFEBAZAAR_API_SECRET=… scripts/publish-cafebazaar.sh rhythmo.apk 0.1.42
#
# Optional: CAFEBAZAAR_AUTO_PUBLISH (true|false, default false: publish by
# hand in the panel after review), CAFEBAZAAR_ROLLOUT_PERCENT (default 100),
# CAFEBAZAAR_API_URL (for tests).
set -euo pipefail

apk="${1:?usage: publish-cafebazaar.sh <release.apk> <version>}"
version="${2:?usage: publish-cafebazaar.sh <release.apk> <version>}"
: "${CAFEBAZAAR_API_SECRET:?set CAFEBAZAAR_API_SECRET}"
api="${CAFEBAZAAR_API_URL:-https://api.pishkhan.cafebazaar.ir/v1}"
auto_publish="${CAFEBAZAAR_AUTO_PUBLISH:-false}"
rollout="${CAFEBAZAAR_ROLLOUT_PERCENT:-100}"

[[ -f "$apk" ]] || { echo "No such package: $apk" >&2; exit 1; }
[[ "$auto_publish" == true || "$auto_publish" == false ]] || { echo "CAFEBAZAAR_AUTO_PUBLISH must be true or false" >&2; exit 1; }
[[ "$rollout" =~ ^[0-9]+$ ]] && (( rollout >= 1 && rollout <= 100 )) || { echo "CAFEBAZAAR_ROLLOUT_PERCENT must be 1-100" >&2; exit 1; }

# The secret goes in a header file, so it never shows in a process list or log.
headers="$(mktemp)"
trap 'rm -f "$headers"' EXIT
printf 'CAFEBAZAAR-PISHKHAN-API-SECRET: %s\nAccept: application/json\n' "$CAFEBAZAAR_API_SECRET" > "$headers"

# call METHOD PATH [curl args…] prints the JSON body; any HTTP error fails.
call() {
  local method="$1" path="$2"
  shift 2
  curl -sS --fail-with-body --retry 2 --max-time 600 -X "$method" -H @"$headers" "$@" "${api}${path}"
}

# expect_success JSON STEP fails unless the API answered {"type":"success"}.
expect_success() {
  local type message
  type="$(jq -r '.type // empty' <<<"$1")"
  message="$(jq -r '.message // empty' <<<"$1")"
  echo "$2: ${message:-$type}"
  [[ "$type" == success ]] || { echo "Cafe Bazaar refused $2" >&2; exit 1; }
}

pending="$(call GET /apps/releases/last-uncommitted)"
if [[ "$(jq -r '.type // empty' <<<"$pending")" == not-exists ]]; then
  expect_success "$(call POST /apps/releases/ -H 'Content-Type: application/json' -d '{}')" "create release"
else
  echo "Reusing the release that is not submitted yet"
fi

upload_package() {
  call POST /apps/releases/upload/ -F "apk=@${apk};type=application/vnd.android.package-archive" -F architecture=all
}

upload_status=0
upload="$(upload_package)" || upload_status=$?
# The draft may disappear between lookup and upload, and the lookup can return
# a success envelope even when there is no usable draft. Recover only from the
# explicit no-release response; never replace or delete an existing release.
if jq -e '(.message // "" | gsub("[[:space:]‌]"; "")) == "رهانشثبتشدهایوجودندارد."' <<<"$upload" >/dev/null 2>&1; then
  expect_success "$(call POST /apps/releases/ -H 'Content-Type: application/json' -d '{}')" "create missing release"
  upload_status=0
  upload="$(upload_package)" || upload_status=$?
fi
expect_success "$upload" "upload $(basename "$apk")"
(( upload_status == 0 )) || exit "$upload_status"

body="$(jq -n --arg v "$version" --argjson auto "$auto_publish" --argjson rollout "$rollout" '{
  changelog_fa: ("نسخه‌ی " + $v + ": بهبودها و رفع اشکال‌ها."),
  changelog_en: ("Version " + $v + ": improvements and fixes."),
  developer_note: ("Automated release " + $v + " from GitHub Actions."),
  staged_rollout_percentage: $rollout,
  auto_publish: $auto
}')"
expect_success "$(call POST /apps/releases/commit/ -H 'Content-Type: application/json' -d "$body")" "submit for review"
