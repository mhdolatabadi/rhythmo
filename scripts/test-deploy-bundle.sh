#!/usr/bin/env bash
# Offline orchestration regressions: no SSH server, registry, or Docker daemon.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
tmp="$(mktemp -d)"
revision=0123456789abcdef0123456789abcdef01234567
tree=abcdef0123456789abcdef0123456789abcdef01
staging="/tmp/rhythmo-deploy-$revision-$$-1"
trap 'rm -rf "$tmp"; rm -rf "$staging"' EXIT
mkdir -p "$tmp/bin" "$tmp/bundle" "$tmp/checkout/deploy" "$tmp/checkout/scripts"
export MOCK_LOG="$tmp/commands.log" MOCK_REVISION="$revision" MOCK_TREE="$tree"
export MOCK_DOCKER_ROOT="$tmp/docker"
mkdir -p "$MOCK_DOCKER_ROOT"

cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env python3
import os
import sys
import json
args = sys.argv[1:]
with open(os.environ['MOCK_LOG'], 'a') as log:
    log.write('docker ' + ' '.join(args) + '\n')
services = ('api', 'web', 'transcriber')

def identity(service):
    return 'sha256:' + str(services.index(service) + 1) * 64

if args[:1] == ['info']:
    print(os.environ.get('MOCK_PLATFORM', 'linux/amd64') if 'OSType' in args[-1] else os.environ['MOCK_DOCKER_ROOT'])
elif args[:2] == ['image', 'load']:
    sys.stdin.buffer.read()
    sys.exit(int(os.environ.get('MOCK_LOAD_FAIL', '0')))
elif args[:2] == ['image', 'inspect']:
    reference = args[2]
    service = next((name for name in services if '/' + name + ':' in reference), None)
    if service:
        image_id = 'sha256:' + 'f' * 64 if os.environ.get('MOCK_LOADED_MISMATCH') == service else identity(service)
        print(image_id + ' linux/amd64 100')
    elif os.environ.get('MOCK_INFRA_MISSING'):
        sys.exit(1)
elif args[:1] == ['inspect'] and '--type=container' in args:
    service = services[int(args[-1][0]) - 1]
    print(('sha256:' + 'f' * 64 if os.environ.get('MOCK_RUNNING_MISMATCH') == service else identity(service)) + ' true')
elif args[:1] == ['compose']:
    command = args[1:]
    if command[:2] == ['--profile', 'transcription']:
        command = command[2:]
    if command[:2] == ['config', '--quiet']:
        sys.exit(int(os.environ.get('MOCK_CONFIG_FAIL', '0')))
    elif command[:2] == ['config', '--format']:
        configured = {}
        for service in services:
            tag = 'src-' + os.environ['MOCK_TREE'] if service == 'transcriber' else os.environ['MOCK_REVISION']
            configured[service] = {'image': 'ghcr.io/mhdolatabadi/rhythmo/' + service + ':' + tag}
            if service == 'transcriber': configured[service]['profiles'] = ['transcription']
        configured['postgres'] = {'image': 'postgres:16-alpine'}
        print(json.dumps({'services': configured}))
    elif command[:2] == ['config', '--images']:
        print('postgres:16-alpine\nminio/minio:latest\ncaddy:2-alpine')
        for service in services:
            tag = 'src-' + os.environ['MOCK_TREE'] if service == 'transcriber' else os.environ['MOCK_REVISION']
            print('ghcr.io/mhdolatabadi/rhythmo/' + service + ':' + tag)
    elif command[:2] == ['ps', '-q']:
        print(str(services.index(command[2]) + 1) * 12)
    elif command[:1] != ['up']:
        sys.exit('Unsupported mocked Compose command: ' + repr(command))
elif args[:2] != ['ps', '-aq']:
    sys.exit('Unexpected Docker command: ' + repr(args))
MOCK
cat > "$tmp/bin/git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >> "$MOCK_LOG"
case "$1" in
  diff) exit "${MOCK_DIRTY:-0}" ;;
  rev-parse)
    case "$*" in
      *:server/transcriber*) printf '%s\n' "$MOCK_TREE" ;;
      *--short*) printf '%.7s\n' "$MOCK_REVISION" ;;
      *) printf '%s\n' "$MOCK_REVISION" ;;
    esac ;;
  fetch|cat-file|checkout) ;;
  merge-base) exit "${MOCK_NOT_MAIN:-0}" ;;
  *) echo "Unexpected git command: $*" >&2; exit 1 ;;
esac
MOCK
cat > "$tmp/bin/df" <<'MOCK'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'mock 999999999 1 %s 1%% /\n' "${MOCK_FREE_KIB:-999999998}"
MOCK
cat > "$tmp/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'timeout %s\n' "$1" >> "$MOCK_LOG"
shift
exec "$@"
MOCK
cat > "$tmp/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$MOCK_LOG"
printf '{"status":"ok"}\n'
MOCK
cat > "$tmp/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "$MOCK_LOG"
# Consume every upload, including failed ones, as a remote socket would.
cat >/dev/null
case "$*" in
  *'bash -s -- preflight '*) exit "${MOCK_SSH_PREFLIGHT_FAIL:-0}" ;;
  *'cat > '*) exit "${MOCK_UPLOAD_FAIL:-0}" ;;
esac
MOCK
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

python3 - "$tmp/bundle" "$revision" "$tree" <<'PY'
import gzip
import hashlib
import json
from pathlib import Path
import sys
bundle, revision, tree = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
archive = gzip.compress(b'tiny Docker archive fixture', mtime=0)
(bundle / 'images.tar.gz').write_bytes(archive)
images = []
for index, service in enumerate(('api', 'web', 'transcriber'), 1):
    tag = 'src-' + tree if service == 'transcriber' else revision
    images.append({'service': service, 'tag': tag,
                   'reference': f'ghcr.io/mhdolatabadi/rhythmo/{service}:{tag}',
                   'manifest': 'sha256:' + 'abcdef'[index] * 64,
                   'config': 'sha256:' + str(index) * 64})
(bundle / 'contract.json').write_text(json.dumps({
    'version': 1, 'revision': revision, 'transcriber_tree': tree,
    'archive_sha256': hashlib.sha256(archive).hexdigest(),
    'archive_bytes': len(archive), 'image_bytes': 300, 'images': images,
}))
PY
archive_bytes="$(wc -c < "$tmp/bundle/images.tar.gz" | tr -d ' ')"
cp deploy/deploy.sh "$tmp/checkout/deploy/"
cp scripts/deploy_image_bundle.py "$tmp/checkout/scripts/"
cat > "$tmp/checkout/deploy/.env" <<'ENV'
NAFIR_DOMAIN=music.example.com
TRANSCRIPTION_TOKEN=0123456789abcdef0123456789abcdef
AUTH_TOKEN_SECRET=fixture-only
POSTGRES_PASSWORD=fixture-only
MINIO_ROOT_USER=fixture-only
MINIO_ROOT_PASSWORD=fixture-only
ENV
printf '# Keep the production override and proxynet configuration.\n' > "$tmp/checkout/deploy/compose.override.yaml"
cp "$tmp/checkout/deploy/.env" "$tmp/env.before"
cp "$tmp/checkout/deploy/compose.override.yaml" "$tmp/override.before"

fail() { echo "$*" >&2; exit 1; }
reset_log() { : > "$MOCK_LOG"; }
expect_failure() {
  if "$@" > "$tmp/output.log" 2>&1; then
    cat "$tmp/output.log" >&2
    fail 'Expected operation to fail.'
  fi
}
assert_absent() {
  if grep -E -- "$1" "$MOCK_LOG"; then fail "Unexpected operation matched: $1"; fi
}
assert_present() { grep -Eq -- "$1" "$MOCK_LOG" || fail "Missing operation: $1"; }
receive() { bash "$root/deploy/receive-deploy-bundle.sh" "$1" "$tmp/checkout" "$revision" "$tree" "$staging" "$archive_bytes" 300; }
stage_fixture() {
  mkdir -p "$staging"
  cp "$tmp/bundle/images.tar.gz" "$tmp/bundle/contract.json" "$staging/"
  cp scripts/deploy_image_bundle.py "$staging/verifier.py"
}
clear_stage() { receive cleanup; }

# Dirty source, unsupported platforms, disk pressure, and non-main revisions
# must all fail before creating staging or changing any running service.
for condition in MOCK_DIRTY=1 MOCK_PLATFORM=linux/arm64 MOCK_FREE_KIB=1 MOCK_NOT_MAIN=1; do
  reset_log
  expect_failure env "$condition" bash deploy/receive-deploy-bundle.sh preflight "$tmp/checkout" "$revision" "$tree" "$staging" "$archive_bytes" 300
  [[ ! -d "$staging" ]] || fail 'Preflight failure created staging.'
  assert_absent 'docker .* (load|up|prune)|git checkout'
done
reset_log
receive preflight
[[ -d "$staging" ]] || fail 'Successful preflight did not create staging.'
clear_stage

# A corrupt archive is rejected before Docker import or checkout.
stage_fixture
printf 'corrupt' >> "$staging/images.tar.gz"
reset_log
expect_failure receive deploy
assert_absent 'docker image load|git checkout|docker compose .*up|curl '
clear_stage

# Import failure and a loaded image identity mismatch cannot change containers.
for condition in MOCK_LOAD_FAIL=1 MOCK_LOADED_MISMATCH=web; do
  stage_fixture
  reset_log
  expect_failure env "$condition" bash deploy/receive-deploy-bundle.sh deploy "$tmp/checkout" "$revision" "$tree" "$staging" "$archive_bytes" 300
  assert_present '^docker image load$'
  assert_absent 'git checkout|docker compose .*up|curl '
  clear_stage
done

# Every release image is checked before checkout and rollout; running identities
# are checked before the health endpoint can declare success.
stage_fixture
reset_log
receive deploy
python3 - "$MOCK_LOG" <<'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
def first(fragment):
    return next(i for i, line in enumerate(lines) if fragment in line)
load = first('docker image load')
checkout = first('git checkout --detach')
up = first(' up -d ')
health = first('curl ')
for service in ('api', 'web', 'transcriber'):
    assert load < first('docker image inspect ghcr.io/mhdolatabadi/rhythmo/' + service + ':') < checkout < up
    assert up < first('ps -q ' + service) < health
assert '--pull never' in lines[up]
assert '--no-build' in lines[up]
PY
assert_absent '(image|system|volume) prune|^docker pull |^docker compose( --profile transcription)? pull |docker rm'
cmp "$tmp/env.before" "$tmp/checkout/deploy/.env"
cmp "$tmp/override.before" "$tmp/checkout/deploy/compose.override.yaml"
clear_stage

# A healthy old process is insufficient: identity mismatch must fail before curl.
stage_fixture
reset_log
expect_failure env MOCK_RUNNING_MISMATCH=web bash "$tmp/checkout/deploy/deploy.sh" "$revision" "$staging" "$tree"
assert_present 'docker compose .*up -d'
assert_absent '^curl '
clear_stage

# Disabled transcription still stages all images, but verifies only api and web.
printf '\nTRANSCRIPTION_DISABLED=true\n' >> "$tmp/checkout/deploy/.env"
stage_fixture
reset_log
receive deploy
assert_present 'docker image inspect .*transcriber:'
assert_absent --profile
assert_absent 'ps -q transcriber'
clear_stage

# A failed or timed-out upload gets exactly three bounded attempts; it never
# invokes the remote deploy phase, and cleanup remains bounded.
export DEPLOY_HOST=deploy.example.com DEPLOY_USER=deployer DEPLOY_PATH="$tmp/checkout"
export GITHUB_RUN_ID="$$" GITHUB_RUN_ATTEMPT=1
reset_log
expect_failure env MOCK_UPLOAD_FAIL=1 bash scripts/transfer-deploy-bundle.sh "$tmp/bundle" "$revision" "$tree"
[[ "$(grep -c 'cat > ' "$MOCK_LOG")" == 3 ]] || fail 'Upload retry count is not bounded to three.'
[[ "$(grep -cx 'timeout 1200' "$MOCK_LOG")" == 3 ]] || fail 'Every upload attempt needs a timeout.'
assert_absent 'bash -s -- deploy '
assert_present 'bash -s -- cleanup '
assert_present '^timeout 60$'
assert_present 'StrictHostKeyChecking=yes.*BatchMode=yes.*ConnectTimeout=20'

reset_log
expect_failure env MOCK_SSH_PREFLIGHT_FAIL=1 bash scripts/transfer-deploy-bundle.sh "$tmp/bundle" "$revision" "$tree"
assert_absent 'cat > |bash -s -- deploy '

# Transfer success sends all three complete files before the one rollout call.
reset_log
bash scripts/transfer-deploy-bundle.sh "$tmp/bundle" "$revision" "$tree"
python3 - "$MOCK_LOG" <<'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
deploy = [i for i, line in enumerate(lines) if 'bash -s -- deploy ' in line]
assert len(deploy) == 1
for name in ('images.tar.gz', 'contract.json', 'verifier.py'):
    uploads = [i for i, line in enumerate(lines) if 'cat > ' in line and name + '.part' in line]
    assert len(uploads) == 1 and uploads[0] < deploy[0]
assert any('bash -s -- cleanup ' in line for line in lines[deploy[0] + 1:])
PY

echo 'SSH image bundle deployment regressions passed.'
