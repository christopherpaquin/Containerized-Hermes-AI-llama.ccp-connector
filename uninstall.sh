#!/usr/bin/env bash
# Removes the Hermes Agent containers created by this deployment.
# Never touches llama.cpp (it isn't managed by this deployment).
#
# By default, ~/.hermes (sessions, memories, skills, config, credentials)
# is preserved. Pass --purge to also delete it -- this is destructive and
# requires typed confirmation.
set -Eeuo pipefail

# shellcheck source=./common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PURGE=0

usage() {
	cat <<EOF
Usage: $(basename "$0") [--purge]

  (no flags)  Stop and remove the Hermes gateway/dashboard containers.
              ~/.hermes is left untouched.
  --purge     Also delete ~/.hermes (sessions, memories, skills, config,
              credentials). Requires typed confirmation. Irreversible.
EOF
}

for arg in "$@"; do
	case "$arg" in
	--purge) PURGE=1 ;;
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

main() {
	load_env

	step_msg="Stopping and removing Hermes containers"
	printf '%s==>%s %s\n' "$BOLD" "$NC" "$step_msg"
	compose down
	ok "Containers removed. ${HERMES_DATA_DIR} was left untouched."

	if ((PURGE == 0)); then
		info "Run with --purge to also delete ${HERMES_DATA_DIR} (sessions, memories, skills, config, credentials)."
		return 0
	fi

	warn "########################################################################"
	warn "# --purge will PERMANENTLY DELETE ${HERMES_DATA_DIR}"
	warn "# This destroys sessions, memories, skills, config, and credentials."
	warn "# This does NOT affect llama.cpp."
	warn "########################################################################"
	read -r -p "Type the exact path '${HERMES_DATA_DIR}' to confirm deletion: " confirm
	if [[ "$confirm" != "$HERMES_DATA_DIR" ]]; then
		error "Confirmation did not match. Aborting purge; containers remain removed but data was kept."
		exit 1
	fi

	rm -rf "${HERMES_DATA_DIR:?}"
	ok "Deleted ${HERMES_DATA_DIR}"
}

main
