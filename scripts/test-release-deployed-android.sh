#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"
case "$1 $2" in
  'workflow run') exit 0 ;;
  'run list') echo 12345 ;;
  'run watch') exit "${WATCH_RESULT:-0}" ;;
  *) exit 99 ;;
esac
GH
chmod +x "$work/gh"
export PATH="$work:$PATH" CALL_LOG="$work/calls"
export DEPLOY_SHA=0123456789abcdef0123456789abcdef01234567
export GITHUB_RUN_ID=987 GITHUB_RUN_ATTEMPT=2
./release-deployed-android.sh
grep -Fq "workflow run android-release.yml --ref main -f ref=$DEPLOY_SHA -f cafebazaar=true -f deployment_run=987-2" "$CALL_LOG"
grep -Fq 'select(.displayTitle == "Android release for deploy 987-2")' "$CALL_LOG"
grep -Fq 'run watch 12345 --exit-status' "$CALL_LOG"
: > "$CALL_LOG"
if DEPLOY_SHA=main ./release-deployed-android.sh; then echo 'Accepted a mutable ref'; exit 1; fi
[[ ! -s "$CALL_LOG" ]]
status=0
WATCH_RESULT=7 ./release-deployed-android.sh || status=$?
[[ "$status" == 7 ]] || { echo "Failed publication did not propagate: $status"; exit 1; }
echo 'Deployed revision dispatch tests passed'
