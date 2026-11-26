#!/usr/bin/env bash
# Offline regression test: no production network or Docker daemon required.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"
if [[ "$1" == pull ]]; then
  case "${MOCK_PULL_FAIL:-}" in
    all) exit 1 ;;
    mirror)
      if [[ "$2" == mirror-docker.runflare.com/* ]]; then exit 1; fi
      ;;
  esac
fi
MOCK
cat > "$tmp/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$tmp/bin/docker" "$tmp/bin/sleep"
export PATH="$tmp/bin:$PATH"
export MOCK_DOCKER_LOG="$tmp/docker.log"

sha="0123456789abcdef0123456789abcdef01234567"
digest="sha256:$(printf 'a%.0s' {1..64})"
mirror="mirror-docker.runflare.com/mhdolatabadi/rhythmo/api@${digest}"
origin="ghcr.io/mhdolatabadi/rhythmo/api@${digest}"
canonical="ghcr.io/mhdolatabadi/rhythmo/api:${sha}"

# The first choice must be the Runflare mirror, pinned by digest.
: > "$MOCK_DOCKER_LOG"
MOCK_PULL_FAIL="" bash deploy/pull-pinned-image.sh ghcr.io/mhdolatabadi/rhythmo api "$sha" "$digest"
grep -qxF "pull $mirror" "$MOCK_DOCKER_LOG"
grep -qxF "image tag $mirror $canonical" "$MOCK_DOCKER_LOG"
if grep -qF "pull $origin" "$MOCK_DOCKER_LOG"; then
  echo "Unexpected direct GHCR pull on successful mirror." >&2
  exit 1
fi

# Fallback is allowed only at precisely the *same* trusted digest.
: > "$MOCK_DOCKER_LOG"
MOCK_PULL_FAIL=mirror bash deploy/pull-pinned-image.sh ghcr.io/mhdolatabadi/rhythmo api "$sha" "$digest"
[[ "$(grep -cxF "pull $mirror" "$MOCK_DOCKER_LOG")" -eq 4 ]]
grep -qxF "pull $origin" "$MOCK_DOCKER_LOG"
grep -qxF "image tag $origin $canonical" "$MOCK_DOCKER_LOG"

# No retag or deployment if neither trusted source can be retrieved.
: > "$MOCK_DOCKER_LOG"
if MOCK_PULL_FAIL=all bash deploy/pull-pinned-image.sh ghcr.io/mhdolatabadi/rhythmo api "$sha" "$digest"; then
  echo "Expected failure when both registries are inaccessible." >&2
  exit 1
fi
if grep -q 'image tag' "$MOCK_DOCKER_LOG"; then
  echo "Failed image was tagged for deployment." >&2
  exit 1
fi

# Reject unpinned images before making any network requests.
: > "$MOCK_DOCKER_LOG"
if bash deploy/pull-pinned-image.sh ghcr.io/mhdolatabadi/rhythmo api "$sha" latest; then
  echo "Accepted an unpinned image." >&2
  exit 1
fi
[[ ! -s "$MOCK_DOCKER_LOG" ]]
echo "Runflare immutable image staging tests passed."
