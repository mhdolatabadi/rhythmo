#!/usr/bin/env bash
# Exercise real deploy.sh orchestration with isolated fake Docker/git/network.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/deploy"
cp deploy/deploy.sh deploy/pull-pinned-image.sh "$tmp/deploy/"
printf 'NAFIR_DOMAIN=test.invalid\nTRANSCRIPTION_DISABLED=true\n' > "$tmp/deploy/.env"
cat > "$tmp/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "$1" in rev-parse) echo "$MOCK_SHA" ;; esac
MOCK
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$1 $2" in
  'info --format') echo linux/x86_64 ;;
  'pull --platform')
    if [[ "$*" == */web@* && "$MOCK_SCENARIO" == pull-failure ]]; then exit 1; fi ;;
  'image inspect')
    case "$3" in */api@*) echo "$MOCK_API linux/amd64" ;; */web@*) echo "$MOCK_WEB linux/amd64" ;; esac ;;
  'compose ps') echo "container-$4" ;;
  'inspect --format')
    if [[ "$MOCK_SCENARIO" == running-mismatch ]]; then echo "sha256:$(printf 'f%.0s' {1..64})"
    elif [[ "$4" == container-api ]]; then echo "$MOCK_API"; else echo "$MOCK_WEB"; fi ;;
esac
MOCK
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'health-request\n' >> "$MOCK_LOG"
printf '{"status":"ok"}\n'
MOCK
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export MOCK_SHA=0123456789abcdef0123456789abcdef01234567
export MOCK_API="sha256:$(printf 'c%.0s' {1..64})"
export MOCK_WEB="sha256:$(printf 'd%.0s' {1..64})"
export MOCK_LOG="$tmp/docker.log"
digest="sha256:$(printf 'a%.0s' {1..64})"
for scenario in pull-failure running-mismatch success; do
  export MOCK_SCENARIO="$scenario"
  : > "$MOCK_LOG"
  result=0
  bash "$tmp/deploy/deploy.sh" "$MOCK_SHA" "$digest" "$digest" registry.example.com/rhythmo "$MOCK_API" "$MOCK_WEB" "$digest" "$MOCK_API" linux/amd64 || result=$?
  if [[ "$scenario" == success ]]; then
    [[ "$result" == 0 ]]
    grep -q '^health-request$' "$MOCK_LOG"
  else
    [[ "$result" != 0 ]]
    if grep -q '^health-request$' "$MOCK_LOG"; then echo 'Health authorized a failed rollout' >&2; exit 1; fi
  fi
  if [[ "$scenario" == pull-failure ]] && grep -q '^compose up' "$MOCK_LOG"; then echo 'Rollout before staging completed' >&2; exit 1; fi
  if grep -Eq '^(rm |image prune|system prune)' "$MOCK_LOG"; then echo 'Unexpected destructive operation' >&2; exit 1; fi
done
echo 'Deploy staging and running-identity regression tests passed.'
