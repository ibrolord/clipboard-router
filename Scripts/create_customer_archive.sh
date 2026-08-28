#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERIFY_SCRIPT="${SCRIPT_DIR}/verify_release.sh"

APP_PATH=""
MANIFEST_PATH=""
PROFILE="local"
DISPLAY_NAME="Clipboard Router"
OUTPUT_ZIP=""
SKIP_NOTARIZATION_CHECK=0
OVERWRITE=0

usage() {
    cat <<'USAGE'
Package a signed, normally notarized, Clipboard Router application as a
deterministic customer-facing download archive.

Usage:
  Scripts/create_customer_archive.sh [options] PATH_TO_APP

Options:
  --output PATH               Zip output path (default: derived under .artifacts/)
  --manifest PATH              Release manifest (default: PATH_TO_APP.release.json)
  --profile local|icloud       Entitlement profile of the input app (default: local)
  --display-name NAME          Customer-facing app name inside the archive (default: "Clipboard Router")
  --skip-notarization-check    Build an engineering-only archive from an unnotarized app.
                                Tags the output filename with -UNNOTARIZED, never asserts
                                Gatekeeper acceptance, and must never be distributed to customers.
  --overwrite                  Replace an existing output archive and sha256 sidecar
  --help                       Show this help

This first runs Scripts/verify_release.sh against PATH_TO_APP, requiring notarization
unless --skip-notarization-check is given. It then stages a copy renamed to the
customer-facing display name, builds a deterministic zip (sorted entries, fixed
per-entry timestamps, preserved POSIX permissions), extracts that zip into a clean
temporary directory, and re-verifies codesign and Gatekeeper on the extracted,
renamed copy before publishing the archive and its sha256 sidecar. Renaming a signed
bundle does not change its code signature or stapled notarization ticket: both are
keyed to bundle contents, not to the bundle's path or folder name.
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
        --output)
            require_value "$@"
            OUTPUT_ZIP="$2"
            shift 2
            ;;
        --manifest)
            require_value "$@"
            MANIFEST_PATH="$2"
            shift 2
            ;;
        --profile)
            require_value "$@"
            PROFILE="$2"
            shift 2
            ;;
        --display-name)
            require_value "$@"
            DISPLAY_NAME="$2"
            shift 2
            ;;
        --skip-notarization-check)
            SKIP_NOTARIZATION_CHECK=1
            shift
            ;;
        --overwrite)
            OVERWRITE=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --*)
            die "unknown option: $1"
            ;;
        *)
            [[ -z "${APP_PATH}" ]] || die "only one application path may be supplied"
            APP_PATH="$1"
            shift
            ;;
    esac
done

[[ -n "${APP_PATH}" ]] || die "an application path is required"
[[ -d "${APP_PATH}" && "${APP_PATH}" == *.app ]] || die "not an application bundle: ${APP_PATH}"
[[ "${PROFILE}" == "local" || "${PROFILE}" == "icloud" ]] || die "--profile must be local or icloud"
[[ -n "${DISPLAY_NAME}" ]] || die "--display-name must not be empty"
[[ "${DISPLAY_NAME}" != */* ]] || die "--display-name must be a single path component"
[[ "${DISPLAY_NAME}" != *.app ]] || die "--display-name must not include .app; it is appended automatically"
if [[ "${SKIP_NOTARIZATION_CHECK}" -eq 1 && -n "${OUTPUT_ZIP}" \
    && "$(basename "${OUTPUT_ZIP}")" != *-UNNOTARIZED.zip ]]; then
    die "--skip-notarization-check requires a custom --output filename ending in -UNNOTARIZED.zip"
fi

if [[ -z "${MANIFEST_PATH}" ]]; then
    MANIFEST_PATH="${APP_PATH}.release.json"
fi
[[ -f "${MANIFEST_PATH}" && ! -L "${MANIFEST_PATH}" ]] || die "missing regular release manifest: ${MANIFEST_PATH}"

echo "Verifying source package before archiving..."
VERIFY_ARGS=(--profile "${PROFILE}" --manifest "${MANIFEST_PATH}")
if [[ "${SKIP_NOTARIZATION_CHECK}" -eq 0 ]]; then
    VERIFY_ARGS+=(--require-notarized)
else
    echo "WARNING: --skip-notarization-check was given; this archive is NOT customer-distributable." >&2
fi
/bin/bash "${VERIFY_SCRIPT}" "${VERIFY_ARGS[@]}" "${APP_PATH}"

VERSION="$(/usr/bin/plutil -extract version raw -o - "${MANIFEST_PATH}")"
BUILD_NUMBER="$(/usr/bin/plutil -extract buildNumber raw -o - "${MANIFEST_PATH}")"

manifest_architecture_label() {
    local index=0
    local value
    local result=""
    while value="$(/usr/bin/plutil -extract "architectures.${index}" raw -o - "${MANIFEST_PATH}" 2>/dev/null)"; do
        result="${result:+${result}-}${value}"
        index=$((index + 1))
    done
    echo "${result}"
}
ARCH_LABEL="$(manifest_architecture_label)"
[[ -n "${ARCH_LABEL}" ]] || die "release manifest has no architecture list"

DISPLAY_APP_NAME="${DISPLAY_NAME}.app"
ARCHIVE_TAG=""
[[ "${SKIP_NOTARIZATION_CHECK}" -eq 0 ]] || ARCHIVE_TAG="-UNNOTARIZED"
if [[ -z "${OUTPUT_ZIP}" ]]; then
    OUTPUT_ZIP="${PROJECT_ROOT}/.artifacts/${DISPLAY_NAME// /-}-${VERSION}-${ARCH_LABEL}${ARCHIVE_TAG}.zip"
fi
[[ "${OUTPUT_ZIP}" == *.zip ]] || die "--output path must end in .zip"

if [[ -e "${OUTPUT_ZIP}" ]]; then
    [[ "${OVERWRITE}" -eq 1 ]] || die "archive already exists; pass --overwrite to replace ${OUTPUT_ZIP}"
fi
SHA_SIDECAR="${OUTPUT_ZIP}.sha256"
if [[ -e "${SHA_SIDECAR}" ]]; then
    [[ "${OVERWRITE}" -eq 1 ]] || die "sha256 sidecar already exists; pass --overwrite to replace ${SHA_SIDECAR}"
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clipboard-router-customer-archive.XXXXXX")"
trap 'rm -rf "${TEMP_ROOT}"' EXIT

STAGE_DIR="${TEMP_ROOT}/stage"
mkdir -p "${STAGE_DIR}"
STAGED_APP="${STAGE_DIR}/${DISPLAY_APP_NAME}"
echo "Staging ${DISPLAY_APP_NAME}..."
/usr/bin/ditto "${APP_PATH}" "${STAGED_APP}"
/usr/bin/xattr -cr "${STAGED_APP}" 2>/dev/null || true

# Renaming a signed/notarized bundle does not change its code signature or stapled
# notarization ticket: both are keyed to bundle contents, not its path or folder name.
/usr/bin/codesign --verify --deep --strict --verbose=2 "${STAGED_APP}" \
    || die "renamed staged app failed codesign verification"
/usr/bin/codesign --verify --strict --verbose=2 "${STAGED_APP}/Contents/Helpers/cr" \
    || die "renamed staged CLI failed codesign verification"

echo "Building deterministic archive..."
STAGE_BUILD_OUTPUT="${TEMP_ROOT}/archive.zip"
/usr/bin/python3 - "${STAGE_DIR}" "${DISPLAY_APP_NAME}" "${STAGE_BUILD_OUTPUT}" <<'PY'
import os
import pathlib
import stat
import sys
import zipfile

stage_dir, display_app_name, output_zip = sys.argv[1:4]
root = pathlib.Path(stage_dir) / display_app_name
FIXED_DATE_TIME = (1980, 1, 1, 0, 0, 0)

entries = sorted(root.rglob("*"), key=lambda p: str(p.relative_to(root)))

with zipfile.ZipFile(output_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    top = zipfile.ZipInfo(display_app_name + "/", date_time=FIXED_DATE_TIME)
    top.create_system = 3
    top.external_attr = (0o755 | stat.S_IFDIR) << 16
    archive.writestr(top, b"")
    for path in entries:
        arcname = f"{display_app_name}/{path.relative_to(root).as_posix()}"
        mode = stat.S_IMODE(path.lstat().st_mode)
        if path.is_symlink():
            info = zipfile.ZipInfo(arcname, date_time=FIXED_DATE_TIME)
            info.create_system = 3
            info.external_attr = (mode | stat.S_IFLNK) << 16
            archive.writestr(info, os.readlink(path))
        elif path.is_dir():
            info = zipfile.ZipInfo(arcname + "/", date_time=FIXED_DATE_TIME)
            info.create_system = 3
            info.external_attr = (mode | stat.S_IFDIR) << 16
            archive.writestr(info, b"")
        else:
            info = zipfile.ZipInfo(arcname, date_time=FIXED_DATE_TIME)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (mode | stat.S_IFREG) << 16
            with open(path, "rb") as handle:
                archive.writestr(info, handle.read())
PY
[[ -f "${STAGE_BUILD_OUTPUT}" ]] || die "archive was not created"

echo "Verifying extracted archive..."
EXTRACT_DIR="${TEMP_ROOT}/extracted"
mkdir -p "${EXTRACT_DIR}"
/usr/bin/ditto -x -k "${STAGE_BUILD_OUTPUT}" "${EXTRACT_DIR}"
EXTRACTED_APP="${EXTRACT_DIR}/${DISPLAY_APP_NAME}"
[[ -d "${EXTRACTED_APP}" ]] || die "extracted archive is missing ${DISPLAY_APP_NAME}"

/usr/bin/codesign --verify --deep --strict --verbose=2 "${EXTRACTED_APP}" \
    || die "extracted archive failed codesign verification"
/usr/bin/codesign --verify --strict --verbose=2 "${EXTRACTED_APP}/Contents/Helpers/cr" \
    || die "extracted CLI failed codesign verification"
[[ -x "${EXTRACTED_APP}/Contents/MacOS/ClipboardRouter" ]] || die "extracted app executable lost its execute bit"
[[ -x "${EXTRACTED_APP}/Contents/Helpers/cr" ]] || die "extracted CLI lost its execute bit"
[[ -x "${EXTRACTED_APP}/Contents/Resources/install-cr.sh" ]] || die "extracted CLI installer lost its execute bit"

if [[ "${SKIP_NOTARIZATION_CHECK}" -eq 0 ]]; then
    /usr/sbin/spctl --assess --type execute --verbose=2 "${EXTRACTED_APP}" \
        || die "extracted archive did not pass Gatekeeper assessment"
    /usr/bin/xcrun stapler validate "${EXTRACTED_APP}" \
        || die "extracted archive is missing a valid stapled notarization ticket"
else
    echo "Gatekeeper assessment (informational only; not required by --skip-notarization-check):"
    /usr/sbin/spctl --assess --type execute --verbose=2 "${EXTRACTED_APP}" || true
fi

mkdir -p "$(dirname "${OUTPUT_ZIP}")"
/bin/cp "${STAGE_BUILD_OUTPUT}" "${OUTPUT_ZIP}"
(cd "$(dirname "${OUTPUT_ZIP}")" && /usr/bin/shasum -a 256 "$(basename "${OUTPUT_ZIP}")") > "${SHA_SIDECAR}.tmp"
/bin/mv "${SHA_SIDECAR}.tmp" "${SHA_SIDECAR}"

echo
echo "Archive: ${OUTPUT_ZIP}"
echo "SHA-256: $(/usr/bin/awk '{print $1}' "${SHA_SIDECAR}")"
echo "Contains: ${DISPLAY_APP_NAME} (${VERSION} build ${BUILD_NUMBER}, ${ARCH_LABEL})"
if [[ "${SKIP_NOTARIZATION_CHECK}" -eq 0 ]]; then
    echo "Verification: codesign + Gatekeeper + stapled notarization ticket passed on the extracted copy"
else
    echo "Verification: codesign passed on the extracted copy; Gatekeeper/notarization NOT required (engineering archive only)"
fi
