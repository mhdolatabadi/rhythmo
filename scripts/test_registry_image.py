"""Contract regression tests; network and real Docker pulls are separate gates."""
import copy
import importlib.util
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("registry_image", Path(__file__).with_name("resolve-registry-image.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
ROOT = "sha256:" + "a" * 64
LEAF = "sha256:" + "b" * 64
CONFIG = "sha256:" + "c" * 64
LAYER = "sha256:" + "d" * 64
MANIFEST = {"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json", "config": {"digest": CONFIG, "size": 100}, "layers": [{"digest": LAYER, "size": 200}]}
INDEX = {"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": [
    {"mediaType": MANIFEST["mediaType"], "digest": LEAF, "size": 500, "platform": {"os": "linux", "architecture": "amd64"}},
    {"mediaType": MANIFEST["mediaType"], "digest": "sha256:" + "e" * 64, "size": 300, "platform": {"os": "unknown", "architecture": "unknown"}},
]}


class ContractTests(unittest.TestCase):
    def test_oci_index_selects_native_image_not_attestation(self):
        self.assertEqual(m.native_manifest(INDEX, "linux/amd64"), LEAF)

    def test_docker_manifest_and_list_supported(self):
        manifest = copy.deepcopy(MANIFEST)
        manifest["mediaType"] = "application/vnd.docker.distribution.manifest.v2+json"
        self.assertIsNone(m.native_manifest(manifest, "linux/amd64"))
        index = copy.deepcopy(INDEX)
        index["mediaType"] = "application/vnd.docker.distribution.manifest.list.v2+json"
        self.assertEqual(m.native_manifest(index, "linux/amd64"), LEAF)

    def test_invalid_or_zero_descriptors_rejected(self):
        for size in [0, -1, "500", True, None]:
            index = copy.deepcopy(INDEX)
            index["manifests"][0]["size"] = size
            with self.subTest(size=size), self.assertRaises(ValueError):
                m.native_manifest(index, "linux/amd64")
        manifest = copy.deepcopy(MANIFEST)
        manifest["layers"][0]["digest"] = "latest"
        with self.assertRaises(ValueError):
            m.native_manifest(manifest, "linux/amd64")

    def test_ambiguous_missing_and_nested_platform_rejected(self):
        for change in ["duplicate", "missing", "nested"]:
            index = copy.deepcopy(INDEX)
            if change == "duplicate":
                index["manifests"].append(index["manifests"][0])
            elif change == "missing":
                index["manifests"][0]["platform"]["architecture"] = "arm64"
            else:
                index["manifests"][0]["mediaType"] = INDEX["mediaType"]
            with self.subTest(change=change), self.assertRaises(ValueError):
                m.native_manifest(index, "linux/amd64")

    def test_invalid_repository_rejected_before_network(self):
        for repo in ["owner/api", "ghcr.io/owner/api", "mirror-docker.runflare.com/owner/api", "https://registry.example.com/app", "registry.example.com/a/../api", "registry.example.com/a//api", "user:pass@registry.example.com/app", "registry.example.com/a;id"]:
            with self.subTest(repo=repo), patch.object(m, "docker") as docker, self.assertRaises(ValueError):
                m.resolve(repo, "abc", "linux/amd64")
            docker.assert_not_called()

    def test_registry_digest_mismatch_stops_before_full_pull(self):
        with patch.object(m, "docker", return_value=ROOT), patch.object(m.subprocess, "run") as pull:
            with self.assertRaises(ValueError):
                m.resolve("registry.example.com/app/api", "abc", "linux/amd64", LEAF)
            pull.assert_not_called()

    def test_full_pull_and_config_identity_required(self):
        import json
        responses = [ROOT, json.dumps(INDEX), json.dumps(MANIFEST), f"{CONFIG} linux/amd64"]
        with patch.object(m, "docker", side_effect=responses), patch.object(m.subprocess, "run") as pull:
            self.assertEqual(m.resolve("registry.example.com/app/api", "abc", "linux/amd64", ROOT), (LEAF, CONFIG))
            pull.assert_called_once_with(["docker", "pull", "--platform", "linux/amd64", f"registry.example.com/app/api@{LEAF}"], check=True)
        for identity in [f"{LAYER} linux/amd64", f"{CONFIG} linux/arm64"]:
            with patch.object(m, "docker", side_effect=responses[:3] + [identity]), patch.object(m.subprocess, "run"), self.assertRaises(ValueError):
                m.resolve("registry.example.com/app/api", "abc", "linux/amd64", ROOT)

    def test_blob_failure_does_not_return_contract(self):
        import json
        with patch.object(m, "docker", side_effect=[ROOT, json.dumps(MANIFEST)]), patch.object(m.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "docker pull")), self.assertRaises(subprocess.CalledProcessError):
            m.resolve("registry.example.com/app/api", "abc", "linux/amd64", ROOT)


if __name__ == "__main__":
    unittest.main()
