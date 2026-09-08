#!/usr/bin/env bash
# End-to-end smoke of a trigger.event workflow on the Rust executor with the
# real workflow hosts, outside the app:
#   publish the Newsletter triage template into a scratch library
#   -> fan out one fake newsletter event
#   -> assert trigger, classifier (real model call), and decision succeeded
#      and the label effect is parked as a proposed effect awaiting approval.
# Costs one small model call. Needs the debug core and hosts built
# (Scripts/dev.sh build) and the claude CLI logged in.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_dir="$(cd "$script_dir/.." && pwd -P)"
cd "$project_dir"

core="$project_dir/Rust/KanameCore/target/debug/kaname-local-core"
llm_host="$project_dir/.build/debug/KanameWorkflowLlmHost"
effect_host="$project_dir/.build/debug/KanameWorkflowConnectorHost"
capability_host="$project_dir/.build/debug/KanameWorkflowCapabilityHost"
for binary in "$core" "$llm_host" "$effect_host" "$capability_host"; do
    [[ -x "$binary" ]] || { echo "smoke: missing $binary (run Scripts/dev.sh build)" >&2; exit 2; }
done
command -v sqlite3 >/dev/null || { echo "smoke: sqlite3 missing" >&2; exit 2; }
: "${KANAME_WORKFLOW_CONNECTOR_SOCKET:?Set the exact authorized Development worker socket path before this live-provider smoke.}"
export KANAME_WORKFLOW_CONNECTOR_SOCKET

scratch="$(mktemp -d /tmp/kaname-triage-smoke.XXXXXX)"
trap 'chmod -R u+rwX "$scratch" 2>/dev/null; rm -rf "$scratch"' EXIT
mkdir -p "$scratch/LocalCore/journal" "$scratch/Workflows"
journal="$scratch/LocalCore/journal/live-provider.sqlite"
projection="$scratch/Workflows/workflow-run-projection.sqlite"

# The template lives in the app source so the installer and this smoke share it.
python3 - "$project_dir/Sources/KanamePrototype/DesktopDurableWorkflowRunsView.swift" "$scratch" <<'PY'
import hashlib, json, re, sys
source, scratch = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
def block(name):
    match = re.search(name + r' = """\n\s*(\{.*?\})\n\s*"""', text, re.S)
    if not match:
        sys.exit(f"smoke: could not find {name} in {source}")
    return match.group(1)
workflow = block("newsletterTriageWorkflowJSONTemplate").replace("__NEWSLETTER_LABEL_ID__", "Label_smoke")
bundle = block("newsletterTriageSchemaBundleJSON")
lock = block("newsletterTriageDependencyLockJSON")
json.loads(workflow); json.loads(bundle); json.loads(lock)
publish = {
    "requestId": "smoke-publish", "workflowId": json.loads(workflow)["workflowId"],
    "packageId": "dev.kaname.newsletter-triage", "name": "Newsletter triage", "summary": "smoke",
    "workflowJson": workflow, "schemaBundleJson": bundle, "dependencyLockJson": lock, "activate": True,
}
json.dump(publish, open(f"{scratch}/publish.json", "w"))
event = {
    "requestId": "smoke-event", "eventContract": "mail.message.received",
    "eventId": "gmail:smoke-account:smoke-message", "contractKey": "smoke-thread",
    "input": {
        "accountBindingId": "smoke-account", "accountId": "smoke-account", "accountAddress": "owner@example.com",
        "messageId": "smoke-message", "conversationId": "smoke-thread",
        "destinationFingerprint": hashlib.sha256(b"gmail:smoke-account:smoke-thread").hexdigest(),
        "resourceIds": ["INBOX"], "labelIds": ["INBOX", "UNREAD"],
        "sender": "Weekly Dispatch <news@newsletter.example.com>", "recipients": "owner@example.com",
        "subject": "This week in Swift: 12 links you missed", "date": "Thu, 4 Sep 2026 09:00:00 +0900",
        "snippet": "Our weekly roundup of Swift articles, talks and tools. Unsubscribe any time.",
        "bodyExcerpt": "Here is this week's roundup of Swift articles, conference talks, and tools. You are receiving this because you subscribed. Unsubscribe | Manage preferences",
        "listUnsubscribe": "<https://newsletter.example.com/unsubscribe/abc>", "attachmentCount": 0,
        "cursor": "12345", "provider": "gmail",
    },
}
json.dump(event, open(f"{scratch}/event.json", "w"))
PY

decode() { xxd -r -p; }

published="$("$core" workflow-library-publish "$journal" "$scratch" < "$scratch/publish.json" | decode)"
echo "publish: $(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['revisionId'], d['executionSupport'], 'active' if d['activated'] else 'inactive')" "$published")"
[[ "$published" == *'"executionSupport":"executable"'* ]] || { echo "smoke: revision is not executable" >&2; exit 1; }

fanout="$(KANAME_WORKFLOW_LLM_COMMAND="$llm_host" KANAME_WORKFLOW_EFFECT_COMMAND="$effect_host" KANAME_WORKFLOW_CAPABILITY_COMMAND="$capability_host" \
    "$core" workflow-event-fanout "$journal" "$projection" "$scratch" < "$scratch/event.json" | decode)"
echo "fanout: $fanout"
[[ "$fanout" == *'"matched":1'* && "$fanout" == *'"admission":"admitted"'* ]] || { echo "smoke: event was not admitted" >&2; exit 1; }

echo "attempts:"
sqlite3 -header -column "$projection" "select substr(node_id, 11, 4) as node, status, coalesce(error_code, '') as error from workflow_attempts order by started_store_position"
effects="$(sqlite3 "$projection" "select status from workflow_effect_authorities")"
echo "effects: ${effects:-none}"

failures=0
check() { # node suffix, expected status
    local status
    status="$(sqlite3 "$projection" "select status from workflow_attempts where node_id like '%$1' limit 1")"
    if [[ "$status" != "$2" ]]; then echo "smoke: node $1 expected $2, got '${status:-missing}'" >&2; failures=$((failures + 1)); fi
}
check 0101 succeeded   # trigger
check 0102 succeeded   # classifier (real model call)
check 0103 succeeded   # decision
[[ "$effects" == "proposed" ]] || { echo "smoke: expected one proposed effect, got '${effects:-none}'" >&2; failures=$((failures + 1)); }
run_error="$(sqlite3 "$projection" "select coalesce(error_code, '') from workflow_runs limit 1")"
run_status="$(sqlite3 "$projection" "select status from workflow_runs limit 1")"
[[ -z "$run_error" && "$run_status" == "running" && "$fanout" == *'"outcome":"waiting"'* ]] || { echo "smoke: run should remain resumable awaiting approval, got '$run_status/$run_error'" >&2; failures=$((failures + 1)); }

if [[ $failures -eq 0 ]]; then
    echo "smoke: OK — trigger, classifier, and decision ran; label effect awaits approval"
else
    echo "smoke: FAILED ($failures)" >&2
    exit 1
fi
