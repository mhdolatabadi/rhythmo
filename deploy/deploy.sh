#!/usr/bin/env bash
# Pulls one validated commit and its prebuilt images, then restarts the stack.
set -euo pipefail

revision="${1:-main}"
# The workflow resolves native manifest AND config digests from the owned registry.
api_digest="${2:-}"
web_digest="${3:-}"
source_repo="${4:-}"
api_config="${5:-}"
web_config="${6:-}"
transcriber_digest="${7:-}"
transcriber_config="${8:-}"
platform="${9:-linux/amd64}"
if [[ -n "$api_digest" || -n "$web_digest" ]]; then
  for digest in "$api_digest" "$web_digest" "$api_config" "$web_config" "$transcriber_digest" "$transcriber_config"; do
    if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "All image manifest and config digests are required." >&2
      exit 1
    fi
  done
  if [[ "${source_repo%%/*}" != *.* ]]; then echo 'Expected an explicit regional registry hostname.' >&2; exit 2; fi
  if [[ ! "$source_repo" =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]+)?/[a-z0-9][a-z0-9._/-]*$ ]] ||
     [[ "$source_repo" == ghcr.io/* || "$source_repo" == mirror-docker.runflare.com/* || "$source_repo" == *..* || "$source_repo" == *//* ]] ||
     [[ "$platform" != linux/amd64 ]]; then
    echo "Invalid owned registry or production platform." >&2
    exit 1
  fi
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
    if docker compose ${compose_args[@]+"${compose_args[@]}"} pull "$@"; then
      return 0
    fi
    echo "Pulling $* failed (attempt ${attempt}); retrying." >&2
    sleep $((attempt * 10))
  done
  return 1
}

# Stage every enabled application service before changing running containers.
if [[ -n "$api_digest" ]]; then
  image_repo="${NAFIR_IMAGE_REPO:-$(grep -E '^NAFIR_IMAGE_REPO=' .env | tail -n 1 | cut -d= -f2- | tr -d '\r' || true)}"
  image_repo="${image_repo:-ghcr.io/mhdolatabadi/rhythmo}"
  bash ./pull-pinned-image.sh "$image_repo" "$source_repo" api "$NAFIR_IMAGE_TAG" "$api_digest" "$api_config" "$platform"
  bash ./pull-pinned-image.sh "$image_repo" "$source_repo" web "$NAFIR_IMAGE_TAG" "$web_digest" "$web_config" "$platform"
  if [[ $transcription_enabled == true ]]; then
    bash ./pull-pinned-image.sh "$image_repo" "$source_repo" transcriber "$NAFIR_TRANSCRIBER_TAG" "$transcriber_digest" "$transcriber_config" "$platform"
  fi
else
  # Legacy manual operation; automated production always supplies the contract.
  pull_with_retries api
  pull_with_retries web
  if [[ $transcription_enabled == true ]]; then pull_with_retries transcriber; fi
fi
# Validate privately: expanded Compose includes secrets and must not be logged.
docker compose ${compose_args[@]+"${compose_args[@]}"} config --quiet

docker compose ${compose_args[@]+"${compose_args[@]}"} up -d --no-build --pull never --remove-orphans

# A health response from an old container is not proof of this rollout.
if [[ -n "$api_digest" ]]; then
  for service in api web transcriber; do
    if [[ "$service" == transcriber && $transcription_enabled != true ]]; then continue; fi
    case "$service" in api) expected="$api_config" ;; web) expected="$web_config" ;; transcriber) expected="$transcriber_config" ;; esac
    container="$(docker compose ${compose_args[@]+"${compose_args[@]}"} ps -q "$service")"
    [[ -n "$container" ]] || { echo "Missing running $service container." >&2; exit 1; }
    actual="$(docker inspect --format '{{.Image}}' "$container")"
    [[ "$actual" == "$expected" ]] || { echo "Running $service image differs from deployment contract." >&2; exit 1; }
  done
fi

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
