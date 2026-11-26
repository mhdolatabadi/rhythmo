#!/usr/bin/env bash
# Pulls one validated commit and its prebuilt images, then restarts the stack.
set -euo pipefail

revision="${1:-main}"
# CI resolves each digest from the successful, commit-pinned GHCR build.
# Never use a mirrored mutable tag to identify a production image.
api_digest="${2:-}"
web_digest="${3:-}"
if [[ -n "$api_digest" || -n "$web_digest" ]]; then
  for digest in "$api_digest" "$web_digest"; do
    if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "Both immutable image digests must be valid SHA-256 references." >&2
      exit 1
    fi
  done
fi
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "deploy/.env is missing; copy .env.example and fill in real values first." >&2
  exit 1
fi

if ! grep -qE '^NAFIR_DOMAIN=' .env; then
  echo "deploy/.env has no NAFIR_DOMAIN; see deploy/README.md." >&2
  exit 1
fi

# Turning transcription on: it runs unless deploy/.env sets
# TRANSCRIPTION_DISABLED=true. A missing or short token is generated once and
# kept in .env. The value is never printed.
transcription_disabled="$(grep -E '^[[:space:]]*TRANSCRIPTION_DISABLED[[:space:]]*=' .env | tail -n 1 | cut -d= -f2- | tr -d " \t\r\"'" | tr '[:upper:]' '[:lower:]' || true)"
case "$transcription_disabled" in
  true | 1 | yes | on) transcription_enabled=false ;;
  *) transcription_enabled=true ;;
esac
unset transcription_disabled
if [[ $transcription_enabled == true ]]; then
  transcription_token="$(grep -E '^TRANSCRIPTION_TOKEN=' .env | tail -n 1 | cut -d= -f2- | tr -d '\r' || true)"
  if (( ${#transcription_token} < 32 )); then
    sed -i '/^TRANSCRIPTION_TOKEN=/d' .env
    printf 'TRANSCRIPTION_TOKEN=%s\n' "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" >> .env
    echo "Generated TRANSCRIPTION_TOKEN in deploy/.env."
  fi
  unset transcription_token
fi

git fetch --prune origin main
git checkout --detach "$revision"

# Images are tagged with the exact source commit. Pull everything before
# changing running containers, so a missing image leaves production untouched.
export NAFIR_IMAGE_TAG="$(git rev-parse HEAD)"
# The transcriber is tagged by the content of its folder (see images.yml), so
# an unchanged transcriber is not downloaded again.
export NAFIR_TRANSCRIBER_TAG="src-$(git rev-parse HEAD:server/transcriber)"
compose_args=()
if [[ $transcription_enabled == true ]]; then
  compose_args=(--profile transcription)
  export TRANSCRIPTION_URL=http://transcriber:8090
fi

# The link to ghcr.io can be slow and drop connections. Docker keeps finished
# layers, so each retry continues where the last one stopped.
pull_with_retries() {
  local attempt
  for attempt in 1 2 3 4; do
    if docker compose "${compose_args[@]}" pull "$@"; then
      return 0
    fi
    echo "Pulling $* failed (attempt ${attempt}); retrying." >&2
    sleep $((attempt * 10))
  done
  return 1
}

# The runner resolved verified GHCR digests for the commit. Fetch each
# image from Runflare by digest and tag it for the existing Compose file.
# Neither service is restarted until both immutable images are staged.
if [[ -n "$api_digest" ]]; then
  image_repo="${NAFIR_IMAGE_REPO:-$(grep -E '^NAFIR_IMAGE_REPO=' .env | tail -n 1 | cut -d= -f2- | tr -d '\r' || true)}"
  image_repo="${image_repo:-ghcr.io/mhdolatabadi/rhythmo}"
  bash ./pull-pinned-image.sh "$image_repo" api "$NAFIR_IMAGE_TAG" "$api_digest"
  bash ./pull-pinned-image.sh "$image_repo" web "$NAFIR_IMAGE_TAG" "$web_digest"
else
  # Manual deployments without digests retain the original pull behavior.
  pull_with_retries api
  pull_with_retries web
fi

start_services=()
if [[ $transcription_enabled == true ]] && ! pull_with_retries transcriber; then
  # Ship the new api and web anyway; the running transcriber keeps working.
  repo="$(grep -E '^NAFIR_IMAGE_REPO=' .env | tail -n 1 | cut -d= -f2- || true)"
  echo "WARNING: could not pull the transcriber image; the running transcriber is kept." >&2
  echo "WARNING: fetch it with: docker pull ${repo:-ghcr.io/mhdolatabadi/rhythmo}/transcriber:${NAFIR_TRANSCRIBER_TAG}" >&2
  mapfile -t start_services < <(docker compose "${compose_args[@]}" config --services | grep -vx transcriber)
fi

# One-time move from the old project name ("deploy", from this folder) to
# "nafir": remove this checkout's old containers so the new ones can take
# their ports. Only containers Compose started from this very folder match;
# volumes are kept and the new containers reuse them.
old_containers="$(docker ps -aq \
  --filter label=com.docker.compose.project=deploy \
  --filter "label=com.docker.compose.project.working_dir=$(pwd)")"
if [[ -n "$old_containers" ]]; then
  echo "Replacing the containers of the old \"deploy\" project."
  docker rm -f $old_containers
fi

docker compose "${compose_args[@]}" up -d --no-build --pull never --remove-orphans "${start_services[@]}"
docker image prune -f

domain="$(grep -E '^NAFIR_DOMAIN=' .env | cut -d= -f2-)"
ops_token="$(grep -E '^OPS_TOKEN=' .env | cut -d= -f2- || true)"

# Reports the bots' webhook and import queue once they have registered. A
# problem is printed but does not fail the deploy: the site itself is up.
check_bots() {
  [[ -n "$ops_token" ]] || return 0
  local report=""
  for attempt in $(seq 1 6); do
    report="$(curl -fsS -H "Authorization: Bearer ${ops_token}" "https://${domain}/api/v1/ops/bots" || true)"
    [[ "$report" == *'"healthy":true'* ]] && break
    sleep 5
  done
  echo "Bot health: ${report:-unavailable}"
  if [[ "$report" != *'"healthy":true'* ]]; then
    echo "WARNING: a bot needs attention; see deploy/README.md, Operating the bots." >&2
  fi
}
for attempt in $(seq 1 30); do
  if curl -fsS "https://${domain}/api/v1/health"; then
    echo
    echo "Deployed $(git rev-parse --short HEAD) to https://${domain}"
    check_bots
    exit 0
  fi
  sleep 5
done

echo "Health check failed for https://${domain}/api/v1/health" >&2
docker compose ps
docker compose logs --tail=100 api
exit 1
