#!/usr/bin/env python3
"""Prepare and verify an immutable production image bundle for SSH delivery."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time


REPOSITORY = "ghcr.io/mhdolatabadi/rhythmo"
PLATFORM = "linux/amd64"
SERVICES = ("api", "web", "transcriber")
SHA = re.compile(r"[0-9a-f]{40}")
HASH = re.compile(r"[0-9a-f]{64}")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
MANIFESTS = {
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
}
INDEXES = {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
}
COMMAND_TIMEOUT = 120
PULL_TIMEOUT = 300
PULL_ATTEMPTS = 3
SAVE_TIMEOUT = 900
CONTRACT_LIMIT = 16384


class BundleError(Exception):
    """A safe, actionable failure without raw Docker/registry diagnostics."""


def require(condition, message):
    if not condition:
        raise BundleError(message)


def validate_revision(revision, transcriber_tree):
    require(isinstance(revision, str) and SHA.fullmatch(revision), "Invalid revision.")
    require(isinstance(transcriber_tree, str) and SHA.fullmatch(transcriber_tree), "Invalid transcriber tree.")


def image_tag(service, revision, transcriber_tree):
    return f"src-{transcriber_tree}" if service == "transcriber" else revision


def command(arguments, label, timeout=COMMAND_TIMEOUT):
    # Docker errors can contain signed blob redirects. Never relay raw output.
    try:
        result = subprocess.run(
            arguments, check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError, UnicodeError) as error:
        raise BundleError(f"{label} failed or timed out.") from error
    return result.stdout.strip()


def json_document(raw):
    try:
        document = json.loads(raw)
    except (ValueError, TypeError) as error:
        raise BundleError("Invalid image manifest JSON.") from error
    require(isinstance(document, dict), "Expected an image manifest object.")
    return document


def descriptor(value):
    require(isinstance(value, dict), "Invalid image descriptor.")
    digest = value.get("digest")
    require(isinstance(digest, str) and DIGEST.fullmatch(digest), "Invalid image descriptor digest.")
    require(type(value.get("size")) is int and value["size"] > 0, "Image descriptor size must be positive.")
    return digest


def native_manifest(document):
    require(document.get("schemaVersion") == 2, "Expected image schema version 2.")
    media_type = document.get("mediaType")
    if media_type in MANIFESTS:
        descriptor(document.get("config"))
        layers = document.get("layers")
        require(isinstance(layers, list) and len(layers) > 0, "Expected image layers.")
        for layer in layers:
            descriptor(layer)
        return None
    require(media_type in INDEXES, "Unsupported image manifest type.")
    manifests = document.get("manifests")
    require(isinstance(manifests, list), "Expected image manifest descriptors.")
    matches = []
    for item in manifests:
        digest = descriptor(item)
        platform = item.get("platform", {})
        require(isinstance(platform, dict), "Invalid image platform descriptor.")
        if platform.get("os") == "linux" and platform.get("architecture") == "amd64" and not platform.get("variant"):
            require(item.get("mediaType") in MANIFESTS, "Nested native platform indexes are unsupported.")
            matches.append(digest)
    require(len(matches) == 1, "Expected exactly one linux/amd64 image manifest.")
    return matches[0]


def inspect_image(reference):
    identity = command(
        ["docker", "image", "inspect", reference, "--format", "{{.Id}} {{.Os}}/{{.Architecture}} {{.Size}}"],
        "Inspecting image identity",
    ).split()
    require(len(identity) == 3, "Invalid image identity response.")
    image_id, platform, size = identity
    require(DIGEST.fullmatch(image_id) and platform == PLATFORM, "Image identity or platform is invalid.")
    require(size.isascii() and size.isdigit() and int(size) > 0, "Image size is invalid.")
    return image_id, int(size)


def validate_image_identity(image):
    image_id, size = inspect_image(image["reference"])
    require(image_id in (image["config"], image["manifest"]), f"Loaded {image['service']} image differs from the verified contract.")
    return size


def resolve_image(service, revision, transcriber_tree):
    tag = image_tag(service, revision, transcriber_tree)
    repository = f"{REPOSITORY}/{service}"
    reference = f"{repository}:{tag}"
    root = command(
        ["docker", "buildx", "imagetools", "inspect", reference, "--format", "{{.Manifest.Digest}}"],
        f"Resolving {service} image digest",
    )
    require(DIGEST.fullmatch(root), "Invalid published image digest.")
    document = json_document(command(
        ["docker", "buildx", "imagetools", "inspect", f"{repository}@{root}", "--raw"],
        f"Reading {service} image manifest",
    ))
    manifest = native_manifest(document) or root
    if manifest != root:
        document = json_document(command(
            ["docker", "buildx", "imagetools", "inspect", f"{repository}@{manifest}", "--raw"],
            f"Reading native {service} image manifest",
        ))
        require(native_manifest(document) is None, "Expected a native image manifest.")
    config = descriptor(document.get("config"))
    pinned = f"{repository}@{manifest}"
    for attempt in range(PULL_ATTEMPTS):
        try:
            command(["docker", "pull", "--platform", PLATFORM, pinned], f"Pulling {service} image", PULL_TIMEOUT)
            break
        except BundleError:
            if attempt == PULL_ATTEMPTS - 1:
                raise
            time.sleep(5 * (attempt + 1))
    image_id, size = inspect_image(pinned)
    require(image_id in (config, manifest), f"Pulled {service} image differs from the published manifest.")
    command(["docker", "image", "tag", pinned, reference], f"Tagging {service} image")
    return {"service": service, "tag": tag, "reference": reference, "manifest": manifest, "config": config}, size


def save_archive(references, archive):
    # Stream Docker's tar through gzip, without a second uncompressed archive.
    processes = []
    try:
        with archive.open("wb") as output:
            save = subprocess.Popen(["docker", "image", "save", *references], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            processes.append(save)
            compress = subprocess.Popen(["gzip", "-n", "-c"], stdin=save.stdout, stdout=output, stderr=subprocess.DEVNULL)
            processes.append(compress)
            save.stdout.close()
            deadline = time.monotonic() + SAVE_TIMEOUT
            compress_status = compress.wait(timeout=SAVE_TIMEOUT)
            save_status = save.wait(timeout=max(0.01, deadline - time.monotonic()))
            require(compress_status == 0 and save_status == 0, "Saving the image archive failed.")
    except (OSError, subprocess.SubprocessError) as error:
        raise BundleError("Saving the image archive failed or timed out.") from error
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
            process.wait()


def archive_hash(path):
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as archive:
        for chunk in iter(lambda: archive.read(1024 * 1024), b""):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def prepare(revision, transcriber_tree, output_dir):
    validate_revision(revision, transcriber_tree)
    directory = Path(output_dir)
    require(not directory.exists() or directory.is_dir(), "Bundle output must be a directory.")
    require(not (directory / "contract.json").exists() and not (directory / "images.tar.gz").exists(), "Bundle output already contains deployment artifacts.")
    directory.mkdir(parents=True, exist_ok=True)
    images = []
    image_bytes = 0
    for service in SERVICES:
        image, size = resolve_image(service, revision, transcriber_tree)
        images.append(image)
        image_bytes += size
    temporary_paths = []
    installed_archive = False
    try:
        with tempfile.NamedTemporaryFile(prefix=".images-", suffix=".tar.gz", dir=directory, delete=False) as temporary:
            archive = Path(temporary.name)
        temporary_paths.append(archive)
        save_archive([image["reference"] for image in images], archive)
        checksum, size = archive_hash(archive)
        require(size > 0, "Image archive is empty.")
        contract = {
            "version": 1, "revision": revision, "transcriber_tree": transcriber_tree,
            "archive_sha256": checksum, "archive_bytes": size, "image_bytes": image_bytes,
            "images": images,
        }
        with tempfile.NamedTemporaryFile(mode="w", prefix=".contract-", suffix=".json", dir=directory, delete=False, encoding="utf-8") as temporary:
            contract_path = Path(temporary.name)
            temporary_paths.append(contract_path)
            json.dump(contract, temporary, sort_keys=True)
            temporary.write("\n")
        archive.replace(directory / "images.tar.gz")
        installed_archive = True
        contract_path.replace(directory / "contract.json")
    except BaseException:
        if installed_archive:
            (directory / "images.tar.gz").unlink(missing_ok=True)
        raise
    finally:
        for path in temporary_paths:
            path.unlink(missing_ok=True)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate contract field.")
        result[key] = value
    return result


def check(directory, revision, transcriber_tree):
    validate_revision(revision, transcriber_tree)
    directory = Path(directory)
    contract_path = directory / "contract.json"
    archive = directory / "images.tar.gz"
    require(contract_path.is_file() and not contract_path.is_symlink(), "Missing regular bundle contract.")
    require(archive.is_file() and not archive.is_symlink(), "Missing regular image archive.")
    with contract_path.open("rb") as source:
        raw = source.read(CONTRACT_LIMIT + 1)
    require(len(raw) <= CONTRACT_LIMIT, "Bundle contract is too large.")
    try:
        contract = json.loads(raw, object_pairs_hook=unique_object)
    except (ValueError, UnicodeError) as error:
        raise BundleError("Invalid bundle contract JSON.") from error
    require(isinstance(contract, dict) and set(contract) == {"version", "revision", "transcriber_tree", "archive_sha256", "archive_bytes", "image_bytes", "images"}, "Unexpected bundle contract fields.")
    require(type(contract["version"]) is int and contract["version"] == 1, "Unsupported bundle contract version.")
    require(contract["revision"] == revision and contract["transcriber_tree"] == transcriber_tree, "Bundle revision differs from the requested deployment.")
    checksum = contract["archive_sha256"]
    require(isinstance(checksum, str) and HASH.fullmatch(checksum), "Invalid archive checksum.")
    for field in ("archive_bytes", "image_bytes"):
        require(type(contract[field]) is int and contract[field] > 0, "Invalid bundle byte count.")
    images = contract["images"]
    require(isinstance(images, list) and len(images) == len(SERVICES), "Bundle must contain all three application images.")
    for service, image in zip(SERVICES, images):
        require(isinstance(image, dict) and set(image) == {"service", "tag", "reference", "manifest", "config"}, "Unexpected image contract fields.")
        tag = image_tag(service, revision, transcriber_tree)
        require(image["service"] == service and image["tag"] == tag and image["reference"] == f"{REPOSITORY}/{service}:{tag}", "Image reference differs from the requested deployment.")
        for field in ("manifest", "config"):
            require(isinstance(image[field], str) and DIGEST.fullmatch(image[field]), "Invalid image contract digest.")
    require(archive.stat().st_size == contract["archive_bytes"], "Image archive size differs from its contract.")
    actual_checksum, actual_size = archive_hash(archive)
    require(actual_size == contract["archive_bytes"] and actual_checksum == checksum, "Image archive checksum differs from its contract.")
    return contract


def verify(directory, revision, transcriber_tree):
    contract = check(directory, revision, transcriber_tree)
    for image in contract["images"]:
        validate_image_identity(image)


def verify_compose(directory, revision, transcriber_tree, transcription_enabled=False):
    contract = check(directory, revision, transcriber_tree)
    compose = ["docker", "compose"]
    if transcription_enabled:
        compose += ["--profile", "transcription"]
    # Capture expanded configuration: it contains credentials and must not log.
    config = json_document(command([*compose, "config", "--format", "json"], "Validating Compose images"))
    services = config.get("services")
    require(isinstance(services, dict), "Invalid Compose service configuration.")
    for image in contract["images"]:
        service = image["service"]
        if service == "transcriber" and not transcription_enabled:
            continue
        configured = services.get(service, {})
        require(configured.get("image") == image["reference"], f"Compose {service} image differs from the verified release.")
    for service, configured in services.items():
        profiles = configured.get("profiles", [])
        if profiles and not (transcription_enabled and "transcription" in profiles):
            continue
        reference = configured.get("image")
        require(isinstance(reference, str) and reference and not reference.startswith("-"), "Every enabled service needs a local image.")
        command(["docker", "image", "inspect", reference, "--format", "{{.Id}}"], f"Checking local {service} image")


def verify_running(directory, revision, transcriber_tree, transcription_enabled=False):
    contract = check(directory, revision, transcriber_tree)
    compose = ["docker", "compose"]
    if transcription_enabled:
        compose += ["--profile", "transcription"]
    for image in contract["images"]:
        service = image["service"]
        if service == "transcriber" and not transcription_enabled:
            continue
        container = command([*compose, "ps", "-q", service], f"Finding running {service} container")
        require(re.fullmatch(r"[0-9a-f]{12,64}", container), f"Expected exactly one running {service} container.")
        state = command(["docker", "inspect", "--type=container", "--format", "{{.Image}} {{.State.Running}}", container], f"Inspecting running {service} image")
        require(state in (f"{image['config']} true", f"{image['manifest']} true"), f"Running {service} image differs from the bundle contract or has stopped.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    create = subparsers.add_parser("prepare")
    create.add_argument("revision")
    create.add_argument("transcriber_tree")
    create.add_argument("directory")
    for name in ("check", "verify", "verify-compose", "verify-running"):
        subparser = subparsers.add_parser(name)
        subparser.add_argument("directory")
        subparser.add_argument("revision")
        subparser.add_argument("transcriber_tree")
        if name in ("verify-compose", "verify-running"):
            subparser.add_argument("--transcription-enabled", action="store_true")
    arguments = parser.parse_args()
    try:
        if arguments.operation == "prepare":
            prepare(arguments.revision, arguments.transcriber_tree, arguments.directory)
        elif arguments.operation == "check":
            check(arguments.directory, arguments.revision, arguments.transcriber_tree)
        elif arguments.operation == "verify":
            verify(arguments.directory, arguments.revision, arguments.transcriber_tree)
        elif arguments.operation == "verify-compose":
            verify_compose(arguments.directory, arguments.revision, arguments.transcriber_tree, arguments.transcription_enabled)
        else:
            verify_running(arguments.directory, arguments.revision, arguments.transcriber_tree, arguments.transcription_enabled)
    except (BundleError, OSError) as error:
        # OSError may include paths; keep filesystem failures free of user data.
        message = str(error) if isinstance(error, BundleError) else "Cannot read or write deployment bundle files."
        parser.exit(1, f"Deployment bundle: {message}\n")


if __name__ == "__main__":
    main()
