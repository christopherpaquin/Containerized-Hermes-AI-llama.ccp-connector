#!/usr/bin/env bash
# Concise operational status for the Hermes Agent deployment.
set -Eeuo pipefail

# shellcheck source=./common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

status_line() {
	local label="$1" value="$2"
	printf '%-20s %s\n' "${label}:" "$value"
}

main() {
	load_env

	local gw_status dash_status
	gw_status="$(gateway_running && echo running || echo stopped)"
	dash_status="$(dashboard_running && echo running || echo stopped)"

	local image
	image="$(docker inspect -f '{{.Config.Image}}' hermes 2>/dev/null || echo 'n/a')"

	local llama_status="unreachable"
	local ctx=""
	local models_json
	if models_json="$(fetch_llamacpp_models 2>/dev/null)"; then
		llama_status="reachable"
		ctx="$(detect_context_size "$models_json")"
	fi

	local provider="n/a" base_url="n/a" model="n/a"
	if gateway_running; then
		provider="$(hermes_exec hermes config get model.provider 2>/dev/null || echo 'n/a')"
		base_url="$(hermes_exec hermes config get model.base_url 2>/dev/null || echo 'n/a')"
		model="$(hermes_exec hermes config get model.default 2>/dev/null || echo 'n/a')"
	fi

	local auth_status="not required (loopback bind)"
	if ! is_loopback_host "$HERMES_DASHBOARD_HOST"; then
		if [[ -n "$HERMES_DASHBOARD_BASIC_AUTH_USERNAME" ]]; then
			auth_status="basic auth (user '${HERMES_DASHBOARD_BASIC_AUTH_USERNAME}')"
		else
			auth_status="NOT CONFIGURED -- non-loopback bind with no provider"
		fi
	fi

	printf '%sHermes Agent status%s\n\n' "$BOLD" "$NC"
	status_line "Gateway" "$gw_status"
	status_line "Dashboard" "$dash_status"
	status_line "Dashboard URL" "http://${HERMES_DASHBOARD_HOST}:${HERMES_DASHBOARD_PORT}"
	status_line "Dashboard auth" "$auth_status"

	local api_status="disabled"
	if [[ "$API_SERVER_ENABLED" == "true" ]]; then
		api_status="enabled -- http://${API_SERVER_HOST}:${API_SERVER_PORT}/v1"
	fi
	status_line "Gateway API server" "$api_status"
	status_line "Image" "$image"
	status_line "llama.cpp" "${llama_status} (${LLAMACPP_BASE_URL})"
	if [[ -n "$ctx" ]]; then
		status_line "llama.cpp context" "${ctx} tokens"
	fi
	status_line "Configured provider" "$provider"
	status_line "Configured base_url" "$base_url"
	status_line "Configured model" "$model"
	status_line "Persistent data" "$HERMES_DATA_DIR"
}

main "$@"
