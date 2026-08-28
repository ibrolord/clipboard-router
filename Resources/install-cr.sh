#!/bin/bash

set -euo pipefail

DESTINATION=""
ASSUME_YES=0
REPLACE=0

usage() {
    cat <<'USAGE'
Export Clipboard Router's packaged `cr` command to a user-selected path.

Usage:
  install-cr.sh --destination PATH [--replace] [--yes]

Options:
  --destination PATH  Exact destination file, for example $HOME/.local/bin/cr
  --replace           Explicitly allow replacing an existing regular file
  --yes               Confirm non-interactively after choosing the destination
  --help              Show this help

This helper never chooses or modifies /usr/local/bin, never edits shell startup
files, and never invokes sudo. The destination's parent directory must already
exist and be writable by the current user.
USAGE
}

die() {
    echo "error: $*" >&2
    exit 1
}

require_value() {
    [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --destination)
            require_value "$@"
            DESTINATION="$2"
            shift 2
            ;;
        --replace)
            REPLACE=1
            shift
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ -n "${DESTINATION}" ]] || die "--destination is required; no system path is selected automatically"
[[ "${DESTINATION}" != */ ]] || die "--destination must name the exported file, not a directory"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CLI="${SCRIPT_DIR}/../Helpers/cr"
[[ -x "${SOURCE_CLI}" ]] || die "the packaged command is missing: ${SOURCE_CLI}"
/usr/bin/codesign --verify --strict --verbose=2 "${SOURCE_CLI}"

DESTINATION_PARENT="$(cd "$(dirname "${DESTINATION}")" 2>/dev/null && pwd)" \
    || die "the destination parent directory does not exist"
DESTINATION_NAME="$(basename "${DESTINATION}")"
[[ -n "${DESTINATION_NAME}" && "${DESTINATION_NAME}" != "." && "${DESTINATION_NAME}" != ".." ]] \
    || die "invalid destination file"
DESTINATION="${DESTINATION_PARENT}/${DESTINATION_NAME}"
[[ -w "${DESTINATION_PARENT}" ]] || die "the destination directory is not writable; this helper never invokes sudo"
[[ ! -L "${DESTINATION}" ]] || die "refusing to replace a symbolic link"
if [[ -e "${DESTINATION}" ]]; then
    [[ -f "${DESTINATION}" ]] || die "the destination exists and is not a regular file"
    [[ "${REPLACE}" -eq 1 ]] || die "the destination exists; pass --replace to approve replacement"
fi

if [[ "${ASSUME_YES}" -ne 1 ]]; then
    [[ -t 0 ]] || die "confirmation requires a terminal; pass --yes after reviewing the destination"
    echo "Export signed command:"
    echo "  from: ${SOURCE_CLI}"
    echo "  to:   ${DESTINATION}"
    read -r -p "Continue? [y/N] " RESPONSE
    [[ "${RESPONSE}" == "y" || "${RESPONSE}" == "Y" ]] || die "cancelled"
fi

TEMP_DESTINATION="${DESTINATION_PARENT}/.${DESTINATION_NAME}.clipboardrouter.$$"
trap 'rm -f "${TEMP_DESTINATION}"' EXIT
/usr/bin/ditto "${SOURCE_CLI}" "${TEMP_DESTINATION}"
/bin/chmod 0755 "${TEMP_DESTINATION}"
/usr/bin/codesign --verify --strict --verbose=2 "${TEMP_DESTINATION}"
/bin/mv -f "${TEMP_DESTINATION}" "${DESTINATION}"
trap - EXIT

echo "Exported: ${DESTINATION}"
echo "Clipboard Router did not edit PATH or any shell startup file."
