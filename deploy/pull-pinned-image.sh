#!/usr/bin/env bash
# Fetch an immutable GHCR image through Runflare, with pinned GHCR fallback.
set -euo pipefail

if (( $# != 4 )); then
  echo "Usage: pull-pinned-image.sh GHCR_REPO SERVICE COMMIT_SHA SHA256_DIGEST" >&2
  exit 2
fi
image_repo="${1%/}"
service="$2"
commit_sha="$3"
digest="$4"
if [[ ! "$image_repo" =~ ^ghcr\.io/[a-zA-Z0-9._/-]+$ ]] ||
   [[ "$service" != api && "$service" != web ]] ||
   [[ ! "$commit_sha" =~ ^[0-9a-f]{40}$ ]] ||
   [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "Invalid immutable image reference." >&2
  exit 2
fi

pull_with_retries() {
  local reference="$1" attempt
  for attempt in 1 2 3 4; do
    if docker pull "$reference"; then
      return 0
    fi
    echo "Pinned image pull failed (attempt ${attempt}); retrying." >&2
    if (( attempt < 4 )); then
      sleep $((attempt * 10))
    fi
  done
  return 1
}

canonical="${image_repo}/${service}"
mirror="mirror-docker.runflare.com/${image_repo#ghcr.io/}/${service}"
source_ref="${mirror}@${digest}"
if ! pull_with_retries "$source_ref"; then
  echo "Runflare unavailable for ${service}; trying original pinned GHCR digest." >&2
  source_ref="${canonical}@${digest}"
  pull_with_retries "$source_ref"
fi

# The digest was resolved on the trusted CI runner from the successful
# Images workflow. Docker validates the requested digest while pulling.
docker image tag "$source_ref" "${canonical}:${commit_sha}"
docker image inspect "${canonical}:${commit_sha}" >/dev/null
