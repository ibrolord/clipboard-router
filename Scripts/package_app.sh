#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=release_validation.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/release_validation.sh"
INFO_TEMPLATE="${PROJECT_ROOT}/Resources/Info.plist"
LOCAL_ENTITLEMENTS="${PROJECT_ROOT}/Resources/Entitlements/ClipboardRouter.Local.entitlements"
ICLOUD_ENTITLEMENTS_TEMPLATE="${PROJECT_ROOT}/Resources/Entitlements/ClipboardRouter.iCloud.entitlements.template"
MAC_APP_STORE_HELPER_ENTITLEMENTS="${PROJECT_ROOT}/Resources/Entitlements/ClipboardRouter.MacAppStoreHelper.entitlements"
PRIVACY_MANIFEST="${PROJECT_ROOT}/Resources/PrivacyInfo.xcprivacy"
APP_ICON="${PROJECT_ROOT}/Resources/AppIcon/ClipboardRouter.icns"
CLI_INSTALLER="${PROJECT_ROOT}/Resources/install-cr.sh"

CONFIGURATION="release"
VERSION="0.1.0"
BUILD_NUMBER="1"
BUNDLE_ID="com.clipboardrouter.ClipboardRouter"
OUTPUT_APP="${PROJECT_ROOT}/.artifacts/ClipboardRouter.app"
OUTPUT_MANIFEST=""
SIGN_IDENTITY="-"
PROVISIONING_PROFILE=""
TEAM_ID=""
CLOUDKIT_CONTAINER=""
CLOUDKIT_ENVIRONMENT=""
TIMESTAMP_MODE="auto"
USE_ICLOUD=0
CUSTOMER_RELEASE=0
LICENSE_SERVICE_URL=""
COMMERCE_PROVIDER=""
LICENSE_PUBLIC_KEY_DER_BASE64=""
OVERWRITE=0
DISTRIBUTION_CHANNEL="direct"
REQUESTED_ARCHITECTURES="native"
SWIFT_BUILD_SANDBOX_ARG=""

# The normal packaging path keeps SwiftPM's subprocess sandbox enabled. CI and the local
# packaged-acceptance runner can opt into SwiftPM's documented no-sandbox mode when the host
# itself already provides the required workspace isolation and the default module cache is not
# writable.
if [[ "${CLIPBOARD_ROUTER_DISABLE_SWIFT_BUILD_SANDBOX:-0}" == "1" ]]; then
    SWIFT_BUILD_SANDBOX_ARG="--disable-sandbox"
fi

usage() {
    cat <<'USAGE'
Package the SwiftPM ClipboardRouter executable as a native macOS application.

Usage:
  Scripts/package_app.sh [options]

Options:
  --configuration debug|release  Swift build configuration (default: release)
  --version VERSION              CFBundleShortVersionString (default: 0.1.0)
  --build-number NUMBER          CFBundleVersion (default: 1)
  --bundle-id IDENTIFIER         Application bundle identifier
  --output PATH                  Output .app path
  --manifest-output PATH         Release manifest path (default: APP_PATH.release.json)
  --distribution-channel CHANNEL direct or macAppStore (default: direct); recorded in
                                 Info.plist and the release manifest so the UI and release
                                 evidence truthfully reflect how the build is distributed
  --architectures LIST           native, universal, arm64, x86_64, or comma-separated list
  --identity IDENTITY            codesign identity; default "-" is ad-hoc
  --team-id TEAM_ID              Ten-character Team ID for any non-ad-hoc Vault build
  --provisioning-profile PATH    Matching Developer ID/macOS distribution profile
  --timestamp auto|none|secure   Signing timestamp policy (default: auto)
  --customer-release            Require production signing, clean Git provenance, and licensing
  --license-service-url URL      Production HTTPS license service (customer release)
  --commerce-provider ID        Commerce provider identifier (customer release)
  --license-public-key-base64 B  DER P-256 public key in Base64 (customer release)
  --overwrite                    Replace an existing output .app

iCloud options (all required together in addition to --team-id):
  --icloud                       Use the CloudKit entitlement template
  --cloudkit-container ID        Container such as iCloud.com.example.App
  --cloudkit-environment ENV     development or production

Without --icloud, the app is sandboxed, has no CloudKit entitlement, and is
ad-hoc signed unless --identity is supplied. Non-ad-hoc builds require a
matching provisioning profile because Vault uses profile-bound Keychain
entitlements. The script never creates or edits Apple Developer identifiers,
containers, profiles, or CloudKit schemas.

The signed `cr` command is packaged at Contents/Helpers/cr. Clipboard Router
never installs it into /usr/local/bin or edits PATH. The bundled installer
requires an explicit destination and confirmation.
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
        --output)
            require_value "$@"
            OUTPUT_APP="$2"
            shift 2
            ;;
        --manifest-output)
            require_value "$@"
            OUTPUT_MANIFEST="$2"
            shift 2
            ;;
        --architectures)
            require_value "$@"
            REQUESTED_ARCHITECTURES="$2"
            shift 2
            ;;
        --distribution-channel)
            require_value "$@"
            DISTRIBUTION_CHANNEL="$2"
            shift 2
            ;;
        --identity)
            require_value "$@"
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        --timestamp)
            require_value "$@"
            TIMESTAMP_MODE="$2"
            shift 2
            ;;
        --customer-release)
            CUSTOMER_RELEASE=1
            shift
            ;;
        --license-service-url)
            require_value "$@"
            LICENSE_SERVICE_URL="$2"
            shift 2
            ;;
        --commerce-provider)
            require_value "$@"
            COMMERCE_PROVIDER="$2"
            shift 2
            ;;
        --license-public-key-base64)
            require_value "$@"
            LICENSE_PUBLIC_KEY_DER_BASE64="$2"
            shift 2
            ;;
        --icloud)
            USE_ICLOUD=1
            shift
            ;;
        --team-id)
            require_value "$@"
            TEAM_ID="$2"
            shift 2
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
        --provisioning-profile)
            require_value "$@"
            PROVISIONING_PROFILE="$2"
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

case "${TIMESTAMP_MODE}" in
    auto|none|secure) ;;
    *) die "--timestamp must be auto, none, or secure" ;;
esac

case "${DISTRIBUTION_CHANNEL}" in
    direct|macAppStore) ;;
    *) die "--distribution-channel must be direct or macAppStore" ;;
esac

[[ "${VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "version must contain two or three numeric components"
[[ "${BUILD_NUMBER}" =~ ^[0-9]+$ ]] || die "build number must be a positive integer"
[[ "${BUILD_NUMBER}" != "0" ]] || die "build number must be greater than zero"
[[ "${BUNDLE_ID}" =~ ^[A-Za-z0-9]+([.-][A-Za-z0-9]+)+$ ]] || die "invalid bundle identifier: ${BUNDLE_ID}"
[[ "${OUTPUT_APP}" == *.app ]] || die "output path must end in .app"
if [[ -z "${OUTPUT_MANIFEST}" ]]; then
    OUTPUT_MANIFEST="${OUTPUT_APP}.release.json"
fi
[[ "${OUTPUT_MANIFEST}" == *.json ]] || die "release manifest path must end in .json"
OUTPUT_APP_CANONICAL="$(/usr/bin/python3 -c 'import os,sys; print(os.path.join(os.path.realpath(os.path.dirname(sys.argv[1]) or "."), os.path.basename(sys.argv[1])))' "${OUTPUT_APP}")"
OUTPUT_MANIFEST_CANONICAL="$(/usr/bin/python3 -c 'import os,sys; print(os.path.join(os.path.realpath(os.path.dirname(sys.argv[1]) or "."), os.path.basename(sys.argv[1])))' "${OUTPUT_MANIFEST}")"
/usr/bin/python3 -c 'import os,sys; app,manifest=sys.argv[1:]; inside=(manifest==app or os.path.commonpath([app,manifest])==app); raise SystemExit(1 if inside else 0)' \
    "${OUTPUT_APP_CANONICAL}" "${OUTPUT_MANIFEST_CANONICAL}" \
    || die "release manifest output must remain outside the signed .app bundle"

LICENSE_FIELD_COUNT=0
[[ -z "${LICENSE_SERVICE_URL}" ]] || LICENSE_FIELD_COUNT=$((LICENSE_FIELD_COUNT + 1))
[[ -z "${COMMERCE_PROVIDER}" ]] || LICENSE_FIELD_COUNT=$((LICENSE_FIELD_COUNT + 1))
[[ -z "${LICENSE_PUBLIC_KEY_DER_BASE64}" ]] || LICENSE_FIELD_COUNT=$((LICENSE_FIELD_COUNT + 1))
[[ "${LICENSE_FIELD_COUNT}" -eq 0 || "${LICENSE_FIELD_COUNT}" -eq 3 ]] \
    || die "license service URL, commerce provider, and public key must be supplied together"
if [[ "${LICENSE_FIELD_COUNT}" -eq 3 ]]; then
    /usr/bin/python3 -c 'import sys, urllib.parse; p=urllib.parse.urlsplit(sys.argv[1]); ok=(p.scheme=="https" and bool(p.hostname) and p.username is None and p.password is None and not p.query and not p.fragment and not any(c.isspace() for c in sys.argv[1])); raise SystemExit(0 if ok else 1)' "${LICENSE_SERVICE_URL}" \
        || die "--license-service-url must be an HTTPS URL without query, fragment, whitespace, or credentials"
    [[ "${#COMMERCE_PROVIDER}" -le 128 && "${COMMERCE_PROVIDER}" =~ ^[A-Za-z0-9._-]+$ ]] \
        || die "--commerce-provider must be a bounded identifier"
    LICENSE_KEY_TEMP="$(mktemp "${TMPDIR:-/tmp}/clipboard-router-license-key.XXXXXX")"
    if ! /usr/bin/printf '%s' "${LICENSE_PUBLIC_KEY_DER_BASE64}" | /usr/bin/base64 -D >"${LICENSE_KEY_TEMP}" 2>/dev/null \
        || ! /usr/bin/openssl pkey -pubin -inform DER -in "${LICENSE_KEY_TEMP}" -text -noout 2>&1 \
            | /usr/bin/grep -q 'prime256v1'; then
        /bin/rm -f "${LICENSE_KEY_TEMP}"
        die "--license-public-key-base64 must decode to a P-256 DER public key"
    fi
    /bin/rm -f "${LICENSE_KEY_TEMP}"
fi
if [[ "${CUSTOMER_RELEASE}" -eq 1 ]]; then
    [[ "${CONFIGURATION}" == "release" ]] || die "--customer-release requires --configuration release"
    [[ "${SIGN_IDENTITY}" != "-" ]] || die "--customer-release requires a non-ad-hoc --identity"
    [[ "${TIMESTAMP_MODE}" != "none" ]] || die "--customer-release requires a secure signing timestamp"
    [[ "${LICENSE_FIELD_COUNT}" -eq 3 ]] || die "--customer-release requires complete production licensing configuration"
    SOURCE_REVISION_PRECHECK="$(/usr/bin/git -C "${PROJECT_ROOT}" rev-parse --verify HEAD 2>/dev/null || true)"
    [[ "${SOURCE_REVISION_PRECHECK}" =~ ^[0-9a-fA-F]{40,64}$ ]] \
        || die "--customer-release requires a real Git source revision"
    [[ -z "$(/usr/bin/git -C "${PROJECT_ROOT}" status --porcelain --untracked-files=normal 2>/dev/null || true)" ]] \
        || die "--customer-release requires a clean source tree"
fi

if [[ "${REQUESTED_ARCHITECTURES}" == "native" ]]; then
    REQUESTED_ARCHITECTURES="$(/usr/bin/uname -m)"
elif [[ "${REQUESTED_ARCHITECTURES}" == "universal" ]]; then
    REQUESTED_ARCHITECTURES="arm64,x86_64"
fi

IFS=',' read -r -a ARCHITECTURES <<< "${REQUESTED_ARCHITECTURES}"
[[ "${#ARCHITECTURES[@]}" -ge 1 ]] || die "at least one architecture is required"
ARCH_ARGS=()
SEEN_ARCHITECTURES=" "
for architecture in "${ARCHITECTURES[@]}"; do
    [[ "${architecture}" == "arm64" || "${architecture}" == "x86_64" ]] \
        || die "unsupported architecture '${architecture}'; choose arm64, x86_64, or universal"
    [[ "${SEEN_ARCHITECTURES}" != *" ${architecture} "* ]] \
        || die "duplicate architecture: ${architecture}"
    SEEN_ARCHITECTURES+="${architecture} "
    ARCH_ARGS+=(--arch "${architecture}")
done

for required_file in "${INFO_TEMPLATE}" "${LOCAL_ENTITLEMENTS}" "${MAC_APP_STORE_HELPER_ENTITLEMENTS}" "${PRIVACY_MANIFEST}" "${CLI_INSTALLER}"; do
    [[ -f "${required_file}" ]] || die "missing packaging resource: ${required_file}"
done
validate_app_icon "${APP_ICON}" || die "${RELEASE_VALIDATION_ERROR}"

if [[ "${USE_ICLOUD}" -eq 1 ]]; then
    [[ "${SIGN_IDENTITY}" != "-" ]] || die "iCloud packaging cannot use ad-hoc signing; pass --identity"
    [[ "${TEAM_ID}" =~ ^[A-Z0-9]{10}$ ]] || die "--team-id must be a ten-character Apple Developer Team ID"
    [[ "${CLOUDKIT_CONTAINER}" =~ ^iCloud\.[A-Za-z0-9]+([.-][A-Za-z0-9]+)+$ ]] || die "invalid CloudKit container identifier"
    [[ "${CLOUDKIT_ENVIRONMENT}" == "development" || "${CLOUDKIT_ENVIRONMENT}" == "production" ]] || die "--cloudkit-environment must be development or production"
    [[ -f "${PROVISIONING_PROFILE}" ]] || die "a matching provisioning profile is required for iCloud packaging"
    [[ -f "${ICLOUD_ENTITLEMENTS_TEMPLATE}" ]] || die "missing iCloud entitlement template"
else
    [[ -z "${CLOUDKIT_CONTAINER}" && -z "${CLOUDKIT_ENVIRONMENT}" ]] || die "CloudKit options require --icloud"
    if [[ "${SIGN_IDENTITY}" == "-" ]]; then
        [[ -z "${TEAM_ID}" ]] || die "--team-id requires a non-ad-hoc --identity"
        [[ -z "${PROVISIONING_PROFILE}" ]] || die "--provisioning-profile requires a non-ad-hoc --identity"
    else
        [[ "${TEAM_ID}" =~ ^[A-Z0-9]{10}$ ]] || die "non-ad-hoc signing requires a ten-character --team-id for Vault Keychain access"
        [[ -f "${PROVISIONING_PROFILE}" ]] || die "non-ad-hoc signing requires a matching provisioning profile for Vault Keychain access"
    fi
fi

echo "Building ClipboardRouter and cr (${CONFIGURATION}; ${REQUESTED_ARCHITECTURES})..."
if ! (cd "${PROJECT_ROOT}" && /usr/bin/swift build ${SWIFT_BUILD_SANDBOX_ARG:+"${SWIFT_BUILD_SANDBOX_ARG}"} --configuration "${CONFIGURATION}" "${ARCH_ARGS[@]}" --product ClipboardRouter); then
    if [[ " ${ARCHITECTURES[*]} " == *" x86_64 "* ]]; then
        die "the selected SDK/toolchain could not build ClipboardRouter for x86_64; use --architectures arm64 or install an SDK/toolchain with x86_64 support"
    fi
    die "ClipboardRouter build failed"
fi
if ! (cd "${PROJECT_ROOT}" && /usr/bin/swift build ${SWIFT_BUILD_SANDBOX_ARG:+"${SWIFT_BUILD_SANDBOX_ARG}"} --configuration "${CONFIGURATION}" "${ARCH_ARGS[@]}" --product cr); then
    if [[ " ${ARCHITECTURES[*]} " == *" x86_64 "* ]]; then
        die "the selected SDK/toolchain could not build cr for x86_64; use --architectures arm64 or install an SDK/toolchain with x86_64 support"
    fi
    die "cr build failed"
fi

BIN_DIR="$(cd "${PROJECT_ROOT}" && /usr/bin/swift build ${SWIFT_BUILD_SANDBOX_ARG:+"${SWIFT_BUILD_SANDBOX_ARG}"} --configuration "${CONFIGURATION}" "${ARCH_ARGS[@]}" --show-bin-path)"
EXECUTABLE_SOURCE="${BIN_DIR}/ClipboardRouter"
CLI_SOURCE="${BIN_DIR}/cr"
[[ -x "${EXECUTABLE_SOURCE}" ]] || die "missing executable ${EXECUTABLE_SOURCE}; add/build the ClipboardRouter executable product first"
[[ -x "${CLI_SOURCE}" ]] || die "missing executable ${CLI_SOURCE}; build the cr executable product first"

validate_binary_architectures() {
    local binary="$1"
    local label="$2"
    local actual
    actual="$(/usr/bin/lipo -archs "${binary}" 2>/dev/null)" \
        || die "could not inspect ${label} architectures"
    local actual_count
    actual_count="$(/usr/bin/wc -w <<< "${actual}" | /usr/bin/tr -d ' ')"
    [[ "${actual_count}" -eq "${#ARCHITECTURES[@]}" ]] \
        || die "${label} architectures '${actual}' do not exactly match requested '${REQUESTED_ARCHITECTURES}'"
    local expected
    for expected in "${ARCHITECTURES[@]}"; do
        [[ " ${actual} " == *" ${expected} "* ]] \
            || die "${label} is missing requested architecture ${expected}"
    done
}

validate_binary_architectures "${EXECUTABLE_SOURCE}" "ClipboardRouter"
validate_binary_architectures "${CLI_SOURCE}" "cr"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clipboard-router-package.XXXXXX")"
trap 'rm -rf "${TEMP_ROOT}"' EXIT
STAGED_APP="${TEMP_ROOT}/ClipboardRouter.app"
CONTENTS_DIR="${STAGED_APP}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
HELPERS_DIR="${CONTENTS_DIR}/Helpers"

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${HELPERS_DIR}"
cp "${EXECUTABLE_SOURCE}" "${MACOS_DIR}/ClipboardRouter"
chmod 0755 "${MACOS_DIR}/ClipboardRouter"
cp "${CLI_SOURCE}" "${HELPERS_DIR}/cr"
chmod 0755 "${HELPERS_DIR}/cr"
/usr/bin/printf '%s (%s)\n' "${VERSION}" "${BUILD_NUMBER}" > "${RESOURCES_DIR}/cr.version"
chmod 0644 "${RESOURCES_DIR}/cr.version"
cp "${CLI_INSTALLER}" "${RESOURCES_DIR}/install-cr.sh"
chmod 0755 "${RESOURCES_DIR}/install-cr.sh"
cp "${INFO_TEMPLATE}" "${CONTENTS_DIR}/Info.plist"
cp "${PRIVACY_MANIFEST}" "${RESOURCES_DIR}/PrivacyInfo.xcprivacy"
cp "${APP_ICON}" "${RESOURCES_DIR}/ClipboardRouter.icns"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ClipboardRouterDistributionChannel string ${DISTRIBUTION_CHANNEL}" "${CONTENTS_DIR}/Info.plist"
if [[ "${LICENSE_FIELD_COUNT}" -eq 3 ]]; then
    /usr/libexec/PlistBuddy -c "Add :ClipboardRouterLicenseServiceURL string ${LICENSE_SERVICE_URL}" "${CONTENTS_DIR}/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :ClipboardRouterCommerceProviderIdentifier string ${COMMERCE_PROVIDER}" "${CONTENTS_DIR}/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :ClipboardRouterLicensePublicKeyDERBase64 string ${LICENSE_PUBLIC_KEY_DER_BASE64}" "${CONTENTS_DIR}/Info.plist"
fi
/usr/bin/plutil -lint "${CONTENTS_DIR}/Info.plist" >/dev/null

# SwiftPM's generated Bundle.module accessor looks immediately beside the main
# bundle for resource bundles in command-line builds. Preserve any such bundle.
for resource_bundle in "${BIN_DIR}"/ClipboardRouter_*.bundle; do
    [[ -e "${resource_bundle}" ]] || continue
    /usr/bin/ditto "${resource_bundle}" "${STAGED_APP}/$(basename "${resource_bundle}")"
done

SIGN_ENTITLEMENTS="${LOCAL_ENTITLEMENTS}"
PROFILE_PLIST=""
PROFILE_APP_ID=""
if [[ -n "${PROVISIONING_PROFILE}" ]]; then
    PROFILE_PLIST="${TEMP_ROOT}/provisioning-profile.plist"
    decode_apple_provisioning_profile "${PROVISIONING_PROFILE}" "${PROFILE_PLIST}" \
        || die "${RELEASE_VALIDATION_ERROR}"
    validate_provisioning_profile_metadata "${PROFILE_PLIST}" "${TEAM_ID}" "${BUNDLE_ID}" \
        || die "${RELEASE_VALIDATION_ERROR}"
    PROFILE_APP_ID="${PROFILE_CONCRETE_APP_ID}"
    cp "${PROVISIONING_PROFILE}" "${CONTENTS_DIR}/embedded.provisionprofile"
fi
if [[ "${USE_ICLOUD}" -eq 0 && "${SIGN_IDENTITY}" != "-" ]]; then
    SIGN_ENTITLEMENTS="${TEMP_ROOT}/ClipboardRouter.SignedLocal.entitlements"
    cp "${LOCAL_ENTITLEMENTS}" "${SIGN_ENTITLEMENTS}"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string ${PROFILE_APP_ID}" "${SIGN_ENTITLEMENTS}"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string ${TEAM_ID}" "${SIGN_ENTITLEMENTS}"
    /usr/libexec/PlistBuddy -c "Add :keychain-access-groups array" "${SIGN_ENTITLEMENTS}"
    /usr/libexec/PlistBuddy -c "Add :keychain-access-groups:0 string ${PROFILE_APP_ID}" "${SIGN_ENTITLEMENTS}"
    /usr/bin/plutil -lint "${SIGN_ENTITLEMENTS}" >/dev/null
fi
if [[ "${USE_ICLOUD}" -eq 1 ]]; then
    SIGN_ENTITLEMENTS="${TEMP_ROOT}/ClipboardRouter.iCloud.entitlements"
    cp "${ICLOUD_ENTITLEMENTS_TEMPLATE}" "${SIGN_ENTITLEMENTS}"

    if [[ "${CLOUDKIT_ENVIRONMENT}" == "development" ]]; then
        CLOUDKIT_ENTITLEMENT_VALUE="Development"
        APS_ENTITLEMENT_VALUE="development"
    else
        CLOUDKIT_ENTITLEMENT_VALUE="Production"
        APS_ENTITLEMENT_VALUE="production"
    fi

    /usr/libexec/PlistBuddy -c "Set :com.apple.developer.aps-environment ${APS_ENTITLEMENT_VALUE}" "${SIGN_ENTITLEMENTS}"
    /usr/libexec/PlistBuddy -c "Set :com.apple.application-identifier ${PROFILE_APP_ID}" "${SIGN_ENTITLEMENTS}"
    /usr/libexec/PlistBuddy -c "Set :com.apple.developer.team-identifier ${TEAM_ID}" "${SIGN_ENTITLEMENTS}"
    /usr/libexec/PlistBuddy -c "Set :com.apple.developer.icloud-container-environment ${CLOUDKIT_ENTITLEMENT_VALUE}" "${SIGN_ENTITLEMENTS}"
    /usr/libexec/PlistBuddy -c "Set :com.apple.developer.icloud-container-identifiers:0 ${CLOUDKIT_CONTAINER}" "${SIGN_ENTITLEMENTS}"
    /usr/libexec/PlistBuddy -c "Set :keychain-access-groups:0 ${PROFILE_APP_ID}" "${SIGN_ENTITLEMENTS}"
    /usr/bin/plutil -lint "${SIGN_ENTITLEMENTS}" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :ClipboardRouterCloudKitContainerIdentifier string ${CLOUDKIT_CONTAINER}" "${CONTENTS_DIR}/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :ClipboardRouterCloudKitEnvironment string ${CLOUDKIT_ENVIRONMENT}" "${CONTENTS_DIR}/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :ClipboardRouterCloudKitPushEnabled true" "${CONTENTS_DIR}/Info.plist"
    /usr/bin/plutil -lint "${CONTENTS_DIR}/Info.plist" >/dev/null

    PROFILE_CLOUDKIT_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-environment' "${PROFILE_PLIST}" 2>/dev/null || true)"
    [[ "${PROFILE_CLOUDKIT_ENVIRONMENT}" == "${CLOUDKIT_ENTITLEMENT_VALUE}" ]] || die "provisioning profile CloudKit environment does not match --cloudkit-environment"

    PROFILE_APS_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.aps-environment' "${PROFILE_PLIST}" 2>/dev/null || true)"
    [[ "${PROFILE_APS_ENVIRONMENT}" == "${APS_ENTITLEMENT_VALUE}" ]] || die "provisioning profile push environment does not match --cloudkit-environment"

    PROFILE_AUTHORIZES_CONTAINER=0
    PROFILE_CONTAINER_INDEX=0
    while PROFILE_CONTAINER="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.icloud-container-identifiers:${PROFILE_CONTAINER_INDEX}" "${PROFILE_PLIST}" 2>/dev/null)"; do
        if [[ "${PROFILE_CONTAINER}" == "${CLOUDKIT_CONTAINER}" ]]; then
            PROFILE_AUTHORIZES_CONTAINER=1
            break
        fi
        PROFILE_CONTAINER_INDEX=$((PROFILE_CONTAINER_INDEX + 1))
    done
    [[ "${PROFILE_AUTHORIZES_CONTAINER}" -eq 1 ]] || die "provisioning profile does not authorize ${CLOUDKIT_CONTAINER}"
fi

TIMESTAMP_ARGS=()
if [[ "${TIMESTAMP_MODE}" == "auto" ]]; then
    if [[ "${SIGN_IDENTITY}" == "-" || "${CLOUDKIT_ENVIRONMENT}" == "development" ]]; then
        TIMESTAMP_ARGS+=(--timestamp=none)
    else
        TIMESTAMP_ARGS+=(--timestamp)
    fi
elif [[ "${TIMESTAMP_MODE}" == "none" ]]; then
    TIMESTAMP_ARGS+=(--timestamp=none)
else
    [[ "${SIGN_IDENTITY}" != "-" ]] || die "secure timestamps are unavailable for ad-hoc signing"
    TIMESTAMP_ARGS+=(--timestamp)
fi

echo "Signing cr with ${SIGN_IDENTITY}..."
CLI_SIGN_ARGS=(--force --sign "${SIGN_IDENTITY}" --options runtime)
if [[ "${DISTRIBUTION_CHANNEL}" == "macAppStore" ]]; then
    CLI_SIGN_ARGS+=(--entitlements "${MAC_APP_STORE_HELPER_ENTITLEMENTS}")
fi
CLI_SIGN_ARGS+=("${TIMESTAMP_ARGS[@]}")
/usr/bin/codesign "${CLI_SIGN_ARGS[@]}" "${HELPERS_DIR}/cr"
/usr/bin/codesign --verify --strict --verbose=2 "${HELPERS_DIR}/cr"

SIGN_ARGS=(--force --sign "${SIGN_IDENTITY}" --entitlements "${SIGN_ENTITLEMENTS}" --options runtime)
SIGN_ARGS+=("${TIMESTAMP_ARGS[@]}")
echo "Signing with ${SIGN_IDENTITY}..."
/usr/bin/codesign "${SIGN_ARGS[@]}" "${STAGED_APP}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${STAGED_APP}"
/usr/bin/codesign --verify --strict --verbose=2 "${HELPERS_DIR}/cr"
if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    SIGNED_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "${STAGED_APP}" 2>&1)"
    SIGNED_TEAM="$(release_signing_field "${SIGNED_DETAILS}" "TeamIdentifier")"
    [[ "${SIGNED_TEAM}" == "${TEAM_ID}" ]] \
        || die "application signing certificate Team ID does not match --team-id"
    validate_profile_signing_certificate \
        "${PROFILE_PLIST}" "${STAGED_APP}" "${TEMP_ROOT}/signing-certificate" \
        || die "${RELEASE_VALIDATION_ERROR}"
    SIGNED_ENTITLEMENTS="${TEMP_ROOT}/signed-local-entitlements.plist"
    /usr/bin/codesign -d --entitlements :- "${STAGED_APP}" > "${SIGNED_ENTITLEMENTS}" 2>/dev/null
    validate_local_profile_entitlements "${PROFILE_PLIST}" "${SIGNED_ENTITLEMENTS}" \
        || die "${RELEASE_VALIDATION_ERROR}"
fi
if [[ "${CUSTOMER_RELEASE}" -eq 1 ]]; then
    CUSTOMER_SIGNING_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "${STAGED_APP}" 2>&1)"
    echo "${CUSTOMER_SIGNING_DETAILS}" | /usr/bin/grep -q '^Authority=Developer ID Application:' \
        || die "--customer-release requires a Developer ID Application signing certificate"
    echo "${CUSTOMER_SIGNING_DETAILS}" | /usr/bin/grep -q '^Timestamp=' \
        || die "--customer-release requires a secure Developer ID signing timestamp"
    CUSTOMER_SIGNED_TEAM="$(echo "${CUSTOMER_SIGNING_DETAILS}" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    [[ "${CUSTOMER_SIGNED_TEAM}" == "${TEAM_ID}" ]] \
        || die "customer release signing certificate Team ID does not match --team-id"
fi

if [[ -e "${OUTPUT_MANIFEST}" ]]; then
    [[ "${OVERWRITE}" -eq 1 ]] || die "release manifest already exists; pass --overwrite to replace ${OUTPUT_MANIFEST}"
    [[ -f "${OUTPUT_MANIFEST}" && ! -L "${OUTPUT_MANIFEST}" ]] \
        || die "refusing to replace a non-regular release manifest"
fi
if [[ -e "${OUTPUT_APP}" ]]; then
    [[ "${OVERWRITE}" -eq 1 ]] || die "output already exists; pass --overwrite to replace ${OUTPUT_APP}"
fi

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

# Bind the packaged binary to the production source inputs even when this checkout is not a
# Git working tree. The release manifest already carries a Git revision when one exists; this
# deterministic tree hash is the fallback (and an additional check) for local source bundles.
#
# Scripts/verify_release.sh recomputes this exact hash from the exact same file list to detect
# drift between the manifest and the checked-out source. If this list ever changes, update the
# identical `source_tree_hash()` function in Scripts/verify_release.sh in the same commit —
# otherwise every packaged artifact will fail verification with a spurious hash mismatch.
source_tree_hash() {
    /usr/bin/python3 - "${PROJECT_ROOT}" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
files = []
for relative in ("Package.swift", "Scripts/package_app.sh", "Scripts/verify_release.sh", "Scripts/verify_source.sh", "Scripts/release_validation.sh"):
    path = root / relative
    if path.is_file():
        files.append(path)
for directory in (root / "Sources", root / "Resources"):
    if directory.is_dir():
        files.extend(path for path in directory.rglob("*") if path.is_file())

digest = hashlib.sha256()
for path in sorted(set(files), key=lambda item: str(item.relative_to(root))):
    digest.update(str(path.relative_to(root)).replace("\\", "/").encode())
    digest.update(b"\0")
    digest.update(path.read_bytes())
    digest.update(b"\0")
print(digest.hexdigest())
PY
}

SOURCE_TREE_HASH="$(source_tree_hash)"
[[ "${SOURCE_TREE_HASH}" =~ ^[0-9a-f]{64}$ ]] || die "could not compute the production source tree hash"

MANIFEST_PLIST="${TEMP_ROOT}/release-manifest.plist"
MANIFEST_JSON="${TEMP_ROOT}/release-manifest.json"
/usr/bin/plutil -create xml1 "${MANIFEST_PLIST}"
/usr/bin/plutil -insert schemaVersion -integer 2 "${MANIFEST_PLIST}"
/usr/bin/plutil -insert bundleIdentifier -string "${BUNDLE_ID}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert version -string "${VERSION}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert buildNumber -string "${BUILD_NUMBER}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert configuration -string "${CONFIGURATION}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert customerRelease -bool "$([[ "${CUSTOMER_RELEASE}" -eq 1 ]] && echo true || echo false)" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert distributionChannel -string "${DISTRIBUTION_CHANNEL}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert buildTimestamp -string "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert sourceTreeHash -string "${SOURCE_TREE_HASH}" "${MANIFEST_PLIST}"

SWIFT_TOOLCHAIN_RAW="$(/usr/bin/swift --version)"
SWIFT_TOOLCHAIN="${SWIFT_TOOLCHAIN_RAW%%$'\n'*}"
XCODE_TOOLCHAIN="$(/usr/bin/xcodebuild -version | /usr/bin/tr '\n' ';' | /usr/bin/sed 's/;$//')"
SDK_VERSION="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
/usr/bin/plutil -insert swiftToolchain -string "${SWIFT_TOOLCHAIN}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert xcodeToolchain -string "${XCODE_TOOLCHAIN}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert sdkVersion -string "${SDK_VERSION}" "${MANIFEST_PLIST}"

SOURCE_REVISION="$(/usr/bin/git -C "${PROJECT_ROOT}" rev-parse --verify HEAD 2>/dev/null || true)"
if [[ "${SOURCE_REVISION}" =~ ^[0-9a-fA-F]{40,64}$ ]]; then
    /usr/bin/plutil -insert sourceRevision -string "$(echo "${SOURCE_REVISION}" | /usr/bin/tr 'A-F' 'a-f')" "${MANIFEST_PLIST}"
    if [[ -n "$(/usr/bin/git -C "${PROJECT_ROOT}" status --porcelain --untracked-files=normal 2>/dev/null || true)" ]]; then
        /usr/bin/plutil -insert sourceTreeDirty -bool true "${MANIFEST_PLIST}"
    else
        /usr/bin/plutil -insert sourceTreeDirty -bool false "${MANIFEST_PLIST}"
    fi
fi

/usr/bin/plutil -insert architectures -array "${MANIFEST_PLIST}"
for index in "${!ARCHITECTURES[@]}"; do
    /usr/bin/plutil -insert "architectures.${index}" -string "${ARCHITECTURES[${index}]}" "${MANIFEST_PLIST}"
done

/usr/bin/plutil -insert artifacts -dictionary "${MANIFEST_PLIST}"
add_manifest_artifact() {
    local key="$1"
    local relative_path="$2"
    local include_hash="${3:-1}"
    local absolute_path="${STAGED_APP}/${relative_path}"
    /usr/bin/plutil -insert "artifacts.${key}" -dictionary "${MANIFEST_PLIST}"
    /usr/bin/plutil -insert "artifacts.${key}.path" -string "${relative_path}" "${MANIFEST_PLIST}"
    if [[ "${include_hash}" -eq 1 ]]; then
        /usr/bin/plutil -insert "artifacts.${key}.sha256" -string "$(sha256_file "${absolute_path}")" "${MANIFEST_PLIST}"
    fi
}

add_manifest_artifact applicationExecutable "Contents/MacOS/ClipboardRouter" 0
add_manifest_artifact commandLineTool "Contents/Helpers/cr" 0
add_manifest_artifact commandLineToolVersion "Contents/Resources/cr.version"
add_manifest_artifact privacyManifest "Contents/Resources/PrivacyInfo.xcprivacy"
add_manifest_artifact cliInstaller "Contents/Resources/install-cr.sh"
/usr/bin/plutil -insert artifacts.applicationExecutable.architectures -array "${MANIFEST_PLIST}"
/usr/bin/plutil -insert artifacts.commandLineTool.architectures -array "${MANIFEST_PLIST}"
for index in "${!ARCHITECTURES[@]}"; do
    /usr/bin/plutil -insert "artifacts.applicationExecutable.architectures.${index}" -string "${ARCHITECTURES[${index}]}" "${MANIFEST_PLIST}"
    /usr/bin/plutil -insert "artifacts.commandLineTool.architectures.${index}" -string "${ARCHITECTURES[${index}]}" "${MANIFEST_PLIST}"
done
/usr/bin/plutil -insert artifacts.commandLineTool.version -string "${VERSION}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert artifacts.commandLineTool.buildNumber -string "${BUILD_NUMBER}" "${MANIFEST_PLIST}"

/usr/bin/plutil -convert json -o "${MANIFEST_JSON}" "${MANIFEST_PLIST}"
/usr/bin/python3 -m json.tool "${MANIFEST_JSON}" >/dev/null \
    || die "generated release manifest is not valid JSON"

# Bind release provenance to the app's code signature. The adjacent copy is retained for
# automation and human inspection, but verification treats this embedded copy as authoritative.
EMBEDDED_MANIFEST="${RESOURCES_DIR}/ClipboardRouter.release.json"
/bin/cp "${MANIFEST_JSON}" "${EMBEDDED_MANIFEST}"
/usr/bin/codesign "${SIGN_ARGS[@]}" "${STAGED_APP}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${STAGED_APP}"
/usr/bin/codesign --verify --strict --verbose=2 "${HELPERS_DIR}/cr"

# Keep an existing verified package intact until its replacement app and manifest have both
# been staged and validated. Roll back both members if either final move fails.
mkdir -p "$(dirname "${OUTPUT_APP}")"
mkdir -p "$(dirname "${OUTPUT_MANIFEST}")"
BACKUP_APP="${OUTPUT_APP}.previous.$$"
BACKUP_MANIFEST="${OUTPUT_MANIFEST}.previous.$$"
[[ ! -e "${BACKUP_APP}" && ! -e "${BACKUP_MANIFEST}" ]] || die "temporary backup path already exists"
if [[ -e "${OUTPUT_APP}" ]]; then
    mv "${OUTPUT_APP}" "${BACKUP_APP}"
fi
if [[ -e "${OUTPUT_MANIFEST}" ]]; then
    mv "${OUTPUT_MANIFEST}" "${BACKUP_MANIFEST}"
fi
if ! mv "${STAGED_APP}" "${OUTPUT_APP}"; then
    [[ ! -e "${BACKUP_APP}" ]] || mv "${BACKUP_APP}" "${OUTPUT_APP}"
    [[ ! -e "${BACKUP_MANIFEST}" ]] || mv "${BACKUP_MANIFEST}" "${OUTPUT_MANIFEST}"
    die "could not install the staged application; the previous package was restored"
fi
if ! /bin/mv "${MANIFEST_JSON}" "${OUTPUT_MANIFEST}"; then
    rm -rf "${OUTPUT_APP}"
    [[ ! -e "${BACKUP_APP}" ]] || mv "${BACKUP_APP}" "${OUTPUT_APP}"
    [[ ! -e "${BACKUP_MANIFEST}" ]] || mv "${BACKUP_MANIFEST}" "${OUTPUT_MANIFEST}"
    die "could not install the release manifest; the previous package was restored"
fi
rm -rf "${BACKUP_APP}"
rm -f "${BACKUP_MANIFEST}"

echo
echo "Packaged: ${OUTPUT_APP}"
echo "Bundle ID: ${BUNDLE_ID}"
echo "Version: ${VERSION} (${BUILD_NUMBER})"
echo "Architectures: ${ARCHITECTURES[*]}"
echo "Distribution channel: ${DISTRIBUTION_CHANNEL}"
echo "CLI: ${OUTPUT_APP}/Contents/Helpers/cr"
echo "Release manifest: ${OUTPUT_MANIFEST}"
if [[ "${USE_ICLOUD}" -eq 1 ]]; then
    echo "Profile: iCloud ${CLOUDKIT_ENVIRONMENT} (${CLOUDKIT_CONTAINER})"
else
    echo "Profile: local-only (no iCloud entitlement)"
fi
echo "Next: ${SCRIPT_DIR}/verify_release.sh --profile $([[ "${USE_ICLOUD}" -eq 1 ]] && echo icloud || echo local) \"${OUTPUT_APP}\""
