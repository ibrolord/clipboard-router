#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=release_validation.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/release_validation.sh"

PROFILE="local"
EXPECTED_BUNDLE_ID=""
EXPECTED_CLOUDKIT_CONTAINER=""
REQUIRE_NOTARIZED=0
REQUIRE_CUSTOMER_RELEASE=0
EXPECTED_DISTRIBUTION_CHANNEL=""
APP_PATH=""
MANIFEST_PATH=""

usage() {
    cat <<'USAGE'
Verify a packaged Clipboard Router application without launching it.

Usage:
  Scripts/verify_release.sh [options] PATH_TO_APP

Options:
  --profile local|icloud         Expected entitlement profile (default: local)
  --bundle-id IDENTIFIER         Require this bundle identifier
  --cloudkit-container ID        Require this CloudKit container (iCloud only)
  --manifest PATH                Release manifest (default: APP_PATH.release.json)
  --require-notarized            Require Gatekeeper acceptance and a staple
  --require-customer-release     Require production licensing and clean Git provenance
  --expect-distribution-channel direct|macAppStore
                                 Require this exact packaged distribution channel
  --help                         Show this help

This also verifies the adjacent release manifest, signed packaged `cr` command,
exact app/CLI version and architectures, and artifact hashes. Direct-distribution
builds additionally run CLI stdin smokes. Mac App Store-signed helpers cannot be
executed before installation, so that profile is verified statically instead.
This does not install the CLI or modify PATH.
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
        --profile)
            require_value "$@"
            PROFILE="$2"
            shift 2
            ;;
        --bundle-id)
            require_value "$@"
            EXPECTED_BUNDLE_ID="$2"
            shift 2
            ;;
        --cloudkit-container)
            require_value "$@"
            EXPECTED_CLOUDKIT_CONTAINER="$2"
            shift 2
            ;;
        --manifest)
            require_value "$@"
            MANIFEST_PATH="$2"
            shift 2
            ;;
        --require-notarized)
            REQUIRE_NOTARIZED=1
            shift
            ;;
        --require-customer-release)
            REQUIRE_CUSTOMER_RELEASE=1
            shift
            ;;
        --expect-distribution-channel)
            require_value "$@"
            EXPECTED_DISTRIBUTION_CHANNEL="$2"
            shift 2
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

# Notarization and commercial licensing are independent release properties.
# Free/beta builds may be Developer ID signed and notarized without embedding a
# commerce-provider license configuration. Callers that require the paid
# customer configuration must opt in separately with --require-customer-release.

[[ "${PROFILE}" == "local" || "${PROFILE}" == "icloud" ]] || die "--profile must be local or icloud"
[[ -z "${EXPECTED_DISTRIBUTION_CHANNEL}" || "${EXPECTED_DISTRIBUTION_CHANNEL}" == "direct" \
    || "${EXPECTED_DISTRIBUTION_CHANNEL}" == "macAppStore" ]] \
    || die "--expect-distribution-channel must be direct or macAppStore"
[[ -n "${APP_PATH}" ]] || die "an application path is required"
[[ -d "${APP_PATH}" && "${APP_PATH}" == *.app ]] || die "not an application bundle: ${APP_PATH}"
if [[ -z "${MANIFEST_PATH}" ]]; then
    MANIFEST_PATH="${APP_PATH}.release.json"
fi

ADJACENT_MANIFEST_PATH="${MANIFEST_PATH}"
EMBEDDED_MANIFEST_PATH="${APP_PATH}/Contents/Resources/ClipboardRouter.release.json"

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
EXECUTABLE="${APP_PATH}/Contents/MacOS/ClipboardRouter"
CLI_EXECUTABLE="${APP_PATH}/Contents/Helpers/cr"
PRIVACY_MANIFEST="${APP_PATH}/Contents/Resources/PrivacyInfo.xcprivacy"
APP_ICON="${APP_PATH}/Contents/Resources/ClipboardRouter.icns"
CLI_INSTALLER="${APP_PATH}/Contents/Resources/install-cr.sh"
[[ -f "${INFO_PLIST}" ]] || die "missing Contents/Info.plist"
[[ -x "${EXECUTABLE}" ]] || die "missing executable Contents/MacOS/ClipboardRouter"
[[ -x "${CLI_EXECUTABLE}" ]] || die "missing signed CLI Contents/Helpers/cr"
[[ -f "${PRIVACY_MANIFEST}" ]] || die "missing PrivacyInfo.xcprivacy"
[[ -f "${APP_ICON}" ]] || die "missing application icon ClipboardRouter.icns"
validate_app_icon "${APP_ICON}" || die "${RELEASE_VALIDATION_ERROR}"
[[ -x "${CLI_INSTALLER}" ]] || die "missing executable CLI installer"
[[ -f "${ADJACENT_MANIFEST_PATH}" && ! -L "${ADJACENT_MANIFEST_PATH}" ]] || die "missing regular release manifest: ${ADJACENT_MANIFEST_PATH}"
[[ -f "${EMBEDDED_MANIFEST_PATH}" && ! -L "${EMBEDDED_MANIFEST_PATH}" ]] || die "missing signature-bound embedded release manifest"
/usr/bin/cmp -s "${ADJACENT_MANIFEST_PATH}" "${EMBEDDED_MANIFEST_PATH}" \
    || die "adjacent release manifest does not match the signature-bound embedded manifest"
MANIFEST_PATH="${EMBEDDED_MANIFEST_PATH}"

/usr/bin/plutil -lint "${INFO_PLIST}" "${PRIVACY_MANIFEST}" >/dev/null
/usr/bin/python3 -m json.tool "${MANIFEST_PATH}" >/dev/null \
    || die "release manifest is not valid JSON"

BUNDLE_PACKAGE_TYPE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "${INFO_PLIST}")"
BUNDLE_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${INFO_PLIST}")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${INFO_PLIST}")"
MINIMUM_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${INFO_PLIST}")"
MENU_BAR_ONLY="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "${INFO_PLIST}")"
AUTOMATIC_TERMINATION="$(/usr/libexec/PlistBuddy -c 'Print :NSSupportsAutomaticTermination' "${INFO_PLIST}")"
SUDDEN_TERMINATION="$(/usr/libexec/PlistBuddy -c 'Print :NSSupportsSuddenTermination' "${INFO_PLIST}")"
CK_SHARING_SUPPORTED="$(/usr/libexec/PlistBuddy -c 'Print :CKSharingSupported' "${INFO_PLIST}" 2>/dev/null || true)"
CLOUDKIT_PUSH_ENABLED="$(/usr/libexec/PlistBuddy -c 'Print :ClipboardRouterCloudKitPushEnabled' "${INFO_PLIST}" 2>/dev/null || true)"
CLOUDKIT_INFO_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :ClipboardRouterCloudKitEnvironment' "${INFO_PLIST}" 2>/dev/null || true)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")"
CALENDAR_USAGE="$(/usr/libexec/PlistBuddy -c 'Print :NSCalendarsWriteOnlyAccessUsageDescription' "${INFO_PLIST}" 2>/dev/null || true)"
CONTACTS_USAGE="$(/usr/libexec/PlistBuddy -c 'Print :NSContactsUsageDescription' "${INFO_PLIST}" 2>/dev/null || true)"
LOCATION_USAGE="$(/usr/libexec/PlistBuddy -c 'Print :NSLocationWhenInUseUsageDescription' "${INFO_PLIST}" 2>/dev/null || true)"
CRM_CALLBACK_SCHEME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "${INFO_PLIST}" 2>/dev/null || true)"
LICENSE_SERVICE_URL="$(/usr/libexec/PlistBuddy -c 'Print :ClipboardRouterLicenseServiceURL' "${INFO_PLIST}" 2>/dev/null || true)"
COMMERCE_PROVIDER="$(/usr/libexec/PlistBuddy -c 'Print :ClipboardRouterCommerceProviderIdentifier' "${INFO_PLIST}" 2>/dev/null || true)"
LICENSE_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :ClipboardRouterLicensePublicKeyDERBase64' "${INFO_PLIST}" 2>/dev/null || true)"
DISTRIBUTION_CHANNEL="$(/usr/libexec/PlistBuddy -c 'Print :ClipboardRouterDistributionChannel' "${INFO_PLIST}" 2>/dev/null || true)"

[[ "${BUNDLE_PACKAGE_TYPE}" == "APPL" ]] || die "CFBundlePackageType must be APPL"
[[ "${BUNDLE_EXECUTABLE}" == "ClipboardRouter" ]] || die "unexpected CFBundleExecutable"
[[ "${MINIMUM_SYSTEM}" == "14.0" ]] || die "LSMinimumSystemVersion must be 14.0"
[[ "${MENU_BAR_ONLY}" == "true" ]] || die "LSUIElement must be true"
[[ "${AUTOMATIC_TERMINATION}" == "false" ]] || die "NSSupportsAutomaticTermination must be false"
[[ "${SUDDEN_TERMINATION}" == "false" ]] || die "NSSupportsSuddenTermination must be false"
[[ "${CK_SHARING_SUPPORTED}" == "true" ]] || die "CKSharingSupported must be true"
[[ -n "${CALENDAR_USAGE}" ]] || die "NSCalendarsWriteOnlyAccessUsageDescription is missing"
[[ -n "${CONTACTS_USAGE}" ]] || die "NSContactsUsageDescription is missing"
[[ -n "${LOCATION_USAGE}" ]] || die "NSLocationWhenInUseUsageDescription is missing"
[[ "${CRM_CALLBACK_SCHEME}" == "clipboardrouter" ]] || die "clipboardrouter OAuth callback scheme is missing"
[[ -z "${DISTRIBUTION_CHANNEL}" || "${DISTRIBUTION_CHANNEL}" == "direct" \
    || "${DISTRIBUTION_CHANNEL}" == "macAppStore" ]] \
    || die "ClipboardRouterDistributionChannel must be direct or macAppStore"
EFFECTIVE_DISTRIBUTION_CHANNEL="${DISTRIBUTION_CHANNEL:-direct}"
if [[ -n "${EXPECTED_DISTRIBUTION_CHANNEL}" ]]; then
    [[ "${EFFECTIVE_DISTRIBUTION_CHANNEL}" == "${EXPECTED_DISTRIBUTION_CHANNEL}" ]] \
        || die "packaged distribution channel does not match --expect-distribution-channel"
fi
if [[ "${REQUIRE_CUSTOMER_RELEASE}" -eq 1 ]]; then
    /usr/bin/python3 -c 'import sys, urllib.parse; p=urllib.parse.urlsplit(sys.argv[1]); ok=(p.scheme=="https" and bool(p.hostname) and p.username is None and p.password is None and not p.query and not p.fragment and not any(c.isspace() for c in sys.argv[1])); raise SystemExit(0 if ok else 1)' "${LICENSE_SERVICE_URL}" \
        || die "customer release license service URL is missing or unsafe"
    [[ -n "${COMMERCE_PROVIDER}" ]] || die "customer release commerce provider is missing"
    LICENSE_KEY_TEMP="$(mktemp "${TMPDIR:-/tmp}/clipboard-router-verify-license-key.XXXXXX")"
    if ! /usr/bin/printf '%s' "${LICENSE_PUBLIC_KEY}" | /usr/bin/base64 -D >"${LICENSE_KEY_TEMP}" 2>/dev/null \
        || ! /usr/bin/openssl pkey -pubin -inform DER -in "${LICENSE_KEY_TEMP}" -text -noout 2>&1 \
            | /usr/bin/grep -q 'prime256v1'; then
        /bin/rm -f "${LICENSE_KEY_TEMP}"
        die "customer release license public key is missing or not P-256 DER"
    fi
    /bin/rm -f "${LICENSE_KEY_TEMP}"
fi
[[ -z "${EXPECTED_BUNDLE_ID}" || "${BUNDLE_ID}" == "${EXPECTED_BUNDLE_ID}" ]] || die "bundle identifier does not match --bundle-id"

manifest_value() {
    /usr/bin/plutil -extract "$1" raw -o - "${MANIFEST_PATH}" 2>/dev/null \
        || die "release manifest is missing $1"
}

MANIFEST_SCHEMA="$(manifest_value schemaVersion)"
MANIFEST_BUNDLE_ID="$(manifest_value bundleIdentifier)"
MANIFEST_VERSION="$(manifest_value version)"
MANIFEST_BUILD_NUMBER="$(manifest_value buildNumber)"
MANIFEST_CONFIGURATION="$(manifest_value configuration)"
MANIFEST_CUSTOMER_RELEASE="$(manifest_value customerRelease)"
MANIFEST_DISTRIBUTION_CHANNEL="$(manifest_value distributionChannel)"
MANIFEST_BUILD_TIMESTAMP="$(manifest_value buildTimestamp)"
MANIFEST_SWIFT_TOOLCHAIN="$(manifest_value swiftToolchain)"
MANIFEST_XCODE_TOOLCHAIN="$(manifest_value xcodeToolchain)"
MANIFEST_SDK_VERSION="$(manifest_value sdkVersion)"
MANIFEST_SOURCE_TREE_HASH="$(manifest_value sourceTreeHash)"
[[ "${MANIFEST_SCHEMA}" == "2" ]] || die "unsupported release manifest schema"
[[ "${MANIFEST_BUNDLE_ID}" == "${BUNDLE_ID}" ]] || die "manifest bundle identifier does not match the app"
[[ "${MANIFEST_VERSION}" == "${VERSION}" ]] || die "manifest version does not match the app"
[[ "${MANIFEST_BUILD_NUMBER}" == "${BUILD_NUMBER}" ]] || die "manifest build number does not match the app"
[[ "${MANIFEST_DISTRIBUTION_CHANNEL}" == "${EFFECTIVE_DISTRIBUTION_CHANNEL}" ]] \
    || die "manifest distribution channel does not match the app"
[[ "${MANIFEST_CONFIGURATION}" == "debug" || "${MANIFEST_CONFIGURATION}" == "release" ]] \
    || die "manifest configuration is invalid"
if [[ "${REQUIRE_CUSTOMER_RELEASE}" -eq 1 ]]; then
    [[ "${MANIFEST_CUSTOMER_RELEASE}" == "true" ]] || die "manifest is not marked as a customer release"
    [[ "${MANIFEST_CONFIGURATION}" == "release" ]] || die "customer release was not built in release configuration"
fi
[[ "${MANIFEST_BUILD_TIMESTAMP}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || die "manifest build timestamp is not UTC RFC 3339"
[[ -n "${MANIFEST_SWIFT_TOOLCHAIN}" && -n "${MANIFEST_XCODE_TOOLCHAIN}" && -n "${MANIFEST_SDK_VERSION}" ]] \
    || die "manifest toolchain metadata is incomplete"
[[ "${MANIFEST_SOURCE_TREE_HASH}" =~ ^[0-9a-f]{64}$ ]] \
    || die "manifest source tree hash is missing or malformed"

# Recompute the source tree hash from the exact same inputs Scripts/package_app.sh hashed when it
# produced this manifest. This is the only check that binds the manifest's sourceTreeHash claim to
# the actual checked-out source rather than trusting whatever value package_app.sh wrote. If either
# script's file list changes, update the other in the same commit or every verification will fail.
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

RECOMPUTED_SOURCE_TREE_HASH="$(source_tree_hash)"
[[ "${RECOMPUTED_SOURCE_TREE_HASH}" =~ ^[0-9a-f]{64}$ ]] \
    || die "could not recompute the source tree hash from the checked-out source"
[[ "${RECOMPUTED_SOURCE_TREE_HASH}" == "${MANIFEST_SOURCE_TREE_HASH}" ]] \
    || die "manifest sourceTreeHash does not match the checked-out source tree (recomputed ${RECOMPUTED_SOURCE_TREE_HASH}, manifest ${MANIFEST_SOURCE_TREE_HASH})"

SOURCE_REVISION="$(/usr/bin/plutil -extract sourceRevision raw -o - "${MANIFEST_PATH}" 2>/dev/null || true)"
SOURCE_TREE_DIRTY=""
if [[ -n "${SOURCE_REVISION}" ]]; then
    [[ "${SOURCE_REVISION}" =~ ^[0-9a-f]{40,64}$ ]] \
        || die "manifest source revision must be a real hexadecimal Git object ID"
    SOURCE_TREE_DIRTY="$(manifest_value sourceTreeDirty)"
    [[ "${SOURCE_TREE_DIRTY}" == "true" || "${SOURCE_TREE_DIRTY}" == "false" ]] \
        || die "manifest sourceTreeDirty must be boolean when sourceRevision is present"
fi
if [[ "${REQUIRE_CUSTOMER_RELEASE}" -eq 1 ]]; then
    [[ "${SOURCE_REVISION}" =~ ^[0-9a-f]{40,64}$ ]] || die "customer release source revision is missing"
    [[ "${SOURCE_TREE_DIRTY}" == "false" ]] || die "customer release source tree was dirty"
fi

APP_ARTIFACT_PATH="$(manifest_value artifacts.applicationExecutable.path)"
CLI_ARTIFACT_PATH="$(manifest_value artifacts.commandLineTool.path)"
PRIVACY_ARTIFACT_PATH="$(manifest_value artifacts.privacyManifest.path)"
INSTALLER_ARTIFACT_PATH="$(manifest_value artifacts.cliInstaller.path)"
CLI_VERSION_ARTIFACT_PATH="$(manifest_value artifacts.commandLineToolVersion.path)"
[[ "${APP_ARTIFACT_PATH}" == "Contents/MacOS/ClipboardRouter" ]] || die "manifest app executable path is invalid"
[[ "${CLI_ARTIFACT_PATH}" == "Contents/Helpers/cr" ]] || die "manifest CLI path is invalid"
[[ "${PRIVACY_ARTIFACT_PATH}" == "Contents/Resources/PrivacyInfo.xcprivacy" ]] || die "manifest privacy path is invalid"
[[ "${INSTALLER_ARTIFACT_PATH}" == "Contents/Resources/install-cr.sh" ]] || die "manifest installer path is invalid"
[[ "${CLI_VERSION_ARTIFACT_PATH}" == "Contents/Resources/cr.version" ]] || die "manifest CLI version path is invalid"

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

# Executable integrity is established by the nested and outer code signatures below. Their
# bytes cannot be included in the signature-bound manifest without creating a hash cycle.
[[ "$(manifest_value artifacts.privacyManifest.sha256)" == "$(sha256_file "${PRIVACY_MANIFEST}")" ]] \
    || die "privacy manifest hash does not match the release manifest"
[[ "$(manifest_value artifacts.cliInstaller.sha256)" == "$(sha256_file "${CLI_INSTALLER}")" ]] \
    || die "CLI installer hash does not match the release manifest"
[[ "$(manifest_value artifacts.commandLineToolVersion.sha256)" == "$(sha256_file "${APP_PATH}/Contents/Resources/cr.version")" ]] \
    || die "CLI version metadata hash does not match the release manifest"
[[ "$(manifest_value artifacts.commandLineTool.version)" == "${VERSION}" ]] \
    || die "packaged CLI version does not exactly match the app version"
[[ "$(manifest_value artifacts.commandLineTool.buildNumber)" == "${BUILD_NUMBER}" ]] \
    || die "packaged CLI build does not exactly match the app build"

manifest_architectures() {
    local key="$1"
    local index=0
    local value
    local result=""
    while value="$(/usr/bin/plutil -extract "${key}.${index}" raw -o - "${MANIFEST_PATH}" 2>/dev/null)"; do
        [[ "${value}" == "arm64" || "${value}" == "x86_64" ]] \
            || die "manifest contains unsupported architecture ${value}"
        [[ " ${result} " != *" ${value} "* ]] || die "manifest repeats architecture ${value}"
        result="${result:+${result} }${value}"
        index=$((index + 1))
    done
    [[ -n "${result}" ]] || die "manifest architecture list ${key} is empty"
    echo "${result}"
}

canonical_architectures() {
    echo "$*" | /usr/bin/tr ' ' '\n' | /usr/bin/sort -u | /usr/bin/paste -sd ' ' -
}

MANIFEST_ARCHITECTURES="$(canonical_architectures "$(manifest_architectures architectures)")"
MANIFEST_APP_ARCHITECTURES="$(canonical_architectures "$(manifest_architectures artifacts.applicationExecutable.architectures)")"
MANIFEST_CLI_ARCHITECTURES="$(canonical_architectures "$(manifest_architectures artifacts.commandLineTool.architectures)")"
ACTUAL_APP_ARCHITECTURES="$(canonical_architectures "$(/usr/bin/lipo -archs "${EXECUTABLE}")")"
ACTUAL_CLI_ARCHITECTURES="$(canonical_architectures "$(/usr/bin/lipo -archs "${CLI_EXECUTABLE}")")"
[[ "${MANIFEST_ARCHITECTURES}" == "${MANIFEST_APP_ARCHITECTURES}" \
   && "${MANIFEST_ARCHITECTURES}" == "${MANIFEST_CLI_ARCHITECTURES}" ]] \
    || die "manifest app and CLI architecture declarations differ"
[[ "${MANIFEST_ARCHITECTURES}" == "${ACTUAL_APP_ARCHITECTURES}" ]] \
    || die "app architectures do not match the release manifest"
[[ "${MANIFEST_ARCHITECTURES}" == "${ACTUAL_CLI_ARCHITECTURES}" ]] \
    || die "CLI architectures do not exactly match the app build"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clipboard-router-verify.XXXXXX")"
trap 'rm -rf "${TEMP_ROOT}"' EXIT

if /usr/bin/grep -E -q '(PLACEHOLDER|TEAM_ID_PLACEHOLDER|CLOUDKIT_CONTAINER_PLACEHOLDER)' "${INFO_PLIST}" "${PRIVACY_MANIFEST}"; then
    die "packaged artifact contains an unsubstituted placeholder"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
/usr/bin/codesign --verify --strict --verbose=2 "${CLI_EXECUTABLE}"

APP_SIGNING_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "${APP_PATH}" 2>&1)"
CLI_SIGNING_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "${CLI_EXECUTABLE}" 2>&1)"
APP_TEAM="$(echo "${APP_SIGNING_DETAILS}" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')"
CLI_TEAM="$(echo "${CLI_SIGNING_DETAILS}" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')"
APP_AUTHORITY="$(echo "${APP_SIGNING_DETAILS}" | /usr/bin/grep '^Authority=' || true)"
CLI_AUTHORITY="$(echo "${CLI_SIGNING_DETAILS}" | /usr/bin/grep '^Authority=' || true)"
APP_SIGNATURE_KIND="$(echo "${APP_SIGNING_DETAILS}" | /usr/bin/awk -F= '/^Signature=/{print $2; exit}')"
CLI_SIGNATURE_KIND="$(echo "${CLI_SIGNING_DETAILS}" | /usr/bin/awk -F= '/^Signature=/{print $2; exit}')"
[[ "${APP_TEAM}" == "${CLI_TEAM}" && "${APP_AUTHORITY}" == "${CLI_AUTHORITY}" \
   && "${APP_SIGNATURE_KIND}" == "${CLI_SIGNATURE_KIND}" ]] \
    || die "CLI and application signing identities do not match"
if [[ "${REQUIRE_CUSTOMER_RELEASE}" -eq 1 ]]; then
    validate_customer_signing_details "${APP_SIGNING_DETAILS}" \
        || die "${RELEASE_VALIDATION_ERROR}"
fi

if [[ "${DISTRIBUTION_CHANNEL}" != "macAppStore" ]]; then
    CLI_HELP_OUTPUT="$("${CLI_EXECUTABLE}" --help)" || die "packaged cr --help failed"
    echo "${CLI_HELP_OUTPUT}" | /usr/bin/grep -q '^Usage:' || die "packaged cr --help output is invalid"
    CLI_VERSION_OUTPUT="$("${CLI_EXECUTABLE}" --version)" || die "packaged cr --version failed"
    [[ "${CLI_VERSION_OUTPUT}" == "cr ${VERSION} (${BUILD_NUMBER})" ]] \
        || die "packaged cr version does not exactly match the application"
    printf 'fatal error: build failed\nmain.swift:42\n' \
        | "${CLI_EXECUTABLE}" analyze --format json - > "${TEMP_ROOT}/cli-analyze.json" \
        || die "packaged cr analyze stdin smoke failed"
    printf '{"b":2,"a":1}\n' \
        | "${CLI_EXECUTABLE}" transform pretty-json - > "${TEMP_ROOT}/cli-transform.json" \
        || die "packaged cr transform stdin smoke failed"
    /usr/bin/grep -q '"kind"' "${TEMP_ROOT}/cli-analyze.json" || die "packaged cr analyze output is invalid"
    /usr/bin/grep -q '"a"' "${TEMP_ROOT}/cli-transform.json" || die "packaged cr transform output is invalid"
fi

ENTITLEMENTS_PLIST="${TEMP_ROOT}/entitlements.plist"
/usr/bin/codesign -d --entitlements :- "${APP_PATH}" > "${ENTITLEMENTS_PLIST}" 2>/dev/null
/usr/bin/plutil -lint "${ENTITLEMENTS_PLIST}" >/dev/null
if /usr/bin/grep -E -q '(PLACEHOLDER|TEAM_ID_PLACEHOLDER|CLOUDKIT_CONTAINER_PLACEHOLDER)' "${ENTITLEMENTS_PLIST}"; then
    die "packaged entitlements contain an unsubstituted placeholder"
fi

SANDBOXED="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
[[ "${SANDBOXED}" == "true" ]] || die "application sandbox entitlement is missing"
USER_SELECTED_READ_WRITE="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
[[ "${USER_SELECTED_READ_WRITE}" == "true" ]] || die "user-selected read-write entitlement is missing"
APP_SCOPED_BOOKMARKS="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.bookmarks.app-scope' "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
[[ "${APP_SCOPED_BOOKMARKS}" == "true" ]] || die "app-scoped bookmark entitlement is missing"
CALENDAR_ACCESS="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.personal-information.calendars' "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
[[ "${CALENDAR_ACCESS}" == "true" ]] || die "calendar entitlement is missing"
CONTACTS_ACCESS="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.personal-information.addressbook' "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
[[ "${CONTACTS_ACCESS}" == "true" ]] || die "Contacts entitlement is missing"
LOCATION_ACCESS="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.personal-information.location' "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
[[ "${LOCATION_ACCESS}" == "true" ]] || die "location entitlement is missing"
NETWORK_CLIENT="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
[[ "${NETWORK_CLIENT}" == "true" ]] || die "outbound network client entitlement is missing"

if [[ "${PROFILE}" == "local" ]]; then
    [[ "${CLOUDKIT_PUSH_ENABLED}" == "false" ]] || die "local profile unexpectedly enables CloudKit push"
    [[ -z "${CLOUDKIT_INFO_ENVIRONMENT}" ]] || die "local profile unexpectedly declares a CloudKit environment"
    if /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-services' "${ENTITLEMENTS_PLIST}" >/dev/null 2>&1; then
        die "local profile unexpectedly includes iCloud services"
    fi
    SIGNING_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "${APP_PATH}" 2>&1)"
    if echo "${SIGNING_DETAILS}" | /usr/bin/grep -q 'Signature=adhoc'; then
        [[ ! -e "${APP_PATH}/Contents/embedded.provisionprofile" ]] \
            || die "ad-hoc local profile unexpectedly embeds a provisioning profile"
    else
        [[ -f "${APP_PATH}/Contents/embedded.provisionprofile" ]] \
            || die "signed local Vault build is missing embedded.provisionprofile"
        PROFILE_PLIST="${TEMP_ROOT}/local-provisioning-profile.plist"
        decode_apple_provisioning_profile "${APP_PATH}/Contents/embedded.provisionprofile" "${PROFILE_PLIST}" \
            || die "${RELEASE_VALIDATION_ERROR}"
        validate_provisioning_profile_metadata "${PROFILE_PLIST}" "${APP_TEAM}" "${BUNDLE_ID}" \
            || die "${RELEASE_VALIDATION_ERROR}"
        PROFILE_TEAM_ID="${APP_TEAM}"
        PROFILE_APP_ID="${PROFILE_CONCRETE_APP_ID}"
        SIGNED_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
        SIGNED_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
        [[ "${SIGNED_TEAM_ID}" == "${PROFILE_TEAM_ID}" ]] \
            || die "signed local Team ID entitlement does not match the embedded profile"
        [[ "${SIGNED_APP_ID}" == "${PROFILE_APP_ID}" ]] \
            || die "signed local application identifier entitlement does not match the embedded profile"
        validate_profile_signing_certificate \
            "${PROFILE_PLIST}" "${APP_PATH}" "${TEMP_ROOT}/local-signing-certificate" \
            || die "${RELEASE_VALIDATION_ERROR}"
        validate_local_profile_entitlements "${PROFILE_PLIST}" "${ENTITLEMENTS_PLIST}" \
            || die "${RELEASE_VALIDATION_ERROR}"
    fi
else
    ICLOUD_SERVICE="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-services:0' "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
    CLOUDKIT_CONTAINER="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers:0' "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
    CLOUDKIT_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
    APS_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.aps-environment' "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
    [[ "${ICLOUD_SERVICE}" == "CloudKit" ]] || die "iCloud profile is missing the CloudKit service entitlement"
    [[ "${CLOUDKIT_CONTAINER}" == iCloud.* ]] || die "iCloud profile has no valid CloudKit container"
    [[ "${CLOUDKIT_ENVIRONMENT}" == "Development" || "${CLOUDKIT_ENVIRONMENT}" == "Production" ]] || die "invalid CloudKit environment entitlement"
    if [[ "${CLOUDKIT_ENVIRONMENT}" == "Development" ]]; then
        EXPECTED_APS_ENVIRONMENT="development"
    else
        EXPECTED_APS_ENVIRONMENT="production"
    fi
    [[ "${APS_ENVIRONMENT}" == "${EXPECTED_APS_ENVIRONMENT}" ]] || die "signed push environment does not match CloudKit environment"
    [[ "${CLOUDKIT_PUSH_ENABLED}" == "true" ]] || die "iCloud profile must enable CloudKit push routing"
    [[ "${CLOUDKIT_INFO_ENVIRONMENT}" == "${EXPECTED_APS_ENVIRONMENT}" ]] || die "Info.plist CloudKit environment does not match signed entitlements"
    [[ -z "${EXPECTED_CLOUDKIT_CONTAINER}" || "${CLOUDKIT_CONTAINER}" == "${EXPECTED_CLOUDKIT_CONTAINER}" ]] || die "CloudKit container does not match --cloudkit-container"
    [[ -f "${APP_PATH}/Contents/embedded.provisionprofile" ]] || die "iCloud profile is missing embedded.provisionprofile"
    CONFIGURED_CONTAINER="$(/usr/libexec/PlistBuddy -c 'Print :ClipboardRouterCloudKitContainerIdentifier' "${INFO_PLIST}" 2>/dev/null || true)"
    [[ "${CONFIGURED_CONTAINER}" == "${CLOUDKIT_CONTAINER}" ]] || die "runtime CloudKit container configuration does not match the signed entitlement"

    SIGNING_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "${APP_PATH}" 2>&1)"
    if echo "${SIGNING_DETAILS}" | /usr/bin/grep -q 'Signature=adhoc'; then
        die "iCloud profile is ad-hoc signed"
    fi

    PROFILE_PLIST="${TEMP_ROOT}/provisioning-profile.plist"
    decode_apple_provisioning_profile "${APP_PATH}/Contents/embedded.provisionprofile" "${PROFILE_PLIST}" \
        || die "${RELEASE_VALIDATION_ERROR}"
    validate_provisioning_profile_metadata "${PROFILE_PLIST}" "${APP_TEAM}" "${BUNDLE_ID}" \
        || die "${RELEASE_VALIDATION_ERROR}"
    PROFILE_TEAM_ID="${APP_TEAM}"
    PROFILE_APP_ID="${PROFILE_CONCRETE_APP_ID}"

    SIGNED_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
    SIGNED_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
    [[ "${SIGNED_TEAM_ID}" == "${PROFILE_TEAM_ID}" ]] || die "signed Team ID entitlement does not match the embedded profile"
    [[ "${SIGNED_APP_ID}" == "${PROFILE_APP_ID}" ]] || die "signed application identifier entitlement does not match the embedded profile"
    validate_profile_signing_certificate \
        "${PROFILE_PLIST}" "${APP_PATH}" "${TEMP_ROOT}/icloud-signing-certificate" \
        || die "${RELEASE_VALIDATION_ERROR}"
    validate_local_profile_entitlements "${PROFILE_PLIST}" "${ENTITLEMENTS_PLIST}" \
        || die "${RELEASE_VALIDATION_ERROR}"

    PROFILE_CLOUDKIT_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-environment' "${PROFILE_PLIST}" 2>/dev/null || true)"
    [[ "${PROFILE_CLOUDKIT_ENVIRONMENT}" == "${CLOUDKIT_ENVIRONMENT}" ]] || die "embedded profile and signed CloudKit environments differ"
    PROFILE_APS_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.aps-environment' "${PROFILE_PLIST}" 2>/dev/null || true)"
    [[ "${PROFILE_APS_ENVIRONMENT}" == "${APS_ENVIRONMENT}" ]] || die "embedded profile and signed push environments differ"

    PROFILE_AUTHORIZES_CONTAINER=0
    PROFILE_CONTAINER_INDEX=0
    while PROFILE_CONTAINER="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.icloud-container-identifiers:${PROFILE_CONTAINER_INDEX}" "${PROFILE_PLIST}" 2>/dev/null)"; do
        if [[ "${PROFILE_CONTAINER}" == "${CLOUDKIT_CONTAINER}" ]]; then
            PROFILE_AUTHORIZES_CONTAINER=1
            break
        fi
        PROFILE_CONTAINER_INDEX=$((PROFILE_CONTAINER_INDEX + 1))
    done
    [[ "${PROFILE_AUTHORIZES_CONTAINER}" -eq 1 ]] || die "embedded profile does not authorize the signed CloudKit container"
fi

if [[ "${REQUIRE_NOTARIZED}" -eq 1 ]]; then
    /usr/sbin/spctl --assess --type execute --verbose=2 "${APP_PATH}"
    /usr/bin/xcrun stapler validate "${APP_PATH}"
fi

echo "Verified: ${APP_PATH}"
echo "Bundle: ${BUNDLE_ID}"
echo "Version: ${VERSION} (${BUILD_NUMBER})"
echo "Minimum macOS: ${MINIMUM_SYSTEM}"
echo "Entitlement profile: ${PROFILE}"
echo "Distribution channel: ${DISTRIBUTION_CHANNEL:-direct}"
if [[ "${APP_SIGNATURE_KIND}" == "adhoc" ]]; then
    echo "Signature: ad-hoc local verification"
else
    echo "Signature: $(release_signing_field "${APP_SIGNING_DETAILS}" "Authority"); TeamIdentifier=${APP_TEAM}"
fi
if [[ "${REQUIRE_NOTARIZED}" -eq 1 ]]; then
    echo "Notarization: Gatekeeper accepted; stapled ticket valid"
else
    echo "Notarization: not required by this verification run"
fi
