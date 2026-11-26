"""Image integrity, isolation and failure tests for SSH deployment bundles."""

import copy
import gzip
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("deploy_image_bundle", Path(__file__).with_name("deploy_image_bundle.py"))
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)
REVISION = "1" * 40
TREE = "2" * 40
ROOT = "sha256:" + "a" * 64
MANIFEST = "sha256:" + "b" * 64
CONFIG = "sha256:" + "c" * 64
LAYER = "sha256:" + "d" * 64
NATIVE_DOCUMENT = {
    "schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "config": {"digest": CONFIG, "size": 100}, "layers": [{"digest": LAYER, "size": 200}],
}
INDEX_DOCUMENT = {
    "schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": [
        {"mediaType": NATIVE_DOCUMENT["mediaType"], "digest": MANIFEST, "size": 500, "platform": {"os": "linux", "architecture": "amd64"}},
        {"mediaType": NATIVE_DOCUMENT["mediaType"], "digest": "sha256:" + "e" * 64, "size": 300, "platform": {"os": "unknown", "architecture": "unknown"}},
    ],
}


def image_contract(service):
    tag = f"src-{TREE}" if service == "transcriber" else REVISION
    return {"service": service, "tag": tag, "reference": f"{bundle.REPOSITORY}/{service}:{tag}", "manifest": MANIFEST, "config": CONFIG}


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.archive = self.directory / "images.tar.gz"
        self.archive.write_bytes(gzip.compress(b"fixture archive", mtime=0))
        checksum, size = bundle.archive_hash(self.archive)
        self.contract = {
            "version": 1, "revision": REVISION, "transcriber_tree": TREE,
            "archive_sha256": checksum, "archive_bytes": size, "image_bytes": 300,
            "images": [image_contract(service) for service in bundle.SERVICES],
        }
        self.write_contract()

    def write_contract(self):
        (self.directory / "contract.json").write_text(json.dumps(self.contract))

    def test_check_validates_without_docker(self):
        with patch.object(bundle, "command") as command:
            self.assertEqual(bundle.check(self.directory, REVISION, TREE), self.contract)
        command.assert_not_called()

    def test_partial_and_corrupt_archives_fail_before_docker(self):
        original = self.archive.read_bytes()
        for content in (original[:-1], bytes([original[0] ^ 1]) + original[1:]):
            with self.subTest(length=len(content)), patch.object(bundle, "command") as command:
                self.archive.write_bytes(content)
                with self.assertRaises(bundle.BundleError):
                    bundle.verify(self.directory, REVISION, TREE)
                command.assert_not_called()

    def test_missing_contract_or_archive_fails(self):
        for name in ("contract.json", "images.tar.gz"):
            path = self.directory / name
            content = path.read_bytes()
            path.unlink()
            with self.subTest(name=name), self.assertRaises(bundle.BundleError):
                bundle.check(self.directory, REVISION, TREE)
            path.write_bytes(content)

    def test_symlink_archive_rejected(self):
        actual = self.directory / "actual.tar.gz"
        self.archive.rename(actual)
        self.archive.symlink_to(actual)
        with self.assertRaises(bundle.BundleError):
            bundle.check(self.directory, REVISION, TREE)

    def test_wrong_revision_or_tree_rejected_before_docker(self):
        for revision, tree in (("3" * 40, TREE), (REVISION, "3" * 40), ("main;id", TREE)):
            with self.subTest(revision=revision, tree=tree), patch.object(bundle, "command") as command, self.assertRaises(bundle.BundleError):
                bundle.verify(self.directory, revision, tree)
            command.assert_not_called()

    def test_strict_contract_rejects_invalid_fields(self):
        original = copy.deepcopy(self.contract)
        mutations = [
            lambda c: c.update(version=True),
            lambda c: c.update(extra="untrusted"),
            lambda c: c.update(archive_bytes=True),
            lambda c: c.update(image_bytes=0),
            lambda c: c.update(archive_sha256="sha256:" + "a" * 64),
            lambda c: c["images"].pop(),
            lambda c: c["images"][0].update(tag="latest"),
            lambda c: c["images"][0].update(reference="registry.example.com/evil:latest"),
            lambda c: c["images"][1].update(service="api"),
            lambda c: c["images"][0].update(manifest="latest"),
            lambda c: c["images"][0].update(config=[]),
            lambda c: c["images"][0].update(platform="linux/arm64"),
        ]
        for index, mutation in enumerate(mutations):
            self.contract = copy.deepcopy(original)
            mutation(self.contract)
            self.write_contract()
            with self.subTest(index=index), self.assertRaises(bundle.BundleError):
                bundle.check(self.directory, REVISION, TREE)

    def test_duplicate_json_fields_rejected(self):
        path = self.directory / "contract.json"
        path.write_text(path.read_text().replace('"version": 1', '"version": 1, "version": 1'))
        with self.assertRaises(bundle.BundleError):
            bundle.check(self.directory, REVISION, TREE)

    def test_loaded_images_accept_classic_and_containerd_identity(self):
        for identity in (CONFIG, MANIFEST):
            with self.subTest(identity=identity), patch.object(bundle, "command", return_value=f"{identity} linux/amd64 999") as command:
                bundle.verify(self.directory, REVISION, TREE)
                self.assertEqual(command.call_count, 3)
                self.assertTrue(all(call.args[0][3].startswith(bundle.REPOSITORY) for call in command.call_args_list))

    def test_loaded_wrong_identity_platform_or_missing_image_fails(self):
        for response in (f"{LAYER} linux/amd64 100", f"{CONFIG} linux/arm64 100", f"{CONFIG} linux/amd64 0", ""):
            with self.subTest(response=response), patch.object(bundle, "command", return_value=response), self.assertRaises(bundle.BundleError):
                bundle.verify(self.directory, REVISION, TREE)

    def test_running_verification_checks_enabled_services(self):
        container = "f" * 64
        for enabled, count in ((False, 2), (True, 3)):
            with self.subTest(enabled=enabled), patch.object(bundle, "command", side_effect=[container, MANIFEST + " true"] * count) as command:
                bundle.verify_running(self.directory, REVISION, TREE, enabled)
                self.assertEqual(command.call_count, count * 2)
                compose_calls = [call.args[0] for call in command.call_args_list[::2]]
                self.assertEqual([call[-1] for call in compose_calls], list(bundle.SERVICES[:count]))
                self.assertEqual("--profile" in compose_calls[0], enabled)

    def test_running_missing_multiple_or_wrong_image_fails(self):
        for responses in ([""], ["f" * 64 + "\n" + "a" * 64], ["f" * 64, LAYER + " true"], ["f" * 64, CONFIG + " false"]):
            with self.subTest(responses=responses), patch.object(bundle, "command", side_effect=responses), self.assertRaises(bundle.BundleError):
                bundle.verify_running(self.directory, REVISION, TREE)

    def test_compose_requires_release_refs_and_local_infrastructure(self):
        config = {"services": {image["service"]: {"image": image["reference"]} for image in self.contract["images"]}}
        config["services"]["postgres"] = {"image": "postgres:16-alpine"}
        with patch.object(bundle, "command", side_effect=[json.dumps(config)] + [CONFIG] * 4) as command:
            bundle.verify_compose(self.directory, REVISION, TREE, True)
            self.assertEqual(command.call_count, 5)
        config["services"]["web"]["image"] = "old/web:latest"
        with patch.object(bundle, "command", return_value=json.dumps(config)), self.assertRaises(bundle.BundleError):
            bundle.verify_compose(self.directory, REVISION, TREE, True)
        config["services"]["web"]["image"] = self.contract["images"][1]["reference"]
        with patch.object(bundle, "command", side_effect=[json.dumps(config), CONFIG, CONFIG, CONFIG, bundle.BundleError("Missing infrastructure image")]), self.assertRaises(bundle.BundleError):
            bundle.verify_compose(self.directory, REVISION, TREE, True)



class PreparationTests(unittest.TestCase):
    def resolve_responses(self, identity=CONFIG):
        return [ROOT, json.dumps(INDEX_DOCUMENT), json.dumps(NATIVE_DOCUMENT), "", f"{identity} linux/amd64 100", ""]

    def test_native_manifest_selected_and_digest_pulled_before_tagging(self):
        for identity in (CONFIG, MANIFEST):
            with self.subTest(identity=identity), patch.object(bundle, "command", side_effect=self.resolve_responses(identity)) as command:
                image, size = bundle.resolve_image("api", REVISION, TREE)
            self.assertEqual((image, size), (image_contract("api"), 100))
            self.assertEqual(command.call_args_list[3].args[0], ["docker", "pull", "--platform", "linux/amd64", f"{bundle.REPOSITORY}/api@{MANIFEST}"])
            self.assertEqual(command.call_args_list[-1].args[0][1:3], ["image", "tag"])

    def test_invalid_manifests_rejected(self):
        malformed = []
        document = copy.deepcopy(INDEX_DOCUMENT)
        document["manifests"][0]["size"] = 0
        malformed.append(document)
        document = copy.deepcopy(INDEX_DOCUMENT)
        document["manifests"][0]["platform"]["architecture"] = "arm64"
        malformed.append(document)
        document = copy.deepcopy(INDEX_DOCUMENT)
        document["manifests"].append(copy.deepcopy(document["manifests"][0]))
        malformed.append(document)
        document = copy.deepcopy(INDEX_DOCUMENT)
        document["manifests"][0]["mediaType"] = INDEX_DOCUMENT["mediaType"]
        malformed.append(document)
        document = copy.deepcopy(NATIVE_DOCUMENT)
        document["config"]["digest"] = "latest"
        malformed.append(document)
        for document in malformed:
            with self.subTest(document=document), self.assertRaises(bundle.BundleError):
                bundle.native_manifest(document)

    def test_failed_pull_is_bounded_and_never_tags(self):
        responses = self.resolve_responses()[:3] + [bundle.BundleError("Pull failed.")] * bundle.PULL_ATTEMPTS
        with patch.object(bundle, "command", side_effect=responses) as command, patch.object(bundle.time, "sleep") as sleep, self.assertRaises(bundle.BundleError):
            bundle.resolve_image("api", REVISION, TREE)
        self.assertEqual(command.call_count, 3 + bundle.PULL_ATTEMPTS)
        self.assertEqual(sleep.call_count, bundle.PULL_ATTEMPTS - 1)
        self.assertFalse(any(call.args[0][1:3] == ["image", "tag"] for call in command.call_args_list))

    def test_wrong_pulled_image_never_tagged(self):
        with patch.object(bundle, "command", side_effect=self.resolve_responses(LAYER)) as command, self.assertRaises(bundle.BundleError):
            bundle.resolve_image("api", REVISION, TREE)
        self.assertEqual(command.call_count, 5)

    def test_prepare_publishes_complete_bundle_and_rejects_reuse(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            images = [(image_contract(service), 100) for service in bundle.SERVICES]
            with patch.object(bundle, "resolve_image", side_effect=images), patch.object(bundle, "save_archive", side_effect=lambda refs, path: path.write_bytes(gzip.compress(b"complete", mtime=0))):
                bundle.prepare(REVISION, TREE, directory)
            contract = bundle.check(directory, REVISION, TREE)
            self.assertEqual(contract["image_bytes"], 300)
            self.assertEqual(set(path.name for path in directory.iterdir()), {"contract.json", "images.tar.gz"})
            with patch.object(bundle, "resolve_image") as resolve, self.assertRaises(bundle.BundleError):
                bundle.prepare(REVISION, TREE, directory)
            resolve.assert_not_called()

    def test_save_failure_never_leaves_publishable_contract(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            images = [(image_contract(service), 100) for service in bundle.SERVICES]
            with patch.object(bundle, "resolve_image", side_effect=images), patch.object(bundle, "save_archive", side_effect=bundle.BundleError("Save failed.")), self.assertRaises(bundle.BundleError):
                bundle.prepare(REVISION, TREE, directory)
            self.assertEqual(list(directory.iterdir()), [])

    def test_invalid_input_rejected_before_subprocess(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(bundle, "command") as command, self.assertRaises(bundle.BundleError):
            bundle.prepare("main;id", TREE, temporary)
        command.assert_not_called()

    def test_subprocess_failures_are_bounded_and_do_not_disclose_raw_errors(self):
        secret = "https://blob.example/private?signature=secret"
        errors = [subprocess.CalledProcessError(1, ["docker"], stderr=secret), subprocess.TimeoutExpired(["docker"], 120, output=secret)]
        for error in errors:
            with self.subTest(error=type(error).__name__), patch.object(bundle.subprocess, "run", side_effect=error) as run, self.assertRaises(bundle.BundleError) as raised:
                bundle.command(["docker", "version"], "Inspecting Docker")
            self.assertNotIn(secret, str(raised.exception))
            self.assertEqual(run.call_args.kwargs["stderr"], subprocess.DEVNULL)
            self.assertEqual(run.call_args.kwargs["timeout"], bundle.COMMAND_TIMEOUT)


if __name__ == "__main__":
    unittest.main()
