#!/usr/bin/env bats
# Tests mempalace-provider-install.sh's control flow (idempotency, rollback,
# uninstall) against a fake `docker`/`hermes` stub -- fully offline, never
# touches a real Hermes deployment.

setup() {
	REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
	WORK_DIR="$(mktemp -d)"
	FAKE_HOME="${WORK_DIR}/home"
	FAKE_BIN="${WORK_DIR}/bin"
	mkdir -p "$FAKE_HOME" "$FAKE_BIN"

	# --- fake `docker` on PATH ahead of the real one ---
	# Container/restart state lives in plain files under
	# $FAKE_HOME/.fake-docker-state. `hermes config get/set/unset`, though,
	# operate directly on config.yaml -- same as the real `hermes` CLI does
	# -- specifically so that rollback()'s `cp` of a backed-up config.yaml
	# also restores memory.provider, exactly as it would for real.
	STATE_DIR="${FAKE_HOME}/.fake-docker-state"
	mkdir -p "$STATE_DIR"
	echo "true" >"${STATE_DIR}/gateway_running"

	cat >"${FAKE_BIN}/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="${FAKE_DOCKER_STATE_DIR:?}"
CONFIG_YAML="${HOME}/.hermes/config.yaml"
MARKER="__memory_provider__"

if [[ "$1" == "inspect" ]]; then
	# docker inspect -f '{{.State.Running}}' <container>
	cat "${STATE_DIR}/gateway_running"
	exit 0
fi

if [[ "$1" == "logs" ]]; then
	# Real docker: `docker logs hermes --since <RFC3339>` only returns lines
	# from that point forward. Fake it with a timestamped log file so tests
	# can prove a STALE pre-restart line doesn't satisfy a post-restart
	# check -- the exact bug being guarded against here.
	since=""
	shift
	while [[ $# -gt 0 ]]; do
		if [[ "$1" == "--since" ]]; then
			since="$2"
			shift 2
		else
			shift
		fi
	done
	touch "${STATE_DIR}/log.txt"
	if [[ -n "$since" ]]; then
		awk -v since="$since" '$1 >= since' "${STATE_DIR}/log.txt"
	else
		cat "${STATE_DIR}/log.txt"
	fi
	exit 0
fi

if [[ "$1" == "exec" ]]; then
	shift
	shift # container name ("hermes")
	# Now: hermes config get|set|unset memory.provider [value] | hermes gateway restart
	if [[ "$1" == "hermes" && "$2" == "config" ]]; then
		case "$3" in
		get)
			[[ "$4" == "memory.provider" ]]
			if grep -q "^${MARKER}: " "$CONFIG_YAML" 2>/dev/null; then
				grep "^${MARKER}: " "$CONFIG_YAML" | sed "s/^${MARKER}: //"
				exit 0
			else
				exit 1
			fi
			;;
		set)
			[[ "$4" == "memory.provider" ]]
			grep -v "^${MARKER}: " "$CONFIG_YAML" >"${CONFIG_YAML}.tmp" 2>/dev/null || true
			mv "${CONFIG_YAML}.tmp" "$CONFIG_YAML"
			echo "${MARKER}: $5" >>"$CONFIG_YAML"
			exit 0
			;;
		unset)
			[[ "$4" == "memory.provider" ]]
			grep -v "^${MARKER}: " "$CONFIG_YAML" >"${CONFIG_YAML}.tmp" 2>/dev/null || true
			mv "${CONFIG_YAML}.tmp" "$CONFIG_YAML"
			exit 0
			;;
		esac
	fi
	if [[ "$1" == "hermes" && "$2" == "gateway" && "$3" == "restart" ]]; then
		if [[ -f "${STATE_DIR}/restart_should_fail" ]]; then
			exit 1
		fi
		echo "true" >"${STATE_DIR}/gateway_running"
		if [[ ! -f "${STATE_DIR}/suppress_log_line" ]]; then
			printf '%s mempalace-remote: initialized (session=x)\n' "$(date -u +%Y-%m-%dT%H:%M:%S)" >>"${STATE_DIR}/log.txt"
		fi
		exit 0
	fi
	echo "fake docker exec: unhandled command: $*" >&2
	exit 99
fi

echo "fake docker: unhandled subcommand: $1" >&2
exit 98
FAKE_DOCKER
	chmod +x "${FAKE_BIN}/docker"
	export FAKE_DOCKER_STATE_DIR="$STATE_DIR"

	export HOME="$FAKE_HOME"
	export PATH="${FAKE_BIN}:${PATH}"
	export SCRIPT="${REPO_DIR}/mempalace-provider-install.sh"
	export HERMES_DATA_DIR="${FAKE_HOME}/.hermes"
	mkdir -p "${HERMES_DATA_DIR}"
	printf 'model:\n  default: /models/x.gguf\n' >"${HERMES_DATA_DIR}/config.yaml"
}

teardown() {
	rm -rf "$WORK_DIR"
}

# Mirrors the fake docker's own config.yaml marker line, so tests assert
# against the same place rollback()'s config.yaml restore would affect.
provider_value() {
	grep "^__memory_provider__: " "${HERMES_DATA_DIR}/config.yaml" 2>/dev/null | sed 's/^__memory_provider__: //'
}

@test "first install: plugin files copied, provider set, gateway restarted" {
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[ -f "${HERMES_DATA_DIR}/plugins/mempalace-remote/__init__.py" ]
	[ -f "${HERMES_DATA_DIR}/plugins/mempalace-remote/plugin.yaml" ]
	# Dev-only test fixtures must never be shipped to the host.
	[ ! -d "${HERMES_DATA_DIR}/plugins/mempalace-remote/tests" ]
	[ "$(provider_value)" = "mempalace-remote" ]
}

@test "idempotent re-install: second run is a no-op for provider config" {
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"already set to mempalace-remote"* ]]
	[ "$(provider_value)" = "mempalace-remote" ]
}

@test "missing rsync: fails cleanly before touching anything" {
	# Build a minimal PATH with no rsync reachable, but keep the fake docker
	# and enough coreutils for the script's own bookkeeping to run.
	MINIMAL_BIN="${WORK_DIR}/minimal-bin"
	mkdir -p "$MINIMAL_BIN"
	for cmd in bash cp mv mkdir date grep sed cat rm dirname basename sleep chown printf true; do
		p="$(command -v "$cmd" || true)"
		[[ -n "$p" ]] && ln -sf "$p" "${MINIMAL_BIN}/${cmd}"
	done
	ln -sf "${FAKE_BIN}/docker" "${MINIMAL_BIN}/docker"

	PATH="${MINIMAL_BIN}" run "$SCRIPT"
	[ "$status" -ne 0 ]
	[[ "$output" == *"rsync"* ]]
	[ ! -d "${HERMES_DATA_DIR}/plugins/mempalace-remote" ]
}

@test "gateway not running: refuses to install" {
	echo "false" >"${STATE_DIR}/gateway_running"
	run "$SCRIPT"
	[ "$status" -ne 0 ]
	[[ "$output" == *"not running"* ]]
}

@test "restart failure triggers rollback: config and plugin dir restored" {
	# First a clean install, so there's a "previous" state to roll back to.
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	cp "${HERMES_DATA_DIR}/config.yaml" "${WORK_DIR}/config-after-first-install.yaml"

	# Now force the *second* run's restart to fail.
	touch "${STATE_DIR}/restart_should_fail"
	run "$SCRIPT"
	[ "$status" -ne 0 ]
	[[ "$output" == *"rolling back"* ]]
	# Plugin directory must still be intact (restored from the pre-run backup).
	[ -f "${HERMES_DATA_DIR}/plugins/mempalace-remote/__init__.py" ]
	# No stray .bak directories left lying around next to the real one.
	[ "$(find "${HERMES_DATA_DIR}/plugins" -maxdepth 1 -name 'mempalace-remote.bak-*' | wc -l)" -eq 0 ]
}

@test "provider never confirms activation: install fails and rolls back (not just a warning)" {
	touch "${STATE_DIR}/suppress_log_line"
	run "$SCRIPT"
	[ "$status" -ne 0 ]
	[[ "$output" == *"rolling back"* ]]
	[[ "$output" == *"never appeared"* || "$output" == *"provider likely failed"* ]]
	# Nothing left half-applied: provider config was rolled back too.
	[ -z "$(provider_value)" ]
}

@test "stale pre-restart init log does not satisfy this restart's activation check" {
	# Simulate an older install that logged its own "initialized" line a
	# long time ago, then this run's restart producing no fresh one --
	# verification must look ONLY at logs from >= this restart's boundary,
	# not accept the old line just because it's somewhere in `docker logs`.
	mkdir -p "$STATE_DIR"
	echo "2000-01-01T00:00:00 mempalace-remote: initialized (session=stale)" >"${STATE_DIR}/log.txt"
	touch "${STATE_DIR}/suppress_log_line"
	run "$SCRIPT"
	[ "$status" -ne 0 ]
	[[ "$output" == *"rolling back"* ]]
	[ -z "$(provider_value)" ]
}

@test "successful install leaves no backup artifacts behind" {
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[ "$(find "${HERMES_DATA_DIR}" -maxdepth 1 -name 'config.yaml.bak-*' | wc -l)" -eq 0 ]
	[ "$(find "${HERMES_DATA_DIR}/plugins" -maxdepth 1 -name 'mempalace-remote.bak-*' 2>/dev/null | wc -l)" -eq 0 ]
}

@test "successful uninstall leaves no backup artifacts behind" {
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	run "$SCRIPT" --uninstall
	[ "$status" -eq 0 ]
	[ "$(find "${HERMES_DATA_DIR}" -maxdepth 1 -name 'config.yaml.bak-*' | wc -l)" -eq 0 ]
	[ "$(find "${HERMES_DATA_DIR}/plugins" -maxdepth 1 -name 'mempalace-remote.bak-*' 2>/dev/null | wc -l)" -eq 0 ]
}

@test "uninstall: removes plugin dir and unsets provider when we own it" {
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	run "$SCRIPT" --uninstall
	[ "$status" -eq 0 ]
	[ ! -d "${HERMES_DATA_DIR}/plugins/mempalace-remote" ]
	[ -z "$(provider_value)" ]
}

@test "uninstall: leaves memory.provider untouched if a different provider is now active" {
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	docker exec hermes hermes config set memory.provider some-other-provider
	run "$SCRIPT" --uninstall
	[ "$status" -eq 0 ]
	[ ! -d "${HERMES_DATA_DIR}/plugins/mempalace-remote" ]
	[ "$(provider_value)" = "some-other-provider" ]
}

@test "--help prints usage and exits 0" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"Usage:"* ]]
}
