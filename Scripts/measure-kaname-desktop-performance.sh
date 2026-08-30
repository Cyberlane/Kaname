#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  measure-kaname-desktop-performance.sh \
    --app <Kaname Candidate.app> \
    --output <receipt.json> \
    --dataset <deterministic-dataset-manifest> \
    --repetitions <1-100> \
    --runtime-authorized

Fixture tests replace --runtime-authorized with --fixture-driver <executable>.
The runtime-authorized flag is an operator assertion for this invocation only.
It is not stored owner authority, owner acceptance, or authorization for a later run.
EOF
}

fail() {
    echo "$1" >&2
    exit 2
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path=""
output_path=""
dataset_path=""
repetitions=""
runtime_authorized=false
fixture_driver=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --app)
            [[ -z "$app_path" ]] || fail "--app may be provided only once."
            [[ "$#" -ge 2 && -n "$2" ]] || fail "--app requires a path."
            app_path="$2"
            shift 2
            ;;
        --output)
            [[ -z "$output_path" ]] || fail "--output may be provided only once."
            [[ "$#" -ge 2 && -n "$2" ]] || fail "--output requires a path."
            output_path="$2"
            shift 2
            ;;
        --dataset)
            [[ -z "$dataset_path" ]] || fail "--dataset may be provided only once."
            [[ "$#" -ge 2 && -n "$2" ]] || fail "--dataset requires a path."
            dataset_path="$2"
            shift 2
            ;;
        --repetitions)
            [[ -z "$repetitions" ]] || fail "--repetitions may be provided only once."
            [[ "$#" -ge 2 && -n "$2" ]] || fail "--repetitions requires a value."
            repetitions="$2"
            shift 2
            ;;
        --runtime-authorized)
            [[ "$runtime_authorized" == false ]] || fail "--runtime-authorized may be provided only once."
            runtime_authorized=true
            shift
            ;;
        --fixture-driver)
            [[ -z "$fixture_driver" ]] || fail "--fixture-driver may be provided only once."
            [[ "$#" -ge 2 && -n "$2" ]] || fail "--fixture-driver requires a path."
            fixture_driver="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ -n "$app_path" ]] || fail "--app is required."
[[ -n "$output_path" ]] || fail "--output is required."
[[ -n "$dataset_path" ]] || fail "--dataset is required."
[[ "$repetitions" =~ ^[1-9][0-9]*$ ]] || fail "--repetitions must be a canonical positive integer."
(( ${#repetitions} <= 3 )) || fail "--repetitions must not exceed 100."
(( repetitions <= 100 )) || fail "--repetitions must not exceed 100."
command -v python3 >/dev/null 2>&1 || fail "Required command is unavailable: python3"
[[ -d "$app_path" && ! -L "$app_path" ]] || fail "--app must be a non-symlink application bundle directory."
[[ -f "$dataset_path" && ! -L "$dataset_path" ]] || fail "--dataset must be a non-symlink regular file."
[[ ! -L "$output_path" ]] || fail "--output must not be a symlink."
app_path="$(python3 - "$app_path" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
)"
dataset_path="$(python3 - "$dataset_path" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
)"
output_path="$(python3 - "$output_path" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
)"
output_relation="$(python3 - "$app_path" "$dataset_path" "$output_path" <<'PY'
import pathlib
import sys

app = pathlib.Path(sys.argv[1])
dataset = pathlib.Path(sys.argv[2])
output = pathlib.Path(sys.argv[3])
if output == dataset:
    print("dataset")
elif output == app or app in output.parents:
    print("bundle")
else:
    print("safe")
PY
)"
[[ "$output_relation" != dataset ]] || fail "--output must not replace the dataset input."
[[ "$output_relation" != bundle ]] || fail "--output must not be inside the measured app bundle."
output_parent_snapshot="$(python3 - "$output_path" <<'PY'
import os
import stat
import sys

path = os.path.abspath(sys.argv[1])
parts = [part for part in os.path.dirname(path).split(os.sep) if part]
directory = os.open(os.sep, os.O_RDONLY | os.O_DIRECTORY)
try:
    for component in parts:
        try:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
        except FileNotFoundError:
            os.mkdir(component, 0o755, dir_fd=directory)
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
        os.close(directory)
        directory = child
    try:
        output = os.stat(os.path.basename(path), dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        output = None
    if output is not None and not stat.S_ISREG(output.st_mode):
        raise SystemExit("--output must be a regular file path")
    metadata = os.fstat(directory)
    print(f"{metadata.st_dev}|{metadata.st_ino}")
finally:
    os.close(directory)
PY
)" || fail "--output parent path is unsafe or could not be created."

if [[ -n "$fixture_driver" ]]; then
    [[ "$runtime_authorized" == false ]] || fail "Fixture mode and --runtime-authorized are mutually exclusive."
    [[ -f "$fixture_driver" && -x "$fixture_driver" && ! -L "$fixture_driver" ]] \
        || fail "--fixture-driver must be a non-symlink executable file."
    fixture_driver="$(cd "$(dirname "$fixture_driver")" && pwd -P)/$(basename "$fixture_driver")"
    evidence_lane="fixture"
else
    [[ "$runtime_authorized" == true ]] || {
        fail "A real Candidate measurement requires the one-run --runtime-authorized operator assertion."
    }
    evidence_lane="candidate-runtime"
fi

for required_command in git jq plutil ps python3; do
    command -v "$required_command" >/dev/null 2>&1 || fail "Required command is unavailable: $required_command"
done
if [[ -z "$fixture_driver" ]]; then
    [[ -x /usr/bin/osascript ]] || fail "Required command is unavailable: /usr/bin/osascript"
    [[ -x /usr/bin/perl ]] || fail "Required command is unavailable: /usr/bin/perl"
    command -v lsof >/dev/null 2>&1 || fail "Required command is unavailable: lsof"
    command -v sw_vers >/dev/null 2>&1 || fail "Required command is unavailable: sw_vers"
    command -v uname >/dev/null 2>&1 || fail "Required command is unavailable: uname"
fi

file_digest() {
    python3 - "$1" <<'PY'
import hashlib
import os
import sys

path = os.path.abspath(sys.argv[1])
parts = [part for part in path.split(os.sep) if part]
directory = os.open(os.sep, os.O_RDONLY | os.O_DIRECTORY)
try:
    for component in parts[:-1]:
        child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
        os.close(directory)
        directory = child
    descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
finally:
    os.close(directory)
digest = hashlib.sha256()
try:
    before = os.fstat(descriptor)
    if not __import__("stat").S_ISREG(before.st_mode):
        raise SystemExit("digest input is not a regular file")
    with os.fdopen(descriptor, "rb", closefd=False) as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    after = os.fstat(descriptor)
    if (before.st_dev, before.st_ino, before.st_mode, before.st_nlink, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
        after.st_dev, after.st_ino, after.st_mode, after.st_nlink, after.st_size, after.st_mtime_ns, after.st_ctime_ns
    ):
        raise SystemExit("digest input changed while it was read")
finally:
    os.close(descriptor)
print("|".join(str(value) for value in (
    digest.hexdigest(), before.st_dev, before.st_ino, before.st_mode, before.st_nlink,
    before.st_size, before.st_mtime_ns, before.st_ctime_ns,
)))
PY
}

bundle_digest() {
    python3 - "$1" <<'PY'
import hashlib
import os
import stat
import sys

root = os.path.abspath(sys.argv[1])
directory = os.open(os.sep, os.O_RDONLY | os.O_DIRECTORY)
try:
    for component in [part for part in root.split(os.sep) if part]:
        child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
        os.close(directory)
        directory = child
except BaseException:
    os.close(directory)
    raise
root_stat = os.fstat(directory)
digest = hashlib.sha256(b"kaname-bundle-tree-v1\0")
identity = hashlib.sha256(b"kaname-bundle-identity-v1\0")
def visit(parent, prefix):
    for name in sorted(os.listdir(parent)):
        relative_text = f"{prefix}/{name}" if prefix else name
        relative = relative_text.encode("utf-8")
        metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if stat.S_ISLNK(metadata.st_mode):
            raise SystemExit(f"bundle contains a symlink: {relative_text}")
        if stat.S_ISDIR(metadata.st_mode):
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            try:
                opened = os.fstat(child)
                if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                    raise SystemExit(f"bundle directory identity changed: {relative_text}")
                digest.update(b"D\0" + relative + b"\0")
                identity.update(b"D\0" + relative + b"\0" + repr((opened.st_dev, opened.st_ino, opened.st_mode, opened.st_nlink, opened.st_mtime_ns, opened.st_ctime_ns)).encode("ascii"))
                visit(child, relative_text)
                after = os.fstat(child)
                if (after.st_dev, after.st_ino, after.st_mode, after.st_nlink, after.st_mtime_ns, after.st_ctime_ns) != (opened.st_dev, opened.st_ino, opened.st_mode, opened.st_nlink, opened.st_mtime_ns, opened.st_ctime_ns):
                    raise SystemExit(f"bundle directory changed while read: {relative_text}")
            finally:
                os.close(child)
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise SystemExit(f"bundle contains a non-regular entry: {relative_text}")
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
        try:
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                raise SystemExit(f"bundle file identity changed: {relative_text}")
            content = hashlib.sha256()
            with os.fdopen(descriptor, "rb", closefd=False) as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    content.update(chunk)
            after = os.fstat(descriptor)
            if (after.st_dev, after.st_ino, after.st_mode, after.st_nlink, after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (opened.st_dev, opened.st_ino, opened.st_mode, opened.st_nlink, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns):
                raise SystemExit(f"bundle file changed while read: {relative_text}")
        finally:
            os.close(descriptor)
        executable = b"1" if opened.st_mode & 0o111 else b"0"
        digest.update(b"F\0" + relative + b"\0" + executable + b"\0" + content.digest())
        identity.update(b"F\0" + relative + b"\0" + repr((opened.st_dev, opened.st_ino, opened.st_mode, opened.st_nlink, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns)).encode("ascii"))
try:
    visit(directory, "")
    final_root = os.fstat(directory)
    if (final_root.st_dev, final_root.st_ino, final_root.st_mode, final_root.st_nlink, final_root.st_mtime_ns, final_root.st_ctime_ns) != (root_stat.st_dev, root_stat.st_ino, root_stat.st_mode, root_stat.st_nlink, root_stat.st_mtime_ns, root_stat.st_ctime_ns):
        raise SystemExit("bundle root changed while read")
finally:
    os.close(directory)
print(f"{digest.hexdigest()}|{root_stat.st_dev}|{root_stat.st_ino}|{identity.hexdigest()}")
PY
}

source_digest() {
    python3 - "$repo_root" "$output_path" <<'PY'
import hashlib
import os
import stat
import subprocess
import sys

root = os.path.abspath(sys.argv[1])
output = os.path.abspath(sys.argv[2])
try:
    excluded_output = os.path.relpath(output, root)
    if excluded_output == os.pardir or excluded_output.startswith(os.pardir + os.sep):
        excluded_output = None
except ValueError:
    excluded_output = None
root_descriptor = os.open(os.sep, os.O_RDONLY | os.O_DIRECTORY)
try:
    for component in [part for part in root.split(os.sep) if part]:
        child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_descriptor)
        os.close(root_descriptor)
        root_descriptor = child
except BaseException:
    os.close(root_descriptor)
    raise
root_stat = os.fstat(root_descriptor)
listed = subprocess.run(
    ["git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
    check=True,
    capture_output=True,
).stdout
paths = sorted(path for path in listed.split(b"\0") if path)
digest = hashlib.sha256(b"kaname-git-visible-source-excluding-exact-output-v1\0")
identity = hashlib.sha256(b"kaname-git-visible-source-identity-v1\0")
def open_parent(relative):
    components = relative.split("/")
    parent = os.dup(root_descriptor)
    try:
        for component in components[:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = child
        return parent, components[-1]
    except BaseException:
        os.close(parent)
        raise
try:
    for raw_path in paths:
        relative = raw_path.decode("utf-8", errors="strict")
        if relative == excluded_output:
            continue
        encoded = relative.encode("utf-8")
        try:
            parent, leaf = open_parent(relative)
        except FileNotFoundError:
            digest.update(b"M\0" + encoded + b"\0")
            identity.update(b"M\0" + encoded + b"\0")
            continue
        try:
            try:
                metadata = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                digest.update(b"M\0" + encoded + b"\0")
                identity.update(b"M\0" + encoded + b"\0")
                continue
            if stat.S_ISLNK(metadata.st_mode):
                target = os.readlink(leaf, dir_fd=parent)
                after = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
                if (after.st_dev, after.st_ino, after.st_mode, after.st_nlink, after.st_mtime_ns, after.st_ctime_ns) != (metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_nlink, metadata.st_mtime_ns, metadata.st_ctime_ns):
                    raise SystemExit(f"source symlink changed while read: {relative}")
                digest.update(b"L\0" + encoded + b"\0" + target.encode("utf-8") + b"\0")
                identity.update(b"L\0" + encoded + b"\0" + repr((metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_nlink, metadata.st_size, metadata.st_mtime_ns, metadata.st_ctime_ns)).encode("ascii"))
                continue
            if not stat.S_ISREG(metadata.st_mode):
                raise SystemExit(f"source entry is not regular: {relative}")
            descriptor = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
            try:
                opened = os.fstat(descriptor)
                if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                    raise SystemExit(f"source identity changed: {relative}")
                content = hashlib.sha256()
                with os.fdopen(descriptor, "rb", closefd=False) as handle:
                    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                        content.update(chunk)
                after = os.fstat(descriptor)
                if (after.st_dev, after.st_ino, after.st_mode, after.st_nlink, after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (opened.st_dev, opened.st_ino, opened.st_mode, opened.st_nlink, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns):
                    raise SystemExit(f"source changed while read: {relative}")
            finally:
                os.close(descriptor)
            executable = b"1" if opened.st_mode & 0o111 else b"0"
            digest.update(b"F\0" + encoded + b"\0" + executable + b"\0" + content.digest())
            identity.update(b"F\0" + encoded + b"\0" + repr((opened.st_dev, opened.st_ino, opened.st_mode, opened.st_nlink, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns)).encode("ascii"))
        finally:
            os.close(parent)
    listed_after = subprocess.run(
        ["git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        check=True,
        capture_output=True,
    ).stdout
    if listed_after != listed:
        raise SystemExit("Git-visible source set changed while read")
    final_root = os.fstat(root_descriptor)
    if (final_root.st_dev, final_root.st_ino) != (root_stat.st_dev, root_stat.st_ino):
        raise SystemExit("source root identity changed while read")
finally:
    os.close(root_descriptor)
print(f"{digest.hexdigest()}|{root_stat.st_dev}|{root_stat.st_ino}|{identity.hexdigest()}")
PY
}

validate_digest() {
    [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

read_bundle_metadata() {
    python3 - "$1" <<'PY'
import json
import os
import plistlib
import stat
import sys

path = os.path.abspath(sys.argv[1])
components = [part for part in path.split(os.sep) if part]
directory = os.open(os.sep, os.O_RDONLY | os.O_DIRECTORY)
try:
    for component in components[:-1]:
        child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
        os.close(directory)
        directory = child
    descriptor = os.open(components[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
finally:
    os.close(directory)
try:
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode) or before.st_size > 1024 * 1024:
        raise SystemExit("Info.plist is not a bounded regular file")
    with os.fdopen(descriptor, "rb", closefd=False) as handle:
        metadata = plistlib.load(handle)
    after = os.fstat(descriptor)
    if (after.st_dev, after.st_ino, after.st_mode, after.st_nlink, after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (before.st_dev, before.st_ino, before.st_mode, before.st_nlink, before.st_size, before.st_mtime_ns, before.st_ctime_ns):
        raise SystemExit("Info.plist changed while read")
finally:
    os.close(descriptor)
keys = ("CFBundleExecutable", "CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "KanameDesktopChannel")
result = {key: metadata.get(key) for key in keys}
if any(not isinstance(result[key], str) or not result[key] for key in keys):
    raise SystemExit("Info.plist metadata is missing or malformed")
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
PY
}

install_receipt_atomically() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import json
import os
import secrets
import stat
import sys

source, destination, expected_parent, evidence_lane = sys.argv[1:]
if evidence_lane not in {"fixture", "candidate-runtime"}:
    raise SystemExit("receipt installer evidence lane is invalid")
expected_device, expected_inode = map(int, expected_parent.split("|"))
source_descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
try:
    source_stat = os.fstat(source_descriptor)
    if not stat.S_ISREG(source_stat.st_mode) or source_stat.st_size > 16 * 1024 * 1024:
        raise SystemExit("generated receipt is not a bounded regular file")
    chunks = []
    remaining = 16 * 1024 * 1024 + 1
    while remaining:
        chunk = os.read(source_descriptor, min(65536, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    data = b"".join(chunks)
    after = os.fstat(source_descriptor)
    if (after.st_dev, after.st_ino, after.st_mode, after.st_nlink, after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (source_stat.st_dev, source_stat.st_ino, source_stat.st_mode, source_stat.st_nlink, source_stat.st_size, source_stat.st_mtime_ns, source_stat.st_ctime_ns):
        raise SystemExit("generated receipt changed while read")
finally:
    os.close(source_descriptor)
document = json.loads(data)
expected_keys = {
    "schemaVersion", "generatedAtUnixMillis", "evidenceLane", "authority", "app", "protocol",
    "timing", "environment", "artifacts", "measurements", "failures", "budgets", "passed",
    "evidenceBoundary",
}
if not isinstance(document, dict) or set(document) != expected_keys:
    raise SystemExit("generated receipt has an unexpected top-level shape")
if type(document.get("schemaVersion")) is not int or document["schemaVersion"] != 2:
    raise SystemExit("generated receipt has an unexpected schema version")
if type(document.get("passed")) is not bool:
    raise SystemExit("generated receipt pass state is not boolean")
path = os.path.abspath(destination)
parts = [part for part in os.path.dirname(path).split(os.sep) if part]
directory = os.open(os.sep, os.O_RDONLY | os.O_DIRECTORY)
try:
    for component in parts:
        child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
        os.close(directory)
        directory = child
    parent_stat = os.fstat(directory)
    if (parent_stat.st_dev, parent_stat.st_ino) != (expected_device, expected_inode):
        raise SystemExit("output parent identity changed")
    leaf = os.path.basename(path)
    try:
        existing = os.stat(leaf, dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        existing = None
    if existing is not None and not stat.S_ISREG(existing.st_mode):
        raise SystemExit("output destination became unsafe")
    temporary = f".kaname-performance-receipt.{secrets.token_hex(16)}"
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
        dir_fd=directory,
    )
    try:
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    installed = False
    try:
        fixture_swap = os.environ.get("KANAME_PERFORMANCE_FIXTURE_SWAP_OUTPUT_DURING_INSTALL")
        if fixture_swap:
            if evidence_lane != "fixture":
                raise RuntimeError("fixture output mutation hook is disabled outside fixture mode")
            fixture_parent = os.path.abspath(fixture_swap)
            if fixture_parent != os.path.dirname(path):
                raise RuntimeError("fixture output swap target does not match the bound parent")
            moved = fixture_parent + ".moved-during-install"
            os.rename(fixture_parent, moved)
            os.mkdir(fixture_parent, 0o755)
        os.replace(temporary, leaf, src_dir_fd=directory, dst_dir_fd=directory)
        installed = True
        os.fsync(directory)
        reopened = os.open(os.sep, os.O_RDONLY | os.O_DIRECTORY)
        try:
            for component in parts:
                child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=reopened)
                os.close(reopened)
                reopened = child
            final_parent = os.fstat(reopened)
            if (final_parent.st_dev, final_parent.st_ino) != (expected_device, expected_inode):
                raise RuntimeError("output parent identity changed after atomic install")
        except BaseException:
            if installed:
                try:
                    os.unlink(leaf, dir_fd=directory)
                    os.fsync(directory)
                except FileNotFoundError:
                    pass
            raise
        finally:
            os.close(reopened)
    except BaseException:
        if not installed:
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass
        raise
finally:
    os.close(directory)
print("true" if document.get("passed") is True else "false")
PY
}

output_location="$(python3 - "$repo_root" "$output_path" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2]).resolve(strict=False)
try:
    print(output.relative_to(root).as_posix())
except ValueError:
    print("")
PY
)"
if [[ -n "$output_location" ]] && git -C "$repo_root" ls-files --error-unmatch -- "$output_location" >/dev/null 2>&1; then
    fail "--output must not replace a tracked repository file."
fi
output_excluded_from_source_digest=false
[[ -z "$output_location" ]] || output_excluded_from_source_digest=true

bundle_snapshot_metadata_before="$(bundle_digest "$app_path")"
bundle_digest_metadata_before="${bundle_snapshot_metadata_before%%|*}"
validate_digest "$bundle_digest_metadata_before" || fail "Initial bundle digest generation failed."
info="$app_path/Contents/Info.plist"
bundle_metadata="$(read_bundle_metadata "$info")" || fail "Kaname app Info.plist is missing, unsafe, or malformed."
executable_name="$(printf '%s\n' "$bundle_metadata" | jq -r '.CFBundleExecutable')"
[[ "$executable_name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Kaname executable name is malformed."
executable="$app_path/Contents/MacOS/$executable_name"
[[ -f "$executable" && -x "$executable" && ! -L "$executable" ]] \
    || fail "Kaname executable is missing or unsafe."
channel="$(printf '%s\n' "$bundle_metadata" | jq -r '.KanameDesktopChannel')"
[[ "$channel" == candidate ]] || fail "The performance harness accepts the Candidate channel only."
bundle_identifier="$(printf '%s\n' "$bundle_metadata" | jq -r '.CFBundleIdentifier')"
[[ "$bundle_identifier" == "com.cyberlane.kaname.desktop.candidate" ]] \
    || fail "The performance harness accepts only the canonical Kaname Candidate bundle identifier."
version="$(printf '%s\n' "$bundle_metadata" | jq -r '.CFBundleShortVersionString')"
build="$(printf '%s\n' "$bundle_metadata" | jq -r '.CFBundleVersion')"
[[ -n "$version" && -n "$build" ]] || fail "Kaname version/build metadata is missing."
bundle_snapshot_metadata_after="$(bundle_digest "$app_path")"
bundle_digest_metadata_after="${bundle_snapshot_metadata_after%%|*}"
[[ "$bundle_snapshot_metadata_after" == "$bundle_snapshot_metadata_before" ]] \
    || fail "The app bundle changed while version, build, and channel metadata were read."
bundle_digest_before="$bundle_digest_metadata_after"
bundle_snapshot_before="$bundle_snapshot_metadata_after"

capture_system_environment() {
    local architecture operating_system power_raw power_source battery_line battery_percentage battery_state
    local thermal_level thermal_state thermal_available
    architecture="$(uname -m)"
    operating_system="$(sw_vers -productVersion)"
    power_source="unavailable"
    battery_percentage=""
    battery_state="unavailable"
    if command -v pmset >/dev/null 2>&1; then
        power_raw="$(pmset -g batt 2>/dev/null || true)"
        power_source="$(printf '%s\n' "$power_raw" | sed -n "s/^Now drawing from '\(.*\)'$/\1/p" | head -n 1)"
        [[ -n "$power_source" ]] || power_source="unavailable"
        battery_line="$(printf '%s\n' "$power_raw" | grep -E '[0-9]+%;' | head -n 1 || true)"
        if [[ -n "$battery_line" ]]; then
            battery_percentage="$(printf '%s\n' "$battery_line" | sed -n 's/.*[^0-9]\([0-9][0-9]*\)%;.*/\1/p')"
            battery_state="$(printf '%s\n' "$battery_line" | awk -F';' '{value=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value}')"
            [[ -n "$battery_state" ]] || battery_state="unavailable"
        else
            battery_state="not-present"
        fi
    fi
    thermal_state=""
    thermal_available=false
    if command -v sysctl >/dev/null 2>&1; then
        thermal_level="$(sysctl -n kern.thermal_level 2>/dev/null || true)"
        if [[ "$thermal_level" =~ ^[0-9]+$ ]]; then
            thermal_available=true
            if [[ "$thermal_level" == 0 ]]; then
                thermal_state="nominal"
            else
                thermal_state="level-$thermal_level"
            fi
        fi
    fi
    jq -cn \
        --arg architecture "$architecture" \
        --arg operatingSystemVersion "$operating_system" \
        --arg powerSource "$power_source" \
        --arg batteryState "$battery_state" \
        --arg batteryPercentage "$battery_percentage" \
        --arg thermalState "$thermal_state" \
        --argjson thermalStateAvailable "$thermal_available" \
        '{architecture: $architecture, operatingSystemVersion: $operatingSystemVersion,
          power: {source: $powerSource, batteryState: $batteryState,
                  batteryPercentage: (if $batteryPercentage == "" then null else ($batteryPercentage | tonumber) end)},
          thermalStateAvailable: $thermalStateAvailable,
          thermalState: (if $thermalState == "" then null else $thermalState end)}'
}

capture_lane_value() {
    local fixture_action="$1" system_provider="$2"
    if [[ -n "$fixture_driver" ]]; then
        "$fixture_driver" "$fixture_action"
    else
        "$system_provider"
    fi
}

validate_environment() {
    jq -e '
        type == "object"
        and ((keys | sort) == ["architecture", "operatingSystemVersion", "power", "thermalState", "thermalStateAvailable"])
        and (.architecture | type == "string" and length > 0 and length <= 128)
        and (.operatingSystemVersion | type == "string" and length > 0 and length <= 128)
        and (.power | type == "object")
        and ((.power | keys | sort) == ["batteryPercentage", "batteryState", "source"])
        and (.power.source | type == "string" and length > 0 and length <= 128)
        and (.power.batteryState | type == "string" and length > 0 and length <= 128)
        and (.power.batteryPercentage == null or
             (.power.batteryPercentage | type == "number" and . >= 0 and . <= 100 and floor == .))
        and (.thermalStateAvailable | type == "boolean")
        and (.thermalState == null or (.thermalState | type == "string" and length > 0 and length <= 128))
        and ((.thermalStateAvailable == true and .thermalState != null) or
             (.thermalStateAvailable == false and .thermalState == null))
    ' >/dev/null
}

capture_environment() {
    local captured
    captured="$(capture_lane_value environment capture_system_environment)" || return 1
    printf '%s\n' "$captured" | validate_environment || return 1
    printf '%s\n' "$captured"
}

capture_system_nanoseconds() {
    /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
        -e 'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1e9'
}

now_nanoseconds() {
    local value
    value="$(capture_lane_value clock capture_system_nanoseconds)" || return 1
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}

wall_clock_millis() {
    python3 - <<'PY'
import time
print(time.time_ns() // 1_000_000)
PY
}

foreground_control() {
    local action="$1" pid="$2"
    if [[ -n "$fixture_driver" ]]; then
        "$fixture_driver" "$action" "$pid"
        return
    fi
    case "$action" in
        background)
            /usr/bin/osascript -e \
                "tell application \"System Events\" to set visible of first application process whose unix id is $pid to false" \
                >/dev/null
            ;;
        activate)
            /usr/bin/osascript -e \
                "tell application \"System Events\" to set frontmost of first application process whose unix id is $pid to true" \
                >/dev/null
            ;;
        is-active)
            /usr/bin/osascript -e \
                "tell application \"System Events\" to get frontmost of first application process whose unix id is $pid"
            ;;
        *)
            return 2
            ;;
    esac
}

UI_INVARIANT_CODE=""
UI_INVARIANT_MESSAGE=""
capture_kaname_ui_processes() {
    local snapshot applications pid actual_executable app_bundle process_info bundle_identifier process_channel app_name process_info_plist canonical_bundle
    if [[ -n "$fixture_driver" ]]; then
        applications="$("$fixture_driver" ui-applications)" || return 1
    else
        applications="$(/usr/bin/osascript -l JavaScript <<'JXA'
const systemEvents = Application('System Events');
const processes = systemEvents.applicationProcesses();
if (processes.length > 512) throw new Error('application process inventory exceeds bound');
JSON.stringify(processes.map(process => ({pid: process.unixId(), bundleIdentifier: process.bundleIdentifier() || ''})));
JXA
        )" || return 1
    fi
    printf '%s\n' "$applications" | jq -e '
        type == "array" and length <= 512
        and all(.[]; type == "object" and ((keys | sort) == ["bundleIdentifier", "pid"])
            and (.pid | type == "number" and . > 0 and floor == .)
            and (.bundleIdentifier | type == "string" and length <= 512))
    ' >/dev/null || return 1
    snapshot='[]'
    while IFS= read -r process_info; do
        pid="$(printf '%s\n' "$process_info" | jq -r '.pid')"
        bundle_identifier="$(printf '%s\n' "$process_info" | jq -r '.bundleIdentifier')"
        canonical_bundle=false
        [[ "$bundle_identifier" == com.cyberlane.kaname.desktop* ]] && canonical_bundle=true
        if [[ -n "$fixture_driver" ]]; then
            actual_executable="$("$fixture_driver" ui-executable "$pid")" || return 1
        else
            actual_executable="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
        fi
        if [[ -z "$actual_executable" ]]; then
            [[ "$canonical_bundle" == false ]] || return 1
            continue
        fi
        if [[ "$(basename "$actual_executable")" == KanamePrototype \
            && "$actual_executable" != *.app/Contents/MacOS/* ]]; then
            snapshot="$(jq -cn \
                --argjson processes "$snapshot" \
                --argjson pid "$pid" \
                --arg executable "$actual_executable" \
                '$processes + [{pid: $pid, executable: $executable}]')"
            continue
        fi
        if [[ "$actual_executable" != *.app/Contents/MacOS/* ]]; then
            [[ "$canonical_bundle" == false ]] || return 1
            continue
        fi
        app_bundle="${actual_executable%%.app/Contents/MacOS/*}.app"
        app_name="$(basename "$app_bundle")"
        if [[ ! -d "$app_bundle" || -L "$app_bundle" ]]; then
            [[ "$canonical_bundle" == false && "$app_name" != Kaname* ]] || return 1
            continue
        fi
        process_info_plist="$app_bundle/Contents/Info.plist"
        if [[ ! -f "$process_info_plist" || -L "$process_info_plist" ]]; then
            [[ "$canonical_bundle" == false && "$app_name" != Kaname* ]] || return 1
            continue
        fi
        process_channel="$(plutil -extract KanameDesktopChannel raw "$process_info_plist" 2>/dev/null || true)"
        if [[ "$canonical_bundle" == false \
            && "$process_channel" != stable \
            && "$process_channel" != candidate \
            && "$process_channel" != development \
            && "$app_name" != Kaname* ]]; then
            continue
        fi
        snapshot="$(jq -cn \
            --argjson processes "$snapshot" \
            --argjson pid "$pid" \
            --arg executable "$actual_executable" \
            '$processes + [{pid: $pid, executable: $executable}]')"
    done < <(printf '%s\n' "$applications" | jq -c '.[]')
    printf '%s\n' "$snapshot" | jq -e '
        type == "array" and length <= 16
        and all(.[]; type == "object" and ((keys | sort) == ["executable", "pid"])
            and (.pid | type == "number" and . > 0 and floor == .)
            and (.executable | type == "string" and length <= 4096))
    ' >/dev/null || return 1
    printf '%s\n' "$snapshot"
}

require_no_kaname_ui_processes() {
    local snapshot count
    if ! snapshot="$(capture_kaname_ui_processes)"; then
        UI_INVARIANT_CODE="ui-process-inventory-unavailable"
        UI_INVARIANT_MESSAGE="The Kaname UI process inventory was unavailable or malformed."
        return 1
    fi
    count="$(printf '%s\n' "$snapshot" | jq 'length')"
    if [[ "$count" -ne 0 ]]; then
        UI_INVARIANT_CODE="another-kaname-ui-running"
        UI_INVARIANT_MESSAGE="Another Stable, Candidate, Development, or unknown Kaname UI process is running."
        return 1
    fi
    return 0
}

require_exact_sole_kaname_ui_process() {
    local pid="$1" snapshot
    if [[ "$pid" != "$active_pid" ]] \
        || [[ -z "$active_process_identity" ]] \
        || ! process_matches_spawned_identity "$pid" "$active_process_identity"; then
        UI_INVARIANT_CODE="spawned-process-identity-mismatch"
        UI_INVARIANT_MESSAGE="The measured PID no longer has the exact parent and start-time identity captured at spawn."
        return 1
    fi
    if ! snapshot="$(capture_kaname_ui_processes)"; then
        UI_INVARIANT_CODE="ui-process-inventory-unavailable"
        UI_INVARIANT_MESSAGE="The Kaname UI process inventory was unavailable or malformed."
        return 1
    fi
    if ! printf '%s\n' "$snapshot" | jq -e \
        --argjson pid "$pid" \
        --arg executable "$executable" \
        'length == 1 and .[0].pid == $pid and .[0].executable == $executable' \
        >/dev/null; then
        UI_INVARIANT_CODE="sole-kaname-ui-mismatch"
        UI_INVARIANT_MESSAGE="The measured PID is not the sole Kaname UI process at the exact expected executable path."
        return 1
    fi
    return 0
}

read_process_identity() {
    local pid="$1" identity
    identity="$(ps -p "$pid" -o ppid= -o lstart= 2>/dev/null | awk '{$1=$1; print}')" || return 1
    [[ -n "$identity" ]] || return 1
    printf '%s\n' "$identity"
}

capture_process_identity() {
    local pid="$1" identity
    identity="$(read_process_identity "$pid")" || return 1
    [[ "$identity" == "$$ "* ]] || return 1
    printf '%s\n' "$identity"
}

process_matches_spawned_identity() {
    local pid="$1" expected_identity="$2" observed_identity
    observed_identity="$(capture_process_identity "$pid")" || return 1
    [[ "$observed_identity" == "$expected_identity" ]]
}

process_matches_expected_executable() {
    local pid="$1" actual_executable
    [[ -n "$fixture_driver" ]] && return 0
    actual_executable="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
    [[ "$actual_executable" == "$executable" ]]
}

shell_job_is_running() {
    local expected_pid="$1" job_pid
    while IFS= read -r job_pid; do
        [[ "$job_pid" == "$expected_pid" ]] && return 0
    done < <(jobs -p)
    return 1
}

active_pid=""
active_process_identity=""
TERMINATION_FAILURE_CODE=""
TERMINATION_FAILURE_MESSAGE=""
SPAWN_FAILURE_CODE=""
SPAWN_FAILURE_MESSAGE=""
last_spawned_pid=""
receipt_tmp=""
qa_root="$(mktemp -d "${TMPDIR:-/tmp}/kaname-performance.XXXXXX")"
cleanup() {
    if [[ -n "$active_pid" && -z "$active_process_identity" ]]; then
        terminate_unidentified_spawned_process "$active_pid" >/dev/null 2>&1 || true
    else
        terminate_active_process >/dev/null 2>&1 || true
    fi
    require_no_kaname_ui_processes >/dev/null 2>&1 || true
    [[ -z "$receipt_tmp" || ! -e "$receipt_tmp" ]] || rm -f "$receipt_tmp"
    [[ -n "$qa_root" && -d "$qa_root" ]] && rm -r "$qa_root"
}
trap cleanup EXIT

terminate_active_process() {
    local pid identity attempts process_state observed_identity
    TERMINATION_FAILURE_CODE=""
    TERMINATION_FAILURE_MESSAGE=""
    [[ -n "$active_pid" ]] || return 0
    pid="$active_pid"
    identity="$active_process_identity"
    if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null || true
        active_pid=""
        active_process_identity=""
        return 0
    fi
    if ! shell_job_is_running "$pid" \
        || [[ -z "$identity" ]] \
        || ! process_matches_spawned_identity "$pid" "$identity" \
        || ! process_matches_expected_executable "$pid"; then
        TERMINATION_FAILURE_CODE="termination-identity-mismatch"
        TERMINATION_FAILURE_MESSAGE="The process identity no longer matched the exact spawned child; no termination signal was sent."
        active_pid=""
        active_process_identity=""
        return 1
    fi
    if ! kill "$pid" 2>/dev/null; then
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            active_pid=""
            active_process_identity=""
            return 0
        fi
        TERMINATION_FAILURE_CODE="termination-signal-failed"
        TERMINATION_FAILURE_MESSAGE="SIGTERM could not be delivered to the exact spawned child."
        return 1
    fi
    for (( attempts = 0; attempts < 100; attempts++ )); do
        if ! shell_job_is_running "$pid" || ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            active_pid=""
            active_process_identity=""
            return 0
        fi
        process_state="$(ps -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]')"
        if [[ "$process_state" == Z* ]]; then
            wait "$pid" 2>/dev/null || true
            active_pid=""
            active_process_identity=""
            return 0
        fi
        observed_identity="$(read_process_identity "$pid" 2>/dev/null || true)"
        if [[ -n "$observed_identity" && "$observed_identity" != "$identity" ]]; then
            TERMINATION_FAILURE_CODE="termination-identity-mismatch"
            TERMINATION_FAILURE_MESSAGE="The spawned child exited and its PID identity changed; the replacement process was not signaled."
            active_pid=""
            active_process_identity=""
            return 1
        fi
        sleep 0.01
    done
    if ! shell_job_is_running "$pid" \
        || ! process_matches_spawned_identity "$pid" "$identity" \
        || ! process_matches_expected_executable "$pid"; then
        TERMINATION_FAILURE_CODE="termination-identity-mismatch"
        TERMINATION_FAILURE_MESSAGE="The process identity changed before forced termination; SIGKILL was not sent."
        active_pid=""
        active_process_identity=""
        return 1
    fi
    if ! kill -KILL "$pid" 2>/dev/null; then
        TERMINATION_FAILURE_CODE="forced-termination-signal-failed"
        TERMINATION_FAILURE_MESSAGE="SIGKILL could not be delivered after the exact spawned child ignored SIGTERM."
        return 1
    fi
    TERMINATION_FAILURE_CODE="forced-termination"
    TERMINATION_FAILURE_MESSAGE="The exact spawned child required a bounded SIGKILL after it ignored SIGTERM."
    for (( attempts = 0; attempts < 100; attempts++ )); do
        if ! shell_job_is_running "$pid" || ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            active_pid=""
            active_process_identity=""
            return 1
        fi
        process_state="$(ps -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]')"
        if [[ "$process_state" == Z* ]]; then
            wait "$pid" 2>/dev/null || true
            active_pid=""
            active_process_identity=""
            return 1
        fi
        observed_identity="$(read_process_identity "$pid" 2>/dev/null || true)"
        if [[ -n "$observed_identity" && "$observed_identity" != "$identity" ]]; then
            active_pid=""
            active_process_identity=""
            return 1
        fi
        sleep 0.01
    done
    TERMINATION_FAILURE_CODE="forced-termination-timeout"
    TERMINATION_FAILURE_MESSAGE="The exact spawned child remained observable after bounded SIGTERM and SIGKILL deadlines."
    return 1
}

terminate_unidentified_spawned_process() {
    local pid="$1" attempts
    if ! shell_job_is_running "$pid"; then
        wait "$pid" 2>/dev/null || true
        active_pid=""
        active_process_identity=""
        return 0
    fi
    kill "$pid" 2>/dev/null || true
    for (( attempts = 0; attempts < 100; attempts++ )); do
        if ! shell_job_is_running "$pid"; then
            wait "$pid" 2>/dev/null || true
            active_pid=""
            active_process_identity=""
            return 0
        fi
        sleep 0.01
    done
    if shell_job_is_running "$pid"; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    for (( attempts = 0; attempts < 100; attempts++ )); do
        if ! shell_job_is_running "$pid"; then
            wait "$pid" 2>/dev/null || true
            active_pid=""
            active_process_identity=""
            return 0
        fi
        sleep 0.01
    done
    return 1
}

current_health=""
spawn_process() {
    local support_base="$1" attempts identity
    SPAWN_FAILURE_CODE=""
    SPAWN_FAILURE_MESSAGE=""
    current_health="$support_base/Kaname Candidate/Runtime/ui-health.json"
    rm -f "$current_health"
    "$executable" --desktop-qa-application-support-base "$support_base" >/dev/null 2>&1 &
    active_pid="$!"
    last_spawned_pid="$active_pid"
    active_process_identity=""
    for (( attempts = 0; attempts < 100; attempts++ )); do
        identity="$(capture_process_identity "$active_pid" 2>/dev/null || true)"
        if [[ -n "$identity" ]]; then
            active_process_identity="$identity"
            return 0
        fi
        if ! shell_job_is_running "$active_pid"; then
            wait "$active_pid" 2>/dev/null || true
            active_pid=""
            SPAWN_FAILURE_CODE="process-exited-before-identity"
            SPAWN_FAILURE_MESSAGE="The spawned child exited before its exact process identity could be bound."
            return 1
        fi
        sleep 0.01
    done
    SPAWN_FAILURE_CODE="spawn-identity-unavailable"
    SPAWN_FAILURE_MESSAGE="The exact spawned child identity could not be bound before the one-second deadline."
    if ! terminate_unidentified_spawned_process "$active_pid"; then
        SPAWN_FAILURE_CODE="spawn-identity-cleanup-failed"
        SPAWN_FAILURE_MESSAGE="The exact shell-owned child could not be reaped after process identity capture failed."
    fi
    return 1
}

READY_FAILURE_CODE=""
READY_FAILURE_MESSAGE=""
wait_for_ready() {
    local attempts=0 observed_pid
    while (( attempts < 500 )); do
        if ! process_matches_spawned_identity "$active_pid" "$active_process_identity"; then
            READY_FAILURE_CODE="process-identity-changed-before-ready"
            READY_FAILURE_MESSAGE="The exact spawned process exited or changed identity before publishing its ready receipt."
            return 1
        fi
        if [[ -s "$current_health" ]]; then
            observed_pid="$(jq -r '.processID // 0' "$current_health" 2>/dev/null || true)"
            if [[ "$observed_pid" == "$active_pid" ]]; then
                return 0
            fi
        fi
        attempts=$((attempts + 1))
        sleep 0.01
    done
    READY_FAILURE_CODE="ready-timeout"
    READY_FAILURE_MESSAGE="The exact process did not publish a matching ready receipt before the five-second deadline."
    return 1
}

FOREGROUND_FAILURE_CODE=""
FOREGROUND_FAILURE_MESSAGE=""
wait_for_foreground_state() {
    local expected="$1" pid="$2" attempts=0 observed
    while (( attempts < 500 )); do
        if [[ "$pid" != "$active_pid" ]] \
            || ! process_matches_spawned_identity "$pid" "$active_process_identity"; then
            FOREGROUND_FAILURE_CODE="process-identity-changed-during-resume"
            FOREGROUND_FAILURE_MESSAGE="The exact warm process exited or changed identity before foreground state was confirmed."
            return 1
        fi
        if ! observed="$(foreground_control is-active "$pid" 2>/dev/null)"; then
            FOREGROUND_FAILURE_CODE="foreground-state-unavailable"
            FOREGROUND_FAILURE_MESSAGE="macOS foreground state was unavailable for the exact warm process."
            return 1
        fi
        case "$observed" in
            true|false) ;;
            *)
                FOREGROUND_FAILURE_CODE="foreground-state-malformed"
                FOREGROUND_FAILURE_MESSAGE="macOS returned a malformed foreground state for the exact warm process."
                return 1
                ;;
        esac
        [[ "$observed" == "$expected" ]] && return 0
        attempts=$((attempts + 1))
        sleep 0.01
    done
    FOREGROUND_FAILURE_CODE="foreground-timeout"
    FOREGROUND_FAILURE_MESSAGE="The exact warm process did not reach the requested foreground state before the five-second deadline."
    return 1
}

RESULT_STATUS=""
RESULT_DURATION=""
RESULT_RSS=""
RESULT_PID=""
RESULT_STAGE=""
RESULT_CODE=""
RESULT_MESSAGE=""

set_failure_result() {
    RESULT_STATUS="failure"
    RESULT_DURATION=""
    RESULT_RSS=""
    RESULT_STAGE="$1"
    RESULT_CODE="$2"
    RESULT_MESSAGE="$3"
}

read_resident_kilobytes() {
    local value
    value="$(ps -o rss= -p "$1" 2>/dev/null | tr -d '[:space:]')" || return 1
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$value"
}

measure_cold_launch() {
    local repetition="$1" started ended duration rss support_base
    RESULT_PID=""
    support_base="$qa_root/cold-$repetition"
    mkdir -p "$support_base"
    if ! require_no_kaname_ui_processes; then
        set_failure_result "single-instance-precondition" "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
        return
    fi
    if ! started="$(now_nanoseconds)"; then
        set_failure_result "clock" "clock-unavailable" "The monotonic clock was unavailable before process launch."
        return
    fi
    if ! spawn_process "$support_base"; then
        RESULT_PID="$last_spawned_pid"
        set_failure_result "process-spawn" "$SPAWN_FAILURE_CODE" "$SPAWN_FAILURE_MESSAGE"
        require_no_kaname_ui_processes \
            || append_integrity_failure "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
        return
    fi
    RESULT_PID="$active_pid"
    if ! wait_for_ready; then
        set_failure_result "ready-receipt" "$READY_FAILURE_CODE" "$READY_FAILURE_MESSAGE"
        if ! terminate_active_process; then
            append_termination_integrity_failure "cold-process"
        fi
        require_no_kaname_ui_processes || append_integrity_failure "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
        return
    fi
    if ! require_exact_sole_kaname_ui_process "$active_pid"; then
        set_failure_result "single-instance-postlaunch" "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
        if ! terminate_active_process; then
            append_termination_integrity_failure "cold-process"
        fi
        require_no_kaname_ui_processes || append_integrity_failure "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
        return
    fi
    if ! ended="$(now_nanoseconds)"; then
        set_failure_result "clock" "clock-unavailable" "The monotonic clock was unavailable after the ready receipt."
        if ! terminate_active_process; then
            append_termination_integrity_failure "cold-process"
        fi
        require_no_kaname_ui_processes || append_integrity_failure "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
        return
    fi
    if (( ended < started )); then
        set_failure_result "clock" "clock-moved-backwards" "The monotonic launch clock moved backwards."
        if ! terminate_active_process; then
            append_termination_integrity_failure "cold-process"
        fi
        require_no_kaname_ui_processes || append_integrity_failure "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
        return
    fi
    if ! rss="$(read_resident_kilobytes "$active_pid")"; then
        set_failure_result "resident-memory" "rss-unavailable" "Resident memory was unavailable for the exact ready process."
        if ! terminate_active_process; then
            append_termination_integrity_failure "cold-process"
        fi
        require_no_kaname_ui_processes || append_integrity_failure "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
        return
    fi
    duration=$((ended - started))
    RESULT_STATUS="success"
    RESULT_DURATION="$duration"
    RESULT_RSS="$rss"
    RESULT_STAGE=""
    RESULT_CODE=""
    RESULT_MESSAGE=""
    if ! terminate_active_process; then
        RESULT_STATUS="failure"
        RESULT_STAGE="process-termination"
        RESULT_CODE="$TERMINATION_FAILURE_CODE"
        RESULT_MESSAGE="$TERMINATION_FAILURE_MESSAGE"
    fi
    if ! require_no_kaname_ui_processes; then
        if [[ "$RESULT_STATUS" == success ]]; then
            RESULT_STATUS="failure"
            RESULT_STAGE="single-instance-posttermination"
            RESULT_CODE="$UI_INVARIANT_CODE"
            RESULT_MESSAGE="$UI_INVARIANT_MESSAGE"
        else
            append_integrity_failure "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
        fi
    fi
}

start_warm_process() {
    local support_base="$qa_root/warm"
    mkdir -p "$support_base"
    if ! require_no_kaname_ui_processes; then
        set_failure_result "single-instance-precondition" "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
        return 1
    fi
    if ! spawn_process "$support_base"; then
        RESULT_PID="$last_spawned_pid"
        set_failure_result "warm-process-setup" "$SPAWN_FAILURE_CODE" "$SPAWN_FAILURE_MESSAGE"
        require_no_kaname_ui_processes \
            || append_integrity_failure "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
        return 1
    fi
    RESULT_PID="$active_pid"
    if ! wait_for_ready; then
        set_failure_result "warm-process-setup" "$READY_FAILURE_CODE" "$READY_FAILURE_MESSAGE"
        if ! terminate_active_process; then
            append_termination_integrity_failure "warm-process"
        fi
        require_no_kaname_ui_processes || append_integrity_failure "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
        return 1
    fi
    if ! require_exact_sole_kaname_ui_process "$active_pid"; then
        set_failure_result "single-instance-postlaunch" "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
        if ! terminate_active_process; then
            append_termination_integrity_failure "warm-process"
        fi
        require_no_kaname_ui_processes || append_integrity_failure "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
        return 1
    fi
    return 0
}

measure_warm_resume() {
    local pid="$1" started ended duration rss
    RESULT_PID="$pid"
    if ! require_exact_sole_kaname_ui_process "$pid"; then
        set_failure_result "single-instance-warm-sample" "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
        return
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        set_failure_result "warm-process" "process-not-running" "The exact warm process was not running before the resume attempt."
        return
    fi
    if ! foreground_control background "$pid" >/dev/null 2>&1; then
        set_failure_result "background" "background-request-failed" "The exact warm process could not be backgrounded."
        return
    fi
    if ! wait_for_foreground_state false "$pid"; then
        set_failure_result "background-confirmation" "$FOREGROUND_FAILURE_CODE" "$FOREGROUND_FAILURE_MESSAGE"
        return
    fi
    if ! started="$(now_nanoseconds)"; then
        set_failure_result "clock" "clock-unavailable" "The monotonic clock was unavailable before foreground activation."
        return
    fi
    if ! foreground_control activate "$pid" >/dev/null 2>&1; then
        set_failure_result "foreground-activation" "activation-request-failed" "The exact warm process rejected the foreground activation request."
        return
    fi
    if ! wait_for_foreground_state true "$pid"; then
        set_failure_result "foreground-confirmation" "$FOREGROUND_FAILURE_CODE" "$FOREGROUND_FAILURE_MESSAGE"
        return
    fi
    if ! ended="$(now_nanoseconds)"; then
        set_failure_result "clock" "clock-unavailable" "The monotonic clock was unavailable after foreground confirmation."
        return
    fi
    if (( ended < started )); then
        set_failure_result "clock" "clock-moved-backwards" "The monotonic resume clock moved backwards."
        return
    fi
    if ! rss="$(read_resident_kilobytes "$pid")"; then
        set_failure_result "resident-memory" "rss-unavailable" "Resident memory was unavailable for the exact warm process."
        return
    fi
    duration=$((ended - started))
    RESULT_STATUS="success"
    RESULT_DURATION="$duration"
    RESULT_RSS="$rss"
    RESULT_STAGE=""
    RESULT_CODE=""
    RESULT_MESSAGE=""
    if ! require_exact_sole_kaname_ui_process "$pid"; then
        set_failure_result "single-instance-warm-sample" "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
    fi
}

cold_attempts='[]'
warm_attempts='[]'
integrity_failures='[]'

append_attempt() {
    local metric="$1" repetition="$2" recorded_at target
    recorded_at="$(wall_clock_millis)"
    if [[ "$RESULT_STATUS" == success ]]; then
        target="$(jq -cn \
            --argjson repetition "$repetition" \
            --argjson durationNanoseconds "$RESULT_DURATION" \
            --argjson residentKilobytes "$RESULT_RSS" \
            --argjson processID "$RESULT_PID" \
            --argjson recordedAtUnixMillis "$recorded_at" \
            '{repetition: $repetition, status: "success", durationNanoseconds: $durationNanoseconds,
              residentKilobytes: $residentKilobytes, processID: $processID,
              recordedAtUnixMillis: $recordedAtUnixMillis}')"
    else
        target="$(jq -cn \
            --argjson repetition "$repetition" \
            --argjson processID "${RESULT_PID:-0}" \
            --argjson recordedAtUnixMillis "$recorded_at" \
            --arg stage "$RESULT_STAGE" \
            --arg code "$RESULT_CODE" \
            --arg message "$RESULT_MESSAGE" \
            '{repetition: $repetition, status: "failure", processID: $processID,
              recordedAtUnixMillis: $recordedAtUnixMillis,
              failure: {stage: $stage, code: $code, message: $message}}')"
        if [[ -n "$RESULT_DURATION" && -n "$RESULT_RSS" ]]; then
            target="$(jq -cn \
                --argjson attempt "$target" \
                --argjson observedDurationNanoseconds "$RESULT_DURATION" \
                --argjson observedResidentKilobytes "$RESULT_RSS" \
                '$attempt + {observedDurationNanoseconds: $observedDurationNanoseconds,
                             observedResidentKilobytes: $observedResidentKilobytes}')"
        fi
    fi
    if [[ "$metric" == coldLaunch ]]; then
        cold_attempts="$(jq -cn --argjson attempts "$cold_attempts" --argjson attempt "$target" '$attempts + [$attempt]')"
    else
        warm_attempts="$(jq -cn --argjson attempts "$warm_attempts" --argjson attempt "$target" '$attempts + [$attempt]')"
    fi
}

append_integrity_failure() {
    local code="$1" message="$2" recorded_at
    recorded_at="$(wall_clock_millis)"
    integrity_failures="$(jq -cn \
        --argjson failures "$integrity_failures" \
        --argjson recordedAtUnixMillis "$recorded_at" \
        --arg code "$code" \
        --arg message "$message" \
        '$failures + [{metric: "harness", repetition: 0, stage: "integrity", code: $code,
                       message: $message, recordedAtUnixMillis: $recordedAtUnixMillis}]')"
}

append_termination_integrity_failure() {
    local scope="$1"
    append_integrity_failure "$scope-$TERMINATION_FAILURE_CODE" "$TERMINATION_FAILURE_MESSAGE"
}

dataset_snapshot_before="$(file_digest "$dataset_path")"
dataset_digest_before="${dataset_snapshot_before%%|*}"
source_snapshot_before="$(source_digest)"
source_digest_before="${source_snapshot_before%%|*}"
validate_digest "$dataset_digest_before" || fail "Dataset digest generation failed."
validate_digest "$bundle_digest_before" || fail "Bundle digest generation failed."
validate_digest "$source_digest_before" || fail "Source digest generation failed."
source_revision="$(git -C "$repo_root" rev-parse --verify HEAD)"
source_status="modified"
[[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]] || source_status="clean"
environment_started="$(capture_environment)" || fail "Environment metadata is malformed or unavailable."
started_at="$(wall_clock_millis)"

for (( repetition = 1; repetition <= repetitions; repetition++ )); do
    measure_cold_launch "$repetition"
    append_attempt coldLaunch "$repetition"
done

RESULT_STATUS=""
RESULT_PID=""
if start_warm_process; then
    warm_pid="$active_pid"
    for (( repetition = 1; repetition <= repetitions; repetition++ )); do
        measure_warm_resume "$warm_pid"
        append_attempt warmResume "$repetition"
    done
    if ! terminate_active_process; then
        append_termination_integrity_failure "warm-process"
    fi
    require_no_kaname_ui_processes || append_integrity_failure "$UI_INVARIANT_CODE" "$UI_INVARIANT_MESSAGE"
else
    setup_stage="$RESULT_STAGE"
    setup_code="$RESULT_CODE"
    setup_message="$RESULT_MESSAGE"
    setup_pid="$RESULT_PID"
    for (( repetition = 1; repetition <= repetitions; repetition++ )); do
        RESULT_STATUS="failure"
        RESULT_STAGE="$setup_stage"
        RESULT_CODE="$setup_code"
        RESULT_MESSAGE="$setup_message"
        RESULT_PID="$setup_pid"
        append_attempt warmResume "$repetition"
    done
fi

if ! environment_completed="$(capture_environment)"; then
    environment_completed='null'
    append_integrity_failure "environment-recheck-failed" "Environment metadata could not be captured after the measurement."
fi
if ! dataset_snapshot_after="$(file_digest "$dataset_path" 2>/dev/null)"; then
    dataset_snapshot_after=""
    dataset_digest_after=""
else
    dataset_digest_after="${dataset_snapshot_after%%|*}"
fi
if ! bundle_snapshot_after="$(bundle_digest "$app_path" 2>/dev/null)"; then
    bundle_snapshot_after=""
    bundle_digest_after=""
else
    bundle_digest_after="${bundle_snapshot_after%%|*}"
fi
if ! source_snapshot_after="$(source_digest 2>/dev/null)"; then
    source_snapshot_after=""
    source_digest_after=""
else
    source_digest_after="${source_snapshot_after%%|*}"
fi
[[ "$dataset_snapshot_after" == "$dataset_snapshot_before" ]] \
    || append_integrity_failure "dataset-changed" "The dataset changed while the measurement was running."
[[ "$bundle_snapshot_after" == "$bundle_snapshot_before" ]] \
    || append_integrity_failure "bundle-changed" "The app bundle changed while the measurement was running."
[[ "$source_snapshot_after" == "$source_snapshot_before" ]] \
    || append_integrity_failure "source-changed" "Git-visible source changed while the measurement was running."
dataset_unchanged=false
bundle_unchanged=false
source_unchanged=false
[[ "$dataset_snapshot_after" == "$dataset_snapshot_before" ]] && dataset_unchanged=true
[[ "$bundle_snapshot_after" == "$bundle_snapshot_before" ]] && bundle_unchanged=true
[[ "$source_snapshot_after" == "$source_snapshot_before" ]] && source_unchanged=true
completed_at="$(wall_clock_millis)"

cold_budget_ns=2000000000
warm_budget_ns=1500000000
rss_budget_kb=524288
dataset_identifier="$(basename "$dataset_path")"
receipt_tmp="$qa_root/generated-receipt.json"

jq -n \
    --arg version "$version" \
    --arg build "$build" \
    --arg channel "$channel" \
    --arg evidenceLane "$evidence_lane" \
    --arg datasetIdentifier "$dataset_identifier" \
    --arg datasetDigest "$dataset_digest_before" \
    --arg datasetDigestAfter "$dataset_digest_after" \
    --argjson datasetUnchanged "$dataset_unchanged" \
    --arg sourceRevision "$source_revision" \
    --arg sourceStatus "$source_status" \
    --arg sourceDigest "$source_digest_before" \
    --arg sourceDigestAfter "$source_digest_after" \
    --argjson sourceUnchanged "$source_unchanged" \
    --argjson outputExcludedFromSourceDigest "$output_excluded_from_source_digest" \
    --arg bundleDigest "$bundle_digest_before" \
    --arg bundleDigestAfter "$bundle_digest_after" \
    --argjson bundleUnchanged "$bundle_unchanged" \
    --arg coldDefinition "Fresh packaged process launch from spawn until that exact PID publishes its ready receipt; the application-support root is fresh, but operating-system and filesystem caches are not purged." \
    --arg warmDefinition "Same already-ready process PID from the foreground activation request until macOS reports that exact PID frontmost, after the harness has confirmed it is backgrounded; process launch is excluded." \
    --argjson runtimeAuthorized "$runtime_authorized" \
    --argjson repetitions "$repetitions" \
    --argjson startedAtUnixMillis "$started_at" \
    --argjson completedAtUnixMillis "$completed_at" \
    --argjson environmentStarted "$environment_started" \
    --argjson environmentCompleted "$environment_completed" \
    --argjson coldAttempts "$cold_attempts" \
    --argjson warmAttempts "$warm_attempts" \
    --argjson integrityFailures "$integrity_failures" \
    --argjson coldBudgetNanoseconds "$cold_budget_ns" \
    --argjson warmBudgetNanoseconds "$warm_budget_ns" \
    --argjson residentBudgetKilobytes "$rss_budget_kb" \
    '
    def nearestRank($values; $percentile):
        ($values | sort) as $sorted
        | if ($sorted | length) == 0 then null
          else (($percentile * ($sorted | length)) | ceil | if . < 1 then 1 else . end) as $rank
          | $sorted[$rank - 1]
          end;
    def summary($attempts; $requested; $budget):
        [$attempts[] | select(.status == "success") | .durationNanoseconds] as $durations
        | [$attempts[] | select(.status == "success") | .residentKilobytes] as $resident
        | ([$attempts[] | select(.status == "failure")] | length) as $failures
        | ([$attempts[].repetition] == [range(1; $requested + 1)]) as $repetitionSetComplete
        | {
            requestedRepetitions: $requested,
            repetitionSetComplete: $repetitionSetComplete,
            attemptCount: ($attempts | length),
            sampleCount: ($durations | length),
            failureCount: $failures,
            p50Nanoseconds: nearestRank($durations; 0.50),
            p95Nanoseconds: nearestRank($durations; 0.95),
            p99Nanoseconds: nearestRank($durations; 0.99),
            maximumNanoseconds: (if ($durations | length) == 0 then null else ($durations | max) end),
            maximumResidentKilobytes: (if ($resident | length) == 0 then null else ($resident | max) end),
            budgetNanoseconds: $budget,
            meetsBudget: (
                ($attempts | length) == $requested
                and $repetitionSetComplete
                and ($durations | length) == $requested
                and $failures == 0
                and nearestRank($durations; 0.95) != null
                and nearestRank($durations; 0.95) <= $budget
            )
          };
    summary($coldAttempts; $repetitions; $coldBudgetNanoseconds) as $coldSummary
    | summary($warmAttempts; $repetitions; $warmBudgetNanoseconds) as $warmSummary
    | ([$coldAttempts[], $warmAttempts[]]
       | map(select(.status == "success") | .residentKilobytes)
       | if length == 0 then null else max end) as $maximumResident
    | ([
          ($coldAttempts[] | select(.status == "failure")
           | {metric: "coldLaunch", repetition, stage: .failure.stage, code: .failure.code,
              message: .failure.message, recordedAtUnixMillis}),
          ($warmAttempts[] | select(.status == "failure")
           | {metric: "warmResume", repetition, stage: .failure.stage, code: .failure.code,
              message: .failure.message, recordedAtUnixMillis})
       ] + $integrityFailures) as $failures
    | ($coldSummary.meetsBudget
       and $warmSummary.meetsBudget
       and $maximumResident != null
       and $maximumResident <= $residentBudgetKilobytes
       and ($failures | length) == 0) as $passed
    | {
        schemaVersion: 2,
        generatedAtUnixMillis: $completedAtUnixMillis,
        evidenceLane: $evidenceLane,
        authority: {
          operatorRuntimeAuthorizationAsserted: $runtimeAuthorized,
          statement: "Operator assertion for this invocation only; not stored owner authority, owner acceptance, or authorization for another run."
        },
        app: {version: $version, build: $build, channel: $channel},
        protocol: {
          requestedRepetitionsPerMetric: $repetitions,
          maximumAllowedRepetitionsPerMetric: 100,
          coldLaunchDefinition: $coldDefinition,
          warmForegroundResumeDefinition: $warmDefinition,
          warmResumeUsesSameReadyProcess: true,
          launchExcludedFromWarmResume: true,
          readyDeadlineMilliseconds: 5000,
          percentileMethod: "nearest-rank"
        },
        timing: {startedAtUnixMillis: $startedAtUnixMillis, completedAtUnixMillis: $completedAtUnixMillis},
        environment: {started: $environmentStarted, completed: $environmentCompleted},
        artifacts: {
          dataset: {
            identifier: $datasetIdentifier,
            digestAlgorithm: "sha256-file-v1",
            datasetDigest: $datasetDigest,
            completedDigest: $datasetDigestAfter,
            unchanged: $datasetUnchanged
          },
          source: {
            revision: $sourceRevision,
            worktreeStatus: $sourceStatus,
            digestAlgorithm: "sha256-git-visible-source-excluding-exact-output-v1",
            sourceDigest: $sourceDigest,
            completedDigest: $sourceDigestAfter,
            unchanged: $sourceUnchanged,
            exactOutputReceiptExcluded: $outputExcludedFromSourceDigest,
            bundleProvenanceAsserted: false
          },
          bundle: {
            digestAlgorithm: "sha256-kaname-bundle-tree-v1",
            bundleDigest: $bundleDigest,
            completedDigest: $bundleDigestAfter,
            unchanged: $bundleUnchanged
          }
        },
        measurements: {
          coldLaunch: {attempts: $coldAttempts, summary: $coldSummary},
          warmResume: {attempts: $warmAttempts, summary: $warmSummary},
          maximumResidentKilobytes: $maximumResident
        },
        failures: $failures,
        budgets: {
          coldLaunchNanoseconds: $coldBudgetNanoseconds,
          warmResumeNanoseconds: $warmBudgetNanoseconds,
          maximumResidentKilobytes: $residentBudgetKilobytes,
          warmResumeStatus: "retained pending the separate owner-gated 9B.7 decision"
        },
        passed: $passed,
        evidenceBoundary: {
          candidateRuntimeMeasured: ($evidenceLane == "candidate-runtime"),
          ownerAccepted: false,
          statement: "A passing receipt is local measurement evidence only; it is not Candidate acceptance or release evidence."
        }
      }
    ' > "$receipt_tmp"

receipt_passed="$(install_receipt_atomically "$receipt_tmp" "$output_path" "$output_parent_snapshot" "$evidence_lane")" \
    || fail "The receipt could not be atomically installed into the identity-bound output directory."
rm -f "$receipt_tmp"
receipt_tmp=""
[[ "$receipt_passed" == true ]] || {
    echo "Kaname desktop performance measurement did not pass: $output_path" >&2
    exit 1
}
echo "$output_path"
