#!/usr/bin/env python3
"""Deterministic SwiftUI source inventory for accessibility review leads.

This tool is intentionally lexical. Its findings identify source locations for
human review; they do not prove accessibility behavior, VoiceOver behavior, or
target-native conformance.
"""

from __future__ import annotations

import argparse
from bisect import bisect_right
from collections import Counter
from dataclasses import dataclass
from functools import partial
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tempfile
from typing import Any, Iterable, Iterator


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
DEFAULT_ROOT = SCRIPT_DIRECTORY.parent
SCHEMA_VERSION = 1
TOOL_VERSION = 2
SOURCE_DIGEST_ALGORITHM = "sha256-path-size-content-v1"
EVIDENCE_CLASS = "static-source-review-leads"
PROOF_BOUNDARY = (
    "Lexical source findings are review leads only. A complete report is not proof of "
    "VoiceOver, keyboard, focus, Reduce Motion, large-text, contrast, or runtime behavior."
)

CATEGORY_ORDER = (
    "actionable-control-semantics",
    "color-only-state",
    "fixed-size-risk",
    "reduce-motion",
    "focus-restoration",
)
CATEGORY_DETAILS = {
    "actionable-control-semantics": {
        "title": "Actionable controls without discoverable labels or hints",
        "heuristic": (
            "Each advertised control and actionable tap/long-press gesture is parsed into its "
            "initializer, family-specific label region, and immediately owned outer modifiers. "
            "Missing, empty, image-only, or indeterminate labels remain review leads."
        ),
    },
    "color-only-state": {
        "title": "Conditional or raw state color",
        "heuristic": (
            "A color/style modifier contains a lexical conditional or recognized raw state color. "
            "Nearby text or symbols may make the state accessible, so every result remains a review lead."
        ),
    },
    "fixed-size-risk": {
        "title": "Fixed-size and fixed-font risk",
        "heuristic": (
            "A SwiftUI frame uses width/height or a font uses a fixed system size. Icons and "
            "bounded layout may be intentional; text clipping and target size require review."
        ),
    },
    "reduce-motion": {
        "title": "Motion without a nearby Reduce Motion marker",
        "heuristic": (
            "A motion API has no lexical reduceMotion/accessibilityReduceMotion marker within "
            "30 source lines. Marker proximity is a triage signal, not behavioral proof."
        ),
    },
    "focus-restoration": {
        "title": "Presentation without a nearby focus-restoration marker",
        "heuristic": (
            "A modal/navigation presentation API has no recognized focus state/restoration marker "
            "within 80 source lines. Native focus behavior still requires runtime review."
        ),
    },
}

DEFAULT_CONFIG: dict[str, Any] = {
    "schemaVersion": SCHEMA_VERSION,
    "includeRoots": ["Sources"],
    "categories": list(CATEGORY_ORDER),
    "maxFiles": 10_000,
    "maxFileBytes": 8_000_000,
    "maxFindings": 50_000,
}
CONFIG_KEYS = frozenset(DEFAULT_CONFIG)

CONTROL_FAMILIES = (
    "Button", "Link", "Menu", "NavigationLink", "DisclosureGroup", "Toggle", "Picker",
    "DatePicker", "TextField", "SecureField", "Slider", "Stepper",
)
CONTROL_PATTERN = re.compile(rf"\b({'|'.join(CONTROL_FAMILIES)})\b(?=\s*[<({{])")
POSITIONAL_TITLE_FAMILIES = frozenset(
    family for family in CONTROL_FAMILIES if family != "Slider"
)
DIRECT_LABEL_TRAILING_FAMILIES = frozenset(
    ("Link", "NavigationLink", "Toggle", "DatePicker", "TextField", "SecureField", "Slider", "Stepper")
)
GESTURE_FAMILIES = (
    "onTapGesture",
    "onLongPressGesture",
    "gesture-TapGesture",
    "gesture-LongPressGesture",
    "highPriorityGesture-TapGesture",
    "highPriorityGesture-LongPressGesture",
    "simultaneousGesture-TapGesture",
    "simultaneousGesture-LongPressGesture",
)
DIRECT_GESTURE_PATTERN = re.compile(r"\.(onTapGesture|onLongPressGesture)\b")
COMPOSED_GESTURE_PATTERN = re.compile(
    r"\.(gesture|highPriorityGesture|simultaneousGesture)\s*\("
)
LABEL_CONSTRUCTOR_PATTERN = re.compile(r"\b(Text|Label)\b(?=\s*[<({])")
IMAGE_PATTERN = re.compile(r"\bImage\s*\(|\bsystemImage\s*:")
COLOR_MODIFIER_PATTERN = re.compile(
    r"\.(?:foregroundStyle|foregroundColor|background|fill|stroke|tint)\s*\("
)
RAW_STATE_COLOR_PATTERN = re.compile(
    r"\b(?:Color\.)?(?:red|green|yellow|orange)\b|"
    r"\bNord\.aurora(?:Red|Green|Yellow|Orange)\b|"
    r"\bKanameColor\.(?:selected|active|success|warning|danger|blocked)\b|"
    r"\b(?:status|state|readiness|attention|approval|health)[A-Za-z0-9_]*(?:Tint|Color)\s*\("
)
FIXED_FRAME_PATTERN = re.compile(r"\.frame\s*\(")
FONT_CALL_PATTERN = re.compile(r"\.font\s*\(")
MOTION_PATTERNS = (
    ("withAnimation", re.compile(r"\bwithAnimation\s*[({]")),
    ("animation", re.compile(r"\.animation\s*\(")),
    ("transition", re.compile(r"\.transition\s*\(")),
    ("matchedGeometryEffect", re.compile(r"\.matchedGeometryEffect\s*\(")),
    ("symbolEffect", re.compile(r"\.symbolEffect\s*\(")),
    ("contentTransition", re.compile(r"\.contentTransition\s*\(")),
    ("TimelineView", re.compile(r"\bTimelineView\s*\(")),
    ("phaseAnimator", re.compile(r"\.phaseAnimator\s*\(")),
    ("keyframeAnimator", re.compile(r"\.keyframeAnimator\s*\(")),
    ("repeatForever", re.compile(r"\.repeatForever\s*\(")),
)
REDUCE_MOTION_PATTERN = re.compile(r"\b(?:accessibilityReduceMotion|reduceMotion)\b")
PRESENTATION_PATTERNS = (
    ("sheet", re.compile(r"\.sheet\s*\(")),
    ("popover", re.compile(r"\.popover\s*\(")),
    ("fullScreenCover", re.compile(r"\.fullScreenCover\s*\(")),
    ("navigationDestination", re.compile(r"\.navigationDestination\s*\(")),
    ("confirmationDialog", re.compile(r"\.confirmationDialog\s*\(")),
    ("alert", re.compile(r"\.alert\s*\(")),
    ("fileImporter", re.compile(r"\.fileImporter\s*\(")),
    ("fileExporter", re.compile(r"\.fileExporter\s*\(")),
)
FOCUS_MARKER_PATTERN = re.compile(
    r"@(?:Accessibility)?FocusState\b|\.focused\s*\(|\.accessibilityFocused\s*\(|"
    r"\b(?:restoreFocus|restoresFocus|focusRestoration|lastFocused)\b|"
    r"\brestore[A-Za-z0-9_]*Focus\b|\bfocus[A-Za-z0-9_]*After\b"
)


class AuditError(RuntimeError):
    """A truthful configuration, coverage, or resource-bound failure."""


@dataclass(frozen=True)
class SourceFile:
    path: str
    filesystem_path: Path
    stat_identity: tuple[int, int, int, int]
    data: bytes
    sha256: str
    text: str
    code: str
    ui_candidate: bool


@dataclass(frozen=True)
class StableFile:
    path: Path
    label: str
    stat_identity: tuple[int, int, int, int]
    data: bytes
    sha256: str


@dataclass(frozen=True)
class ArgumentSpan:
    name: str | None
    start: int
    end: int


@dataclass(frozen=True)
class ClosureSpan:
    name: str | None
    start: int
    end: int


@dataclass(frozen=True)
class ModifierSpan:
    name: str
    start: int
    end: int


@dataclass(frozen=True)
class ControlOccurrence:
    family: str
    start: int
    end: int
    arguments: tuple[ArgumentSpan, ...]
    closures: tuple[ClosureSpan, ...]
    modifiers: tuple[ModifierSpan, ...]


@dataclass(frozen=True)
class GestureOccurrence:
    family: str
    start: int
    end: int
    modifiers: tuple[ModifierSpan, ...]


@dataclass(frozen=True)
class ActionableAnalysis:
    findings: tuple[dict[str, object], ...]
    control_counts: Counter[str]
    gesture_counts: Counter[str]


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def validate_relative_path(value: object, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise AuditError(f"{field} entries must be non-empty strings")
    path = PurePosixPath(value)
    if path.is_absolute() or path == PurePosixPath(".") or ".." in path.parts:
        raise AuditError(f"{field} entry must be a repository-relative path: {value!r}")
    normalized = path.as_posix()
    if normalized != value or "\\" in value:
        raise AuditError(f"{field} entry is not normalized POSIX syntax: {value!r}")
    return normalized


def positive_integer(value: object, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise AuditError(f"{field} must be a positive integer")
    return value


def file_identity(metadata: os.stat_result) -> tuple[int, int, int, int]:
    return (metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns)


def read_stable_path(path: Path, label: str, max_bytes: int | None = None) -> StableFile:
    """Read one regular file through a no-follow descriptor and bind its content."""

    try:
        before = os.lstat(path)
    except OSError as error:
        raise AuditError(f"could not inspect {label}: {error}") from error
    if stat.S_ISLNK(before.st_mode):
        raise AuditError(f"refuses symlinked file: {label}")
    if not stat.S_ISREG(before.st_mode):
        raise AuditError(f"expected a regular file: {label}")
    if max_bytes is not None and before.st_size > max_bytes:
        raise AuditError(f"coverage limit exceeded for {label}: {before.st_size} bytes > maxFileBytes {max_bytes}")

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise AuditError(f"could not open {label} without following symlinks: {error}") from error
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise AuditError(f"expected a regular opened file: {label}")
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise AuditError(f"file changed before it was opened: {label}")
        chunks: list[bytes] = []
        byte_count = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            byte_count += len(chunk)
            if max_bytes is not None and byte_count > max_bytes:
                raise AuditError(f"coverage limit exceeded while reading {label}")
            chunks.append(chunk)
        after_descriptor = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        after_path = os.lstat(path)
    except OSError as error:
        raise AuditError(f"could not recheck {label}: {error}") from error
    data = b"".join(chunks)
    expected = file_identity(before)
    if (
        file_identity(opened) != expected
        or file_identity(after_descriptor) != expected
        or file_identity(after_path) != expected
        or len(data) != before.st_size
    ):
        raise AuditError(f"file changed while it was being read: {label}")
    return StableFile(path, label, expected, data, hashlib.sha256(data).hexdigest())


def verify_stable_path(snapshot: StableFile) -> None:
    current = read_stable_path(snapshot.path, snapshot.label, len(snapshot.data))
    if current.stat_identity != snapshot.stat_identity or current.sha256 != snapshot.sha256:
        raise AuditError(f"file content changed before report completion: {snapshot.label}")


def load_config(path: Path | None) -> tuple[dict[str, Any], str, StableFile | None]:
    snapshot: StableFile | None = None
    if path is None:
        raw: object = dict(DEFAULT_CONFIG)
    else:
        try:
            snapshot = read_stable_path(path, f"config {path}", 1_000_000)
            raw = json.loads(snapshot.data.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise AuditError(f"could not read config {path}: {error}") from error
    if not isinstance(raw, dict):
        raise AuditError("config must be a JSON object")
    unknown = sorted(set(raw) - CONFIG_KEYS)
    missing = sorted(CONFIG_KEYS - set(raw))
    if unknown:
        raise AuditError(f"config contains unknown fields: {', '.join(unknown)}")
    if missing:
        raise AuditError(f"config is missing required fields: {', '.join(missing)}")
    schema_version = raw.get("schemaVersion")
    if isinstance(schema_version, bool) or not isinstance(schema_version, int):
        raise AuditError("config schemaVersion must be an integer")
    if schema_version != SCHEMA_VERSION:
        raise AuditError(f"config schemaVersion must be {SCHEMA_VERSION}")

    roots_value = raw.get("includeRoots")
    if not isinstance(roots_value, list) or not roots_value:
        raise AuditError("includeRoots must be a non-empty array")
    roots = [validate_relative_path(value, "includeRoots") for value in roots_value]
    if len(set(roots)) != len(roots):
        raise AuditError("includeRoots contains duplicates")
    root_parts = [PurePosixPath(value).parts for value in roots]
    for index, first in enumerate(root_parts):
        for second in root_parts[index + 1:]:
            shorter, longer = sorted((first, second), key=len)
            if longer[:len(shorter)] == shorter:
                raise AuditError("includeRoots may not overlap")

    categories_value = raw.get("categories")
    if not isinstance(categories_value, list) or not categories_value:
        raise AuditError("categories must be a non-empty array")
    if any(not isinstance(value, str) for value in categories_value):
        raise AuditError("categories entries must be strings")
    categories = list(categories_value)
    if len(set(categories)) != len(categories):
        raise AuditError("categories contains duplicates")
    unknown_categories = sorted(set(categories) - set(CATEGORY_ORDER))
    if unknown_categories:
        raise AuditError(f"config contains unknown categories: {', '.join(unknown_categories)}")
    categories.sort(key=CATEGORY_ORDER.index)

    config = {
        "schemaVersion": SCHEMA_VERSION,
        "includeRoots": roots,
        "categories": categories,
        "maxFiles": positive_integer(raw.get("maxFiles"), "maxFiles"),
        "maxFileBytes": positive_integer(raw.get("maxFileBytes"), "maxFileBytes"),
        "maxFindings": positive_integer(raw.get("maxFindings"), "maxFindings"),
    }
    return config, hashlib.sha256(canonical_json(config)).hexdigest(), snapshot


def _has_odd_backslash_prefix(source: str, index: int) -> bool:
    backslashes = 0
    cursor = index - 1
    while cursor >= 0 and source[cursor] == "\\":
        backslashes += 1
        cursor -= 1
    return backslashes % 2 == 1


def _is_string_delimiter_escaped(source: str, index: int, hashes: int) -> bool:
    return hashes == 0 and _has_odd_backslash_prefix(source, index)


def _looks_like_bare_regex_start(source: str, index: int) -> bool:
    if index + 1 >= len(source) or source[index + 1] in "/=*\n\r" or source[index + 1].isspace():
        return False
    cursor = index - 1
    while cursor >= 0 and source[cursor].isspace():
        cursor -= 1
    if cursor < 0 or source[cursor] in "=([{,:;!?&|+-*%^~<>":
        return True
    prefix = source[:cursor + 1]
    token = re.search(r"([A-Za-z_][A-Za-z0-9_]*)$", prefix)
    return token is not None and token.group(1) in {"case", "return", "throw", "try", "await", "in", "where"}


def _regex_closing_index(source: str, start: int, hashes: int) -> int | None:
    closing = "/" + ("#" * hashes)
    index = start
    in_character_class = False
    while index < len(source):
        character = source[index]
        if character in "\n\r" and hashes == 0:
            return None
        if character == "[" and not _has_odd_backslash_prefix(source, index):
            in_character_class = True
        elif character == "]" and not _has_odd_backslash_prefix(source, index):
            in_character_class = False
        elif (
            not in_character_class
            and source.startswith(closing, index)
            and not _has_odd_backslash_prefix(source, index)
        ):
            return index
        index += 1
    return None


def mask_swift_noncode(source: str, label: str) -> str:
    """Mask comments, strings, and regex literals, rejecting incomplete lexing."""

    output = list(source)
    length = len(source)
    index = 0
    block_depth = 0
    line_comment = False
    string_delimiter: tuple[int, bool, int] | None = None

    def blank(position: int) -> None:
        if output[position] != "\n":
            output[position] = " "

    while index < length:
        if line_comment:
            if source[index] == "\n":
                line_comment = False
            else:
                blank(index)
            index += 1
            continue

        if block_depth:
            if source.startswith("/*", index):
                blank(index)
                if index + 1 < length:
                    blank(index + 1)
                block_depth += 1
                index += 2
            elif source.startswith("*/", index):
                blank(index)
                if index + 1 < length:
                    blank(index + 1)
                block_depth -= 1
                index += 2
            else:
                blank(index)
                index += 1
            continue

        if string_delimiter is not None:
            hashes, triple, opener = string_delimiter
            closing = ('"""' if triple else '"') + ("#" * hashes)
            if source.startswith(closing, index) and not _is_string_delimiter_escaped(source, index, hashes):
                for offset in range(len(closing)):
                    blank(index + offset)
                index += len(closing)
                string_delimiter = None
                continue
            if hashes == 0 and source[index] == "\\":
                blank(index)
                if index + 1 < length:
                    blank(index + 1)
                index += 2
                continue
            if not triple and source[index] in "\n\r":
                raise AuditError(f"unterminated Swift string literal in {label} at character {opener + 1}")
            blank(index)
            index += 1
            continue

        if source.startswith("//", index):
            blank(index)
            if index + 1 < length:
                blank(index + 1)
            line_comment = True
            index += 2
            continue
        if source.startswith("/*", index):
            blank(index)
            if index + 1 < length:
                blank(index + 1)
            block_depth = 1
            index += 2
            continue

        hashes = 0
        while index + hashes < length and source[index + hashes] == "#":
            hashes += 1
        quote_index = index + hashes
        if quote_index < length and source[quote_index] == '"':
            triple = source.startswith('"""', quote_index)
            opener_length = hashes + (3 if triple else 1)
            for offset in range(opener_length):
                blank(index + offset)
            opener = index
            index += opener_length
            string_delimiter = (hashes, triple, opener)
            continue

        regex_hashes = hashes
        slash_index = index + regex_hashes
        extended_regex = regex_hashes > 0 and slash_index < length and source[slash_index] == "/"
        bare_regex = regex_hashes == 0 and source[index] == "/" and _looks_like_bare_regex_start(source, index)
        if extended_regex or bare_regex:
            content_start = slash_index + 1
            closing_index = _regex_closing_index(source, content_start, regex_hashes)
            if closing_index is None:
                raise AuditError(f"unterminated Swift regex literal in {label} at character {index + 1}")
            end = closing_index + 1 + regex_hashes
            for position in range(index, end):
                blank(position)
            index = end
            continue

        index += 1

    if block_depth:
        raise AuditError(f"unterminated Swift block comment in {label}")
    if string_delimiter is not None:
        raise AuditError(f"unterminated Swift string literal in {label} at character {string_delimiter[2] + 1}")
    return "".join(output)


def is_ui_candidate(code: str) -> bool:
    return bool(
        re.search(r"\bimport\s+SwiftUI\b|:\s*(?:some\s+)?View\b", code)
        or CONTROL_PATTERN.search(code)
        or DIRECT_GESTURE_PATTERN.search(code)
        or COMPOSED_GESTURE_PATTERN.search(code)
    )


def verify_file_identity(source: SourceFile) -> None:
    verify_stable_path(StableFile(
        source.filesystem_path,
        source.path,
        source.stat_identity,
        source.data,
        source.sha256,
    ))


def verify_source_set(root: Path, config: dict[str, Any], sources: list[SourceFile]) -> None:
    current_paths: list[str] = []
    for include_root in config["includeRoots"]:
        directory = root / include_root
        current_paths.extend(relative for relative, _ in _walk_source_tree(directory, root))
    expected_paths = [source.path for source in sources]
    if sorted(current_paths) != expected_paths:
        raise AuditError("Swift source set changed before report completion")
    for source in sources:
        verify_file_identity(source)


def _walk_source_tree(directory: Path, root: Path) -> Iterator[tuple[str, Path]]:
    try:
        with os.scandir(directory) as iterator:
            entries = sorted(iterator, key=lambda entry: entry.name)
    except OSError as error:
        relative = directory.relative_to(root).as_posix()
        raise AuditError(f"could not enumerate include tree {relative}: {error}") from error
    for entry in entries:
        path = Path(entry.path)
        relative = path.relative_to(root).as_posix()
        try:
            if entry.is_symlink():
                raise AuditError(f"coverage refuses nested symlink entry: {relative}")
            if entry.is_dir(follow_symlinks=False):
                yield from _walk_source_tree(path, root)
            elif entry.is_file(follow_symlinks=False) and entry.name.endswith(".swift"):
                yield relative, path
            elif entry.name.endswith(".swift"):
                raise AuditError(f"coverage expected a regular source file: {relative}")
        except OSError as error:
            raise AuditError(f"could not inspect source-tree entry {relative}: {error}") from error


def _assert_real_directory(path: Path, label: str) -> None:
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise AuditError(f"{label} is unavailable: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise AuditError(f"{label} must be a real directory")


def discover_sources(root: Path, config: dict[str, Any]) -> list[SourceFile]:
    discovered: dict[str, Path] = {}
    for include_root in config["includeRoots"]:
        directory = root / include_root
        current = root
        try:
            for part in PurePosixPath(include_root).parts:
                current = current / part
                _assert_real_directory(current, f"include root component {current.relative_to(root).as_posix()}")
        except AuditError as error:
            raise AuditError(f"include root is unavailable: {include_root}: {error}") from error
        for relative, path in _walk_source_tree(directory, root):
            discovered[relative] = path

    ordered = sorted(discovered.items())
    if not ordered:
        raise AuditError("coverage found no Swift source files")
    if len(ordered) > config["maxFiles"]:
        raise AuditError(
            f"coverage would truncate files: {len(ordered)} discovered > maxFiles {config['maxFiles']}"
        )

    sources: list[SourceFile] = []
    for relative, path in ordered:
        snapshot = read_stable_path(path, relative, config["maxFileBytes"])
        try:
            text = snapshot.data.decode("utf-8")
        except UnicodeDecodeError as error:
            raise AuditError(f"source is not valid UTF-8: {relative}: {error}") from error
        code = mask_swift_noncode(text, relative)
        sources.append(SourceFile(
            relative,
            path,
            snapshot.stat_identity,
            snapshot.data,
            snapshot.sha256,
            text,
            code,
            is_ui_candidate(code),
        ))
    if not any(source.ui_candidate for source in sources):
        raise AuditError("coverage found no SwiftUI source candidates")
    return sources


def source_digest(sources: Iterable[SourceFile]) -> str:
    digest = hashlib.sha256()
    digest.update((SOURCE_DIGEST_ALGORITHM + "\0").encode("ascii"))
    for source in sources:
        path_bytes = source.path.encode("utf-8")
        digest.update(len(path_bytes).to_bytes(8, "big"))
        digest.update(path_bytes)
        digest.update(len(source.data).to_bytes(8, "big"))
        digest.update(source.data)
    return digest.hexdigest()


def line_starts(text: str) -> list[int]:
    starts = [0]
    starts.extend(index + 1 for index, character in enumerate(text) if character == "\n")
    return starts


def line_column(starts: list[int], offset: int) -> tuple[int, int]:
    index = bisect_right(starts, offset) - 1
    return index + 1, offset - starts[index] + 1


def skip_whitespace(code: str, index: int) -> int:
    while index < len(code) and code[index].isspace():
        index += 1
    return index


def matching_delimiter(code: str, opening: int, label: str) -> int:
    pairs = {"(": ")", "[": "]", "{": "}"}
    opening_character = code[opening] if opening < len(code) else ""
    if opening_character not in pairs:
        raise AuditError(f"internal parser expected a delimiter while analyzing {label}")
    stack = [pairs[opening_character]]
    for index in range(opening + 1, len(code)):
        character = code[index]
        if character in pairs:
            stack.append(pairs[character])
        elif character in ")]}":
            if character != stack[-1]:
                raise AuditError(f"unbalanced Swift delimiters while analyzing {label}")
            _ = stack.pop()
            if not stack:
                return index
    raise AuditError(f"unterminated Swift expression while analyzing {label}")


def matching_generic_arguments(code: str, opening: int, label: str) -> int:
    if opening >= len(code) or code[opening] != "<":
        raise AuditError(f"internal parser expected generic arguments while analyzing {label}")
    depth = 1
    for index in range(opening + 1, len(code)):
        character = code[index]
        if character == "<":
            depth += 1
        elif character == ">" and (index == 0 or code[index - 1] != "-"):
            depth -= 1
            if depth == 0:
                return index
    raise AuditError(f"unterminated Swift generic arguments while analyzing {label}")


def skip_generic_arguments(code: str, start: int, label: str) -> int:
    cursor = skip_whitespace(code, start)
    if cursor < len(code) and code[cursor] == "<":
        cursor = matching_generic_arguments(code, cursor, label) + 1
    return skip_whitespace(code, cursor)


def balanced_call(code: str, start: int, label: str) -> str:
    opening = code.find("(", start, min(len(code), start + 256))
    if opening < 0:
        raise AuditError(f"could not find call delimiter while analyzing {label}")
    closing = matching_delimiter(code, opening, label)
    return code[start:closing + 1]


def split_arguments(
    code: str,
    original: str,
    opening: int,
    closing: int,
    label: str,
) -> tuple[ArgumentSpan, ...]:
    spans: list[tuple[int, int]] = []
    start = opening + 1
    stack: list[str] = []
    pairs = {"(": ")", "[": "]", "{": "}"}
    for index in range(start, closing):
        character = code[index]
        if character in pairs:
            stack.append(pairs[character])
        elif character in ")]}":
            if not stack or character != stack[-1]:
                raise AuditError(f"unbalanced Swift argument delimiters while analyzing {label}")
            _ = stack.pop()
        elif character == "," and not stack:
            spans.append((start, index))
            start = index + 1
    spans.append((start, closing))
    arguments: list[ArgumentSpan] = []
    for span_start, span_end in spans:
        if not original[span_start:span_end].strip():
            continue
        segment = code[span_start:span_end]
        name_match = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*|_)\s*:", segment)
        arguments.append(ArgumentSpan(
            name_match.group(1) if name_match else None,
            span_start + (name_match.end() if name_match else 0),
            span_end,
        ))
    return tuple(arguments)


def parse_modifier_chain(code: str, start: int, label: str) -> tuple[tuple[ModifierSpan, ...], int]:
    modifiers: list[ModifierSpan] = []
    cursor = start
    while True:
        candidate = skip_whitespace(code, cursor)
        if candidate >= len(code) or code[candidate] != ".":
            break
        name_match = re.match(r"\.([A-Za-z_][A-Za-z0-9_]*)", code[candidate:])
        if name_match is None:
            raise AuditError(f"could not parse outer modifier while analyzing {label}")
        name = name_match.group(1)
        end = candidate + name_match.end()
        end = skip_whitespace(code, end)
        if end < len(code) and code[end] == "(":
            end = matching_delimiter(code, end, label) + 1
        end = skip_whitespace(code, end)
        if end < len(code) and code[end] == "{":
            end = matching_delimiter(code, end, label) + 1
        modifiers.append(ModifierSpan(name, candidate, end))
        cursor = end
    return tuple(modifiers), cursor


def parse_control_occurrence(source: SourceFile, match: re.Match[str]) -> ControlOccurrence:
    family = match.group(1)
    label = f"{source.path}:{family} at character {match.start() + 1}"
    cursor = skip_generic_arguments(source.code, match.end(), label)
    arguments: tuple[ArgumentSpan, ...] = ()
    closures: list[ClosureSpan] = []
    if cursor < len(source.code) and source.code[cursor] == "(":
        closing = matching_delimiter(source.code, cursor, label)
        arguments = split_arguments(source.code, source.text, cursor, closing, label)
        cursor = closing + 1
    elif cursor < len(source.code) and source.code[cursor] == "{":
        closing = matching_delimiter(source.code, cursor, label)
        closures.append(ClosureSpan(None, cursor, closing + 1))
        cursor = closing + 1
    else:
        raise AuditError(f"unsupported control form while analyzing {label}")

    cursor = skip_whitespace(source.code, cursor)
    if not closures and cursor < len(source.code) and source.code[cursor] == "{":
        closing = matching_delimiter(source.code, cursor, label)
        closures.append(ClosureSpan(None, cursor, closing + 1))
        cursor = closing + 1
    while True:
        candidate = skip_whitespace(source.code, cursor)
        name_match = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*\{", source.code[candidate:])
        if name_match is None:
            break
        opening = candidate + name_match.end() - 1
        closing = matching_delimiter(source.code, opening, label)
        closures.append(ClosureSpan(name_match.group(1), opening, closing + 1))
        cursor = closing + 1
    modifiers, end = parse_modifier_chain(source.code, cursor, label)
    return ControlOccurrence(family, match.start(), end, arguments, tuple(closures), modifiers)


def _literal_content_state(content: str, hashes: str) -> str:
    saw_nonwhitespace = False
    index = 0
    while index < len(content):
        character = content[index]
        if character != "\\":
            saw_nonwhitespace = saw_nonwhitespace or not character.isspace()
            index += 1
            continue
        cursor = index + 1
        while cursor < len(content) and content[cursor] == "#":
            cursor += 1
        if content[index + 1:cursor] != hashes:
            saw_nonwhitespace = True
            index += 1
            continue
        if cursor >= len(content):
            return "indeterminate-expression"
        escape = content[cursor]
        if escape == "(":
            return "indeterminate-expression"
        if escape in "nrt":
            index = cursor + 1
            continue
        if escape in {'"', "'", "\\"}:
            saw_nonwhitespace = True
            index = cursor + 1
            continue
        if escape == "u":
            unicode_match = re.match(r"u\{([0-9A-Fa-f]{1,8})\}", content[cursor:])
            if unicode_match is None:
                return "indeterminate-expression"
            try:
                scalar = chr(int(unicode_match.group(1), 16))
            except (ValueError, OverflowError):
                return "indeterminate-expression"
            saw_nonwhitespace = saw_nonwhitespace or not scalar.isspace()
            index = cursor + unicode_match.end()
            continue
        if escape in "\n\r":
            index = cursor + 1
            continue
        return "indeterminate-expression"
    return "nonempty-literal" if saw_nonwhitespace else "empty-literal"


def _string_literal_state(value: str) -> str | None:
    stripped = value.strip()
    opener = re.match(r"(#{0,})((?:\"\"\")|\")", stripped)
    if opener is None:
        return None
    hashes = opener.group(1)
    quote = opener.group(2)
    closing = quote + hashes
    if not stripped.endswith(closing) or len(stripped) < opener.end() + len(closing):
        return None
    content = stripped[opener.end():len(stripped) - len(closing)]
    return _literal_content_state(content, hashes)


def positional_title_state(source: SourceFile, occurrence: ControlOccurrence) -> str:
    if occurrence.family not in POSITIONAL_TITLE_FAMILIES:
        return "family-has-no-positional-title"
    positional = next((argument for argument in occurrence.arguments if argument.name is None), None)
    if positional is None:
        return "no-positional-title"
    literal_state = _string_literal_state(source.text[positional.start:positional.end])
    if literal_state == "empty-literal":
        return "empty-literal-title"
    if literal_state == "nonempty-literal":
        return "nonempty-literal-title"
    return "indeterminate-positional-title"


def label_regions(occurrence: ControlOccurrence) -> tuple[tuple[int, int], ...]:
    regions = [(argument.start, argument.end) for argument in occurrence.arguments if argument.name == "label"]
    regions.extend((closure.start, closure.end) for closure in occurrence.closures if closure.name == "label")
    unnamed = [closure for closure in occurrence.closures if closure.name is None]
    if not regions and unnamed:
        if occurrence.family in DIRECT_LABEL_TRAILING_FAMILIES:
            regions.append((unnamed[0].start, unnamed[0].end))
        elif occurrence.family == "Button" and any(argument.name == "action" for argument in occurrence.arguments):
            regions.append((unnamed[0].start, unnamed[0].end))
    return tuple(regions)


def combine_label_states(states: Iterable[str]) -> str:
    values = set(states)
    for state in ("empty-literal", "indeterminate-expression", "nonempty-literal"):
        if state in values:
            return state
    return "absent"


def label_constructor_state(source: SourceFile, match: re.Match[str], limit: int) -> str:
    label = f"{source.path}:{match.group(1)} label at character {match.start() + 1}"
    cursor = skip_generic_arguments(source.code, match.end(), label)
    if cursor < limit and source.code[cursor] == "(":
        closing = matching_delimiter(source.code, cursor, label)
        if closing >= limit:
            raise AuditError(f"label constructor escapes its owned region while analyzing {label}")
        arguments = split_arguments(source.code, source.text, cursor, closing, label)
        value = next(
            (
                argument for argument in arguments
                if argument.name is None or argument.name in {"title", "verbatim"}
            ),
            None,
        )
        if value is None:
            return "absent"
        literal = _string_literal_state(source.text[value.start:value.end])
        if literal is not None:
            return literal
        nested = label_content_state(source, ((value.start, value.end),))
        return nested if nested != "absent" else "indeterminate-expression"
    if cursor < limit and source.code[cursor] == "{":
        closing = matching_delimiter(source.code, cursor, label)
        if closing >= limit:
            raise AuditError(f"label closure escapes its owned region while analyzing {label}")
        nested = label_content_state(source, ((cursor + 1, closing),))
        return nested if nested != "absent" else "indeterminate-expression"
    raise AuditError(f"unsupported label constructor while analyzing {label}")


def label_content_state(source: SourceFile, regions: Iterable[tuple[int, int]]) -> str:
    states: list[str] = []
    for start, end in regions:
        for match in LABEL_CONSTRUCTOR_PATTERN.finditer(source.code, start, end):
            states.append(label_constructor_state(source, match, end))
    return combine_label_states(states)


def modifier_value_state(
    source: SourceFile,
    modifiers: tuple[ModifierSpan, ...],
    name: str,
) -> str:
    states: list[str] = []
    for modifier in modifiers:
        if modifier.name != name:
            continue
        label = f"{source.path}:{name} at character {modifier.start + 1}"
        opening = source.code.find("(", modifier.start, modifier.end)
        if opening < 0:
            states.append("indeterminate-expression")
            continue
        closing = matching_delimiter(source.code, opening, label)
        arguments = split_arguments(source.code, source.text, opening, closing, label)
        value = next((argument for argument in arguments if argument.name is None), None)
        if value is None:
            states.append("indeterminate-expression")
            continue
        literal = _string_literal_state(source.text[value.start:value.end])
        if literal is not None:
            states.append(literal)
            continue
        nested = label_content_state(source, ((value.start, value.end),))
        states.append(nested if nested != "absent" else "indeterminate-expression")
    if not states:
        return "absent"
    if "empty-literal" in states:
        return "empty-literal"
    if "indeterminate-expression" in states:
        return "indeterminate-expression"
    return "nonempty-literal"


def parse_gesture_occurrences(source: SourceFile) -> list[GestureOccurrence]:
    occurrences: list[GestureOccurrence] = []
    for match in DIRECT_GESTURE_PATTERN.finditer(source.code):
        family = match.group(1)
        label = f"{source.path}:{family} at character {match.start() + 1}"
        cursor = skip_whitespace(source.code, match.end())
        has_parenthesized_action = False
        if cursor < len(source.code) and source.code[cursor] == "(":
            cursor = matching_delimiter(source.code, cursor, label) + 1
            has_parenthesized_action = True
        cursor = skip_whitespace(source.code, cursor)
        if cursor < len(source.code) and source.code[cursor] == "{":
            cursor = matching_delimiter(source.code, cursor, label) + 1
        elif not has_parenthesized_action:
            raise AuditError(f"gesture action closure is incomplete while analyzing {label}")
        modifiers, end = parse_modifier_chain(source.code, cursor, label)
        occurrences.append(GestureOccurrence(family, match.start(), end, modifiers))

    for match in COMPOSED_GESTURE_PATTERN.finditer(source.code):
        modifier = match.group(1)
        opening = source.code.find("(", match.start(), match.end() + 1)
        label = f"{source.path}:{modifier} at character {match.start() + 1}"
        closing = matching_delimiter(source.code, opening, label)
        expression = source.code[opening + 1:closing]
        gesture_types = [name for name in ("TapGesture", "LongPressGesture") if re.search(rf"\b{name}\s*\(", expression)]
        if not gesture_types:
            continue
        modifiers, end = parse_modifier_chain(source.code, closing + 1, label)
        occurrences.extend(
            GestureOccurrence(f"{modifier}-{gesture_type}", match.start(), end, modifiers)
            for gesture_type in gesture_types
        )
    return occurrences


def window(lines: list[str], center: int, radius: int) -> str:
    return "\n".join(lines[max(0, center - radius):min(len(lines), center + radius + 1)])


def evidence_line(lines: list[str], line_index: int) -> str:
    return lines[line_index].strip()[:240]


def finding(
    category: str,
    source: SourceFile,
    line: int,
    column: int,
    rule_id: str,
    summary: str,
    evidence: str,
    details: dict[str, object] | None = None,
) -> dict[str, object]:
    result: dict[str, object] = {
        "category": category,
        "path": source.path,
        "line": line,
        "column": column,
        "ruleId": rule_id,
        "summary": summary,
        "evidence": evidence,
        "evidenceClass": EVIDENCE_CLASS,
    }
    if details:
        result["details"] = details
    return result


def finding_sort_key(item: dict[str, object]) -> tuple[str, int, int, int, str]:
    line = item["line"]
    column = item["column"]
    if isinstance(line, bool) or not isinstance(line, int):
        raise AuditError("internal finding line must be an integer")
    if isinstance(column, bool) or not isinstance(column, int):
        raise AuditError("internal finding column must be an integer")
    return (
        str(item["path"]),
        line,
        column,
        CATEGORY_ORDER.index(str(item["category"])),
        str(item["ruleId"]),
    )


def actionable_analysis(source: SourceFile) -> ActionableAnalysis:
    results: list[dict[str, object]] = []
    original_lines = source.text.splitlines()
    starts = line_starts(source.code)
    control_counts: Counter[str] = Counter()
    gesture_counts: Counter[str] = Counter()

    for match in CONTROL_PATTERN.finditer(source.code):
        occurrence = parse_control_occurrence(source, match)
        control_counts[occurrence.family] += 1
        line, column = line_column(starts, match.start())
        index = line - 1
        regions = label_regions(occurrence)
        label_code = "\n".join(source.code[start:end] for start, end in regions)
        title_state = positional_title_state(source, occurrence)
        label_state = label_content_state(source, regions)
        explicit_label_state = modifier_value_state(source, occurrence.modifiers, "accessibilityLabel")
        explicit_hint_state = modifier_value_state(source, occurrence.modifiers, "accessibilityHint")
        image_signal = bool(IMAGE_PATTERN.search(label_code))
        verified_title = title_state == "nonempty-literal-title"
        indeterminate_title = title_state == "indeterminate-positional-title"
        verified_label = label_state == "nonempty-literal"
        verified_explicit_label = explicit_label_state == "nonempty-literal"
        verified_explicit_hint = explicit_hint_state == "nonempty-literal"
        missing: list[str] = []
        if not (verified_title or verified_label or verified_explicit_label):
            missing.append("label")
        if image_signal and not (verified_title or verified_label) and not verified_explicit_hint:
            missing.append("hint")
        review_reasons: list[str] = []
        if indeterminate_title:
            review_reasons.append("arbitrary-positional-title")
        if label_state in {"empty-literal", "indeterminate-expression"}:
            review_reasons.append(f"{label_state}-label-content")
        if explicit_label_state in {"empty-literal", "indeterminate-expression"}:
            review_reasons.append(f"{explicit_label_state}-accessibility-label")
        if explicit_hint_state in {"empty-literal", "indeterminate-expression"}:
            review_reasons.append(f"{explicit_hint_state}-accessibility-hint")
        if missing or review_reasons:
            rule_id = (
                "swiftui.indeterminate-control-title"
                if indeterminate_title
                else "swiftui.empty-accessibility-label"
                if explicit_label_state == "empty-literal"
                else "swiftui.indeterminate-accessibility-label"
                if explicit_label_state == "indeterminate-expression"
                else "swiftui.empty-accessibility-hint"
                if explicit_hint_state == "empty-literal"
                else "swiftui.indeterminate-accessibility-hint"
                if explicit_hint_state == "indeterminate-expression"
                else "swiftui.empty-control-label"
                if label_state == "empty-literal"
                else "swiftui.indeterminate-control-label"
                if label_state == "indeterminate-expression"
                else "swiftui.empty-control-title"
                if title_state == "empty-literal-title"
                else "swiftui.actionable-control-semantics"
            )
            results.append(finding(
                "actionable-control-semantics",
                source,
                line,
                column,
                rule_id,
                (
                    f"{occurrence.family} has an arbitrary positional title whose semantics need review"
                    if indeterminate_title
                    else f"{occurrence.family} has an empty explicit accessibility label"
                    if explicit_label_state == "empty-literal"
                    else f"{occurrence.family} has an indeterminate explicit accessibility label"
                    if explicit_label_state == "indeterminate-expression"
                    else f"{occurrence.family} has an empty explicit accessibility hint"
                    if explicit_hint_state == "empty-literal"
                    else f"{occurrence.family} has an indeterminate explicit accessibility hint"
                    if explicit_hint_state == "indeterminate-expression"
                    else f"{occurrence.family} has empty trailing label content"
                    if label_state == "empty-literal"
                    else f"{occurrence.family} has indeterminate trailing label content"
                    if label_state == "indeterminate-expression"
                    else f"{occurrence.family} uses an empty title and needs an explicit accessible label"
                    if title_state == "empty-literal-title"
                    else f"{occurrence.family} needs review for missing {' and '.join(missing)} semantics"
                ),
                evidence_line(original_lines, index),
                {
                    "missing": missing,
                    "reviewReasons": review_reasons,
                    "labelRegionCount": len(regions),
                    "positionalTitleState": title_state,
                    "labelContentState": label_state,
                    "ownedOuterAccessibilityLabelState": explicit_label_state,
                    "ownedOuterAccessibilityHintState": explicit_hint_state,
                },
            ))

    for occurrence in parse_gesture_occurrences(source):
        gesture_counts[occurrence.family] += 1
        line, column = line_column(starts, occurrence.start)
        index = line - 1
        modifier_code = "\n".join(source.code[modifier.start:modifier.end] for modifier in occurrence.modifiers)
        label_state = modifier_value_state(source, occurrence.modifiers, "accessibilityLabel")
        hint_state = modifier_value_state(source, occurrence.modifiers, "accessibilityHint")
        button_trait = any(modifier.name == "accessibilityAddTraits" for modifier in occurrence.modifiers) and bool(
            re.search(r"\b(?:AccessibilityTraits\.)?isButton\b", modifier_code)
        )
        label = label_state == "nonempty-literal"
        hint = hint_state == "nonempty-literal"
        missing = [name for name, present in (("label", label), ("hint", hint), ("button trait", button_trait)) if not present]
        if missing:
            results.append(finding(
                "actionable-control-semantics",
                source,
                line,
                column,
                "swiftui.actionable-gesture-semantics",
                f"{occurrence.family} needs review for missing {', '.join(missing)}",
                evidence_line(original_lines, index),
                {
                    "missing": missing,
                    "markerOwnership": "modifiers chained after this gesture modifier only",
                    "ownedOuterAccessibilityLabelState": label_state,
                    "ownedOuterAccessibilityHintState": hint_state,
                },
            ))
    return ActionableAnalysis(tuple(results), control_counts, gesture_counts)


def color_findings(source: SourceFile) -> list[dict[str, object]]:
    results: list[dict[str, object]] = []
    original_lines = source.text.splitlines()
    code_lines = source.code.splitlines()
    starts = line_starts(source.code)
    for match in COLOR_MODIFIER_PATTERN.finditer(source.code):
        line, column = line_column(starts, match.start())
        index = line - 1
        expression = balanced_call(
            source.code,
            match.start(),
            f"{source.path}:color modifier at character {match.start() + 1}",
        )
        conditional = ("?" in expression and ":" in expression) or bool(re.search(r"\bif\b", expression))
        raw_state_color = bool(RAW_STATE_COLOR_PATTERN.search(expression))
        if not (conditional or raw_state_color):
            continue
        context = window(code_lines, index, 2)
        semantic_marker = bool(re.search(r"\.accessibility(?:Label|Value)\s*\(", context))
        results.append(finding(
            "color-only-state",
            source,
            line,
            column,
            "swiftui.state-color-signal",
            "Conditional or raw state color/style needs a non-color semantic review",
            evidence_line(original_lines, index),
            {
                "lexicalContextRadiusLines": 2,
                "nearbyAccessibilityLabelOrValueMarker": semantic_marker,
                "signals": [
                    signal for signal, present in (
                        ("conditional", conditional),
                        ("raw-state-color", raw_state_color),
                    ) if present
                ],
            },
        ))
    return results


def fixed_size_findings(source: SourceFile) -> list[dict[str, object]]:
    results: list[dict[str, object]] = []
    original_lines = source.text.splitlines()
    starts = line_starts(source.code)
    for match in FIXED_FRAME_PATTERN.finditer(source.code):
        line, column = line_column(starts, match.start())
        index = line - 1
        expression = balanced_call(
            source.code,
            match.start(),
            f"{source.path}:frame modifier at character {match.start() + 1}",
        )
        dimensions = sorted({
            dimension.group(1)
            for dimension in re.finditer(r"\b(width|height)\s*:\s*([^,)]+)", expression)
            if dimension.group(2).strip() not in {".infinity", "nil"}
        })
        if dimensions:
            results.append(finding(
                "fixed-size-risk",
                source,
                line,
                column,
                "swiftui.fixed-frame-dimension",
                f"Fixed frame {', '.join(dimensions)} needs large-text and target-size review",
                evidence_line(original_lines, index),
                {"dimensions": dimensions, "boundedCallCharacters": len(expression)},
            ))
    for match in FONT_CALL_PATTERN.finditer(source.code):
        expression = balanced_call(
            source.code,
            match.start(),
            f"{source.path}:font modifier at character {match.start() + 1}",
        )
        if not re.search(r"\.system\s*\([^)]*\bsize\s*:", expression, re.DOTALL):
            continue
        line, column = line_column(starts, match.start())
        index = line - 1
        results.append(finding(
            "fixed-size-risk",
            source,
            line,
            column,
            "swiftui.fixed-system-font-size",
            "Fixed system font size needs Dynamic Type and clipping review",
            evidence_line(original_lines, index),
        ))
    return results


def proximity_findings(
    source: SourceFile,
    *,
    category: str,
    patterns: tuple[tuple[str, re.Pattern[str]], ...],
    nearby_marker: re.Pattern[str],
    radius: int,
    rule_id: str,
    summary_template: str,
    skip_nil_animation: bool = False,
) -> list[dict[str, object]]:
    results: list[dict[str, object]] = []
    original_lines = source.text.splitlines()
    code_lines = source.code.splitlines()
    starts = line_starts(source.code)
    for api, pattern in patterns:
        for match in pattern.finditer(source.code):
            line, column = line_column(starts, match.start())
            index = line - 1
            if (
                skip_nil_animation
                and api == "animation"
                and re.search(r"\.animation\s*\(\s*nil\b", code_lines[index])
            ):
                continue
            context = window(code_lines, index, radius)
            if nearby_marker.search(context):
                continue
            results.append(finding(
                category,
                source,
                line,
                column,
                rule_id,
                summary_template.format(api=api),
                evidence_line(original_lines, index),
                {"api": api, "lexicalContextRadiusLines": radius},
            ))
    return results


ANALYZERS = {
    "color-only-state": color_findings,
    "fixed-size-risk": fixed_size_findings,
    "reduce-motion": partial(
        proximity_findings,
        category="reduce-motion",
        patterns=MOTION_PATTERNS,
        nearby_marker=REDUCE_MOTION_PATTERN,
        radius=30,
        rule_id="swiftui.motion-without-reduce-motion-marker",
        summary_template="{api} has no nearby Reduce Motion marker",
        skip_nil_animation=True,
    ),
    "focus-restoration": partial(
        proximity_findings,
        category="focus-restoration",
        patterns=PRESENTATION_PATTERNS,
        nearby_marker=FOCUS_MARKER_PATTERN,
        radius=80,
        rule_id="swiftui.presentation-without-focus-marker",
        summary_template="{api} presentation has no nearby focus-restoration marker",
    ),
}


def build_report(
    root: Path,
    config: dict[str, Any],
    config_digest: str,
    tool_snapshot: StableFile,
    config_snapshot: StableFile | None,
) -> tuple[dict[str, object], list[SourceFile]]:
    sources = discover_sources(root, config)
    ui_sources = [source for source in sources if source.ui_candidate]
    control_counts: Counter[str] = Counter()
    gesture_counts: Counter[str] = Counter()
    findings: list[dict[str, object]] = []
    for source in ui_sources:
        actionable = actionable_analysis(source)
        control_counts.update(actionable.control_counts)
        gesture_counts.update(actionable.gesture_counts)
        for category in config["categories"]:
            if category == "actionable-control-semantics":
                findings.extend(actionable.findings)
            else:
                findings.extend(ANALYZERS[category](source))
            if len(findings) > config["maxFindings"]:
                raise AuditError(
                    f"findings would truncate: more than maxFindings {config['maxFindings']}; "
                    "raise the bound and rerun for a complete report"
                )
    findings.sort(key=finding_sort_key)
    counts = Counter(str(item["category"]) for item in findings)
    verify_source_set(root, config, sources)
    verify_stable_path(tool_snapshot)
    if config_snapshot is not None:
        verify_stable_path(config_snapshot)
    finding_digest = hashlib.sha256(canonical_json(findings)).hexdigest()
    files = [
        {
            "path": source.path,
            "bytes": len(source.data),
            "lines": source.text.count("\n") + (0 if source.text.endswith("\n") else 1),
            "sha256": source.sha256,
            "analyzedAsSwiftUI": source.ui_candidate,
        }
        for source in sources
    ]
    report: dict[str, object] = {
        "schemaVersion": SCHEMA_VERSION,
        "toolIdentity": {
            "name": "audit-kaname-accessibility",
            "version": TOOL_VERSION,
            "sha256": tool_snapshot.sha256,
        },
        "evidenceClass": EVIDENCE_CLASS,
        "proofBoundary": PROOF_BOUNDARY,
        "exitPolicy": {
            "acceptedExitCode": 0,
            "findings": "success-review-leads",
            "invalidArguments": "failure",
            "invalidConfig": "failure",
            "incompleteCoverage": "failure",
            "resourceTruncation": "failure",
            "outputIO": "failure",
            "unexpectedFailure": "failure",
        },
        "sourceIdentity": {
            "algorithm": SOURCE_DIGEST_ALGORITHM,
            "digest": source_digest(sources),
            "fileCount": len(sources),
            "byteCount": sum(len(source.data) for source in sources),
        },
        "config": config,
        "configSha256": config_digest,
        "scope": {
            "includeRoots": config["includeRoots"],
            "includePattern": "**/*.swift",
            "sourceExclusions": [],
            "classification": (
                "analyze files containing import SwiftUI, a View conformance marker, or an advertised "
                "control/gesture occurrence"
            ),
            "suppressions": "none; this version has no allowlist",
            "actionableControlFamilies": list(CONTROL_FAMILIES),
            "actionableGestureFamilies": list(GESTURE_FAMILIES),
        },
        "coverage": {
            "discoveredSwiftFiles": len(sources),
            "analyzedSwiftUIFiles": len(ui_sources),
            "classifiedNonUIFiles": len(sources) - len(ui_sources),
            "readFailures": 0,
            "truncated": False,
            "complete": True,
            "files": files,
        },
        "categories": [
            {"id": category, **CATEGORY_DETAILS[category]}
            for category in config["categories"]
        ],
        "inventory": {
            "actionableControlCoverage": {
                control: {
                    "occurrences": control_counts.get(control, 0),
                    "analyzed": control_counts.get(control, 0),
                    "skipped": 0,
                }
                for control in CONTROL_FAMILIES
            },
            "actionableGestureCoverage": {
                gesture: {
                    "occurrences": gesture_counts.get(gesture, 0),
                    "analyzed": gesture_counts.get(gesture, 0),
                    "skipped": 0,
                }
                for gesture in GESTURE_FAMILIES
            },
            "analysisPolicy": "every advertised occurrence must be analyzed; any unparseable occurrence fails the audit",
        },
        "findingCount": len(findings),
        "findingCountsByCategory": {
            category: counts.get(category, 0) for category in config["categories"]
        },
        "findingsSha256": finding_digest,
        "findings": findings,
        "truncated": False,
    }
    return report, sources


def text_report(report: dict[str, object]) -> str:
    tool = report["toolIdentity"]
    source = report["sourceIdentity"]
    coverage = report["coverage"]
    counts = report["findingCountsByCategory"]
    config = report["config"]
    assert (
        isinstance(tool, dict)
        and isinstance(source, dict)
        and isinstance(coverage, dict)
        and isinstance(counts, dict)
        and isinstance(config, dict)
    )
    categories = config["categories"]
    assert isinstance(categories, list) and all(isinstance(category, str) for category in categories)
    lines = [
        "Kaname accessibility source inventory",
        f"Evidence: {EVIDENCE_CLASS}; {PROOF_BOUNDARY}",
        f"Tool: v{tool['version']} {tool['sha256']}; config {report['configSha256']}",
        f"Source: {source['digest']} ({source['fileCount']} Swift files, {source['byteCount']} bytes)",
        (
            f"Coverage: {coverage['analyzedSwiftUIFiles']} SwiftUI candidates analyzed; "
            f"{coverage['classifiedNonUIFiles']} non-UI Swift files classified; complete, untruncated"
        ),
        f"Review leads: {report['findingCount']}",
    ]
    lines.extend(f"  {category}: {counts[category]}" for category in categories)
    lines.append(f"Findings digest: {report['findingsSha256']}")
    return "\n".join(lines) + "\n"


def absolute_without_resolving(path: Path) -> Path:
    return Path(os.path.abspath(os.fspath(path)))


def resolve_existing_path(path: Path, label: str) -> Path:
    try:
        return path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise AuditError(f"{label} is unavailable: {path}: {error}") from error


def canonicalize_existing_directory(path: Path, label: str) -> Path:
    absolute = absolute_without_resolving(path)
    canonical = resolve_existing_path(absolute, label)
    _assert_real_directory(canonical, label)
    return canonical


def canonicalize_parent_only(path: Path, label: str) -> Path:
    absolute = absolute_without_resolving(path)
    parent = resolve_existing_path(absolute.parent, f"{label} parent")
    return parent / absolute.name


def assert_real_directory_chain(path: Path, label: str) -> None:
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            metadata = os.lstat(current)
        except OSError as error:
            raise AuditError(f"{label} directory is unavailable: {current}: {error}") from error
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise AuditError(f"{label} directory chain must contain only real directories: {current}")


def validate_output_destination(
    path: Path,
    root: Path,
    config: dict[str, Any],
    protected: Iterable[StableFile],
) -> None:
    assert_real_directory_chain(path.parent, "output")
    for include_root in config["includeRoots"]:
        source_root = root / include_root
        try:
            path.relative_to(source_root)
        except ValueError:
            continue
        raise AuditError(f"output must be outside scanned source roots: {path}")

    protected_list = list(protected)
    if any(path == snapshot.path for snapshot in protected_list):
        raise AuditError(f"output collides with protected source, config, or tool input: {path}")
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        return
    except OSError as error:
        raise AuditError(f"could not inspect output destination {path}: {error}") from error
    if stat.S_ISLNK(metadata.st_mode):
        raise AuditError(f"output destination must not be a symlink: {path}")
    if not stat.S_ISREG(metadata.st_mode):
        raise AuditError(f"output destination must be a regular file or absent: {path}")
    identity = (metadata.st_dev, metadata.st_ino)
    if any(identity == snapshot.stat_identity[:2] for snapshot in protected_list):
        raise AuditError(f"output hard-link collides with protected source, config, or tool input: {path}")


def write_atomic(path: Path, data: bytes) -> None:
    assert_real_directory_chain(path.parent, "output")
    try:
        existing = os.lstat(path)
    except FileNotFoundError:
        existing = None
    if existing is not None and (stat.S_ISLNK(existing.st_mode) or not stat.S_ISREG(existing.st_mode)):
        raise AuditError(f"output destination must remain a regular file or absent: {path}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        written = read_stable_path(path, f"output {path}", len(data))
        if written.data != data:
            raise AuditError(f"output verification failed after atomic write: {path}")
    finally:
        if temporary.exists():
            temporary.unlink()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Emit deterministic lexical accessibility review leads for Kaname SwiftUI source."
    )
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="Repository root (default: script parent).")
    parser.add_argument("--config", type=Path, help="Exact JSON config; built-in strict config is used by default.")
    parser.add_argument("--format", choices=("json", "text"), default="json")
    parser.add_argument("--output", type=Path, help="Write the complete report atomically instead of stdout.")
    arguments = parser.parse_args(argv)

    try:
        root = canonicalize_existing_directory(arguments.root, "repository root")
        config_path = canonicalize_parent_only(arguments.config, "config") if arguments.config else None
        if config_path is not None:
            assert_real_directory_chain(config_path.parent, "config")
        tool_path = absolute_without_resolving(Path(__file__))
        assert_real_directory_chain(tool_path.parent, "tool")
        tool_snapshot = read_stable_path(tool_path, "audit tool", 2_000_000)
        config, config_digest, config_snapshot = load_config(config_path)
        report, sources = build_report(root, config, config_digest, tool_snapshot, config_snapshot)
        if arguments.format == "json":
            rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
        else:
            rendered = text_report(report)
        data = rendered.encode("utf-8")
        protected = [tool_snapshot]
        if config_snapshot is not None:
            protected.append(config_snapshot)
        protected.extend(
            StableFile(source.filesystem_path, source.path, source.stat_identity, source.data, source.sha256)
            for source in sources
        )
        verify_source_set(root, config, sources)
        for snapshot in protected[:2 if config_snapshot is not None else 1]:
            verify_stable_path(snapshot)
        if arguments.output:
            output_path = canonicalize_parent_only(arguments.output, "output")
            validate_output_destination(output_path, root, config, protected)
            write_atomic(output_path, data)
            verify_source_set(root, config, sources)
            for snapshot in protected[:2 if config_snapshot is not None else 1]:
                verify_stable_path(snapshot)
        else:
            sys.stdout.buffer.write(data)
        return 0
    except (AuditError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
