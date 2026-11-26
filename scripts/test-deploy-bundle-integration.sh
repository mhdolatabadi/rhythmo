#!/usr/bin/env bash
# Disposable real registry + image export/import; run only on the CI daemon.
set -euo pipefail
cd "$(dirname "$0")/.."
temporary="$(mktemp -d)"
registry="rhythmo-bundle-registry-$$"
builder="rhythmo-bundle-builder-$$"
cleanup() {
  docker buildx rm "$builder" >/dev/null 2>&1 || true
  docker rm -f "$registry" >/dev/null 2>&1 || true
  rm -rf "$temporary"
}
trap cleanup EXIT
docker run -d --name "$registry" -p 5000:5000 registry:2 >/dev/null
cat > "$temporary/buildkit.toml" <<'TOML'
[registry."localhost:5000"]
  http = true
TOML
docker buildx create --name "$builder" --driver docker-container \
  --driver-opt network=host --buildkitd-config "$temporary/buildkit.toml" --use >/dev/null
printf 'rhythmo bundle integrity fixture\n' > "$temporary/payload"
printf 'FROM scratch\nCOPY payload /payload\n' > "$temporary/Dockerfile"
revision=1111111111111111111111111111111111111111
tree=2222222222222222222222222222222222222222
docker buildx build --platform linux/amd64 --provenance=mode=min --push \
  -t "localhost:5000/rhythmo/api:$revision" \
  -t "localhost:5000/rhythmo/web:$revision" \
  -t "localhost:5000/rhythmo/transcriber:src-$tree" "$temporary"
python3 - "$temporary/bundle" "$revision" "$tree" <<'PY'
import importlib.util
import subprocess
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location('bundle', Path('scripts/deploy_image_bundle.py'))
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)
# Dependency injection is confined to this disposable test, never a production
# flag that could redirect a trusted release to an arbitrary registry.
bundle.REPOSITORY = 'localhost:5000/rhythmo'
directory, revision, tree = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
bundle.prepare(revision, tree, directory)
contract = bundle.check(directory, revision, tree)
bundle.verify(directory, revision, tree)
identities = {bundle.inspect_image(image['reference'])[0] for image in contract['images']}
for identity in identities:
    subprocess.run(['docker', 'image', 'rm', '--force', identity], check=True)
for image in contract['images']:
    result = subprocess.run(['docker', 'image', 'inspect', image['reference']], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert result.returncode != 0, 'Fixture image must be absent before import'
subprocess.run(['docker', 'image', 'load', '--input', str(directory / 'images.tar.gz')], check=True)
bundle.verify(directory, revision, tree)
print('Real registry, native manifests, archive export/import and loaded identities passed.')
PY
