#!/usr/bin/env bash
# Backs up ~/.hermes (config, sessions, memories, skills, credentials) to a
# timestamped tarball. Safe to run manually or on a cron schedule.
#
# The archive contains real secrets (Slack tokens, API_SERVER_KEY, dashboard
# auth secret, any OAuth credentials) -- it is NOT suitable for git/GitHub,
# even a private repo. Keep it on local disk or push it to another host you
# control (HERMES_BACKUP_REMOTE below); never a public/shared location.
set -Eeuo pipefail

# shellcheck source=./common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
HERMES_BACKUP_DIR="${HERMES_BACKUP_DIR:-${HOME}/hermes-backups}"
HERMES_BACKUP_KEEP="${HERMES_BACKUP_KEEP:-14}"
HERMES_BACKUP_REMOTE="${HERMES_BACKUP_REMOTE:-}"

main() {
	require_cmd tar
	require_cmd find

	if [[ ! -d "$HERMES_DATA_DIR" ]]; then
		error "${HERMES_DATA_DIR} does not exist -- nothing to back up."
		exit 1
	fi

	mkdir -p "$HERMES_BACKUP_DIR"
	chmod 700 "$HERMES_BACKUP_DIR"

	local timestamp archive
	timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
	archive="${HERMES_BACKUP_DIR}/hermes-backup-${timestamp}.tar.gz"

	info "Archiving ${HERMES_DATA_DIR} -> ${archive}"
	# home/.cache and lazy-packages are pure, regenerable caches (npm/pip
	# downloads, on-demand Python deps for optional features) -- excluding
	# them keeps the backup to real state instead of ~500MB of cache.
	tar czf "$archive" \
		--exclude='.hermes/home/.cache' \
		--exclude='.hermes/lazy-packages' \
		-C "$HOME" .hermes
	chmod 600 "$archive"
	ok "Backup created: ${archive} ($(du -h "$archive" | cut -f1))"

	if [[ -n "$HERMES_BACKUP_REMOTE" ]]; then
		require_cmd rsync
		info "Copying to remote: ${HERMES_BACKUP_REMOTE}"
		rsync -a "$archive" "$HERMES_BACKUP_REMOTE/"
		ok "Copied to ${HERMES_BACKUP_REMOTE}"
	fi

	local count
	count="$(find "$HERMES_BACKUP_DIR" -maxdepth 1 -name 'hermes-backup-*.tar.gz' | wc -l)"
	if ((count > HERMES_BACKUP_KEEP)); then
		info "Rotating: keeping the newest ${HERMES_BACKUP_KEEP} of ${count} local backups"
		find "$HERMES_BACKUP_DIR" -maxdepth 1 -name 'hermes-backup-*.tar.gz' -printf '%T@ %p\n' |
			sort -rn | tail -n "+$((HERMES_BACKUP_KEEP + 1))" | cut -d' ' -f2- |
			while IFS= read -r old; do
				rm -f "$old"
				info "Removed old backup: $(basename "$old")"
			done
	fi

	ok "Done. $(find "$HERMES_BACKUP_DIR" -maxdepth 1 -name 'hermes-backup-*.tar.gz' | wc -l) backup(s) retained in ${HERMES_BACKUP_DIR}."
}

main "$@"
