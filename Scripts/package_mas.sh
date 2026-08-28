#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGE_SCRIPT="${SCRIPT_DIR}/package_app.sh"
VERIFY_SCRIPT="${SCRIPT_DIR}/verify_release.sh"
# shellcheck source=release_validation.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/release_validation.sh"

CONFIGURATION="release"
VERSION="0.1.0"
BUILD_NUMBER="1"
BUNDLE_ID="com.clipboardrouter.ClipboardRouter"
TEAM_ID=""
APP_IDENTITY=""
INSTALLER_IDENTITY=""
PROVISIONING_PROFILE=""
USE_ICLOUD=0
CLOUDKIT_CONTAINER=""
CLOUDKIT_ENVIRONMENT=""
OUTPUT_PKG="${PROJECT_ROOT}/.artifacts/mas/ClipboardRouter.pkg"
OUTPUT_MANIFEST=""
OVERWRITE=0
REQUESTED_ARCHITECTURES="native"

usage() {
    cat <<'USAGE'
Build, sign, and package the SwiftPM ClipboardRouter app as a Mac App Store
installer product (.pkg), ready to hand to Transporter or Xcode Organizer.

Usage:
  Scripts/package_mas.sh [options]

Required:
  --team-id TEAM_ID                    Ten-character Apple Developer Team ID
  --app-identity IDENTITY               "Apple Distribution: ..." or
                                         "3rd Party Mac Developer Application: ..." certificate
  --installer-identity IDENTITY          "3rd Party Mac Developer Installer: ..." or
                                         "Mac Installer Distribution: ..." certificate
  --provisioning-profile PATH            Mac App Store provisioning profile matching
                                         --bundle-id, --team-id, and --app-identity

Options:
  --configuration debug|release          Swift build configuration (default: release)
  --version VERSION                      CFBundleShortVersionString (default: 0.1.0)
  --build-number NUMBER                  CFBundleVersion (default: 1)
  --bundle-id IDENTIFIER                 Application bundle identifier
  --architectures LIST                   native, universal, arm64, x86_64, or comma-separated
                                         list (default: native)
  --output PATH                          Output .pkg path (default: .artifacts/mas/ClipboardRouter.pkg)
  --manifest-output PATH                 Evidence manifest path (default: OUTPUT_PKG.release.json)
  --overwrite                            Replace an existing output .pkg and manifest

iCloud options (all required together, in addition to the required flags above):
  --icloud                               Use the CloudKit entitlement template
  --cloudkit-container ID                Container such as iCloud.com.example.App
  --cloudkit-environment ENV             development or production

This script always packages the application with the macAppStore distribution channel, so
the app never labels itself an Engineering Build and never shows direct-license activation,
settings, or purchase UI; premium functionality remains unlocked exactly as the engineering-
evaluation policy already unlocks it. This script never creates or edits Apple Developer
identities, provisioning profiles, App Store Connect records, or App Store metadata. It
never accepts, stores, or contacts App Store Connect. The resulting .pkg still requires
human upload through Transporter (or Xcode Organizer) and a complete App Store Connect
listing before submission for review.
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
        --configuration)
            require_value "$@"
            CONFIGURATION="$2"
            shift 2
            ;;
        --version)
            require_value "$@"
            VERSION="$2"
            shift 2
            ;;
        --build-number)
            require_value "$@"
            BUILD_NUMBER="$2"
            shift 2
            ;;
        --bundle-id)
            require_value "$@"
            BUNDLE_ID="$2"
            shift 2
            ;;
        --architectures)
            require_value "$@"
            REQUESTED_ARCHITECTURES="$2"
            shift 2
            ;;
        --team-id)
            require_value "$@"
            TEAM_ID="$2"
            shift 2
            ;;
        --app-identity)
            require_value "$@"
            APP_IDENTITY="$2"
            shift 2
            ;;
        --installer-identity)
            require_value "$@"
            INSTALLER_IDENTITY="$2"
            shift 2
            ;;
        --provisioning-profile)
            require_value "$@"
            PROVISIONING_PROFILE="$2"
            shift 2
            ;;
        --icloud)
            USE_ICLOUD=1
            shift
            ;;
        --cloudkit-container)
            require_value "$@"
            CLOUDKIT_CONTAINER="$2"
            shift 2
            ;;
        --cloudkit-environment)
            require_value "$@"
            CLOUDKIT_ENVIRONMENT="$2"
            shift 2
            ;;
        --output)
            require_value "$@"
            OUTPUT_PKG="$2"
            shift 2
            ;;
        --manifest-output)
            require_value "$@"
            OUTPUT_MANIFEST="$2"
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
        *)
            die "unknown option: $1"
            ;;
    esac
done

case "${CONFIGURATION}" in
    debug|release) ;;
    *) die "--configuration must be debug or release" ;;
esac
[[ "${VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "version must contain two or three numeric components"
[[ "${BUILD_NUMBER}" =~ ^[0-9]+$ && "${BUILD_NUMBER}" != "0" ]] || die "build number must be a positive integer"
[[ "${BUNDLE_ID}" =~ ^[A-Za-z0-9]+([.-][A-Za-z0-9]+)+$ ]] || die "invalid bundle identifier: ${BUNDLE_ID}"
case "${REQUESTED_ARCHITECTURES}" in
    native|universal) ;;
    *)
        IFS=',' read -r -a MAS_ARCHITECTURE_CHECK <<< "${REQUESTED_ARCHITECTURES}"
        [[ "${#MAS_ARCHITECTURE_CHECK[@]}" -ge 1 ]] || die "--architectures must not be empty"
        for architecture in "${MAS_ARCHITECTURE_CHECK[@]}"; do
            [[ "${architecture}" == "arm64" || "${architecture}" == "x86_64" ]] \
                || die "--architectures must be native, universal, arm64, x86_64, or a comma-separated list of arm64/x86_64"
        done
        ;;
esac
[[ "${TEAM_ID}" =~ ^[A-Z0-9]{10}$ ]] || die "--team-id must be a ten-character Apple Developer Team ID"
case "${APP_IDENTITY}" in
    "Apple Distribution: "*|"3rd Party Mac Developer Application: "*) ;;
    *) die "--app-identity must be an 'Apple Distribution: ...' or '3rd Party Mac Developer Application: ...' certificate" ;;
esac
case "${INSTALLER_IDENTITY}" in
    "3rd Party Mac Developer Installer: "*|"Mac Installer Distribution: "*) ;;
    *) die "--installer-identity must be a '3rd Party Mac Developer Installer: ...' or 'Mac Installer Distribution: ...' certificate" ;;
esac
[[ -f "${PROVISIONING_PROFILE}" ]] || die "--provisioning-profile is required and must exist"
if [[ "${USE_ICLOUD}" -eq 1 ]]; then
    [[ "${CLOUDKIT_CONTAINER}" =~ ^iCloud\.[A-Za-z0-9]+([.-][A-Za-z0-9]+)+$ ]] || die "invalid CloudKit container identifier"
    [[ "${CLOUDKIT_ENVIRONMENT}" == "development" || "${CLOUDKIT_ENVIRONMENT}" == "production" ]] || die "--cloudkit-environment must be development or production"
else
    [[ -z "${CLOUDKIT_CONTAINER}" && -z "${CLOUDKIT_ENVIRONMENT}" ]] || die "CloudKit options require --icloud"
fi
[[ "${OUTPUT_PKG}" == *.pkg ]] || die "--output path must end in .pkg"
if [[ -z "${OUTPUT_MANIFEST}" ]]; then
    OUTPUT_MANIFEST="${OUTPUT_PKG}.release.json"
fi
[[ "${OUTPUT_MANIFEST}" == *.json ]] || die "--manifest-output path must end in .json"
if [[ -e "${OUTPUT_PKG}" ]]; then
    [[ "${OVERWRITE}" -eq 1 ]] || die "output already exists; pass --overwrite to replace ${OUTPUT_PKG}"
fi
if [[ -e "${OUTPUT_MANIFEST}" ]]; then
    [[ "${OVERWRITE}" -eq 1 ]] || die "evidence manifest already exists; pass --overwrite to replace ${OUTPUT_MANIFEST}"
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clipboard-router-mas.XXXXXX")"
trap 'rm -rf "${TEMP_ROOT}"' EXIT

STAGED_APP="${TEMP_ROOT}/ClipboardRouter.app"

echo "Building and signing the Mac App Store application bundle..."
PACKAGE_ARGS=(
    --configuration "${CONFIGURATION}"
    --version "${VERSION}"
    --build-number "${BUILD_NUMBER}"
    --bundle-id "${BUNDLE_ID}"
    --architectures "${REQUESTED_ARCHITECTURES}"
    --identity "${APP_IDENTITY}"
    --team-id "${TEAM_ID}"
    --provisioning-profile "${PROVISIONING_PROFILE}"
    --output "${STAGED_APP}"
    --distribution-channel macAppStore
    --overwrite
)
PROFILE_KIND="local"
if [[ "${USE_ICLOUD}" -eq 1 ]]; then
    PACKAGE_ARGS+=(--icloud --cloudkit-container "${CLOUDKIT_CONTAINER}" --cloudkit-environment "${CLOUDKIT_ENVIRONMENT}")
    PROFILE_KIND="icloud"
fi
/bin/bash "${PACKAGE_SCRIPT}" "${PACKAGE_ARGS[@]}"

echo "Verifying the signed application bundle..."
VERIFY_ARGS=(--profile "${PROFILE_KIND}" --bundle-id "${BUNDLE_ID}" --expect-distribution-channel macAppStore)
[[ "${USE_ICLOUD}" -eq 0 ]] || VERIFY_ARGS+=(--cloudkit-container "${CLOUDKIT_CONTAINER}")
/bin/bash "${VERIFY_SCRIPT}" "${VERIFY_ARGS[@]}" "${STAGED_APP}"

APP_SIGNING_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "${STAGED_APP}" 2>&1)"
APP_AUTHORITY="$(release_signing_field "${APP_SIGNING_DETAILS}" "Authority")"
case "${APP_AUTHORITY}" in
    "Apple Distribution: "*|"3rd Party Mac Developer Application: "*) ;;
    "Developer ID Application: "*)
        die "the application is signed with a Developer ID certificate; Mac App Store submissions require --app-identity to be an Apple Distribution or 3rd Party Mac Developer Application certificate"
        ;;
    *)
        die "unexpected application signing authority for a Mac App Store build: ${APP_AUTHORITY}"
        ;;
esac
ENTITLEMENTS_PLIST="${TEMP_ROOT}/mas-entitlements.plist"
/usr/bin/codesign -d --entitlements :- "${STAGED_APP}" > "${ENTITLEMENTS_PLIST}" 2>/dev/null
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "${ENTITLEMENTS_PLIST}" >/dev/null 2>&1; then
    die "release build unexpectedly carries the debugger entitlement com.apple.security.get-task-allow"
fi
CLI_ENTITLEMENTS_PLIST="${TEMP_ROOT}/mas-cli-entitlements.plist"
/usr/bin/codesign -d --entitlements :- "${STAGED_APP}/Contents/Helpers/cr" > "${CLI_ENTITLEMENTS_PLIST}" 2>/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "${CLI_ENTITLEMENTS_PLIST}" 2>/dev/null || true)" == "true" ]] \
    || die "Mac App Store CLI helper is missing com.apple.security.app-sandbox"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.inherit' "${CLI_ENTITLEMENTS_PLIST}" 2>/dev/null || true)" == "true" ]] \
    || die "Mac App Store CLI helper is missing com.apple.security.inherit"

APP_MANIFEST_PATH="${STAGED_APP}.release.json"
manifest_value() {
    /usr/bin/plutil -extract "$1" raw -o - "${APP_MANIFEST_PATH}" 2>/dev/null \
        || die "application release manifest is missing $1"
}
APP_SWIFT_TOOLCHAIN="$(manifest_value swiftToolchain)"
APP_XCODE_TOOLCHAIN="$(manifest_value xcodeToolchain)"
APP_SDK_VERSION="$(manifest_value sdkVersion)"

echo "Building the Mac App Store installer package..."
STAGED_PKG="${TEMP_ROOT}/ClipboardRouter.pkg"
/usr/bin/productbuild \
    --component "${STAGED_APP}" /Applications \
    --identifier "${BUNDLE_ID}.pkg" \
    --version "${VERSION}" \
    --sign "${INSTALLER_IDENTITY}" \
    "${STAGED_PKG}"
[[ -f "${STAGED_PKG}" ]] || die "productbuild did not produce a package"

echo "Validating the installer signature..."
PKG_SIGNATURE_DETAILS="$(/usr/sbin/pkgutil --check-signature "${STAGED_PKG}" 2>&1)"
echo "${PKG_SIGNATURE_DETAILS}"
echo "${PKG_SIGNATURE_DETAILS}" | /usr/bin/grep -q "no signature" \
    && die "the installer package is unsigned"
echo "${PKG_SIGNATURE_DETAILS}" | /usr/bin/grep -qE "Developer ID Installer|Developer ID Application" \
    && die "the installer package is signed with a Developer ID certificate, not a Mac App Store installer certificate"
echo "${PKG_SIGNATURE_DETAILS}" | /usr/bin/grep -q "(${TEAM_ID})" \
    || die "installer signing certificate Team ID does not match --team-id"

echo "Expanding the package to verify its embedded application..."
EXPAND_DIR="${TEMP_ROOT}/expanded"
/usr/sbin/pkgutil --expand-full "${STAGED_PKG}" "${EXPAND_DIR}"
EMBEDDED_APPS=("${EXPAND_DIR}"/*.pkg/Payload/*.app)
[[ "${#EMBEDDED_APPS[@]}" -eq 1 && -d "${EMBEDDED_APPS[0]}" ]] \
    || die "expanded package does not contain exactly one embedded application"
EMBEDDED_APP="${EMBEDDED_APPS[0]}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${EMBEDDED_APP}" \
    || die "embedded application failed codesign verification after packaging"
EMBEDDED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${EMBEDDED_APP}/Contents/Info.plist")"
[[ "${EMBEDDED_BUNDLE_ID}" == "${BUNDLE_ID}" ]] \
    || die "embedded application bundle identifier does not match --bundle-id"
[[ -f "${EMBEDDED_APP}/Contents/embedded.provisionprofile" ]] \
    || die "embedded application is missing embedded.provisionprofile"

echo "Validating the embedded provisioning profile..."
PROFILE_PLIST="${TEMP_ROOT}/mas-provisioning-profile.plist"
decode_apple_provisioning_profile "${EMBEDDED_APP}/Contents/embedded.provisionprofile" "${PROFILE_PLIST}" \
    || die "${RELEASE_VALIDATION_ERROR}"
validate_provisioning_profile_metadata "${PROFILE_PLIST}" "${TEAM_ID}" "${BUNDLE_ID}" \
    || die "${RELEASE_VALIDATION_ERROR}"
PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :Name' "${PROFILE_PLIST}" 2>/dev/null || echo "")"
PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "${PROFILE_PLIST}" 2>/dev/null || echo "")"
validate_profile_signing_certificate \
    "${PROFILE_PLIST}" "${EMBEDDED_APP}" "${TEMP_ROOT}/mas-signing-certificate" \
    || die "${RELEASE_VALIDATION_ERROR}"

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}
PKG_SHA256="$(sha256_file "${STAGED_PKG}")"

SOURCE_REVISION="$(/usr/bin/git -C "${PROJECT_ROOT}" rev-parse --verify HEAD 2>/dev/null || true)"
SOURCE_TREE_DIRTY_KNOWN=0
if [[ "${SOURCE_REVISION}" =~ ^[0-9a-fA-F]{40,64}$ ]]; then
    SOURCE_REVISION="$(echo "${SOURCE_REVISION}" | /usr/bin/tr 'A-F' 'a-f')"
    if [[ -n "$(/usr/bin/git -C "${PROJECT_ROOT}" status --porcelain --untracked-files=normal 2>/dev/null || true)" ]]; then
        SOURCE_TREE_DIRTY="true"
    else
        SOURCE_TREE_DIRTY="false"
    fi
    SOURCE_TREE_DIRTY_KNOWN=1
fi

MANIFEST_PLIST="${TEMP_ROOT}/mas-release-manifest.plist"
MANIFEST_JSON="${TEMP_ROOT}/mas-release-manifest.json"
/usr/bin/plutil -create xml1 "${MANIFEST_PLIST}"
/usr/bin/plutil -insert schemaVersion -integer 1 "${MANIFEST_PLIST}"
/usr/bin/plutil -insert distributionChannel -string "macAppStore" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert bundleIdentifier -string "${BUNDLE_ID}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert version -string "${VERSION}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert buildNumber -string "${BUILD_NUMBER}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert configuration -string "${CONFIGURATION}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert teamIdentifier -string "${TEAM_ID}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert appSigningAuthority -string "${APP_AUTHORITY}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert installerIdentity -string "${INSTALLER_IDENTITY}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert provisioningProfileName -string "${PROFILE_NAME}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert provisioningProfileUUID -string "${PROFILE_UUID}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert buildTimestamp -string "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert swiftToolchain -string "${APP_SWIFT_TOOLCHAIN}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert xcodeToolchain -string "${APP_XCODE_TOOLCHAIN}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert sdkVersion -string "${APP_SDK_VERSION}" "${MANIFEST_PLIST}"
if [[ "${SOURCE_TREE_DIRTY_KNOWN}" -eq 1 ]]; then
    /usr/bin/plutil -insert sourceRevision -string "${SOURCE_REVISION}" "${MANIFEST_PLIST}"
    /usr/bin/plutil -insert sourceTreeDirty -bool "${SOURCE_TREE_DIRTY}" "${MANIFEST_PLIST}"
fi
/usr/bin/plutil -insert package -dictionary "${MANIFEST_PLIST}"
/usr/bin/plutil -insert package.path -string "$(basename "${OUTPUT_PKG}")" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert package.sha256 -string "${PKG_SHA256}" "${MANIFEST_PLIST}"
/usr/bin/plutil -convert json -o "${MANIFEST_JSON}" "${MANIFEST_PLIST}"
/usr/bin/python3 -m json.tool "${MANIFEST_JSON}" >/dev/null \
    || die "generated evidence manifest is not valid JSON"

mkdir -p "$(dirname "${OUTPUT_PKG}")"
mkdir -p "$(dirname "${OUTPUT_MANIFEST}")"
/bin/mv "${STAGED_PKG}" "${OUTPUT_PKG}"
/bin/mv "${MANIFEST_JSON}" "${OUTPUT_MANIFEST}"

echo
echo "Packaged: ${OUTPUT_PKG}"
echo "SHA-256: ${PKG_SHA256}"
echo "Bundle ID: ${BUNDLE_ID}"
echo "Version: ${VERSION} (${BUILD_NUMBER})"
echo "Architectures: ${REQUESTED_ARCHITECTURES}"
echo "Distribution channel: macAppStore"
echo "App signing: ${APP_AUTHORITY}"
echo "Installer signing: verified Team ID ${TEAM_ID}"
echo "Provisioning profile: ${PROFILE_NAME} (${PROFILE_UUID})"
echo "Evidence manifest: ${OUTPUT_MANIFEST}"
echo
echo "This package is upload-ready for Transporter or Xcode Organizer. This script does not"
echo "upload to App Store Connect, create App Store Connect records, or submit for review."
