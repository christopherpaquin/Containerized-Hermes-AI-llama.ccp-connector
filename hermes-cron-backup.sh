#!/usr/bin/env bash
# Runs INSIDE the Hermes gateway container, invoked by Hermes's own cron
# scheduler (`hermes cron create ... --script backup-hermes-data.sh --no-agent`)
# -- not by the host. deploy.sh installs this to
# ~/.hermes/scripts/backup-hermes-data.sh (Hermes cron requires scripts to
# live under ~/.hermes/scripts/); do not run it directly on the host, use
# ./backup.sh for that instead.
#
# Writes to $HERMES_CRON_BACKUP_DEST (default: /opt/data/backups, i.e. still
# on the same volume as the data it's backing up -- see README "Backups").
# Once an NFS share is mounted into the container (add a volume in
# compose.yaml and point HERMES_CRON_BACKUP_DEST at its mount path), this
# becomes a real off-volume backup with no script changes needed.
#
# --no-agent delivers this script's stdout verbatim as the job's result;
# keep stdout to one summary line per run.
set -Eeuo pipefail

SRC="/opt/data"
DEST="${HERMES_CRON_BACKUP_DEST:-/opt/data/backups}"
KEEP="${HERMES_CRON_BACKUP_KEEP:-14}"

mkdir -p "$DEST"
chmod 700 "$DEST"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive="${DEST}/hermes-backup-${timestamp}.tar.gz"

# Exclude: home/.cache and lazy-packages (regenerable caches), and the
# destination directory itself (avoid tarring the backups into the backup).
tar czf "$archive" \
	--exclude="home/.cache" \
	--exclude="lazy-packages" \
	--exclude="$(basename "$DEST")" \
	-C "$SRC" .
chmod 600 "$archive"

size="$(du -h "$archive" | cut -f1)"

count="$(find "$DEST" -maxdepth 1 -name 'hermes-backup-*.tar.gz' | wc -l)"
removed=0
if ((count > KEEP)); then
	while IFS= read -r old; do
		rm -f "$old"
		removed=$((removed + 1))
	done < <(find "$DEST" -maxdepth 1 -name 'hermes-backup-*.tar.gz' -printf '%T@ %p\n' |
		sort -rn | tail -n "+$((KEEP + 1))" | cut -d' ' -f2-)
fi

retained="$((count > KEEP ? KEEP : count))"
echo "Hermes backup: ${archive} (${size}). Retained ${retained} backup(s) in ${DEST}, removed ${removed} old."
