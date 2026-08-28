#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKIP_TESTS=0
DISABLE_SWIFTPM_SANDBOX=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-tests)
            SKIP_TESTS=1
            ;;
        --disable-swiftpm-sandbox)
            DISABLE_SWIFTPM_SANDBOX=1
            ;;
        *)
            echo "usage: Scripts/verify_source.sh [--skip-tests] [--disable-swiftpm-sandbox]" >&2
            exit 1
            ;;
    esac
    shift
done

if [[ "${DISABLE_SWIFTPM_SANDBOX}" -eq 1 ]]; then
    export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/clipboard-router-verify-clang"
    export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/clipboard-router-verify-swiftpm"
fi

echo "Checking shell syntax..."
for script in "${SCRIPT_DIR}"/*.sh; do
    /bin/bash -n "${script}"
done
/bin/bash -n "${PROJECT_ROOT}/Resources/install-cr.sh"

if command -v shellcheck >/dev/null 2>&1; then
    echo "Running shellcheck..."
    shellcheck "${SCRIPT_DIR}"/*.sh "${PROJECT_ROOT}/Resources/install-cr.sh"
else
    echo "shellcheck: not installed (skipped)"
fi

echo "Running release integrity regressions..."
"${SCRIPT_DIR}/test_release_integrity.sh"

echo "Checking property lists..."
/usr/bin/plutil -lint \
    "${PROJECT_ROOT}/Resources/Info.plist" \
    "${PROJECT_ROOT}/Resources/PrivacyInfo.xcprivacy" \
    "${PROJECT_ROOT}/Resources/Entitlements/ClipboardRouter.Local.entitlements" \
    "${PROJECT_ROOT}/Resources/Entitlements/ClipboardRouter.iCloud.entitlements.template"

CRM_CALLBACK_SCHEME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "${PROJECT_ROOT}/Resources/Info.plist" 2>/dev/null || true)"
[[ "${CRM_CALLBACK_SCHEME}" == "clipboardrouter" ]] || {
    echo "Resources/Info.plist must register the clipboardrouter OAuth callback scheme" >&2
    exit 1
}

echo "Checking Swift package manifest..."
if [[ "${DISABLE_SWIFTPM_SANDBOX}" -eq 1 ]]; then
    (cd "${PROJECT_ROOT}" && /usr/bin/swift package --disable-sandbox describe >/dev/null)
else
    (cd "${PROJECT_ROOT}" && /usr/bin/swift package describe >/dev/null)
fi

if [[ "${SKIP_TESTS}" -eq 0 ]]; then
    echo "Running Swift tests..."
    if [[ "${DISABLE_SWIFTPM_SANDBOX}" -eq 1 ]]; then
        (cd "${PROJECT_ROOT}" && /usr/bin/swift test --disable-sandbox)
    else
        (cd "${PROJECT_ROOT}" && /usr/bin/swift test)
    fi
fi

echo "Source verification passed."
