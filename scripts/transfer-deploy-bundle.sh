#!/usr/bin/env bash
# Authenticated, bounded archive transfer. A failed upload never starts rollout.
set -euo pipefail
[[ $# == 3 ]] || exit 2
bundle="$1" revision="$2" tree="$3"
[[ "$revision" =~ ^[0-9a-f]{40}$ && "$tree" =~ ^[0-9a-f]{40}$ ]] || exit 2
: "${DEPLOY_HOST:?}" "${DEPLOY_USER:?}" "${DEPLOY_PATH:?}" "${GITHUB_RUN_ID:?}" "${GITHUB_RUN_ATTEMPT:?}"
[[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ && "$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+$ ]] || exit 2
[[ "$DEPLOY_HOST" != -* && "$DEPLOY_USER" != -* && "$DEPLOY_PATH" == /* ]] || exit 2
[[ "${DEPLOY_PORT:-22}" =~ ^[0-9]+$ ]] || exit 2
root="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$root/scripts/deploy_image_bundle.py" check "$bundle" "$revision" "$tree"
read -r archive_bytes image_bytes < <(python3 - "$bundle/contract.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print(c['archive_bytes'], c['image_bytes'])
PY
)
staging="/tmp/rhythmo-deploy-$revision-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
ssh_args=(-i "$HOME/.ssh/id_deploy" -o StrictHostKeyChecking=yes -o BatchMode=yes
  -o IdentitiesOnly=yes -o ConnectTimeout=20 -o ServerAliveInterval=15
  -o ServerAliveCountMax=12 -p "${DEPLOY_PORT:-22}" "$DEPLOY_USER@$DEPLOY_HOST")
remote_phase() {
  local command
  printf -v command 'bash -s -- %q %q %q %q %q %q %q' \
    "$1" "$DEPLOY_PATH" "$revision" "$tree" "$staging" "$archive_bytes" "$image_bytes"
  timeout "$2" ssh "${ssh_args[@]}" "$command" < "$root/deploy/receive-deploy-bundle.sh"
}
# Cleanup is bounded and limited to this attempt's paths, including interrupts.
cleanup() { remote_phase cleanup 60 || echo 'Temporary transfer cleanup needs a workflow retry.' >&2; }
trap cleanup EXIT
trap 'exit 130' INT TERM
remote_phase preflight 180

upload() {
  local source="$1" name="$2" command attempt
  printf -v command 'umask 077; cat > %q && mv -- %q %q' \
    "$staging/$name.part" "$staging/$name.part" "$staging/$name"
  for attempt in 1 2 3; do
    if timeout 1200 ssh "${ssh_args[@]}" "$command" < "$source"; then return 0; fi
    echo "Bundle upload failed (attempt $attempt/3)." >&2
    if (( attempt < 3 )); then sleep $((attempt * 10)); fi
  done
  return 1
}
upload "$bundle/images.tar.gz" images.tar.gz
upload "$bundle/contract.json" contract.json
upload "$root/scripts/deploy_image_bundle.py" verifier.py
# Do not automatically retry an uncertain rollout after an SSH disconnect.
remote_phase deploy 1800
