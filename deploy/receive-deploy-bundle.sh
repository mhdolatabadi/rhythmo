#!/usr/bin/env bash
# Run from the validated Actions checkout, before loading any on-host script.
set -euo pipefail
[[ $# == 7 ]] || { echo 'Incomplete bundle deployment arguments.' >&2; exit 2; }
phase="$1" checkout="$2" revision="$3" tree="$4" staging="$5" archive_bytes="$6" image_bytes="$7"
[[ "$phase" == preflight || "$phase" == deploy || "$phase" == cleanup ]] || exit 2
[[ "$revision" =~ ^[0-9a-f]{40}$ && "$tree" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$staging" =~ ^/tmp/rhythmo-deploy-${revision}-[0-9]+-[0-9]+$ ]] || exit 2
[[ "$checkout" == /* && "$archive_bytes" =~ ^[1-9][0-9]{0,11}$ && "$image_bytes" =~ ^[1-9][0-9]{0,11}$ ]] || exit 2
[[ ! -L "$staging" ]] || exit 2

if [[ "$phase" == cleanup ]]; then
  # Only this workflow attempt's temporary transfer files; never Docker data.
  if [[ -d "$staging" && -O "$staging" ]]; then
    rm -f -- "$staging/images.tar.gz" "$staging/images.tar.gz.part" \
      "$staging/contract.json" "$staging/contract.json.part" \
      "$staging/verifier.py" "$staging/verifier.py.part"
    rmdir -- "$staging"
  fi
  exit 0
fi

cd "$checkout"
git diff --quiet
git diff --cached --quiet
[[ -f deploy/.env ]] || { echo 'Missing production environment file.' >&2; exit 1; }
for program in docker python3 gzip timeout; do command -v "$program" >/dev/null; done
platform="$(docker info --format '{{.OSType}}/{{.Architecture}}')"
case "$platform" in linux/x86_64|linux/amd64) ;; *) echo 'Unsupported production platform.' >&2; exit 1 ;; esac

if [[ "$phase" == preflight ]]; then
  # Refuse an older rollback revision without this deployment contract before
  # spending time transferring images or changing the checkout.
  timeout 120 git fetch origin main
  git merge-base --is-ancestor "$revision" FETCH_HEAD
  git cat-file -e "$revision:scripts/deploy_image_bundle.py"
  [[ "$(git rev-parse "$revision:server/transcriber")" == "$tree" ]]
  docker_root="$(docker info --format '{{.DockerRootDir}}')"
  free_kib() { df -Pk "$1" | awk 'END {print $4}'; }
  temp_free="$(free_kib /tmp)"
  docker_free="$(free_kib "$docker_root")"
  # Account for the compressed archive plus load/extraction headroom, including
  # hosts where /tmp and Docker share one filesystem. Do not prune to make room.
  required=$((archive_bytes + image_bytes * 2 + 268435456))
  if (( temp_free * 1024 < archive_bytes + 268435456 || docker_free * 1024 < required )); then
    echo 'Insufficient disk space for verified image staging; no services changed.' >&2
    exit 1
  fi
  mkdir -m 700 -- "$staging"
  echo 'Production image staging preflight passed.'
  exit 0
fi

[[ -d "$staging" && -O "$staging" ]] || exit 2
python3 "$staging/verifier.py" check "$staging" "$revision" "$tree"
# Docker verifies the image data as it imports it. Keep raw output out of logs.
if ! timeout 1200 bash -o pipefail -c 'gzip -dc -- "$1/images.tar.gz" | docker image load >/dev/null 2>&1' bash "$staging"; then
  echo 'Image archive import failed; no services changed.' >&2
  exit 1
fi
python3 "$staging/verifier.py" verify "$staging" "$revision" "$tree"
git merge-base --is-ancestor "$revision" FETCH_HEAD
[[ "$(git rev-parse "$revision:server/transcriber")" == "$tree" ]]
git checkout --detach "$revision"
exec bash deploy/deploy.sh "$revision" "$staging" "$tree"
