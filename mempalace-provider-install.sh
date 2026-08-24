#!/usr/bin/env bash
# Installs (or uninstalls) the mempalace-remote Hermes MemoryProvider plugin
# into the persistent ~/.hermes/plugins directory and wires it up via
# `hermes config set memory.provider`. Safe to re-run (idempotent).
#
# On any failure partway through install, automatically rolls back both the
# plugin directory and config.yaml to their pre-install state and restarts
# the gateway with that restored state -- never leaves a half-applied setup.
#
# Usage: ./mempalace-provider-install.sh [--uninstall]
set -Eeuo pipefail

# shellcheck source=./common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

step() { printf '\n%s==>%s %s\n' "$BOLD" "$NC" "$*"; }

PLUGIN_NAME="mempalace-remote"
PLUGIN_SRC="${SCRIPT_DIR}/plugins/${PLUGIN_NAME}"
PLUGIN_DEST=""   # set in main(), after load_env populates HERMES_DATA_DIR
CONFIG_YAML=""

usage() {
	cat <<-EOF
	Usage: $0 [--uninstall]

	Installs the ${PLUGIN_NAME} MemoryProvider plugin into the persistent
	Hermes plugins directory (survives container recreation) and sets
	memory.provider in config.yaml via the official 'hermes config' CLI
	(no YAML surgery). Backs up config.yaml and any previously installed
	plugin directory first; rolls both back automatically -- restoring and
	restarting the gateway with the prior state -- if anything fails.

	  --uninstall   Remove the plugin directory and unset memory.provider,
	                but only if it is still set to ${PLUGIN_NAME} (leaves a
	                newer provider choice untouched).
	EOF
}

UNINSTALL=false
for arg in "$@"; do
	case "$arg" in
	--uninstall) UNINSTALL=true ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		error "Unknown argument: $arg"
		usage
		exit 2
		;;
	esac
done

check_prereqs() {
	step "Checking prerequisites"
	require_cmd rsync
	require_cmd docker
	if ! gateway_running; then
		error "Hermes gateway container ('hermes') is not running. Start it first (./deploy.sh)."
		exit 1
	fi
	ok "Prerequisites present, gateway running."
}

BACKUP_SUFFIX="$(date +%Y%m%d%H%M%S%N)"
CONFIG_BACKUP=""
PLUGIN_BACKUP=""

# Snapshots current config.yaml and plugin directory before mutating either,
# so rollback() always has something concrete to restore.
backup_state() {
	step "Backing up current state"
	if [[ -f "$CONFIG_YAML" ]]; then
		CONFIG_BACKUP="${CONFIG_YAML}.bak-${BACKUP_SUFFIX}"
		cp -p "$CONFIG_YAML" "$CONFIG_BACKUP"
		ok "config.yaml backed up to $(basename "$CONFIG_BACKUP")"
	fi
	if [[ -d "$PLUGIN_DEST" ]]; then
		PLUGIN_BACKUP="${PLUGIN_DEST}.bak-${BACKUP_SUFFIX}"
		mv "$PLUGIN_DEST" "$PLUGIN_BACKUP"
		ok "Previous plugin directory moved aside to $(basename "$PLUGIN_BACKUP")"
	fi
}

# Restores both the plugin directory and config.yaml to their pre-install
# state and restarts the gateway with that restored state -- so a failed
# install never leaves new plugin code paired with stale config, or vice
# versa, and never leaves the running gateway out of sync with disk.
rollback() {
	error "Install failed -- rolling back."
	if [[ -n "$PLUGIN_BACKUP" && -d "$PLUGIN_BACKUP" ]]; then
		rm -rf "$PLUGIN_DEST"
		mv "$PLUGIN_BACKUP" "$PLUGIN_DEST"
		warn "Restored previous plugin directory."
	elif [[ -d "$PLUGIN_DEST" ]]; then
		rm -rf "$PLUGIN_DEST"
		warn "Removed partially-installed plugin directory (no prior version existed)."
	fi
	if [[ -n "$CONFIG_BACKUP" && -f "$CONFIG_BACKUP" ]]; then
		cp -p "$CONFIG_BACKUP" "$CONFIG_YAML"
		warn "Restored config.yaml from backup."
	fi
	warn "Restarting gateway with restored state..."
	if hermes_exec hermes gateway restart >/dev/null 2>&1 && gateway_running; then
		warn "Rollback complete -- gateway is back on the pre-install state."
	else
		error "Rollback restored files, but the gateway restart failed or it is not running now."
		error "Check 'docker logs hermes' and restart it manually: docker compose restart gateway"
	fi
}

install_plugin_files() {
	step "Installing plugin files -> ${PLUGIN_DEST}"
	mkdir -p "$(dirname "$PLUGIN_DEST")"
	rsync -a --delete --exclude 'tests/' --exclude '__pycache__/' "${PLUGIN_SRC}/" "${PLUGIN_DEST}/"
	if ! chown -R "${HERMES_UID}:${HERMES_GID}" "$PLUGIN_DEST" 2>/dev/null; then
		warn "Could not chown ${PLUGIN_DEST} to ${HERMES_UID}:${HERMES_GID} -- continuing (only matters if it differs from the rest of ~/.hermes, which is already owned correctly)."
	fi
	ok "Plugin files in place."
}

set_provider_config() {
	step "Setting memory.provider = ${PLUGIN_NAME} in config.yaml"
	if hermes_exec hermes config get memory.provider 2>/dev/null | grep -qx "$PLUGIN_NAME"; then
		ok "memory.provider already set to ${PLUGIN_NAME} (idempotent, nothing to do)."
		return 0
	fi
	hermes_exec hermes config set memory.provider "$PLUGIN_NAME"
	ok "memory.provider set."
}

restart_and_verify() {
	step "Restarting gateway to load the new provider"
	# Captured BEFORE triggering the restart, so the activation check below
	# only ever sees log lines from THIS restart -- a stale "initialized"
	# line left over from a previous install (e.g. on a reinstall/upgrade)
	# must never be able to satisfy it.
	local restart_boundary
	restart_boundary="$(date -u +%Y-%m-%dT%H:%M:%S)"
	hermes_exec hermes gateway restart
	if ! gateway_running; then
		error "Gateway is not running immediately after restart."
		return 1
	fi

	# Definitive activation check, not just "the container is up": the
	# plugin logs "mempalace-remote: initialized" from its own initialize()
	# hook, which only fires if Hermes actually imported and registered the
	# provider. Its absence means an import error, a bad config, or an
	# unresolvable MCP target -- any of which should fail this install (and
	# trigger rollback via main()'s ERR trap), not just warn.
	local _attempt
	for _attempt in $(seq 1 10); do
		if ! gateway_running; then
			error "Gateway stopped running during startup."
			return 1
		fi
		if docker logs hermes --since "$restart_boundary" 2>&1 | grep -qi "mempalace-remote: initialized"; then
			ok "Gateway restarted; mempalace-remote provider confirmed initialized."
			return 0
		fi
		sleep 1
	done
	error "Gateway restarted but no 'mempalace-remote: initialized' log line appeared within 10s -- the provider likely failed to load. Check 'docker logs hermes' for the actual error."
	return 1
}

# Removes this run's transaction backups. Only called after a verified
# success -- on failure, rollback() needs them, and they're left in place
# for rollback's own diagnostics if IT also fails.
cleanup_backups() {
	if [[ -n "$CONFIG_BACKUP" && -f "$CONFIG_BACKUP" ]]; then
		rm -f "$CONFIG_BACKUP"
	fi
	if [[ -n "$PLUGIN_BACKUP" && -d "$PLUGIN_BACKUP" ]]; then
		rm -rf "$PLUGIN_BACKUP"
	fi
	return 0
}

do_uninstall() {
	step "Uninstalling ${PLUGIN_NAME}"
	# Not auto-rolled-back on failure (unlike install): the user explicitly
	# asked to remove this, so silently reinstalling it after a failed step
	# would be more surprising than leaving the backups in place for manual
	# recovery and saying so.
	trap 'error "Uninstall did not fully complete -- backups left at ${CONFIG_BACKUP:-<none>} and ${PLUGIN_BACKUP:-<none>} for manual recovery."' ERR
	backup_state
	if hermes_exec hermes config get memory.provider 2>/dev/null | grep -qx "$PLUGIN_NAME"; then
		hermes_exec hermes config unset memory.provider
		ok "memory.provider unset (was ${PLUGIN_NAME})."
	else
		warn "memory.provider is not currently ${PLUGIN_NAME} -- leaving it untouched (a different provider may be active)."
	fi
	rm -rf "$PLUGIN_DEST"
	ok "Plugin directory removed."
	hermes_exec hermes gateway restart
	ok "Gateway restarted."
	trap - ERR
	cleanup_backups
}

main() {
	load_env
	PLUGIN_DEST="${HERMES_DATA_DIR}/plugins/${PLUGIN_NAME}"
	CONFIG_YAML="${HERMES_DATA_DIR}/config.yaml"

	check_prereqs

	if $UNINSTALL; then
		do_uninstall
		exit 0
	fi

	trap 'rollback' ERR
	backup_state
	install_plugin_files
	set_provider_config
	restart_and_verify
	trap - ERR
	cleanup_backups
	ok "${PLUGIN_NAME} installed and active."
}

main "$@"
