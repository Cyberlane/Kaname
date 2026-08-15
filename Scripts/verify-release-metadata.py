#!/usr/bin/env python3
"""Focused deterministic and fail-closed verification for release metadata."""

from __future__ import annotations

import importlib.util
import json
import pathlib
import tempfile


ROOT = pathlib.Path(__file__).resolve().parent.parent
GENERATOR_PATH = ROOT / "Scripts/generate-release-metadata.py"


def load_generator():
    specification = importlib.util.spec_from_file_location("kaname_release_metadata", GENERATOR_PATH)
    if specification is None or specification.loader is None:
        raise RuntimeError("could not load release metadata generator")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def fixture_inputs(root: pathlib.Path) -> tuple[dict, dict]:
    workspace = root / "workspace"
    dependency = root / "registry/dependency-1.2.3"
    unreachable = root / "registry/unreachable-9.9.9"
    for directory in (workspace, dependency, unreachable):
        directory.mkdir(parents=True)
        (directory / "Cargo.toml").write_text("[package]\nname='fixture'\nversion='1.0.0'\n", encoding="utf-8")
        (directory / "LICENSE-MIT").write_text("Fixture MIT license text.\n", encoding="utf-8")
    root_id = "path+file:///private/workspace#fixture_root@0.1.0"
    dependency_id = f"{GENERATOR.CRATES_IO_SOURCE}#dependency@1.2.3"
    unreachable_id = f"{GENERATOR.CRATES_IO_SOURCE}#unreachable@9.9.9"
    metadata = {
        "resolve": {
            "root": root_id,
            "nodes": [
                {"id": root_id, "deps": [{"pkg": dependency_id}]},
                {"id": dependency_id, "deps": []},
                {"id": unreachable_id, "deps": []},
            ],
        },
        "packages": [
            {
                "id": root_id,
                "name": "fixture_root",
                "version": "0.1.0",
                "source": None,
                "license": None,
                "license_file": None,
                "manifest_path": str(workspace / "Cargo.toml"),
                "repository": None,
            },
            {
                "id": dependency_id,
                "name": "dependency",
                "version": "1.2.3",
                "source": GENERATOR.CRATES_IO_SOURCE,
                "license": "MIT",
                "license_file": None,
                "manifest_path": str(dependency / "Cargo.toml"),
                "repository": "https://example.invalid/dependency",
            },
            {
                "id": unreachable_id,
                "name": "unreachable",
                "version": "9.9.9",
                "source": GENERATOR.CRATES_IO_SOURCE,
                "license": "MIT",
                "license_file": None,
                "manifest_path": str(unreachable / "Cargo.toml"),
                "repository": None,
            },
        ],
    }
    lock = {
        "package": [
            {
                "name": "dependency",
                "version": "1.2.3",
                "source": GENERATOR.CRATES_IO_SOURCE,
                "checksum": "a" * 64,
            },
            {
                "name": "unreachable",
                "version": "9.9.9",
                "source": GENERATOR.CRATES_IO_SOURCE,
                "checksum": "b" * 64,
            },
        ]
    }
    return metadata, lock


def expect_failure(action, contains: str) -> None:
    try:
        action()
    except GENERATOR.ReleaseMetadataError as error:
        assert contains in str(error), (contains, str(error))
    else:
        raise AssertionError(f"expected release metadata failure containing: {contains}")


def verify_fixture() -> None:
    with tempfile.TemporaryDirectory(prefix="kaname-release-metadata-fixture-") as temporary:
        root = pathlib.Path(temporary)
        metadata, lock = fixture_inputs(root)
        packages = GENERATOR.cargo_packages(metadata, lock)
        assert [package["name"] for package in packages] == ["dependency"]
        assert packages[0]["checksum"] == "a" * 64
        assert packages[0]["license_documents"] == [("LICENSE-MIT", "Fixture MIT license text.")]

        swift = {
            "name": "swift-protobuf",
            "version": "1.2.3",
            "revision": "c" * 40,
            "source": "https://example.invalid/swift-protobuf.git",
            "license": "Apache-2.0",
            "license_documents": [("LICENSE.txt", "Fixture Apache license text.")],
        }
        first = root / "first"
        second = root / "second"
        first.mkdir()
        second.mkdir()
        GENERATOR.write_notices(first / "notices.md", swift, packages)
        GENERATOR.write_sbom(first / "sbom.json", swift, packages)
        GENERATOR.write_notices(second / "notices.md", swift, packages)
        GENERATOR.write_sbom(second / "sbom.json", swift, packages)
        assert (first / "notices.md").read_bytes() == (second / "notices.md").read_bytes()
        assert (first / "sbom.json").read_bytes() == (second / "sbom.json").read_bytes()
        serialized = (first / "notices.md").read_text() + (first / "sbom.json").read_text()
        assert temporary not in serialized
        assert "unreachable" not in serialized

        dependency_directory = pathlib.Path(metadata["packages"][1]["manifest_path"]).parent
        (dependency_directory / "LICENSE-MIT").unlink()
        expect_failure(lambda: GENERATOR.cargo_packages(metadata, lock), "license text is missing")
        broken_lock = json.loads(json.dumps(lock))
        broken_lock["package"][0].pop("checksum")
        expect_failure(lambda: GENERATOR.cargo_packages(metadata, broken_lock), "checksum is missing")
        broken_metadata = json.loads(json.dumps(metadata))
        broken_metadata["packages"][1]["source"] = None
        expect_failure(lambda: GENERATOR.cargo_packages(broken_metadata, lock), "required metadata is missing: source")

        reviewed_exceptions = (
            ("jsonschema-regex", "0.49.9"),
            ("jsonschema-value", "0.49.9"),
            ("uuid-simd", "0.8.0"),
            ("vsimd", "0.8.0"),
        )
        for reviewed_name, reviewed_version in reviewed_exceptions:
            reviewed_directory = root / reviewed_name
            reviewed_directory.mkdir()
            reviewed_package = {
                "name": reviewed_name,
                "version": reviewed_version,
                "source": GENERATOR.CRATES_IO_SOURCE,
                "license": "MIT",
                "manifest_path": str(reviewed_directory / "Cargo.toml"),
            }
            documents, reason = GENERATOR.license_documents(reviewed_package)
            assert documents == []
            assert reason == f"{reviewed_name}-{reviewed_version}-mit-text-omitted-from-published-crate"
        reviewed_package["version"] = "0.49.10"
        expect_failure(lambda: GENERATOR.license_documents(reviewed_package), "license text is missing")


def verify_repository_generation() -> None:
    with (
        tempfile.TemporaryDirectory(prefix="kaname-release-metadata-real-a-") as first_temporary,
        tempfile.TemporaryDirectory(prefix="kaname-release-metadata-real-b-") as second_temporary,
    ):
        first = pathlib.Path(first_temporary)
        second = pathlib.Path(second_temporary)
        GENERATOR.generate(first)
        GENERATOR.generate(second)
        for name in ("THIRD_PARTY_NOTICES.md", "Kaname-SBOM.cdx.json"):
            assert (first / name).read_bytes() == (second / name).read_bytes(), name
        serialized = (first / "THIRD_PARTY_NOTICES.md").read_text() + (first / "Kaname-SBOM.cdx.json").read_text()
        assert str(ROOT) not in serialized
        assert str(pathlib.Path.home()) not in serialized
        assert "/.cargo/registry/" not in serialized
        sbom = json.loads((first / "Kaname-SBOM.cdx.json").read_text())
        components = sbom["components"]
        assert not any(component["name"] == "kaname_core" for component in components)
        cargo_components = [component for component in components if component["purl"].startswith("pkg:cargo/")]
        assert cargo_components
        assert all(component.get("hashes", [{}])[0].get("alg") == "SHA-256" for component in cargo_components)
        metadata = GENERATOR.load_cargo_metadata()
        expected_cargo_count = len(GENERATOR.reachable_package_ids(metadata) - {metadata["resolve"]["root"]})
        assert len(cargo_components) == expected_cargo_count


GENERATOR = load_generator()


def main() -> None:
    verify_fixture()
    verify_repository_generation()
    print("Kaname release metadata verification passed.")


if __name__ == "__main__":
    main()
