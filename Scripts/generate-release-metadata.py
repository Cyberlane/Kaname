#!/usr/bin/env python3
"""Generate deterministic, path-free notices and a CycloneDX SBOM."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parent.parent
CARGO_MANIFEST = ROOT / "Rust/KanameCore/Cargo.toml"
CARGO_LOCK = ROOT / "Rust/KanameCore/Cargo.lock"
SWIFT_RESOLVED = ROOT / "Package.resolved"
SWIFT_PROTOBUF_CHECKOUT = ROOT / ".build/checkouts/swift-protobuf"
CARGO_TARGET = "aarch64-apple-darwin"
CRATES_IO_SOURCE = "registry+https://github.com/rust-lang/crates.io-index"
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")

# Reviewed 2026-08-10 against the exact 3.2.0 package metadata and upstream
# repository. These packages declare MIT but omit license text from their
# published crate archives. Any name, version, source, or license drift fails.
REVIEWED_LICENSE_TEXT_ALLOWLIST: dict[tuple[str, str, str, str], str] = {
    (name, "3.2.0", CRATES_IO_SOURCE, "MIT"): "protoc-bin-vendored-3.2.0-mit-text-omitted-upstream"
    for name in (
        "protoc-bin-vendored",
        "protoc-bin-vendored-linux-aarch_64",
        "protoc-bin-vendored-linux-ppcle_64",
        "protoc-bin-vendored-linux-s390_64",
        "protoc-bin-vendored-linux-x86_32",
        "protoc-bin-vendored-linux-x86_64",
        "protoc-bin-vendored-macos-aarch_64",
        "protoc-bin-vendored-macos-x86_64",
        "protoc-bin-vendored-win32",
    )
}


class ReleaseMetadataError(RuntimeError):
    """Release metadata is incomplete or cannot be proven from locked inputs."""


def load_cargo_metadata() -> dict[str, Any]:
    command = [
        "cargo",
        "metadata",
        "--locked",
        "--offline",
        "--filter-platform",
        CARGO_TARGET,
        "--format-version",
        "1",
        "--manifest-path",
        str(CARGO_MANIFEST),
    ]
    completed = subprocess.run(command, cwd=ROOT, check=True, capture_output=True, text=True)
    return json.loads(completed.stdout)


def load_cargo_lock() -> dict[str, Any]:
    import tomllib

    return tomllib.loads(CARGO_LOCK.read_text(encoding="utf-8"))


def reachable_package_ids(metadata: dict[str, Any]) -> set[str]:
    resolution = metadata.get("resolve")
    if not isinstance(resolution, dict) or not isinstance(resolution.get("root"), str):
        raise ReleaseMetadataError("cargo metadata did not provide a resolved workspace root")
    nodes = {node["id"]: node for node in resolution.get("nodes", []) if isinstance(node, dict) and "id" in node}
    root_id = resolution["root"]
    pending = [root_id]
    reachable: set[str] = set()
    while pending:
        package_id = pending.pop()
        if package_id in reachable:
            continue
        node = nodes.get(package_id)
        if node is None:
            raise ReleaseMetadataError(f"resolved package node is missing: {package_id}")
        reachable.add(package_id)
        for dependency in node.get("deps", []):
            dependency_id = dependency.get("pkg") if isinstance(dependency, dict) else None
            if not isinstance(dependency_id, str):
                raise ReleaseMetadataError(f"resolved dependency is malformed for: {package_id}")
            pending.append(dependency_id)
    return reachable


def license_documents(package: dict[str, Any]) -> tuple[list[tuple[str, str]], str | None]:
    name = required_string(package, "name")
    version = required_string(package, "version")
    source = required_string(package, "source")
    license_expression = required_string(package, "license")
    manifest_path = pathlib.Path(required_string(package, "manifest_path"))
    package_directory = manifest_path.parent.resolve()
    candidates: list[pathlib.Path]
    if package.get("license_file"):
        candidates = [pathlib.Path(required_string(package, "license_file"))]
    else:
        candidates = sorted(
            (
                path
                for path in package_directory.iterdir()
                if path.is_file() and path.name.upper().startswith(("LICENSE", "COPYING", "UNLICENSE"))
            ),
            key=lambda path: path.name,
        )
    documents: list[tuple[str, str]] = []
    for candidate in candidates:
        resolved = candidate.resolve()
        if resolved == package_directory or package_directory not in resolved.parents:
            raise ReleaseMetadataError(f"license file escapes package directory: {name} {version}")
        if candidate.is_symlink() or not candidate.is_file():
            raise ReleaseMetadataError(f"license file is not a regular local file: {name} {version}")
        text = candidate.read_text(encoding="utf-8", errors="strict").strip()
        if not text:
            raise ReleaseMetadataError(f"license file is empty: {name} {version}")
        documents.append((candidate.name, text))
    allowlist_key = (name, version, source, license_expression)
    if documents:
        return documents, None
    reason = REVIEWED_LICENSE_TEXT_ALLOWLIST.get(allowlist_key)
    if reason is None:
        raise ReleaseMetadataError(f"license text is missing and not reviewed: {name} {version}")
    return [], reason


def cargo_packages(metadata: dict[str, Any], lock: dict[str, Any]) -> list[dict[str, Any]]:
    resolution = metadata["resolve"]
    root_id = resolution["root"]
    reachable = reachable_package_ids(metadata)
    packages_by_id = {package["id"]: package for package in metadata.get("packages", [])}
    lock_by_key = {
        (package.get("name"), str(package.get("version")), package.get("source")): package
        for package in lock.get("package", [])
    }
    packages: list[dict[str, Any]] = []
    for package_id in sorted(reachable - {root_id}):
        package = packages_by_id.get(package_id)
        if package is None:
            raise ReleaseMetadataError(f"reachable package metadata is missing: {package_id}")
        name = required_string(package, "name")
        version = required_string(package, "version")
        source = required_string(package, "source")
        license_expression = required_string(package, "license")
        locked = lock_by_key.get((name, version, source))
        if locked is None:
            raise ReleaseMetadataError(f"reachable package is absent from Cargo.lock: {name} {version}")
        checksum = locked.get("checksum")
        if not isinstance(checksum, str) or SHA256_PATTERN.fullmatch(checksum) is None:
            raise ReleaseMetadataError(f"locked SHA-256 checksum is missing: {name} {version}")
        documents, allowlist_reason = license_documents(package)
        repository = package.get("repository")
        if repository is not None and not isinstance(repository, str):
            raise ReleaseMetadataError(f"repository metadata is malformed: {name} {version}")
        packages.append(
            {
                "name": name,
                "version": version,
                "source": source,
                "checksum": checksum,
                "license": license_expression,
                "repository": repository or "",
                "license_documents": documents,
                "license_allowlist_reason": allowlist_reason,
            }
        )
    return sorted(packages, key=lambda item: (item["name"], item["version"], item["source"]))


def swift_protobuf() -> dict[str, Any]:
    resolved = json.loads(SWIFT_RESOLVED.read_text(encoding="utf-8"))
    pins = [pin for pin in resolved.get("pins", []) if pin.get("identity") == "swift-protobuf"]
    if len(pins) != 1:
        raise ReleaseMetadataError("Package.resolved must contain exactly one swift-protobuf pin")
    pin = pins[0]
    state = pin.get("state")
    if not isinstance(state, dict):
        raise ReleaseMetadataError("swift-protobuf pin state is missing")
    version = required_string(state, "version")
    revision = required_string(state, "revision")
    source = required_string(pin, "location")
    license_path = SWIFT_PROTOBUF_CHECKOUT / "LICENSE.txt"
    if license_path.is_symlink() or not license_path.is_file():
        raise ReleaseMetadataError("swift-protobuf license text is unavailable in the locked checkout")
    license_text = license_path.read_text(encoding="utf-8", errors="strict").strip()
    if not license_text:
        raise ReleaseMetadataError("swift-protobuf license text is empty")
    return {
        "name": "swift-protobuf",
        "version": version,
        "revision": revision,
        "source": source,
        "license": "Apache-2.0",
        "license_documents": [("LICENSE.txt", license_text)],
    }


def required_string(value: dict[str, Any], key: str) -> str:
    result = value.get(key)
    if not isinstance(result, str) or not result.strip():
        raise ReleaseMetadataError(f"required metadata is missing: {key}")
    return result


def write_notices(output: pathlib.Path, swift: dict[str, Any], cargo: list[dict[str, Any]]) -> None:
    sections = [
        "# Kaname Third-Party Notices",
        "",
        f"Generated from the locked dependency graph for {CARGO_TARGET}.",
    ]
    for package in [swift, *cargo]:
        sections.extend(["", f"## {package['name']} {package['version']}", "", f"License: {package['license']}"])
        if package.get("checksum"):
            sections.extend(["", f"Locked SHA-256: {package['checksum']}"])
        if package.get("revision"):
            sections.extend(["", f"Locked revision: {package['revision']}"])
        for document_name, text in package["license_documents"]:
            sections.extend(["", f"### {document_name}", "", text])
        if package.get("license_allowlist_reason"):
            sections.extend(["", f"Reviewed license-text exception: {package['license_allowlist_reason']}"])
    output.write_text("\n".join(sections).rstrip() + "\n", encoding="utf-8")


def write_sbom(output: pathlib.Path, swift: dict[str, Any], cargo: list[dict[str, Any]]) -> None:
    swift_component: dict[str, Any] = {
        "type": "library",
        "name": swift["name"],
        "version": swift["version"],
        "purl": f"pkg:github/apple/swift-protobuf@{swift['version']}",
        "licenses": [{"license": {"id": swift["license"]}}],
        "properties": [
            {"name": "kaname:locked-revision", "value": swift["revision"]},
            {"name": "kaname:source", "value": swift["source"]},
        ],
    }
    components = [swift_component]
    for package in cargo:
        component: dict[str, Any] = {
            "type": "library",
            "name": package["name"],
            "version": package["version"],
            "purl": f"pkg:cargo/{package['name']}@{package['version']}",
            "hashes": [{"alg": "SHA-256", "content": package["checksum"]}],
            "licenses": [{"expression": package["license"]}],
            "properties": [{"name": "kaname:source", "value": package["source"]}],
        }
        if package["repository"]:
            component["externalReferences"] = [{"type": "vcs", "url": package["repository"]}]
        if package["license_allowlist_reason"]:
            component["properties"].append(
                {"name": "kaname:license-text-exception", "value": package["license_allowlist_reason"]}
            )
        components.append(component)
    payload = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "component": {"type": "application", "name": "Kaname"},
            "properties": [{"name": "kaname:cargo-target", "value": CARGO_TARGET}],
        },
        "components": sorted(components, key=lambda item: (str(item["name"]), str(item["version"]))),
    }
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def generate(output_directory: pathlib.Path) -> None:
    output_directory.mkdir(parents=True, exist_ok=True)
    cargo = cargo_packages(load_cargo_metadata(), load_cargo_lock())
    swift = swift_protobuf()
    write_notices(output_directory / "THIRD_PARTY_NOTICES.md", swift, cargo)
    write_sbom(output_directory / "Kaname-SBOM.cdx.json", swift, cargo)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_directory", type=pathlib.Path)
    args = parser.parse_args()
    generate(args.output_directory)


if __name__ == "__main__":
    main()
