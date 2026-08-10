#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${1:-$repo_root/.build/Kaname Candidate.app}"
output_path="${2:-$repo_root/.build/performance/desktop-launch.json}"
info="$app_path/Contents/Info.plist"
[[ -f "$info" ]] || { echo "Kaname app bundle not found: $app_path" >&2; exit 1; }
executable_name="$(plutil -extract CFBundleExecutable raw "$info")"
executable="$app_path/Contents/MacOS/$executable_name"
[[ -x "$executable" ]] || { echo "Kaname executable is missing." >&2; exit 1; }

channel="$(plutil -extract KanameDesktopChannel raw "$info")"
case "$channel" in
    stable) support_name="Kaname" ;;
    candidate) support_name="Kaname Candidate" ;;
    *) echo "Unknown desktop channel: $channel" >&2; exit 1 ;;
esac

qa_base="$(mktemp -d "${TMPDIR:-/tmp}/kaname-performance.XXXXXX")"
health="$qa_base/$support_name/Runtime/ui-health.json"
active_pid=""
cleanup() {
    if [[ -n "$active_pid" ]] && kill -0 "$active_pid" 2>/dev/null; then
        kill "$active_pid" 2>/dev/null || true
        wait "$active_pid" 2>/dev/null || true
    fi
    rm -r "$qa_base"
}
trap cleanup EXIT

now_nanoseconds() {
    # macOS' system Python reports a process-relative monotonic epoch, so values
    # from separate invocations cannot be subtracted. Perl exposes the shared
    # CLOCK_MONOTONIC value; its startup cost makes this measurement slightly
    # conservative rather than producing impossible negative launch times.
    /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
        -e 'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1e9'
}

measure_launch() {
    local started ended duration rss_kb attempts
    rm -f "$health"
    started="$(now_nanoseconds)"
    "$executable" --desktop-qa-application-support-base "$qa_base" >/dev/null 2>&1 &
    active_pid="$!"
    attempts=0
    until [[ -s "$health" ]] \
        && [[ "$(jq -r '.processID // 0' "$health" 2>/dev/null || true)" == "$active_pid" ]]; do
        if ! kill -0 "$active_pid" 2>/dev/null; then
            echo "Kaname exited before its ready handshake." >&2
            return 1
        fi
        attempts=$((attempts + 1))
        [[ "$attempts" -lt 500 ]] || { echo "Kaname missed the five-second ready deadline." >&2; return 1; }
        sleep 0.01
    done
    ended="$(now_nanoseconds)"
    duration=$((ended - started))
    [[ "$duration" -ge 0 ]] || { echo "Kaname launch clock moved backwards." >&2; return 1; }
    rss_kb="$(ps -o rss= -p "$active_pid" | tr -d ' ')"
    [[ "${rss_kb:-0}" -gt 0 ]] || { echo "Kaname resident-memory measurement was unavailable." >&2; return 1; }
    kill "$active_pid"
    wait "$active_pid" 2>/dev/null || true
    active_pid=""
    printf '%s %s\n' "$duration" "${rss_kb:-0}"
}

read -r cold_ns cold_rss_kb < <(measure_launch)
read -r warm_ns warm_rss_kb < <(measure_launch)
cold_budget_ns=2000000000
warm_budget_ns=1500000000
rss_budget_kb=524288

mkdir -p "$(dirname "$output_path")"
jq -n \
    --arg version "$(plutil -extract CFBundleShortVersionString raw "$info")" \
    --arg build "$(plutil -extract CFBundleVersion raw "$info")" \
    --arg channel "$channel" \
    --arg architecture "$(uname -m)" \
    --arg macOS "$(sw_vers -productVersion)" \
    --argjson coldNanoseconds "$cold_ns" \
    --argjson warmNanoseconds "$warm_ns" \
    --argjson maximumResidentKilobytes "$((cold_rss_kb > warm_rss_kb ? cold_rss_kb : warm_rss_kb))" \
    --argjson coldBudgetNanoseconds "$cold_budget_ns" \
    --argjson warmBudgetNanoseconds "$warm_budget_ns" \
    --argjson residentBudgetKilobytes "$rss_budget_kb" \
    '{schemaVersion: 1, app: {version: $version, build: $build, channel: $channel}, environment: {architecture: $architecture, macOS: $macOS}, measurements: {coldLaunchNanoseconds: $coldNanoseconds, warmLaunchNanoseconds: $warmNanoseconds, maximumResidentKilobytes: $maximumResidentKilobytes}, budgets: {coldLaunchNanoseconds: $coldBudgetNanoseconds, warmLaunchNanoseconds: $warmBudgetNanoseconds, maximumResidentKilobytes: $residentBudgetKilobytes}, passed: ($coldNanoseconds >= 0 and $warmNanoseconds >= 0 and $maximumResidentKilobytes > 0 and $coldNanoseconds <= $coldBudgetNanoseconds and $warmNanoseconds <= $warmBudgetNanoseconds and $maximumResidentKilobytes <= $residentBudgetKilobytes)}' \
    > "$output_path"

jq -e '.passed == true' "$output_path" >/dev/null || {
    echo "Kaname desktop launch performance exceeded its retained budget: $output_path" >&2
    exit 1
}
echo "$output_path"
