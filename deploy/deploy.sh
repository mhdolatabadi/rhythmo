#!/usr/bin/env bash
# Pulls one validated commit and its prebuilt images, then restarts the stack.
set -euo pipefail

revision="${1:-main}"
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

pull_with_retries api web
if [[ $transcription_enabled == true ]]; then
  # A partial release silently left the audio-to-text feature broken.
  # Fail before replacing the healthy stack if the required model image
  # cannot be pulled. The previous containers remain unchanged.
  pull_with_retries transcriber
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

docker compose "${compose_args[@]}" up -d --no-build --remove-orphans

# A successful API /health does not prove that the Whisper model loaded.
# Probe the private service with its own container token and fail the release
# when the model cannot serve requests. Never print the token.
check_transcription_ready() {
  [[ $transcription_enabled == true ]] || return 0
  for attempt in $(seq 1 30); do
    if docker compose "${compose_args[@]}" exec -T transcriber python -c '
import os
import urllib.request
request = urllib.request.Request(
    "http://127.0.0.1:8090/health",
    headers={"Authorization": "Bearer " + os.environ["TRANSCRIPTION_TOKEN"]})
with urllib.request.urlopen(request, timeout=3) as response:
    raise SystemExit(0 if response.status == 200 else 1)
' >/dev/null 2>&1; then
      echo "Transcription model: ready"
      # A model can load yet fail on its very first real inference. Exercise
      # the complete decoder + model path with synthetic audio before a
      # successful deployment and automatic Cafe Bazaar release.
      if ! docker compose "${compose_args[@]}" exec -T transcriber python -c '
import os
import urllib.request
request = urllib.request.Request(
    "http://127.0.0.1:8090/self-test",
    data=b"",
    headers={"Authorization": "Bearer " + os.environ["TRANSCRIPTION_TOKEN"]},
    method="POST")
with urllib.request.urlopen(request, timeout=240) as response:
    raise SystemExit(0 if response.status == 200 else 1)
' >/dev/null 2>&1; then
        echo "ERROR: Whisper could not run an inference on synthetic audio." >&2
        docker compose "${compose_args[@]}" logs --tail=30 transcriber >&2 || true
        return 1
      fi
      echo "Transcription inference smoke test: passed"
      return 0
    fi
    sleep 5
  done
  echo "ERROR: transcription model was not ready; deployment cannot be marked successful." >&2
  docker compose "${compose_args[@]}" ps transcriber >&2 || true
  docker compose "${compose_args[@]}" logs --tail=30 transcriber >&2 || true
  return 1
}
check_transcription_ready
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

check_transcription_ops() {
  [[ $transcription_enabled == true && -n "$ops_token" ]] || return 0
  local report
  report="$(curl -fsS -H "Authorization: Bearer ${ops_token}" "https://${domain}/api/v1/ops/transcription" || true)"
  echo "Transcription health: ${report:-unavailable}"
  if [[ "$report" != *'"healthy":true'* ]]; then
    echo "WARNING: transcription is not healthy; see the transcriber and API logs." >&2
  fi
}
for attempt in $(seq 1 30); do
  if curl -fsS "https://${domain}/api/v1/health"; then
    echo
    echo "Deployed $(git rev-parse --short HEAD) to https://${domain}"
    check_bots
    check_transcription_ops
    exit 0
  fi
  sleep 5
done

echo "Health check failed for https://${domain}/api/v1/health" >&2
docker compose ps
docker compose logs --tail=100 api
exit 1
