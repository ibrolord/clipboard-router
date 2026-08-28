#!/bin/bash

# Pure release-validation helpers shared by the verifier and its regression
# tests. This file intentionally performs no work when sourced.

# Consumed by callers after a failed validation.
# shellcheck disable=SC2034
RELEASE_VALIDATION_ERROR=""
PROFILE_APP_ID_PREFIX=""
PROFILE_CONCRETE_APP_ID=""

release_signing_field() {
    local signing_details="$1"
    local field="$2"

    /usr/bin/printf '%s\n' "${signing_details}" \
        | /usr/bin/awk -F= -v field="${field}" '$1 == field { print substr($0, length(field) + 2); exit }'
}

release_timestamp_has_codesign_format() {
    local timestamp="$1"

    [[ "${timestamp}" =~ ^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[[:space:]]+([1-9]|[12][0-9]|3[01]),[[:space:]][0-9]{4}[[:space:]]+at[[:space:]]+([1-9]|1[0-2]):[0-5][0-9]:[0-5][0-9][[:space:]]+(AM|PM)$ ]]
}

validate_customer_signing_details() {
    local signing_details="$1"
    local team_identifier
    local signature_kind
    local first_authority
    local timestamp

    RELEASE_VALIDATION_ERROR=""
    team_identifier="$(release_signing_field "${signing_details}" "TeamIdentifier")"
    signature_kind="$(release_signing_field "${signing_details}" "Signature")"
    first_authority="$(release_signing_field "${signing_details}" "Authority")"
    timestamp="$(release_signing_field "${signing_details}" "Timestamp")"

    if [[ ! "${team_identifier}" =~ ^[A-Z0-9]{10}$ ]]; then
        RELEASE_VALIDATION_ERROR="customer release has no valid signing TeamIdentifier"
        return 1
    fi
    if [[ "${signature_kind}" == "adhoc" ]]; then
        # shellcheck disable=SC2034
        RELEASE_VALIDATION_ERROR="customer release uses an ad-hoc signature"
        return 1
    fi
    if [[ "${first_authority}" != "Developer ID Application: "* || "${first_authority}" == "Developer ID Application: " ]]; then
        RELEASE_VALIDATION_ERROR="customer release is not signed with a Developer ID Application certificate"
        return 1
    fi

    if ! release_timestamp_has_codesign_format "${timestamp}"; then
        # A trusted `codesign -dv` emits secure timestamps in this stable form.
        # Fail closed on missing sentinel or malformed values.
        RELEASE_VALIDATION_ERROR="customer release has no valid secure signing timestamp"
        return 1
    fi

    return 0
}

decode_apple_provisioning_profile() {
    local profile_path="$1"
    local output_plist="$2"
    local signer_certificate="${output_plist}.cms-signer.pem"
    local embedded_certificates="${output_plist}.cms-certificates.pem"
    local certificate_paths="${output_plist}.cms-certificate-paths"
    local untrusted_payload="${output_plist}.untrusted"
    local apple_root=""
    local certificate_path
    local certificate_fingerprint
    local signer_subject

    RELEASE_VALIDATION_ERROR=""
    # Validate both halves explicitly. OpenSSL checks the cryptographic CMS
    # signature and exports the actual signer. Security.framework evaluates that
    # signer against the macOS trust store. Requiring an Apple-owned signer keeps
    # an otherwise trusted third-party certificate from minting a fake profile.
    if ! /usr/bin/openssl cms -verify -binary -inform DER \
        -in "${profile_path}" -noverify -out "${untrusted_payload}" \
        -signer "${signer_certificate}" -certsout "${embedded_certificates}" \
        >/dev/null 2>&1; then
        RELEASE_VALIDATION_ERROR="provisioning profile CMS signature is invalid or untrusted"
        return 1
    fi
    if ! /usr/bin/python3 - "${embedded_certificates}" "${output_plist}.cms-certificate-" >"${certificate_paths}" <<'PY'
import re
import sys

source, prefix = sys.argv[1:]
with open(source, "rb") as stream:
    certificates = re.findall(
        br"-----BEGIN CERTIFICATE-----\s*.*?\s*-----END CERTIFICATE-----",
        stream.read(),
        re.DOTALL,
    )
if not certificates:
    raise SystemExit(1)
for index, certificate in enumerate(certificates):
    path = f"{prefix}{index}.pem"
    with open(path, "wb") as stream:
        stream.write(certificate + b"\n")
    print(path)
PY
    then
        RELEASE_VALIDATION_ERROR="provisioning profile CMS signature is invalid or untrusted"
        return 1
    fi
    # Fingerprints are the current Apple Root CA certificates published by Apple
    # at https://www.apple.com/certificateauthority/ (verified 2026-08-20).
    while IFS= read -r certificate_path; do
        certificate_fingerprint="$(/usr/bin/openssl x509 -in "${certificate_path}" -noout -fingerprint -sha256 2>/dev/null \
            | /usr/bin/sed 's/^.*=//; s/://g' \
            | /usr/bin/tr '[:lower:]' '[:upper:]')"
        case "${certificate_fingerprint}" in
            B0B1730ECBC7FF4505142C49F1295E6EDA6BCAED7E2C68C5BE91B5A11001F024|\
            C2B9B042DD57830E7D117DAC55AC8AE19407D38E41D88F3215BC3A890444A050|\
            63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179)
                apple_root="${certificate_path}"
                break
                ;;
        esac
    done < "${certificate_paths}"
    if [[ -z "${apple_root}" ]]; then
        RELEASE_VALIDATION_ERROR="provisioning profile CMS signature is invalid or untrusted"
        return 1
    fi
    signer_subject="$(/usr/bin/openssl x509 -in "${signer_certificate}" -noout -subject -nameopt RFC2253 2>/dev/null || true)"
    if [[ "${signer_subject}" != *"O=Apple Inc."* ]]; then
        RELEASE_VALIDATION_ERROR="provisioning profile CMS signature is invalid or untrusted"
        return 1
    fi
    if ! /usr/bin/openssl cms -verify -binary -inform DER \
        -in "${profile_path}" -CAfile "${apple_root}" -out "${output_plist}" \
        >/dev/null 2>&1; then
        RELEASE_VALIDATION_ERROR="provisioning profile CMS signature is invalid or untrusted"
        return 1
    fi
    if ! /usr/bin/plutil -lint "${output_plist}" >/dev/null 2>&1; then
        RELEASE_VALIDATION_ERROR="provisioning profile payload is not a valid property list"
        return 1
    fi
    return 0
}

validate_provisioning_profile_metadata() {
    local profile_plist="$1"
    local expected_team="$2"
    local bundle_identifier="$3"
    local result

    RELEASE_VALIDATION_ERROR=""
    PROFILE_APP_ID_PREFIX=""
    PROFILE_CONCRETE_APP_ID=""
    if ! result="$(/usr/bin/python3 - "${profile_plist}" "${expected_team}" "${bundle_identifier}" <<'PY'
import datetime
import plistlib
import sys

path, expected_team, bundle_id = sys.argv[1:]

def fail(message):
    print(message)
    raise SystemExit(1)

with open(path, "rb") as stream:
    profile = plistlib.load(stream)

teams = profile.get("TeamIdentifier")
if not isinstance(teams, list) or expected_team not in teams:
    fail("provisioning profile Team ID does not match --team-id")

prefixes = profile.get("ApplicationIdentifierPrefix")
if not isinstance(prefixes, list) or len(prefixes) != 1 or not isinstance(prefixes[0], str):
    fail("provisioning profile has no unambiguous App ID prefix")
prefix = prefixes[0]
concrete_app_id = f"{prefix}.{bundle_id}"

expiration = profile.get("ExpirationDate")
now = datetime.datetime.now(datetime.timezone.utc)
if not isinstance(expiration, datetime.datetime):
    fail("provisioning profile has no expiration date")
if expiration.tzinfo is None:
    expiration = expiration.replace(tzinfo=datetime.timezone.utc)
if expiration <= now:
    fail("provisioning profile is expired")

entitlements = profile.get("Entitlements")
if not isinstance(entitlements, dict):
    fail("provisioning profile has no entitlement allowlist")
profile_team = entitlements.get("com.apple.developer.team-identifier")
if profile_team != expected_team:
    fail("provisioning profile Team entitlement does not match --team-id")
app_pattern = entitlements.get("com.apple.application-identifier")
if app_pattern is None:
    app_pattern = entitlements.get("application-identifier")

def authorizes(pattern, value):
    return isinstance(pattern, str) and (
        pattern == value or (pattern.endswith("*") and value.startswith(pattern[:-1]))
    )

if not authorizes(app_pattern, concrete_app_id):
    fail("provisioning profile does not authorize the bundle identifier")

groups = entitlements.get("keychain-access-groups")
if not isinstance(groups, list) or not any(authorizes(group, concrete_app_id) for group in groups):
    fail("provisioning profile does not authorize the Vault Keychain access group")

certificates = profile.get("DeveloperCertificates")
if not isinstance(certificates, list) or not certificates or not all(isinstance(item, bytes) for item in certificates):
    fail("provisioning profile has no developer certificate allowlist")

if not isinstance(profile.get("DER-Encoded-Profile"), bytes):
    fail("provisioning profile has no DER-encoded authorization payload")

print(f"{prefix}|{concrete_app_id}")
PY
)"; then
        RELEASE_VALIDATION_ERROR="${result:-provisioning profile metadata is invalid}"
        return 1
    fi

    PROFILE_APP_ID_PREFIX="${result%%|*}"
    PROFILE_CONCRETE_APP_ID="${result#*|}"
    if [[ -z "${PROFILE_APP_ID_PREFIX}" || -z "${PROFILE_CONCRETE_APP_ID}" || "${result}" != *"|"* ]]; then
        RELEASE_VALIDATION_ERROR="provisioning profile metadata validation returned an invalid result"
        return 1
    fi
    return 0
}

validate_profile_signing_certificate() {
    local profile_plist="$1"
    local signed_app="$2"
    local certificate_prefix="$3"

    RELEASE_VALIDATION_ERROR=""
    # codesign appends 0, 1, ... to this prefix; certificate 0 is documented as
    # the leaf signing certificate. The long option requires the `=` form when
    # a custom prefix is supplied.
    if ! /usr/bin/codesign -d --extract-certificates="${certificate_prefix}" "${signed_app}" >/dev/null 2>&1; then
        RELEASE_VALIDATION_ERROR="could not extract the application signing certificate"
        return 1
    fi
    if ! /usr/bin/python3 - "${profile_plist}" "${certificate_prefix}0" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    profile = plistlib.load(stream)
with open(sys.argv[2], "rb") as stream:
    leaf = stream.read()
allowed = profile.get("DeveloperCertificates", [])
raise SystemExit(0 if any(isinstance(item, bytes) and item == leaf for item in allowed) else 1)
PY
    then
        RELEASE_VALIDATION_ERROR="signing certificate is not authorized by the provisioning profile"
        return 1
    fi
    return 0
}

validate_app_icon() {
    local icns_path="$1"
    local extract_dir
    local iconset_dir
    local required_representation
    local width
    local height

    RELEASE_VALIDATION_ERROR=""
    if [[ ! -f "${icns_path}" ]]; then
        RELEASE_VALIDATION_ERROR="application icon is missing: ${icns_path}"
        return 1
    fi

    extract_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/clipboard-router-icon-verify.XXXXXX")" || {
        RELEASE_VALIDATION_ERROR="could not create a temporary directory to verify the application icon"
        return 1
    }
    iconset_dir="${extract_dir}/verify.iconset"

    # `iconutil` is the authoritative decoder for the ICNS container; a stale or
    # truncated file (e.g. missing the 512x512@2x representation Apple requires
    # for Mac App Store submission) either fails to decode or round-trips
    # without the representation, so re-extracting and inspecting it here
    # catches the same defect Transporter rejects at upload time.
    if ! /usr/bin/iconutil --convert iconset --output "${iconset_dir}" "${icns_path}" >/dev/null 2>&1; then
        /bin/rm -rf "${extract_dir}"
        RELEASE_VALIDATION_ERROR="application icon could not be decoded as a valid ICNS file: ${icns_path}"
        return 1
    fi

    required_representation="${iconset_dir}/icon_512x512@2x.png"
    if [[ ! -f "${required_representation}" ]]; then
        /bin/rm -rf "${extract_dir}"
        RELEASE_VALIDATION_ERROR="application icon is missing the required 512x512@2x (1024x1024) representation"
        return 1
    fi

    width="$(/usr/bin/sips -g pixelWidth "${required_representation}" 2>/dev/null | /usr/bin/awk '/pixelWidth:/ {print $2}')"
    height="$(/usr/bin/sips -g pixelHeight "${required_representation}" 2>/dev/null | /usr/bin/awk '/pixelHeight:/ {print $2}')"
    /bin/rm -rf "${extract_dir}"

    if [[ "${width}" != "1024" || "${height}" != "1024" ]]; then
        RELEASE_VALIDATION_ERROR="application icon's 512x512@2x representation is ${width:-unknown}x${height:-unknown} pixels, expected 1024x1024"
        return 1
    fi

    return 0
}

validate_local_profile_entitlements() {
    local profile_plist="$1"
    local signed_entitlements_plist="$2"

    RELEASE_VALIDATION_ERROR=""
    if ! /usr/bin/python3 - "${profile_plist}" "${signed_entitlements_plist}" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    profile = plistlib.load(stream)
with open(sys.argv[2], "rb") as stream:
    signed = plistlib.load(stream)
allowed = profile.get("Entitlements", {})

def matches(pattern, value):
    return isinstance(pattern, str) and (
        pattern == value or (pattern.endswith("*") and value.startswith(pattern[:-1]))
    )

signed_app_id = signed.get("com.apple.application-identifier")
profile_app_id = allowed.get("com.apple.application-identifier", allowed.get("application-identifier"))
if not matches(profile_app_id, signed_app_id):
    raise SystemExit(1)
if signed.get("com.apple.developer.team-identifier") != allowed.get("com.apple.developer.team-identifier"):
    raise SystemExit(1)
signed_groups = signed.get("keychain-access-groups")
allowed_groups = allowed.get("keychain-access-groups")
if not isinstance(signed_groups, list) or not signed_groups:
    raise SystemExit(1)
if not isinstance(allowed_groups, list):
    raise SystemExit(1)
if not all(any(matches(pattern, group) for pattern in allowed_groups) for group in signed_groups):
    raise SystemExit(1)
PY
    then
        RELEASE_VALIDATION_ERROR="signed restricted entitlements are not authorized by the provisioning profile"
        return 1
    fi
    return 0
}
