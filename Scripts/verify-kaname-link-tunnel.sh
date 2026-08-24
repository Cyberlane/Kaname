#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DESIRED_STATE="$REPOSITORY_ROOT/Infrastructure/KanameLinkTunnel/desired-state.json"
ADMIN_SCRIPT="$SCRIPT_DIR/kaname-link-cloudflare-admin.mjs"
receipt_path=""
expected_gateway_pid=""
allow_inactive=0
skip_public=0

usage() {
  cat <<'EOF'
Usage: Scripts/verify-kaname-link-tunnel.sh --receipt ABSOLUTE_PATH [options]

Options:
  --desired-state PATH  Override the checked-in desired state.
  --gateway-pid PID     Require the loopback listener to belong to this exact PID.
  --allow-inactive      Permit an inactive/down tunnel for pre-runtime provisioning checks.
  --skip-public         Skip public DNS and unauthenticated HTTPS checks.

Required environment:
  CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_ZONE_ID
EOF
}

while (($# > 0)); do
  case "$1" in
    --receipt)
      receipt_path="${2:?--receipt requires an absolute path}"
      shift 2
      ;;
    --desired-state)
      DESIRED_STATE="${2:?--desired-state requires a path}"
      shift 2
      ;;
    --gateway-pid)
      expected_gateway_pid="${2:?--gateway-pid requires a PID}"
      shift 2
      ;;
    --allow-inactive)
      allow_inactive=1
      shift
      ;;
    --skip-public)
      skip_public=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$receipt_path" || "$receipt_path" != /* ]]; then
  echo "--receipt must be an explicit absolute path" >&2
  exit 2
fi
if [[ -n "$expected_gateway_pid" && ! "$expected_gateway_pid" =~ ^[1-9][0-9]*$ ]]; then
  echo "--gateway-pid must be a positive integer" >&2
  exit 2
fi

for dependency in node lsof; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "Required command is unavailable: $dependency" >&2
    exit 2
  fi
done

desired_fields="$({ node - "$DESIRED_STATE" <<'NODE'
const fs = require("node:fs");
const state = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const origin = new URL(state.originService);
process.stdout.write(`${state.hostname}\n${origin.port}\n`);
NODE
} 2>/dev/null)" || {
  echo "Unable to read hostname and port from desired state" >&2
  exit 2
}
hostname="$(printf '%s\n' "$desired_fields" | sed -n '1p')"
gateway_port="$(printf '%s\n' "$desired_fields" | sed -n '2p')"
if [[ -z "$hostname" || ! "$gateway_port" =~ ^[1-9][0-9]*$ ]]; then
  echo "Desired state hostname or port is invalid" >&2
  exit 2
fi

verification_json="$(node "$ADMIN_SCRIPT" verify --desired-state "$DESIRED_STATE" --receipt "$receipt_path")"
tunnel_state="$(printf '%s' "$verification_json" | node -e '
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  const value = JSON.parse(input);
  if (value.ok !== true || typeof value.tunnel?.status !== "string") process.exit(2);
  process.stdout.write(value.tunnel.status);
});
')"
if [[ "$allow_inactive" -eq 0 && "$tunnel_state" != "healthy" ]]; then
  echo "Tunnel is configured but not healthy (status: $tunnel_state)" >&2
  exit 1
fi

listener_output="$(lsof -nP -a -iTCP:"$gateway_port" -sTCP:LISTEN -Fpcn 2>/dev/null || true)"
listener_names="$(printf '%s\n' "$listener_output" | sed -n 's/^n//p')"
listener_pids="$(printf '%s\n' "$listener_output" | sed -n 's/^p//p' | sort -u)"
listener_name_count="$(printf '%s\n' "$listener_names" | sed '/^$/d' | wc -l | tr -d ' ')"
listener_pid_count="$(printf '%s\n' "$listener_pids" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$listener_name_count" -ne 1 || "$listener_names" != "127.0.0.1:$gateway_port" ]]; then
  echo "Expected exactly one listener at 127.0.0.1:$gateway_port and no wildcard/other listener" >&2
  exit 1
fi
if [[ "$listener_pid_count" -ne 1 ]]; then
  echo "Expected the gateway listener to have exactly one owning PID" >&2
  exit 1
fi
if [[ -n "$expected_gateway_pid" && "$listener_pids" != "$expected_gateway_pid" ]]; then
  echo "Gateway listener PID $listener_pids does not match expected PID $expected_gateway_pid" >&2
  exit 1
fi

if [[ "$skip_public" -eq 0 ]]; then
  for dependency in dig curl; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
      echo "Required public-verification command is unavailable: $dependency" >&2
      exit 2
    fi
  done
  public_addresses="$(dig +short A "$hostname"; dig +short AAAA "$hostname")"
  if [[ -z "$public_addresses" ]]; then
    echo "Public hostname does not resolve: $hostname" >&2
    exit 1
  fi
  probe_denied_public_path() {
    local probe_path="$1"
    local probe_label="$2"
    local http_code
    http_code="$(curl \
      --silent \
      --show-error \
      --path-as-is \
      --max-time 15 \
      --output /dev/null \
      --write-out '%{http_code}' \
      "https://$hostname$probe_path")"
    case "$http_code" in
      401|403|404) ;;
      *)
        echo "$probe_label public probe returned unsafe/unexpected HTTP status $http_code" >&2
        exit 1
        ;;
    esac
  }

  probe_denied_public_path "/health" "Loopback-only /health"
  probe_denied_public_path "/v1/enroll/extra" "Non-exact enrollment path"
  probe_denied_public_path "/__kaname_link_unauthenticated_probe__" "Unknown path"
fi

printf '%s\n' "$verification_json"
printf 'Kaname Link tunnel verified: hostname=%s tunnel_status=%s gateway_pid=%s\n' \
  "$hostname" "$tunnel_state" "$listener_pids"
