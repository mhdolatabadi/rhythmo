#!/usr/bin/env bash
# Runs scripts/publish-cafebazaar.sh against a fake Pishkhan API (#95):
# a fresh release, a pending one, a refused upload, and no secret in logs.
set -euo pipefail
cd "$(dirname "$0")"
work="$(mktemp -d)"
trap 'kill "$(jobs -p)" 2>/dev/null || true; rm -rf "$work"' EXIT
echo APKDATA > "$work/app.apk"
export NO_PROXY='*' no_proxy='*' CAFEBAZAAR_API_SECRET=s3cret

run() { # name port pending|fresh ok|fail expected-exit
  : > "$work/log"
  python3 cafebazaar-mock.py "$2" "$3" "$4" "$work/log" &
  local pid=$!
  for _ in $(seq 50); do curl -s "http://127.0.0.1:$2/" >/dev/null 2>&1 && break; sleep 0.1; done
  local status=0
  CAFEBAZAAR_API_URL="http://127.0.0.1:$2/v1" ./publish-cafebazaar.sh "$work/app.apk" 0.1.42 > "$work/out" 2>&1 || status=$?
  kill "$pid"
  cat "$work/out"
  [[ "$status" == "$5" ]] || { echo "FAIL $1: exit $status, want $5"; exit 1; }
  ! grep -q s3cret "$work/out" || { echo "FAIL $1: secret in output"; exit 1; }
  grep -q '/v1/.* auth=False' "$work/log" && { echo "FAIL $1: request without the secret"; exit 1; }
  echo "ok $1"
}

run fresh 19101 fresh ok 0
grep -q 'POST /v1/apps/releases/ ' "$work/log"
grep -q '"auto_publish": false' "$work/log"
CAFEBAZAAR_AUTO_PUBLISH=true run automatic 19104 fresh ok 0
grep -q '"auto_publish": true' "$work/log"
run pending 19102 pending ok 0
! grep -q 'POST /v1/apps/releases/ ' "$work/log"
run refused 19103 fresh fail 1
! grep -q 'commit' "$work/log"
echo "all Cafe Bazaar publish tests passed"
