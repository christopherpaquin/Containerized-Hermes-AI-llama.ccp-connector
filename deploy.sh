#!/usr/bin/env bash
# Deploys Hermes Agent (gateway + dashboard) configured against a llama.cpp
# llama-server already running natively on this host. Safe to re-run.
set -Eeuo pipefail

# shellcheck source=./common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

trap 'error "deploy.sh failed at line ${LINENO}."' ERR

MIN_CONTEXT=65536

step() { printf '\n%s==>%s %s\n' "$BOLD" "$NC" "$*"; }

check_prereqs() {
	step "Checking prerequisites"
	require_cmd docker
	require_cmd curl
	require_cmd jq
	require_cmd sed
	require_cmd id
	require_cmd openssl

	if ! docker compose version >/dev/null 2>&1; then
		error "'docker compose' is not available. Install the Docker Compose plugin."
		exit 3
	fi
	ok "docker compose: $(docker compose version --short 2>/dev/null || echo present)"

	if ! docker info >/dev/null 2>&1; then
		error "Docker daemon is not reachable. Is Docker running, and is this user in the 'docker' group?"
		exit 1
	fi
	ok "Docker daemon reachable"
}

check_llamacpp() {
	step "Checking llama.cpp at ${LLAMACPP_BASE_URL}"
	local host port
	host="$(url_host "$LLAMACPP_BASE_URL")"
	port="$(url_port "$LLAMACPP_BASE_URL")"

	if ! tcp_reachable "$host" "$port" 5; then
		error "Nothing is listening on ${host}:${port}."
		error "Start llama-server (e.g. 'llama-server --jinja -c 65536 -m <model.gguf> --port ${port}') and re-run."
		exit 1
	fi
	ok "Port ${port} is reachable on ${host}"

	local models_json
	if ! models_json="$(fetch_llamacpp_models)"; then
		error "GET ${LLAMACPP_BASE_URL}/models failed. Is llama-server actually serving an OpenAI-compatible API?"
		exit 1
	fi
	ok "llama.cpp OpenAI-compatible API responded at ${LLAMACPP_BASE_URL}/models"

	MODEL_ID="$(resolve_model_id "$models_json")" || {
		error "llama.cpp returned no models. Load a model and re-run."
		exit 1
	}
	ok "Selected model: ${MODEL_ID}"

	local ctx
	ctx="$(detect_context_size "$models_json")"
	if [[ -z "$ctx" ]]; then
		warn "########################################################################"
		warn "# Could not detect llama.cpp's context size (--ctx-size) automatically."
		warn "# Hermes Agent requires >= ${MIN_CONTEXT} tokens of context for agent/"
		warn "# tool-calling use and will refuse to start below that. CONFIRM your"
		warn "# llama-server was launched with --ctx-size ${MIN_CONTEXT} (or higher)."
		warn "########################################################################"
	elif [[ "$ctx" -lt "$MIN_CONTEXT" ]]; then
		warn "########################################################################"
		warn "# llama.cpp is reporting n_ctx=${ctx}, below Hermes Agent's required"
		warn "# ${MIN_CONTEXT}. Hermes will refuse to start against this model."
		warn "# Restart llama-server with --ctx-size ${MIN_CONTEXT} (or higher)."
		warn "########################################################################"
	else
		ok "llama.cpp context size: ${ctx} tokens (>= ${MIN_CONTEXT} required)"
	fi
}

ensure_local_env() {
	step "Preparing deployment .env"
	if [[ ! -f "$ENV_FILE" ]]; then
		cp "$ENV_EXAMPLE" "$ENV_FILE"
		info "Created ${ENV_FILE} from .env.example"
	fi

	local host_uid host_gid
	host_uid="$(id -u)"
	host_gid="$(id -g)"
	upsert_env_var "$ENV_FILE" HERMES_UID "$host_uid"
	upsert_env_var "$ENV_FILE" HERMES_GID "$host_gid"
	ok "HERMES_UID=${host_uid} HERMES_GID=${host_gid} (matches invoking host user)"

	# Reload so this run picks up anything just written.
	load_env
}

check_dashboard_auth() {
	step "Checking dashboard bind/auth configuration"

	if is_loopback_host "$HERMES_DASHBOARD_HOST"; then
		ok "Dashboard bind ${HERMES_DASHBOARD_HOST} is loopback-only; no auth provider required."
		return 0
	fi

	warn "Dashboard is configured to bind to ${HERMES_DASHBOARD_HOST} (non-loopback / LAN-reachable)."
	warn "Hermes refuses to serve a non-loopback dashboard without an auth provider."

	if [[ -z "$HERMES_DASHBOARD_BASIC_AUTH_USERNAME" || -z "$HERMES_DASHBOARD_BASIC_AUTH_PASSWORD" ]]; then
		error "Set HERMES_DASHBOARD_BASIC_AUTH_USERNAME and HERMES_DASHBOARD_BASIC_AUTH_PASSWORD in .env"
		error "before binding the dashboard to a non-loopback address."
		exit 1
	fi

	if [[ -z "$HERMES_DASHBOARD_BASIC_AUTH_SECRET" ]]; then
		local secret
		secret="$(openssl rand -hex 32)"
		upsert_env_var "$ENV_FILE" HERMES_DASHBOARD_BASIC_AUTH_SECRET "$secret"
		load_env
		info "Generated HERMES_DASHBOARD_BASIC_AUTH_SECRET (keeps dashboard sessions stable across restarts)."
	fi

	ok "Basic auth configured for dashboard user '${HERMES_DASHBOARD_BASIC_AUTH_USERNAME}'."
}

ensure_data_dir() {
	step "Preparing persistent data directory"
	if [[ ! -d "$HERMES_DATA_DIR" ]]; then
		mkdir -p "$HERMES_DATA_DIR"
		info "Created ${HERMES_DATA_DIR}"
	else
		ok "${HERMES_DATA_DIR} already exists (preserved)"
	fi
}

validate_compose() {
	step "Validating compose configuration"
	compose config >/dev/null
	ok "compose.yaml is valid"
}

start_containers() {
	step "Pulling ${HERMES_IMAGE}:${HERMES_IMAGE_TAG}"
	compose pull
	ok "Image pulled"

	step "Starting Hermes gateway"
	compose up -d gateway
	wait_for_config_seed
	ok "Gateway is running"

	step "Starting Hermes dashboard"
	compose up -d dashboard
	wait_for_dashboard_port
	ok "Dashboard is running"
}

wait_for_dashboard_port() {
	local probe_host attempts=30
	probe_host="$(dashboard_probe_host)"
	while ((attempts > 0)); do
		if tcp_reachable "$probe_host" "$HERMES_DASHBOARD_PORT" 1; then
			return 0
		fi
		attempts=$((attempts - 1))
		sleep 1
	done
	error "Timed out waiting for the dashboard to listen on ${HERMES_DASHBOARD_HOST}:${HERMES_DASHBOARD_PORT}."
	exit 1
}

wait_for_config_seed() {
	local attempts=30
	while ((attempts > 0)); do
		if docker exec hermes test -f /opt/data/config.yaml 2>/dev/null; then
			return 0
		fi
		attempts=$((attempts - 1))
		sleep 1
	done
	error "Timed out waiting for Hermes to seed config.yaml under ${HERMES_DATA_DIR}."
	exit 1
}

configure_provider() {
	step "Configuring Hermes model provider (custom / llama.cpp)"

	local desired_provider="custom"
	local desired_base_url="$LLAMACPP_BASE_URL"
	local desired_model="$MODEL_ID"
	local desired_api_key="none"

	local current_provider current_base_url current_model
	current_provider="$(hermes_exec hermes config get model.provider 2>/dev/null || true)"
	current_base_url="$(hermes_exec hermes config get model.base_url 2>/dev/null || true)"
	current_model="$(hermes_exec hermes config get model.default 2>/dev/null || true)"

	if [[ "$current_provider" == "$desired_provider" &&
		"$current_base_url" == "$desired_base_url" &&
		"$current_model" == "$desired_model" ]]; then
		ok "model.provider/base_url/default already match desired local llama.cpp config; skipping."
		return 0
	fi

	local cfg="${HERMES_DATA_DIR}/config.yaml"
	if [[ -f "$cfg" ]]; then
		local ts
		ts="$(date -u +%Y%m%dT%H%M%SZ)"
		cp "$cfg" "${cfg}.bak.${ts}"
		info "Backed up config.yaml -> $(basename "$cfg").bak.${ts}"
	fi

	hermes_exec hermes config set model.provider "$desired_provider"
	hermes_exec hermes config set model.base_url "$desired_base_url"
	hermes_exec hermes config set model.default "$desired_model"
	hermes_exec hermes config set model.api_key "$desired_api_key"
	ok "Applied model.provider=custom model.base_url=${desired_base_url} model.default=${desired_model}"

	info "hermes config check:"
	hermes_exec hermes config check || warn "hermes config check reported issues (see above)."
}

print_summary() {
	local provider base_url model
	provider="$(hermes_exec hermes config get model.provider 2>/dev/null || echo unknown)"
	base_url="$(hermes_exec hermes config get model.base_url 2>/dev/null || echo unknown)"
	model="$(hermes_exec hermes config get model.default 2>/dev/null || echo unknown)"

	printf '\n'
	printf 'Hermes Agent:       %s\n' "$(gateway_running && echo running || echo NOT RUNNING)"
	printf 'Hermes Dashboard:   http://%s:%s\n' "$HERMES_DASHBOARD_HOST" "$HERMES_DASHBOARD_PORT"
	printf 'Inference provider: %s\n' "$provider"
	printf 'llama.cpp endpoint: %s\n' "$base_url"
	printf 'Model:              %s\n' "$model"
	printf 'Persistent data:    %s\n' "$HERMES_DATA_DIR"
	printf '\n'
}

main() {
	load_env
	check_prereqs
	check_llamacpp
	ensure_local_env
	check_dashboard_auth
	ensure_data_dir
	validate_compose
	start_containers
	configure_provider
	validate_compose

	step "Running post-deployment health check"
	if "${SCRIPT_DIR}/healthcheck.sh"; then
		ok "Health check passed"
	else
		error "Health check reported failures -- see output above."
		print_summary
		exit 1
	fi

	print_summary
}

main "$@"
