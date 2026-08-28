#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_SCRIPT="${SCRIPT_DIR}/package_app.sh"
VERIFY_SCRIPT="${SCRIPT_DIR}/verify_release.sh"
ARCHIVE_SCRIPT="${SCRIPT_DIR}/create_customer_archive.sh"
CASK_SCRIPT="${SCRIPT_DIR}/generate_homebrew_cask.sh"
MAS_SCRIPT="${SCRIPT_DIR}/package_mas.sh"
# shellcheck source=release_validation.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/release_validation.sh"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clipboard-router-release-tests.XXXXXX")"
trap '/bin/rm -rf "${TEMP_ROOT}"' EXIT

TESTS_RUN=0

fail() {
    echo "not ok: $*" >&2
    exit 1
}

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "ok ${TESTS_RUN}: $*"
}

expect_script_failure() {
    local label="$1"
    local expected_message="$2"
    shift 2

    local output_file="${TEMP_ROOT}/command-output-${TESTS_RUN}.txt"
    if "$@" >"${output_file}" 2>&1; then
        fail "${label} unexpectedly succeeded"
    fi
    /usr/bin/grep -F -q -- "${expected_message}" "${output_file}" \
        || fail "${label} did not report '${expected_message}'"
    if /usr/bin/grep -F -q -- "Building ClipboardRouter" "${output_file}"; then
        fail "${label} reached the build despite being a preflight failure"
    fi
    pass "${label}"
}

expect_signing_failure() {
    local label="$1"
    local expected_message="$2"
    local signing_details="$3"

    if validate_customer_signing_details "${signing_details}"; then
        fail "${label} unexpectedly accepted signing details"
    fi
    [[ "${RELEASE_VALIDATION_ERROR}" == "${expected_message}" ]] \
        || fail "${label} reported '${RELEASE_VALIDATION_ERROR}'"
    pass "${label}"
}

NESTED_APP="${TEMP_ROOT}/NestedManifest.app"
expect_script_failure \
    "package rejects a manifest nested inside the app before build" \
    "release manifest output must remain outside the signed .app bundle" \
    /bin/bash "${PACKAGE_SCRIPT}" \
        --output "${NESTED_APP}" \
        --manifest-output "${NESTED_APP}/Contents/Resources/release.json"

expect_script_failure \
    "customer package rejects timestamp none before build" \
    "--customer-release requires a secure signing timestamp" \
    /bin/bash "${PACKAGE_SCRIPT}" \
        --customer-release \
        --identity "Developer ID Application: Regression Fixture (ABCDEFGHIJ)" \
        --team-id ABCDEFGHIJ \
        --timestamp none \
        --output "${TEMP_ROOT}/NoTimestamp.app"

expect_script_failure \
    "non-ad-hoc local package requires a Vault provisioning profile before build" \
    "non-ad-hoc signing requires a matching provisioning profile for Vault Keychain access" \
    /bin/bash "${PACKAGE_SCRIPT}" \
        --identity "Developer ID Application: Regression Fixture (ABCDEFGHIJ)" \
        --team-id ABCDEFGHIJ \
        --output "${TEMP_ROOT}/NoProfile.app"

FAKE_PROFILE_ROOT="${TEMP_ROOT}/fake-profile"
/bin/mkdir -p "${FAKE_PROFILE_ROOT}"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -subj '/CN=Not Apple/' \
    -keyout "${FAKE_PROFILE_ROOT}/key.pem" -out "${FAKE_PROFILE_ROOT}/cert.pem" -days 1 \
    >/dev/null 2>&1
/usr/bin/printf '%s\n' \
    '<?xml version="1.0"?><plist version="1.0"><dict><key>Name</key><string>Fabricated</string></dict></plist>' \
    > "${FAKE_PROFILE_ROOT}/payload.plist"
/usr/bin/openssl smime -sign -binary -in "${FAKE_PROFILE_ROOT}/payload.plist" \
    -signer "${FAKE_PROFILE_ROOT}/cert.pem" -inkey "${FAKE_PROFILE_ROOT}/key.pem" \
    -outform der -out "${FAKE_PROFILE_ROOT}/fake.provisionprofile" -nodetach \
    >/dev/null 2>&1
if decode_apple_provisioning_profile \
    "${FAKE_PROFILE_ROOT}/fake.provisionprofile" "${FAKE_PROFILE_ROOT}/decoded.plist"; then
    fail "profile validation accepted a self-signed CMS payload"
fi
[[ "${RELEASE_VALIDATION_ERROR}" == "provisioning profile CMS signature is invalid or untrusted" ]] \
    || fail "profile validation reported an unexpected self-signed CMS error"
pass "profile validation rejects a self-signed CMS payload"

FAKE_APP="${TEMP_ROOT}/Tampered.app"
/bin/mkdir -p \
    "${FAKE_APP}/Contents/MacOS" \
    "${FAKE_APP}/Contents/Helpers" \
    "${FAKE_APP}/Contents/Resources"
/usr/bin/printf 'fixture\n' >"${FAKE_APP}/Contents/Info.plist"
/usr/bin/printf 'app fixture\n' >"${FAKE_APP}/Contents/MacOS/ClipboardRouter"
/usr/bin/printf 'cli fixture\n' >"${FAKE_APP}/Contents/Helpers/cr"
/usr/bin/printf 'original privacy fixture\n' >"${FAKE_APP}/Contents/Resources/PrivacyInfo.xcprivacy"
VALID_TEST_ICON="${TEMP_ROOT}/ClipboardRouterValid.icns"
/usr/bin/iconutil --convert icns \
    --output "${VALID_TEST_ICON}" \
    "${SCRIPT_DIR}/../Resources/AppIcon/ClipboardRouter.iconset" >/dev/null 2>&1 \
    || fail "could not build a valid ICNS fixture from the checked-in iconset"
/bin/cp "${VALID_TEST_ICON}" "${FAKE_APP}/Contents/Resources/ClipboardRouter.icns"
/usr/bin/printf '#!/bin/bash\nexit 0\n' >"${FAKE_APP}/Contents/Resources/install-cr.sh"
/bin/chmod 0755 \
    "${FAKE_APP}/Contents/MacOS/ClipboardRouter" \
    "${FAKE_APP}/Contents/Helpers/cr" \
    "${FAKE_APP}/Contents/Resources/install-cr.sh"

EMBEDDED_MANIFEST="${FAKE_APP}/Contents/Resources/ClipboardRouter.release.json"
ADJACENT_MANIFEST="${FAKE_APP}.release.json"
ORIGINAL_PRIVACY_HASH="$(/usr/bin/shasum -a 256 "${FAKE_APP}/Contents/Resources/PrivacyInfo.xcprivacy" | /usr/bin/awk '{print $1}')"
/usr/bin/printf '{"schemaVersion":2,"artifacts":{"privacyManifest":{"sha256":"%s"}}}\n' \
    "${ORIGINAL_PRIVACY_HASH}" >"${EMBEDDED_MANIFEST}"
/bin/cp "${EMBEDDED_MANIFEST}" "${ADJACENT_MANIFEST}"

# Model the attempted bypass: alter an artifact, then update only the adjacent
# manifest to the new hash. The verifier must reject that untrusted manifest
# before it examines any signature or artifact hash.
/usr/bin/printf 'tampered privacy fixture\n' >"${FAKE_APP}/Contents/Resources/PrivacyInfo.xcprivacy"
TAMPERED_PRIVACY_HASH="$(/usr/bin/shasum -a 256 "${FAKE_APP}/Contents/Resources/PrivacyInfo.xcprivacy" | /usr/bin/awk '{print $1}')"
/usr/bin/plutil -replace artifacts.privacyManifest.sha256 -string "${TAMPERED_PRIVACY_HASH}" "${ADJACENT_MANIFEST}"
expect_script_failure \
    "adjacent manifest hash recomputation cannot bypass embedded binding" \
    "adjacent release manifest does not match the signature-bound embedded manifest" \
    /bin/bash "${VERIFY_SCRIPT}" --manifest "${ADJACENT_MANIFEST}" "${FAKE_APP}"

validate_app_icon "${TEMP_ROOT}/does-not-exist.icns" \
    && fail "icon validation accepted a missing file"
[[ "${RELEASE_VALIDATION_ERROR}" == "application icon is missing: ${TEMP_ROOT}/does-not-exist.icns" ]] \
    || fail "icon validation reported an unexpected missing-file error: ${RELEASE_VALIDATION_ERROR}"
pass "icon validation rejects a missing ICNS file"

GARBAGE_ICON="${TEMP_ROOT}/Garbage.icns"
/usr/bin/printf 'not an icns file\n' >"${GARBAGE_ICON}"
validate_app_icon "${GARBAGE_ICON}" \
    && fail "icon validation accepted an undecodable file"
[[ "${RELEASE_VALIDATION_ERROR}" == "application icon could not be decoded as a valid ICNS file: ${GARBAGE_ICON}" ]] \
    || fail "icon validation reported an unexpected decode error: ${RELEASE_VALIDATION_ERROR}"
pass "icon validation rejects a file that iconutil cannot decode"

# Regression fixture for the Transporter 409 rejection: an ICNS built from an
# iconset missing the large representations, mirroring the stale/incomplete
# ClipboardRouter.icns that was checked in without a true 512x512@2x image.
TRUNCATED_ICONSET_SOURCE="${SCRIPT_DIR}/../Resources/AppIcon/ClipboardRouter.iconset"
TRUNCATED_ICONSET="${TEMP_ROOT}/Truncated.iconset"
/bin/mkdir -p "${TRUNCATED_ICONSET}"
/bin/cp \
    "${TRUNCATED_ICONSET_SOURCE}/icon_16x16.png" \
    "${TRUNCATED_ICONSET_SOURCE}/icon_32x32.png" \
    "${TRUNCATED_ICONSET_SOURCE}/icon_128x128.png" \
    "${TRUNCATED_ICONSET}/"
TRUNCATED_ICON="${TEMP_ROOT}/Truncated.icns"
/usr/bin/iconutil --convert icns --output "${TRUNCATED_ICON}" "${TRUNCATED_ICONSET}" >/dev/null 2>&1 \
    || fail "could not build the truncated ICNS regression fixture"
validate_app_icon "${TRUNCATED_ICON}" \
    && fail "icon validation accepted an ICNS missing its 512x512@2x representation"
[[ "${RELEASE_VALIDATION_ERROR}" == "application icon is missing the required 512x512@2x (1024x1024) representation" ]] \
    || fail "icon validation reported an unexpected truncated-icon error: ${RELEASE_VALIDATION_ERROR}"
pass "icon validation rejects a stale ICNS missing the 512x512@2x representation (Transporter 409 regression)"

validate_app_icon "${VALID_TEST_ICON}" \
    || fail "icon validation rejected a complete ICNS built from the checked-in iconset: ${RELEASE_VALIDATION_ERROR}"
pass "icon validation accepts a complete ICNS with a true 1024x1024 512x512@2x representation"

TRUNCATED_ICON_APP="${TEMP_ROOT}/TruncatedIcon.app"
/bin/mkdir -p \
    "${TRUNCATED_ICON_APP}/Contents/MacOS" \
    "${TRUNCATED_ICON_APP}/Contents/Helpers" \
    "${TRUNCATED_ICON_APP}/Contents/Resources"
/usr/bin/printf 'fixture\n' >"${TRUNCATED_ICON_APP}/Contents/Info.plist"
/usr/bin/printf 'app fixture\n' >"${TRUNCATED_ICON_APP}/Contents/MacOS/ClipboardRouter"
/usr/bin/printf 'cli fixture\n' >"${TRUNCATED_ICON_APP}/Contents/Helpers/cr"
/usr/bin/printf 'privacy fixture\n' >"${TRUNCATED_ICON_APP}/Contents/Resources/PrivacyInfo.xcprivacy"
/usr/bin/printf '#!/bin/bash\nexit 0\n' >"${TRUNCATED_ICON_APP}/Contents/Resources/install-cr.sh"
/bin/chmod 0755 \
    "${TRUNCATED_ICON_APP}/Contents/MacOS/ClipboardRouter" \
    "${TRUNCATED_ICON_APP}/Contents/Helpers/cr" \
    "${TRUNCATED_ICON_APP}/Contents/Resources/install-cr.sh"
/bin/cp "${TRUNCATED_ICON}" "${TRUNCATED_ICON_APP}/Contents/Resources/ClipboardRouter.icns"
expect_script_failure \
    "verifier rejects a packaged app whose ICNS lacks the 512x512@2x representation" \
    "application icon is missing the required 512x512@2x (1024x1024) representation" \
    /bin/bash "${VERIFY_SCRIPT}" "${TRUNCATED_ICON_APP}"

VALID_DETAILS=$'Executable=/Applications/ClipboardRouter.app/Contents/MacOS/ClipboardRouter\nIdentifier=com.clipboardrouter.ClipboardRouter\nFormat=app bundle with Mach-O thin (arm64)\nSignature size=9123\nAuthority=Developer ID Application: Regression Fixture (ABCDEFGHIJ)\nAuthority=Developer ID Certification Authority\nAuthority=Apple Root CA\nTimestamp=Aug 15, 2026 at 12:34:56 PM\nTeamIdentifier=ABCDEFGHIJ'
validate_customer_signing_details "${VALID_DETAILS}" \
    || fail "valid Developer ID signing fixture was rejected: ${RELEASE_VALIDATION_ERROR}"
pass "verifier customer-signing seam accepts a valid Developer ID fixture"

expect_signing_failure \
    "verifier customer mode rejects a missing secure timestamp" \
    "customer release has no valid secure signing timestamp" \
    $'Signature size=9123\nAuthority=Developer ID Application: Regression Fixture (ABCDEFGHIJ)\nTeamIdentifier=ABCDEFGHIJ'

expect_signing_failure \
    "verifier customer mode rejects an invalid secure timestamp" \
    "customer release has no valid secure signing timestamp" \
    $'Signature size=9123\nAuthority=Developer ID Application: Regression Fixture (ABCDEFGHIJ)\nTimestamp=none\nTeamIdentifier=ABCDEFGHIJ'

expect_signing_failure \
    "verifier customer mode rejects a malformed timestamp" \
    "customer release has no valid secure signing timestamp" \
    $'Signature size=9123\nAuthority=Developer ID Application: Regression Fixture (ABCDEFGHIJ)\nTimestamp=definitely-not-a-codesign-timestamp\nTeamIdentifier=ABCDEFGHIJ'

expect_signing_failure \
    "verifier customer mode rejects an Apple Development identity" \
    "customer release is not signed with a Developer ID Application certificate" \
    $'Signature size=9123\nAuthority=Apple Development: Regression Fixture (ABCDEFGHIJ)\nTimestamp=Aug 15, 2026 at 12:34:56 PM\nTeamIdentifier=ABCDEFGHIJ'

expect_signing_failure \
    "verifier customer mode rejects a Developer ID Installer identity" \
    "customer release is not signed with a Developer ID Application certificate" \
    $'Signature size=9123\nAuthority=Developer ID Installer: Regression Fixture (ABCDEFGHIJ)\nTimestamp=Aug 15, 2026 at 12:34:56 PM\nTeamIdentifier=ABCDEFGHIJ'

expect_signing_failure \
    "verifier customer mode rejects an ad-hoc signature" \
    "customer release uses an ad-hoc signature" \
    $'Signature=adhoc\nAuthority=Developer ID Application: Spoofed Fixture (ABCDEFGHIJ)\nTimestamp=Aug 15, 2026 at 12:34:56 PM\nTeamIdentifier=ABCDEFGHIJ'

expect_signing_failure \
    "verifier customer mode rejects an invalid TeamIdentifier" \
    "customer release has no valid signing TeamIdentifier" \
    $'Signature size=9123\nAuthority=Developer ID Application: Regression Fixture (ABCDEFGHIJ)\nTimestamp=Aug 15, 2026 at 12:34:56 PM\nTeamIdentifier=not set'

expect_script_failure \
    "customer archive rejects a missing application path" \
    "not an application bundle" \
    /bin/bash "${ARCHIVE_SCRIPT}" "${TEMP_ROOT}/does-not-exist.app"

FAKE_SOURCE_APP="${TEMP_ROOT}/FakeSource.app"
/bin/mkdir -p "${FAKE_SOURCE_APP}/Contents"
expect_script_failure \
    "customer archive rejects a display name containing .app" \
    "must not include .app" \
    /bin/bash "${ARCHIVE_SCRIPT}" --display-name "Clipboard Router.app" "${FAKE_SOURCE_APP}"

expect_script_failure \
    "customer archive rejects an invalid --profile" \
    "--profile must be local or icloud" \
    /bin/bash "${ARCHIVE_SCRIPT}" --profile bogus "${FAKE_SOURCE_APP}"

expect_script_failure \
    "engineering archive rejects an unmarked custom output" \
    "--skip-notarization-check requires a custom --output filename ending in -UNNOTARIZED.zip" \
    /bin/bash "${ARCHIVE_SCRIPT}" \
        --skip-notarization-check \
        --output "${TEMP_ROOT}/unsafe-release.zip" \
        --manifest "${ADJACENT_MANIFEST}" \
        "${FAKE_APP}"

expect_script_failure \
    "cask generator rejects an insecure homepage" \
    "--homepage must be an HTTPS URL" \
    /bin/bash "${CASK_SCRIPT}" \
        --version 0.1.0 \
        --homepage "http://example.com" \
        --arm64-url "https://example.com/a.zip" \
        --arm64-sha256 "$(/usr/bin/python3 -c 'print("a" * 64)')"

expect_script_failure \
    "cask generator rejects a malformed sha256" \
    "--arm64-sha256 must be a lowercase 64-character hex sha256" \
    /bin/bash "${CASK_SCRIPT}" \
        --version 0.1.0 \
        --homepage "https://example.com" \
        --arm64-url "https://example.com/a.zip" \
        --arm64-sha256 "not-a-hash"

expect_script_failure \
    "cask generator rejects a lone --x86-64-url without its sha256" \
    "--x86-64-url and --x86-64-sha256 must be supplied together" \
    /bin/bash "${CASK_SCRIPT}" \
        --version 0.1.0 \
        --homepage "https://example.com" \
        --arm64-url "https://example.com/a.zip" \
        --arm64-sha256 "$(/usr/bin/python3 -c 'print("a" * 64)')" \
        --x86-64-url "https://example.com/b.zip"

CASK_FIXTURE_SHA="$(/usr/bin/python3 -c 'print("a" * 64)')"
CASK_OUTPUT_1="$(/bin/bash "${CASK_SCRIPT}" \
    --version 0.1.0 \
    --homepage "https://example.com" \
    --arm64-url "https://example.com/a.zip" \
    --arm64-sha256 "${CASK_FIXTURE_SHA}")"
CASK_OUTPUT_2="$(/bin/bash "${CASK_SCRIPT}" \
    --version 0.1.0 \
    --homepage "https://example.com" \
    --arm64-url "https://example.com/a.zip" \
    --arm64-sha256 "${CASK_FIXTURE_SHA}")"
[[ "${CASK_OUTPUT_1}" == "${CASK_OUTPUT_2}" ]] \
    || fail "cask generator output is not deterministic for identical arguments"
echo "${CASK_OUTPUT_1}" | /usr/bin/grep -q "sha256 \"${CASK_FIXTURE_SHA}\"" \
    || fail "cask generator output is missing the requested sha256"
echo "${CASK_OUTPUT_1}" | /usr/bin/grep -q 'depends_on arch: :arm64' \
    || fail "arm64-only cask output is missing the arch dependency"
pass "cask generator produces deterministic, correctly pinned arm64-only output"

CASK_UNIVERSAL_OUTPUT="$(/bin/bash "${CASK_SCRIPT}" \
    --version 0.1.0 \
    --homepage "https://example.com" \
    --arm64-url "https://example.com/u.zip" \
    --arm64-sha256 "${CASK_FIXTURE_SHA}" \
    --x86-64-url "https://example.com/u.zip" \
    --x86-64-sha256 "${CASK_FIXTURE_SHA}")"
echo "${CASK_UNIVERSAL_OUTPUT}" | /usr/bin/grep -q 'on_arm' \
    && fail "identical arm64/x86_64 pairs unexpectedly produced per-architecture blocks"
echo "${CASK_UNIVERSAL_OUTPUT}" | /usr/bin/grep -q '^  url "https://example.com/u.zip"$' \
    || fail "universal cask output is missing a single unrestricted url"
pass "cask generator collapses identical arm64/x86_64 pairs into a single universal download"

CASK_SHA_B="$(/usr/bin/python3 -c 'print("b" * 64)')"
CASK_PER_ARCH_OUTPUT="$(/bin/bash "${CASK_SCRIPT}" \
    --version 0.1.0 \
    --homepage "https://example.com" \
    --arm64-url "https://example.com/arm.zip" \
    --arm64-sha256 "${CASK_FIXTURE_SHA}" \
    --x86-64-url "https://example.com/intel.zip" \
    --x86-64-sha256 "${CASK_SHA_B}")"
echo "${CASK_PER_ARCH_OUTPUT}" | /usr/bin/grep -q 'on_arm' \
    || fail "differing arm64/x86_64 pairs did not produce an on_arm block"
echo "${CASK_PER_ARCH_OUTPUT}" | /usr/bin/grep -q 'on_intel' \
    || fail "differing arm64/x86_64 pairs did not produce an on_intel block"
pass "cask generator emits per-architecture blocks when arm64 and x86_64 pairs differ"

expect_script_failure \
    "MAS packaging rejects a malformed --team-id before build" \
    "--team-id must be a ten-character Apple Developer Team ID" \
    /bin/bash "${MAS_SCRIPT}" \
        --app-identity "Apple Distribution: Regression Fixture (ABCDEFGHIJ)" \
        --installer-identity "3rd Party Mac Developer Installer: Regression Fixture (ABCDEFGHIJ)" \
        --provisioning-profile "${FAKE_PROFILE_ROOT}/fake.provisionprofile"

expect_script_failure \
    "MAS packaging rejects a Developer ID application identity before build" \
    "--app-identity must be an 'Apple Distribution: ...' or '3rd Party Mac Developer Application: ...' certificate" \
    /bin/bash "${MAS_SCRIPT}" \
        --team-id ABCDEFGHIJ \
        --app-identity "Developer ID Application: Regression Fixture (ABCDEFGHIJ)" \
        --installer-identity "3rd Party Mac Developer Installer: Regression Fixture (ABCDEFGHIJ)" \
        --provisioning-profile "${FAKE_PROFILE_ROOT}/fake.provisionprofile"

expect_script_failure \
    "MAS packaging rejects a Developer ID installer identity before build" \
    "--installer-identity must be a '3rd Party Mac Developer Installer: ...' or 'Mac Installer Distribution: ...' certificate" \
    /bin/bash "${MAS_SCRIPT}" \
        --team-id ABCDEFGHIJ \
        --app-identity "Apple Distribution: Regression Fixture (ABCDEFGHIJ)" \
        --installer-identity "Developer ID Installer: Regression Fixture (ABCDEFGHIJ)" \
        --provisioning-profile "${FAKE_PROFILE_ROOT}/fake.provisionprofile"

expect_script_failure \
    "MAS packaging rejects a missing provisioning profile before build" \
    "--provisioning-profile is required and must exist" \
    /bin/bash "${MAS_SCRIPT}" \
        --team-id ABCDEFGHIJ \
        --app-identity "Apple Distribution: Regression Fixture (ABCDEFGHIJ)" \
        --installer-identity "3rd Party Mac Developer Installer: Regression Fixture (ABCDEFGHIJ)" \
        --provisioning-profile "${TEMP_ROOT}/does-not-exist.provisionprofile"

expect_script_failure \
    "MAS packaging rejects an invalid --architectures before build" \
    "--architectures must be native, universal, arm64, x86_64, or a comma-separated list of arm64/x86_64" \
    /bin/bash "${MAS_SCRIPT}" \
        --team-id ABCDEFGHIJ \
        --app-identity "Apple Distribution: Regression Fixture (ABCDEFGHIJ)" \
        --installer-identity "3rd Party Mac Developer Installer: Regression Fixture (ABCDEFGHIJ)" \
        --provisioning-profile "${FAKE_PROFILE_ROOT}/fake.provisionprofile" \
        --architectures ppc

expect_script_failure \
    "package rejects an invalid --distribution-channel before build" \
    "--distribution-channel must be direct or macAppStore" \
    /bin/bash "${PACKAGE_SCRIPT}" \
        --distribution-channel bogus \
        --output "${TEMP_ROOT}/BogusChannel.app"

expect_script_failure \
    "verifier rejects an invalid --expect-distribution-channel before requiring an app path" \
    "--expect-distribution-channel must be direct or macAppStore" \
    /bin/bash "${VERIFY_SCRIPT}" --expect-distribution-channel bogus

echo "Release integrity regressions passed (${TESTS_RUN} checks)."
