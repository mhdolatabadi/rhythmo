#!/usr/bin/env bash
# Runs after a successful server deployment. Waiting here keeps automatic
# releases serialized by the production deployment concurrency group.
set -euo pipefail
: "${DEPLOY_SHA:?DEPLOY_SHA is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"
[[ "$DEPLOY_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "Expected an exact deployed commit" >&2; exit 1; }
[[ "$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+-[0-9]+$ ]] || exit 1
key="$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
gh workflow run android-release.yml --ref main   -f "ref=$DEPLOY_SHA" -f cafebazaar=true -f "deployment_run=$key"
for attempt in $(seq 1 40); do
  run_id="$(gh run list --workflow android-release.yml --event workflow_dispatch     --limit 100 --json databaseId,displayTitle     --jq ".[] | select(.displayTitle == \"Android release for deploy $key\") | .databaseId" | head -n 1)"
  if [[ "$run_id" =~ ^[0-9]+$ ]]; then
    # Includes signed builds, APK upload and the Bazaar review submission.
    timeout 40m gh run watch "$run_id" --exit-status
    exit 0
  fi
  sleep 3
done
echo "Android release did not appear for deployment $key" >&2
exit 1
