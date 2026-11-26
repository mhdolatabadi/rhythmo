#!/usr/bin/env bash
# Offline staging failure tests; these do not certify a real registry.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"
case "$1 $2" in
  'info --format') echo "${MOCK_PLATFORM:-linux/x86_64}" ;;
  'pull --platform') [[ "${MOCK_FAIL:-}" != pull ]] ;;
  'image inspect') echo "${MOCK_IDENTITY:-$MOCK_CONFIG linux/amd64}" ;;
esac
MOCK
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH"
export MOCK_DOCKER_LOG="$tmp/docker.log"
export MOCK_CONFIG="sha256:$(printf 'c%.0s' {1..64})"
sha="0123456789abcdef0123456789abcdef01234567"
digest="sha256:$(printf 'a%.0s' {1..64})"
args=(ghcr.io/mhdolatabadi/rhythmo registry.example.com/rhythmo api "$sha" "$digest" "$MOCK_CONFIG" linux/amd64)
: > "$MOCK_DOCKER_LOG"
bash deploy/pull-pinned-image.sh "${args[@]}"
grep -qxF "pull --platform linux/amd64 registry.example.com/rhythmo/api@$digest" "$MOCK_DOCKER_LOG"
grep -qxF "image tag registry.example.com/rhythmo/api@$digest ghcr.io/mhdolatabadi/rhythmo/api:$sha" "$MOCK_DOCKER_LOG"
for scenario in pull identity platform; do
  : > "$MOCK_DOCKER_LOG"
  export MOCK_FAIL='' MOCK_IDENTITY="$MOCK_CONFIG linux/amd64" MOCK_PLATFORM=linux/x86_64
  case "$scenario" in
    pull) MOCK_FAIL=pull ;;
    identity) MOCK_IDENTITY="$digest linux/amd64" ;;
    platform) MOCK_PLATFORM=linux/aarch64 ;;
  esac
  if bash deploy/pull-pinned-image.sh "${args[@]}"; then echo "Accepted $scenario failure" >&2; exit 1; fi
  if grep -q 'image tag' "$MOCK_DOCKER_LOG"; then echo 'Retag after failure' >&2; exit 1; fi
done
unset MOCK_FAIL MOCK_IDENTITY MOCK_PLATFORM
for bad in ghcr.io/owner/app mirror-docker.runflare.com/owner/app 'registry.example.com/a;id' 'registry.example.com/a/../b'; do
  : > "$MOCK_DOCKER_LOG"
  args[1]="$bad"
  if bash deploy/pull-pinned-image.sh "${args[@]}"; then echo 'Invalid registry accepted' >&2; exit 1; fi
  [[ ! -s "$MOCK_DOCKER_LOG" ]]
done
# Missing native/config contract must fail before Docker or filesystem mutation.
: > "$MOCK_DOCKER_LOG"
if bash deploy/deploy.sh "$sha" "$digest" "$digest"; then exit 1; fi
[[ ! -s "$MOCK_DOCKER_LOG" ]]
echo 'Owned registry image contract tests passed.'
