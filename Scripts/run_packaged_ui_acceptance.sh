#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ACCEPTANCE_APP="${PROJECT_ROOT}/.artifacts/ClipboardRouter-UIAcceptance.app"
ACCEPTANCE_MANIFEST="${PROJECT_ROOT}/.artifacts/ClipboardRouter-UIAcceptance.app.release.json"
ACCEPTANCE_BUNDLE_ID="com.clipboardrouter.ClipboardRouter.uiacceptance"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/clipboard-router-ui-acceptance-clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/clipboard-router-ui-acceptance-swiftpm"
export CLIPBOARD_ROUTER_DISABLE_SWIFT_BUILD_SANDBOX=1

cd "${PROJECT_ROOT}"

swift build --disable-sandbox --configuration debug --product cr-ui-acceptance
BIN_PATH="$(swift build --disable-sandbox --configuration debug --show-bin-path)"
RUNNER="${BIN_PATH}/cr-ui-acceptance"
"${RUNNER}" --self-test-parser

"${SCRIPT_DIR}/package_app.sh" \
    --configuration release \
    --bundle-id "${ACCEPTANCE_BUNDLE_ID}" \
    --output "${ACCEPTANCE_APP}" \
    --manifest-output "${ACCEPTANCE_MANIFEST}" \
    --overwrite

"${SCRIPT_DIR}/verify_release.sh" \
    --profile local \
    --bundle-id "${ACCEPTANCE_BUNDLE_ID}" \
    "${ACCEPTANCE_APP}"

set +e
"${RUNNER}" --preflight
PREFLIGHT_STATUS=$?
set -e

if [[ "${PREFLIGHT_STATUS}" -eq 77 ]]; then
    echo "Packaged UI acceptance skipped after creating and verifying the exact artifact: the environment is unavailable (Accessibility permission not granted, screen locked, or no console session). See the SKIP reason above, resolve it, then rerun." >&2
    exit 77
fi
if [[ "${PREFLIGHT_STATUS}" -ne 0 ]]; then
    echo "Packaged UI acceptance preflight failed with status ${PREFLIGHT_STATUS}." >&2
    exit "${PREFLIGHT_STATUS}"
fi

RUN_ID="$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$"
EVIDENCE_DIRECTORY="${PROJECT_ROOT}/.artifacts/ui-acceptance/${RUN_ID}"
set +e
"${RUNNER}" \
    --app "${ACCEPTANCE_APP}" \
    --run-id "${RUN_ID}" \
    --evidence-directory "${EVIDENCE_DIRECTORY}"
RUN_STATUS=$?
set -e
if [[ "${RUN_STATUS}" -eq 77 ]]; then
    echo "Packaged UI acceptance skipped during the run because the interactive session became unavailable. Resolve the session state and rerun; see ${EVIDENCE_DIRECTORY}/report.json." >&2
fi
exit "${RUN_STATUS}"
