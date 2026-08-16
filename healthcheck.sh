#!/usr/bin/env bash
# Verifies the full Hermes -> llama.cpp -> model path actually works, not
# just that containers exist. Exits 0 only if every check passes.
set -Eeuo pipefail

# shellcheck source=./common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

FAILURES=0
MIN_CONTEXT=65536
PROBE_PHRASE="HERMES_LLAMA_OK"

pass() { ok "$*"; }
fail() {
	error "$*"
	FAILURES=$((FAILURES + 1))
}

check_containers() {
	if gateway_running; then pass "Hermes gateway container is running"; else fail "Hermes gateway container ('hermes') is not running"; fi
	if dashboard_running; then pass "Hermes dashboard container is running"; else fail "Hermes dashboard container ('hermes-dashboard') is not running"; fi
}

check_llamacpp() {
	local json
	if json="$(fetch_llamacpp_models)"; then
		pass "llama.cpp OpenAI-compatible API responds at ${LLAMACPP_BASE_URL}/models"
	else
		fail "GET ${LLAMACPP_BASE_URL}/models failed"
		return
	fi

	local ctx
	ctx="$(detect_context_size "$json")"
	if [[ -z "$ctx" ]]; then
		warn "llama.cpp did not report a context size (n_ctx). CONFIRM --ctx-size >= ${MIN_CONTEXT} manually."
	elif [[ "$ctx" -lt "$MIN_CONTEXT" ]]; then
		fail "llama.cpp context size is ${ctx}, below the ${MIN_CONTEXT} Hermes Agent requires for tool use"
	else
		pass "llama.cpp context size is ${ctx} (>= ${MIN_CONTEXT})"
	fi
}

check_dashboard_port() {
	local probe_host port="$HERMES_DASHBOARD_PORT"
	probe_host="$(dashboard_probe_host)"
	if tcp_reachable "$probe_host" "$port" 3; then
		pass "Dashboard port ${HERMES_DASHBOARD_HOST}:${port} is listening"
	else
		fail "Dashboard port ${HERMES_DASHBOARD_HOST}:${port} is not accepting connections"
		return
	fi

	if is_loopback_host "$HERMES_DASHBOARD_HOST"; then
		return
	fi

	local code
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${probe_host}:${port}/" || echo 000)"
	if [[ "$code" == "200" ]]; then
		fail "Dashboard served HTTP 200 with NO credentials on a non-loopback bind -- auth gate is not active!"
	else
		pass "Dashboard requires authentication on its non-loopback bind (unauthenticated request -> HTTP ${code})"
	fi
}

check_api_server() {
	if [[ "$API_SERVER_ENABLED" != "true" ]]; then
		pass "Gateway API server is disabled (API_SERVER_ENABLED != true)"
		return
	fi

	local probe_host
	probe_host="$(api_server_probe_host)"
	if ! tcp_reachable "$probe_host" "$API_SERVER_PORT" 3; then
		fail "Gateway API server port ${API_SERVER_HOST}:${API_SERVER_PORT} is not accepting connections"
		return
	fi
	pass "Gateway API server port ${API_SERVER_HOST}:${API_SERVER_PORT} is listening"

	local code
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${probe_host}:${API_SERVER_PORT}/v1/models" || echo 000)"
	if [[ "$code" == "401" || "$code" == "403" ]]; then
		pass "Gateway API server rejects unauthenticated requests (HTTP ${code})"
	else
		fail "Gateway API server did not reject an unauthenticated request (HTTP ${code}, expected 401/403)"
	fi

	if [[ -n "$API_SERVER_KEY" ]]; then
		code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer ${API_SERVER_KEY}" "http://${probe_host}:${API_SERVER_PORT}/v1/models" || echo 000)"
		if [[ "$code" == "200" ]]; then
			pass "Gateway API server accepts requests with a valid API_SERVER_KEY"
		else
			fail "Gateway API server rejected a request with a valid API_SERVER_KEY (HTTP ${code})"
		fi
	fi
}

check_hermes_config() {
	if ! gateway_running; then
		fail "Cannot verify Hermes configuration -- gateway container is not running"
		return
	fi

	local provider base_url model
	provider="$(hermes_exec hermes config get model.provider 2>/dev/null || true)"
	base_url="$(hermes_exec hermes config get model.base_url 2>/dev/null || true)"
	model="$(hermes_exec hermes config get model.default 2>/dev/null || true)"

	if [[ "$provider" == "custom" ]]; then
		pass "Hermes model.provider = custom"
	else
		fail "Hermes model.provider = '${provider}' (expected 'custom')"
	fi

	if [[ "$base_url" == "$LLAMACPP_BASE_URL" ]]; then
		pass "Hermes model.base_url = ${base_url}"
	else
		fail "Hermes model.base_url = '${base_url}' (expected '${LLAMACPP_BASE_URL}')"
	fi

	if [[ -n "$model" ]]; then
		pass "Hermes model.default = ${model}"
	else
		fail "Hermes model.default is empty"
	fi
}

check_no_cloud_keys() {
	local env_file="${HERMES_DATA_DIR}/.env"
	if [[ ! -f "$env_file" ]]; then
		pass "No cloud provider credentials on disk (${env_file} does not exist)"
		return
	fi

	local hits
	hits="$(grep -E '^[A-Z0-9_]*_API_KEY=.+' "$env_file" 2>/dev/null | grep -vE '^\s*#' || true)"
	if [[ -z "$hits" ]]; then
		pass "No cloud provider API keys found in ${env_file}"
	else
		warn "Cloud provider API key(s) present in ${env_file}:"
		warn "$(printf '%s' "$hits" | sed -E 's/=.*/=<redacted>/')"
		warn "These are not used by the local llama.cpp provider, but auxiliary/fallback"
		warn "tasks could use them if fallback_providers is ever configured. Remove any"
		warn "keys you don't intend to use to keep this deployment strictly local-only."
	fi
}

check_end_to_end() {
	if ! gateway_running; then
		fail "Cannot run end-to-end test -- gateway container is not running"
		return
	fi

	local out
	if ! out="$(docker exec hermes hermes -z "Reply with exactly: ${PROBE_PHRASE}" 2>&1)"; then
		fail "Hermes -> llama.cpp end-to-end test failed to execute: ${out}"
		return
	fi

	if [[ "$out" == *"$PROBE_PHRASE"* ]]; then
		pass "Hermes -> llama.cpp -> model end-to-end test succeeded"
	else
		fail "Hermes -> llama.cpp end-to-end test returned unexpected output: ${out}"
	fi
}

main() {
	load_env
	printf '%sHermes Agent health check%s\n' "$BOLD" "$NC"
	check_containers
	check_llamacpp
	check_dashboard_port
	check_api_server
	check_hermes_config
	check_no_cloud_keys
	check_end_to_end

	printf '\n'
	if ((FAILURES == 0)); then
		ok "All checks passed."
		exit 0
	else
		error "${FAILURES} check(s) failed."
		exit 1
	fi
}

main "$@"
