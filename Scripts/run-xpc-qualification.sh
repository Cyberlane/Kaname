#!/usr/bin/env bash
set -euo pipefail

: "${KANAME_XPC_SIGNING_IDENTITY:?Set KANAME_XPC_SIGNING_IDENTITY to an Apple Development identity.}"

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

cargo build --manifest-path Rust/KanameXPCQualificationCore/Cargo.toml
swift build --product KanameXPCQualification

binary="$(swift build --show-bin-path)/KanameXPCQualification"
core="$(pwd)/Rust/KanameXPCQualificationCore/target/debug/kaname_xpc_qualification_core"
identifier="com.cyberlane.kaname.xpcqualification"

test -x "$core"

codesign --force --sign "$KANAME_XPC_SIGNING_IDENTITY" --identifier "$identifier" "$binary"

team_identifier="$(codesign -dvv "$binary" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
test -n "$team_identifier"

requirement="anchor apple generic and certificate leaf[subject.OU] = \"$team_identifier\" and identifier \"$identifier\""
exec "$binary" --run --requirement "$requirement" --core-executable "$core"
