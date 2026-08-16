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
#
# If HERMES_CRON_BACKUP_NFS_MOUNT is set, verifies that path is an actual
# mount point before backing up -- and aborts (no backup written, emails
# ALERT_EMAIL_TO via Gmail SMTP) rather than silently writing to local
# disk under an unmounted mount point, which would look identical to a
# successful off-volume backup.
set -Eeuo pipefail

SRC="/opt/data"
DEST="${HERMES_CRON_BACKUP_DEST:-/opt/data/backups}"
KEEP="${HERMES_CRON_BACKUP_KEEP:-14}"
NFS_MOUNT_CHECK="${HERMES_CRON_BACKUP_NFS_MOUNT:-}"
ALERT_SMTP_FROM="${ALERT_SMTP_FROM:-}"
ALERT_SMTP_APP_PASSWORD="${ALERT_SMTP_APP_PASSWORD:-}"
ALERT_EMAIL_TO="${ALERT_EMAIL_TO:-}"

# Self-contained duplicate of common.sh's send_alert_email -- this script
# has no access to the repo's common.sh from inside the container.
send_alert_email() {
	local subject="$1" body="$2"
	if [[ -z "$ALERT_SMTP_FROM" || -z "$ALERT_SMTP_APP_PASSWORD" || -z "$ALERT_EMAIL_TO" ]]; then
		echo "Email alerting not configured -- cannot send: $subject" >&2
		return 1
	fi
	local msg
	msg="$(mktemp)"
	{
		printf 'From: Hermes Backup <%s>\n' "$ALERT_SMTP_FROM"
		printf 'To: %s\n' "$ALERT_EMAIL_TO"
		printf 'Subject: %s\n' "$subject"
		printf 'Date: %s\n' "$(date -R)"
		printf '\n'
		printf '%s\n' "$body"
	} >"$msg"
	local rc=0
	curl -s --url "smtps://smtp.gmail.com:465" --ssl-reqd \
		--mail-from "$ALERT_SMTP_FROM" --mail-rcpt "$ALERT_EMAIL_TO" \
		--user "${ALERT_SMTP_FROM}:${ALERT_SMTP_APP_PASSWORD}" \
		--upload-file "$msg" || rc=$?
	rm -f "$msg"
	return "$rc"
}

if [[ -n "$NFS_MOUNT_CHECK" ]] && ! mountpoint -q "$NFS_MOUNT_CHECK" 2>/dev/null; then
	msg="Hermes backup ABORTED (container cron): expected mount '${NFS_MOUNT_CHECK}' is not mounted as of $(date -u +%FT%TZ). No backup was written -- it would otherwise have landed on the same volume it's supposed to be backing up away from. Check the host's NFS mount and the compose.yaml volume, then wait for the next scheduled run or trigger one manually."
	echo "$msg" >&2
	send_alert_email "Hermes backup ALERT: NFS mount missing (container cron)" "$msg" || echo "Could not send alert email" >&2
	exit 1
fi

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
