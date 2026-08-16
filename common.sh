#!/usr/bin/env bash
# Shared helpers for the Hermes Agent deployment scripts.
# Sourced by deploy.sh, healthcheck.sh, status.sh, uninstall.sh.
# shellcheck disable=SC2034 # variables here are consumed by the sourcing scripts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

if [[ -t 1 ]]; then
	RED=$'\033[0;31m'
	GREEN=$'\033[0;32m'
	YELLOW=$'\033[0;33m'
	BLUE=$'\033[0;34m'
	BOLD=$'\033[1m'
	NC=$'\033[0m'
else
	RED=""
	GREEN=""
	YELLOW=""
	BLUE=""
	BOLD=""
	NC=""
fi

info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
ok() { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
error() { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*" >&2; }

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		error "Required command '$1' not found in PATH. Install it and re-run."
		exit 3
	fi
}

# Loads ./.env (if present) and fills in defaults for anything unset.
load_env() {
	if [[ -f "$ENV_FILE" ]]; then
		set -a
		# shellcheck disable=SC1090
		source "$ENV_FILE"
		set +a
	fi
	HERMES_IMAGE="${HERMES_IMAGE:-nousresearch/hermes-agent}"
	HERMES_IMAGE_TAG="${HERMES_IMAGE_TAG:-v2026.8.13}"
	HERMES_UID="${HERMES_UID:-10000}"
	HERMES_GID="${HERMES_GID:-10000}"
	LLAMACPP_BASE_URL="${LLAMACPP_BASE_URL:-http://127.0.0.1:8080/v1}"
	HERMES_MODEL="${HERMES_MODEL:-}"
	HERMES_DASHBOARD_HOST="${HERMES_DASHBOARD_HOST:-127.0.0.1}"
	HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
	HERMES_DASHBOARD_BASIC_AUTH_USERNAME="${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-}"
	HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-}"
	HERMES_DASHBOARD_BASIC_AUTH_SECRET="${HERMES_DASHBOARD_BASIC_AUTH_SECRET:-}"
	API_SERVER_ENABLED="${API_SERVER_ENABLED:-false}"
	API_SERVER_HOST="${API_SERVER_HOST:-127.0.0.1}"
	API_SERVER_PORT="${API_SERVER_PORT:-8642}"
	API_SERVER_KEY="${API_SERVER_KEY:-}"
	SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
	SLACK_APP_TOKEN="${SLACK_APP_TOKEN:-}"
	SLACK_ALLOWED_USERS="${SLACK_ALLOWED_USERS:-}"
	HERMES_DATA_DIR="${HOME}/.hermes"
}

# True (exit 0) when the given bind address is loopback-only.
is_loopback_host() {
	local h="$1"
	[[ "$h" == "127.0.0.1" || "$h" == "::1" || "$h" == "localhost" ]]
}

# Address to probe FROM this host for a service bound to the given host.
# A 0.0.0.0 (or ::) wildcard bind is also reachable via loopback.
probe_host_for() {
	local h="$1"
	if [[ "$h" == "0.0.0.0" || "$h" == "::" ]]; then
		printf '127.0.0.1'
	else
		printf '%s' "$h"
	fi
}

dashboard_probe_host() { probe_host_for "$HERMES_DASHBOARD_HOST"; }
api_server_probe_host() { probe_host_for "$API_SERVER_HOST"; }

# Idempotently set KEY=VALUE in a dotenv-style file, no duplicate keys.
upsert_env_var() {
	local file="$1" key="$2" value="$3"
	if [[ ! -f "$file" ]]; then
		printf '%s=%s\n' "$key" "$value" >"$file"
		return 0
	fi
	if grep -qE "^${key}=" "$file"; then
		sed -i "s|^${key}=.*|${key}=${value}|" "$file"
	else
		printf '%s=%s\n' "$key" "$value" >>"$file"
	fi
}

compose() {
	(cd "$SCRIPT_DIR" && docker compose --env-file "$ENV_FILE" "$@")
}

# Parses host:port out of a base URL like http://127.0.0.1:8080/v1
url_host() { printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*$##'; }
url_port() {
	local rest
	rest="$(printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://[^:/]+##')"
	if [[ "$rest" =~ ^:([0-9]+) ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
	elif [[ "$1" =~ ^https:// ]]; then
		printf '443'
	else
		printf '80'
	fi
}

# TCP-level reachability check, no HTTP semantics involved.
tcp_reachable() {
	local host="$1" port="$2" timeout_s="${3:-3}"
	timeout "$timeout_s" bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" 2>/dev/null
}

fetch_llamacpp_models() {
	curl -fsS --max-time 5 "${LLAMACPP_BASE_URL}/models"
}

# Resolves which model id Hermes should use. Prints the id on stdout.
# Honors HERMES_MODEL override; auto-selects when exactly one model is served.
resolve_model_id() {
	local json="$1" count
	count="$(jq -r '.data | length' <<<"$json")"

	if [[ -n "$HERMES_MODEL" ]]; then
		printf '%s' "$HERMES_MODEL"
		return 0
	fi

	if [[ "$count" -eq 1 ]]; then
		jq -r '.data[0].id' <<<"$json"
		return 0
	fi

	if [[ "$count" -gt 1 ]]; then
		warn "llama.cpp is serving ${count} models and HERMES_MODEL is not set in .env."
		warn "Defaulting to the first model. Set HERMES_MODEL in .env to pin a specific one."
		jq -r '.data[0].id' <<<"$json"
		return 0
	fi

	return 1
}

# Prints the detected context size (n_ctx) if the server exposes it, else empty.
detect_context_size() {
	local json="$1"
	jq -r '.data[0].meta.n_ctx // empty' <<<"$json"
}

hermes_exec() {
	docker exec hermes "$@"
}

gateway_running() {
	[[ "$(docker inspect -f '{{.State.Running}}' hermes 2>/dev/null)" == "true" ]]
}

dashboard_running() {
	[[ "$(docker inspect -f '{{.State.Running}}' hermes-dashboard 2>/dev/null)" == "true" ]]
}
