#!/usr/bin/env bash
# Read-only host checks first, then execute the exact validated script revision.
set -euo pipefail
(( $# == 10 )) || { echo 'Incomplete deployment contract.' >&2; exit 2; }
checkout="$1"
shift
revision="$1"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || exit 2
cd "$checkout"
# Never overwrite tracked operator changes or print an expanded environment.
git diff --quiet
git diff --cached --quiet
docker version --format 'Docker server {{.Server.Version}}'
platform="$(docker info --format '{{.OSType}}/{{.Architecture}}')"
case "$platform" in linux/x86_64|linux/amd64) ;; *) echo 'Unsupported server platform.' >&2; exit 1 ;; esac
# Status/timing only; do not log redirects, authorization headers or signed URLs.
for host in ghcr.io pkg-containers.githubusercontent.com; do
  curl --silent --output /dev/null --connect-timeout 10 --max-time 15 \
    --write-out "Network $host HTTP %{http_code} TLS %{time_appconnect}s\\n" "https://$host/v2/" || true
done
# Fetching the repository is still a network dependency; no source rebuilds.
git fetch origin main
git cat-file -e "$revision^{commit}"
git merge-base --is-ancestor "$revision" FETCH_HEAD
git checkout --detach "$revision"
exec bash deploy/deploy.sh "$@"
