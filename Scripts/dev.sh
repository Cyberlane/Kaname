#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: Scripts/dev.sh <command> [args]

One developer loop for the Kaname desktop app on the Development channel.

Commands
  build            Debug-build every Swift product and both Rust binaries the app bundles.
  check            Fast compile check: swift build of the app only, plus cargo check.
  run              Build (debug), then launch the Development app, replacing a running one.
  logs             Tail the newest Development UI logs and the local-core service log.
  test [swift|rust]  Run Rust core tests and all Swift tests (requires Xcode).
  smoke            Run the Newsletter triage flow through the core with the real hosts
                   (one small model call) and assert it parks on the approval gate.
  clean            Remove .build and Rust target directories.
  doctor           Report toolchain facts that decide what works on this Mac.

Environment
  KANAME_DEV_NO_LAUNCH=1   `run` builds but does not launch.
EOF
}

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_dir="$(cd "$script_dir/.." && pwd -P)"
cd "$project_dir"

# Homebrew Python (3.11+) is required by the release-metadata step; system python3 lacks tomllib.
if [[ -d /opt/homebrew/bin ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
fi

application_support_base="${KANAME_APPLICATION_SUPPORT_BASE:-$HOME/Library/Application Support}"
support_root="$application_support_base/Kaname Dev"
runtime_logs_root="$support_root/Runtime/Logs"
service_error_log="$support_root/Runtime/LaunchAgents/kaname-local-control-service.stderr.log"

swift_products=(
    KanamePrototype
    KanameLocalControlService
    KanameUpdateHelper
    KanameConversationWorker
    KanameWorkflowWorker
    KanameWorkflowLlmHost
    KanameWorkflowCapabilityHost
    KanameWorkflowConnectorHost
)

has_xcode() {
    [[ "$(xcode-select -p 2>/dev/null || true)" == *"Xcode.app"* ]]
}

ensure_swift_flow_previews_stripped() {
    # Command Line Tools cannot expand the #Preview macro that the swift-flow dependency uses.
    # On such machines the package is put into edit mode and its previews are stripped locally.
    if has_xcode; then
        return
    fi
    local package_dir="$project_dir/Packages/swift-flow"
    if [[ ! -d "$package_dir" ]]; then
        echo "dev: swift-flow needs Xcode for #Preview; placing it in edit mode and stripping previews." >&2
        swift package edit swift-flow
    fi
    local file
    for file in \
        "$package_dir/Sources/SwiftFlow/Previews/FlowCanvasPreview.swift" \
        "$package_dir/Sources/SwiftFlow/Previews/FlowCanvasLivePreview.swift" \
        "$package_dir/Sources/SwiftFlow/Views/MiniMap.swift"; do
        [[ -f "$file" ]] || continue
        if grep -q '^#Preview' "$file"; then
            python3 - "$file" <<'PY'
import re, sys
path = sys.argv[1]
source = open(path, encoding="utf-8").read()
out = []
depth = 0
in_preview = False
for line in source.splitlines(keepends=True):
    if not in_preview and line.startswith("#Preview"):
        in_preview = True
        depth = line.count("{") - line.count("}")
        if depth <= 0 and "{" in line:
            in_preview = False
        continue
    if in_preview:
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            in_preview = False
        continue
    out.append(line)
open(path, "w", encoding="utf-8").write("".join(out))
PY
        fi
    done
}

build_all() {
    ensure_swift_flow_previews_stripped
    local product
    for product in "${swift_products[@]}"; do
        swift build -c debug --product "$product"
    done
    cargo build --locked --manifest-path Rust/KanameCore/Cargo.toml --bin kaname-local-core
    cargo build --locked --manifest-path Rust/KanameLinkCore/Cargo.toml --bin kaname-link-gateway
}

command_name="${1:-}"
[[ -n "$command_name" ]] || { usage; exit 64; }
shift

case "$command_name" in
    build)
        build_all
        ;;
    check)
        ensure_swift_flow_previews_stripped
        swift build -c debug --product KanamePrototype
        cargo check --locked --manifest-path Rust/KanameCore/Cargo.toml --bin kaname-local-core
        ;;
    run)
        ensure_swift_flow_previews_stripped
        if [[ "${KANAME_DEV_NO_LAUNCH:-0}" == "1" ]]; then
            build_all
        else
            exec "$script_dir/run-phase0-prototype.sh" --replace "$@"
        fi
        ;;
    logs)
        latest_session="$(find "$runtime_logs_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1 || true)"
        files=()
        [[ -n "$latest_session" ]] && files+=("$latest_session/ui.stdout.log" "$latest_session/ui.stderr.log")
        [[ -f "$service_error_log" ]] && files+=("$service_error_log")
        if [[ ${#files[@]} -eq 0 ]]; then
            echo "dev: no Development logs under $runtime_logs_root yet; run Scripts/dev.sh run first." >&2
            exit 1
        fi
        exec tail -n 200 -F "${files[@]}"
        ;;
    test)
        target="${1:-all}"
        case "$target" in
            all|rust|swift) ;;
            *) echo "dev: unknown test target: $target (expected all, rust, or swift)." >&2; exit 64 ;;
        esac
        if [[ "$target" != "rust" ]] && ! has_xcode; then
            echo "dev: Swift tests require Xcode; no passing test result was produced." >&2
            exit 1
        fi
        if [[ "$target" == "all" || "$target" == "rust" ]]; then
            cargo test --locked --manifest-path Rust/KanameCore/Cargo.toml
        fi
        if [[ "$target" == "all" || "$target" == "swift" ]]; then
            swift test --skip DesktopGlobalSearchPerformanceTests
            swift test --skip-build --filter DesktopGlobalSearchPerformanceTests
        fi
        ;;
    smoke)
        exec "$script_dir/smoke-workflow-triage.sh"
        ;;
    clean)
        rm -rf "$project_dir/.build" "$project_dir/Rust/KanameCore/target" "$project_dir/Rust/KanameLinkCore/target"
        ;;
    doctor)
        echo "xcode-select: $(xcode-select -p 2>/dev/null || echo none)"
        echo "swift:        $(swift --version 2>&1 | head -n 1)"
        echo "cargo:        $(cargo --version 2>/dev/null || echo missing)"
        echo "python3:      $(python3 --version 2>/dev/null || echo missing) ($(command -v python3))"
        echo "jq:           $(command -v jq || echo missing)"
        echo "claude:       $(command -v claude || echo missing)"
        echo "codex:        $(command -v codex || echo missing)"
        echo "opencode:     $(command -v opencode || echo missing)"
        echo "gh:           $(command -v gh || echo missing)"
        echo "swift-flow:   $([[ -d Packages/swift-flow ]] && echo 'edit mode (previews stripped)' || echo 'resolved package')"
        echo "dev support:  $support_root"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        exit 64
        ;;
esac
