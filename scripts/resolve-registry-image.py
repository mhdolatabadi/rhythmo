#!/usr/bin/env python3
"""Verify a published image and emit a native manifest/config contract."""
import argparse
import json
import re
import subprocess

DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
REPO = re.compile(r"[a-z0-9][a-z0-9.-]*(?::[0-9]+)?/[a-z0-9][a-z0-9._/-]*")
MANIFESTS = {"application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json"}
INDEXES = {"application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json"}


def descriptor(value):
    if not isinstance(value, dict) or not isinstance(value.get("digest"), str) or not DIGEST.fullmatch(value["digest"]):
        raise ValueError("Invalid descriptor digest")
    if type(value.get("size")) is not int or value["size"] <= 0:
        raise ValueError("Descriptor size must be positive")
    return value["digest"]


def native_manifest(document, platform):
    """Ignore attestations; require exactly one directly selectable platform."""
    if document.get("schemaVersion") != 2:
        raise ValueError("Expected schemaVersion 2")
    media = document.get("mediaType")
    if media in MANIFESTS:
        descriptor(document.get("config"))
        layers = document.get("layers")
        if not isinstance(layers, list) or not layers:
            raise ValueError("Expected image layers")
        for layer in layers:
            descriptor(layer)
        return None
    if media not in INDEXES:
        raise ValueError("Unsupported image media type")
    os_name, arch = platform.split("/")
    matches = []
    for item in document.get("manifests", []):
        descriptor(item)
        p = item.get("platform", {})
        if p.get("os") == os_name and p.get("architecture") == arch and not p.get("variant"):
            if item.get("mediaType") not in MANIFESTS:
                raise ValueError("Nested platform indexes are not supported")
            matches.append(item["digest"])
    if len(matches) != 1:
        raise ValueError("Expected exactly one native platform manifest")
    return matches[0]


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True).strip()


def resolve(repository, tag, platform, expected_root=None):
    if not REPO.fullmatch(repository) or ".." in repository or "//" in repository:
        raise ValueError("Expected a registry hostname and repository namespace")
    host = repository.split("/")[0]
    if "." not in host and not host.startswith("localhost:"):
        raise ValueError("Expected an explicit registry hostname")
    if host in {"ghcr.io", "mirror-docker.runflare.com"}:
        raise ValueError("Production requires an owned regional registry")
    if not re.fullmatch(r"[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}", tag):
        raise ValueError("Invalid immutable tag")
    if platform != "linux/amd64":
        raise ValueError("Only the built linux/amd64 production platform is supported")
    reference = f"{repository}:{tag}"
    root = docker("buildx", "imagetools", "inspect", reference, "--format", "{{.Manifest.Digest}}")
    if not DIGEST.fullmatch(root) or (expected_root and root != expected_root):
        raise ValueError("Published registry digest differs from build output")
    doc = json.loads(docker("buildx", "imagetools", "inspect", f"{repository}@{root}", "--raw"))
    digest = native_manifest(doc, platform) or root
    if digest != root:
        doc = json.loads(docker("buildx", "imagetools", "inspect", f"{repository}@{digest}", "--raw"))
        if native_manifest(doc, platform) is not None:
            raise ValueError("Expected a native image manifest")
    config = descriptor(doc["config"])
    pinned = f"{repository}@{digest}"
    # Manifest HEAD alone cannot prove blob reachability. Pull every layer.
    subprocess.run(["docker", "pull", "--platform", platform, pinned], check=True)
    identity = docker("image", "inspect", pinned, "--format", "{{.Id}} {{.Os}}/{{.Architecture}}")
    if identity != f"{config} {platform}":
        raise ValueError("Pulled image config or platform differs from published contract")
    return digest, config


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("repository")
    p.add_argument("tag")
    p.add_argument("--platform", default="linux/amd64")
    p.add_argument("--expected-root")
    p.add_argument("--output", required=True)
    p.add_argument("--prefix", choices=["api", "web", "transcriber"], required=True)
    a = p.parse_args()
    digest, config = resolve(a.repository, a.tag, a.platform, a.expected_root)
    with open(a.output, "a", encoding="utf-8") as output:
        output.write(f"{a.prefix}_digest={digest}\n{a.prefix}_config={config}\n")


if __name__ == "__main__":
    main()
