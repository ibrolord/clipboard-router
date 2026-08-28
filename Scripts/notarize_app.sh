#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_PATH=""
KEYCHAIN_PROFILE=""
ZIP_PATH="${PROJECT_ROOT}/.artifacts/ClipboardRouter-notarization.zip"
OVERWRITE=0

usage() {
    cat <<'USAGE'
Submit a Developer ID-signed app to Apple's notarization service and staple it.

Usage:
  Scripts/notarize_app.sh --keychain-profile PROFILE [options] PATH_TO_APP

Options:
  --keychain-profile NAME  notarytool credential profile (required)
  --zip PATH               Notarization upload archive path
  --overwrite              Replace an existing upload archive
  --help                   Show this help

Create the credential once with:
  xcrun notarytool store-credentials PROFILE

Credentials are read by notarytool from Keychain. This script never accepts or
writes an Apple ID password, app-specific password, issuer ID, or private key.
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
        --keychain-profile)
            require_value "$@"
            KEYCHAIN_PROFILE="$2"
            shift 2
            ;;
        --zip)
            require_value "$@"
            ZIP_PATH="$2"
            shift 2
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

[[ -n "${KEYCHAIN_PROFILE}" ]] || die "--keychain-profile is required"
[[ -d "${APP_PATH}" && "${APP_PATH}" == *.app ]] || die "not an application bundle: ${APP_PATH}"
[[ "${ZIP_PATH}" == *.zip ]] || die "--zip path must end in .zip"

/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
SIGNING_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "${APP_PATH}" 2>&1)"
if echo "${SIGNING_DETAILS}" | /usr/bin/grep -q 'Signature=adhoc'; then
    die "notarization requires a Developer ID-signed application, not an ad-hoc signature"
fi

if [[ -e "${ZIP_PATH}" ]]; then
    [[ "${OVERWRITE}" -eq 1 ]] || die "archive exists; pass --overwrite to replace ${ZIP_PATH}"
    rm -f "${ZIP_PATH}"
fi
mkdir -p "$(dirname "${ZIP_PATH}")"

echo "Creating notarization archive..."
/usr/bin/ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "Submitting to Apple notarization service..."
/usr/bin/xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${KEYCHAIN_PROFILE}" --wait

echo "Stapling notarization ticket..."
/usr/bin/xcrun stapler staple "${APP_PATH}"
/usr/bin/xcrun stapler validate "${APP_PATH}"
/usr/sbin/spctl --assess --type execute --verbose=2 "${APP_PATH}"

echo "Notarized and stapled: ${APP_PATH}"
echo "Upload archive: ${ZIP_PATH}"
