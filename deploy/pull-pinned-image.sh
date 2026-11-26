#!/usr/bin/env bash
# Stage a verified native manifest from the owned production registry.
set -euo pipefail
if (( $# != 7 )); then
  echo 'Usage: pull-pinned-image.sh CANONICAL_REPO SOURCE_REPO SERVICE TAG MANIFEST CONFIG PLATFORM' >&2
  exit 2
fi
canonical="${1%/}"
source_repo="${2%/}"
service="$3"
tag="$4"
digest="$5"
config="$6"
platform="$7"
repo_pattern='^[a-z0-9][a-z0-9.-]*(:[0-9]+)?/[a-z0-9][a-z0-9._/-]*$'
if [[ "${source_repo%%/*}" != *.* && "${source_repo%%/*}" != localhost:* ]]; then
  echo 'Expected an explicit registry hostname.' >&2; exit 2
fi
if [[ ! "$canonical" =~ $repo_pattern || ! "$source_repo" =~ $repo_pattern ]] ||
   [[ "$source_repo" == ghcr.io/* || "$source_repo" == mirror-docker.runflare.com/* ]] ||
   [[ "$source_repo" == *..* || "$source_repo" == *//* ]] ||
   [[ "$service" != api && "$service" != web && "$service" != transcriber ]] ||
   [[ ! "$tag" =~ ^([0-9a-f]{40}|src-[0-9a-f]{40})$ ]] ||
   [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ || ! "$config" =~ ^sha256:[0-9a-f]{64}$ ]] ||
   [[ "$platform" != linux/amd64 ]]; then
  echo 'Invalid production image contract.' >&2
  exit 2
fi
server_platform="$(docker info --format '{{.OSType}}/{{.Architecture}}')"
case "$server_platform" in linux/x86_64|linux/amd64) ;; *) echo 'Server platform differs from production build.' >&2; exit 1 ;; esac
source_ref="${source_repo}/${service}@${digest}"
# No mirror fallback, mutable tag fallback, daemon restart or automatic login.
docker pull --platform "$platform" "$source_ref"
identity="$(docker image inspect "$source_ref" --format '{{.Id}} {{.Os}}/{{.Architecture}}')"
if [[ "$identity" != "$config $platform" ]]; then
  echo 'Pulled image identity differs from the verified build contract.' >&2
  exit 1
fi
docker image tag "$source_ref" "${canonical}/${service}:${tag}"
