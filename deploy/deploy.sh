#!/usr/bin/env bash
# Starts a validated revision only after its image bundle has been staged.
set -euo pipefail

[[ $# == 3 ]] || { echo 'Deploy through the repository workflow with a verified image bundle.' >&2; exit 2; }
revision="$1" bundle="$2" tree="$3"
[[ "$revision" =~ ^[0-9a-f]{40}$ && "$tree" =~ ^[0-9a-f]{40}$ && "$bundle" == /* ]] || exit 2
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "deploy/.env is missing; copy .env.example and fill in real values first." >&2
  exit 1
fi

if ! grep -qE '^NAFIR_DOMAIN=' .env; then
  echo "deploy/.env has no NAFIR_DOMAIN; see deploy/README.md." >&2
  exit 1
fi

# The bootstrap has already staged all images and checked out this exact commit.
[[ "$(git rev-parse HEAD)" == "$revision" ]]
[[ "$(git rev-parse HEAD:server/transcriber)" == "$tree" ]]
python3 ../scripts/deploy_image_bundle.py verify "$bundle" "$revision" "$tree"
# Use the canonical tags verified by the bundle even when an old .env retains
# a compatibility repository name. Operator Compose overrides remain in place.
export NAFIR_IMAGE_REPO=ghcr.io/mhdolatabadi/rhythmo
export NAFIR_IMAGE_TAG="$revision"
export NAFIR_TRANSCRIBER_TAG="src-$tree"

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

compose_args=()
verify_args=()
if [[ $transcription_enabled == true ]]; then
  compose_args=(--profile transcription)
  verify_args=(--transcription-enabled)
  export TRANSCRIPTION_URL=http://transcriber:8090
fi

# Expanded Compose contains secrets. Validate privately and forbid pulls/builds.
docker compose ${compose_args[@]+"${compose_args[@]}"} config --quiet
python3 ../scripts/deploy_image_bundle.py verify-compose "$bundle" "$revision" "$tree" ${verify_args[@]+"${verify_args[@]}"}
docker compose ${compose_args[@]+"${compose_args[@]}"} up -d --no-build --pull never
python3 ../scripts/deploy_image_bundle.py verify-running "$bundle" "$revision" "$tree" ${verify_args[@]+"${verify_args[@]}"}

domain="$(grep -E '^NAFIR_DOMAIN=' .env | cut -d= -f2-)"
ops_token="$(grep -E '^OPS_TOKEN=' .env | cut -d= -f2- || true)"

# Reports the bots' webhook and import queue once they have registered. A
# problem is printed but does not fail the deploy: the site itself is up.
check_bots() {
  [[ -n "$ops_token" ]] || return 0
  local report=""
  for attempt in $(seq 1 6); do
    report="$(curl --connect-timeout 10 --max-time 20 -fsS -H "Authorization: Bearer ${ops_token}" "https://${domain}/api/v1/ops/bots" || true)"
    [[ "$report" == *'"healthy":true'* ]] && break
    sleep 5
  done
  echo "Bot health: ${report:-unavailable}"
  if [[ "$report" != *'"healthy":true'* ]]; then
    echo "WARNING: a bot needs attention; see deploy/README.md, Operating the bots." >&2
  fi
}
for attempt in $(seq 1 30); do
  if curl --connect-timeout 10 --max-time 15 -fsS "https://${domain}/api/v1/health"; then
    echo
    echo "Deployed $(git rev-parse --short HEAD) to https://${domain}"
    check_bots
    exit 0
  fi
  sleep 5
done

echo "Health check failed for https://${domain}/api/v1/health" >&2
docker compose ps
exit 1
