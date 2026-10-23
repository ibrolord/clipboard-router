#!/usr/bin/env bash
# Builds an ISOLATED, team-signed acceptance copy of the REAL Clipboard Router app (real
# ClipboardRouter executable + real `cr`, release) for a human click-through of
# Settings > Agent Access. Run as:  bash Scripts/mcp/package_agent_access_acceptance_app.sh
#
# Safety model (synthetic data only):
#  * CFBundleIdentifier is com.clipboardrouter.ClipboardRouter.uiacceptance. The existing
#    UIAcceptanceRuntime gate additionally needs `--clipboard-router-ui-acceptance
#    --ui-acceptance-run-id <id>`; it then injects an in-memory Vault / secure-share key store,
#    an isolated defaults suite, a temp support directory and a named pasteboard. Without the
#    arguments the dedicated bundle id fails closed (no production paths).
#  * No commerce keys, no CloudKit keys, no provisioning profile. Entitlements are ONLY the
#    non-restricted ones from Resources/Entitlements/ClipboardRouter.Local.entitlements.
#  * CFBundleURLTypes is removed so LaunchServices cannot route clipboardrouter:// callbacks here.
#  * Output goes to a NEW .artifacts/agent-access-acceptance/<UTC>/ directory; nothing existing is
#    overwritten (refuses if the target exists). package_app.sh is not used or modified.
#
# Options: [--team-identity "Apple Development: NAME (ID)"] [--run-id ID] [--no-verify]
# --no-verify skips the launch + `cr mcp` probe; build, signing and entitlement checks still run.
set -uo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness"
REPO="$(cd "${HARNESS}/../../.." && pwd)"
PY="$(command -v python3)"
TEAM_IDENTITY="${CR_HARNESS_IDENTITY:-}"
RUN_ID="agentaccess-$(date -u +%Y%m%dt%H%M%Sz)"
VERIFY=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --team-identity) TEAM_IDENTITY="${2:-}"; shift 2 ;;
        --run-id) RUN_ID="${2:-}"; shift 2 ;;
        --no-verify) VERIFY=0; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ "${RUN_ID}" =~ ^[A-Za-z0-9._-]{1,48}$ ]] || { echo "unsafe --run-id" >&2; exit 2; }
if [[ -z "${TEAM_IDENTITY}" ]]; then
    TEAM_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
[[ -n "${TEAM_IDENTITY}" ]] || { echo "no team signing identity found (use --team-identity)" >&2; exit 2; }

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${REPO}/.artifacts/agent-access-acceptance/${STAMP}"
APP="${OUT_DIR}/ClipboardRouter-AgentAccessAcceptance.app"
LOGDIR="${REPO}/.artifacts/mcp-logs/acceptance-app/${STAMP}"
[[ ! -e "${OUT_DIR}" ]] || { echo "refusing to overwrite ${OUT_DIR}" >&2; exit 2; }
mkdir -p "${OUT_DIR}" "${LOGDIR}"
BUILD_PATH="${CR_ACCEPTANCE_BUILD_PATH:-/tmp/cr-acceptance-build}"
BUNDLE_ID="com.clipboardrouter.ClipboardRouter.uiacceptance"
RESULTS="${LOGDIR}/results.tsv"; : > "${RESULTS}"
WATCHDOG="${HARNESS}/watchdog.sh"
APID=""

record() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "${RESULTS}"; echo "$1 $2${3:+  ($3)}"; }
check_rc() { if [[ "$2" == "0" ]]; then record PASS "$1"; else record FAIL "$1" "${3:-rc=$2}"; fi; }
stop_app() { # only the process this script started
    if [[ -n "${APID}" ]]; then
        kill -TERM "${APID}" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do kill -0 "${APID}" 2>/dev/null || break; sleep 0.5; done
        kill -KILL "${APID}" 2>/dev/null || true
        wait "${APID}" 2>/dev/null || true
        APID=""
    fi
}
trap stop_app EXIT
finish() {
    {
        echo "agent-access acceptance app ${STAMP}  identity: ${TEAM_IDENTITY}"
        echo "app: ${APP}"
        echo "PASS=$(grep -c '^PASS' "${RESULTS}") FAIL=$(grep -c '^FAIL' "${RESULTS}") INCOMPLETE=$(grep -c '^INCOMPLETE' "${RESULTS}")"
        cat "${RESULTS}"
    } > "${LOGDIR}/summary.txt"
    echo "== summary: ${LOGDIR}/summary.txt"; sed -n 3p "${LOGDIR}/summary.txt"
    [[ "$(grep -c '^FAIL' "${RESULTS}")" == "0" ]]
    exit $?
}

echo "== logs: ${LOGDIR}"; echo "== app:  ${APP}"
# ---------------------------------------------------------------- build (own scratch path)
"${WATCHDOG}" 1800 "${LOGDIR}/build-app.log" swift build --scratch-path "${BUILD_PATH}" -c release --product ClipboardRouter --package-path "${REPO}"
check_rc "build_real_app_release" "$?" "see build-app.log"
"${WATCHDOG}" 900 "${LOGDIR}/build-cr.log" swift build --scratch-path "${BUILD_PATH}" -c release --product cr --package-path "${REPO}"
check_rc "build_real_cr_release" "$?" "see build-cr.log"
BIN_DIR="${BUILD_PATH}/release"
[[ -x "${BIN_DIR}/ClipboardRouter" && -x "${BIN_DIR}/cr" ]] || { record FAIL "built_executables_present" "missing ${BIN_DIR}/ClipboardRouter or cr"; finish; }

# ---------------------------------------------------------------- assemble
CONTENTS="${APP}/Contents"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources" "${CONTENTS}/Helpers"
cp "${BIN_DIR}/ClipboardRouter" "${CONTENTS}/MacOS/ClipboardRouter"; chmod 0755 "${CONTENTS}/MacOS/ClipboardRouter"
cp "${BIN_DIR}/cr" "${CONTENTS}/Helpers/cr"; chmod 0755 "${CONTENTS}/Helpers/cr"
printf '%s (%s)\n' "0.1.0" "1" > "${CONTENTS}/Resources/cr.version"
cp "${REPO}/Resources/install-cr.sh" "${CONTENTS}/Resources/install-cr.sh"; chmod 0755 "${CONTENTS}/Resources/install-cr.sh"
cp "${REPO}/Resources/Info.plist" "${CONTENTS}/Info.plist"
cp "${REPO}/Resources/PrivacyInfo.xcprivacy" "${CONTENTS}/Resources/PrivacyInfo.xcprivacy"
cp "${REPO}/Resources/AppIcon/ClipboardRouter.icns" "${CONTENTS}/Resources/ClipboardRouter.icns"
PB=/usr/libexec/PlistBuddy
"${PB}" -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "${CONTENTS}/Info.plist"
"${PB}" -c "Set :CFBundleDisplayName Clipboard Router (Agent Access Acceptance)" "${CONTENTS}/Info.plist"
"${PB}" -c "Set :CFBundleName Agent Access Acceptance" "${CONTENTS}/Info.plist"
"${PB}" -c "Add :ClipboardRouterDistributionChannel string direct" "${CONTENTS}/Info.plist"
"${PB}" -c "Delete :CFBundleURLTypes" "${CONTENTS}/Info.plist"
/usr/bin/plutil -lint "${CONTENTS}/Info.plist" > "${LOGDIR}/plutil.log" 2>&1
check_rc "info_plist_valid" "$?" "see plutil.log"
for resource_bundle in "${BIN_DIR}"/ClipboardRouter_*.bundle; do
    [[ -e "${resource_bundle}" ]] || continue
    /usr/bin/ditto "${resource_bundle}" "${APP}/$(basename "${resource_bundle}")"
done
# Hard safety: the plist must carry no commerce or CloudKit configuration.
if grep -Eq 'ClipboardRouterLicense|ClipboardRouterCommerce|ClipboardRouterCloudKitContainer|ClipboardRouterCloudKitEnvironment' "${CONTENTS}/Info.plist"; then
    record FAIL "info_plist_has_no_commerce_or_cloudkit_keys" "unexpected key"
elif "${PB}" -c "Print :ClipboardRouterCloudKitPushEnabled" "${CONTENTS}/Info.plist" 2>/dev/null | grep -q true; then
    record FAIL "info_plist_has_no_commerce_or_cloudkit_keys" "push enabled"
else record PASS "info_plist_has_no_commerce_or_cloudkit_keys"; fi

# ---------------------------------------------------------------- sign
codesign --force --sign "${TEAM_IDENTITY}" --timestamp=none --identifier com.clipboardrouter.cr --options runtime "${CONTENTS}/Helpers/cr" > "${LOGDIR}/codesign.log" 2>&1
check_rc "sign_helper_cr_no_entitlements" "$?" "see codesign.log"
codesign --force --sign "${TEAM_IDENTITY}" --timestamp=none --options runtime \
    --entitlements "${REPO}/Resources/Entitlements/ClipboardRouter.Local.entitlements" "${APP}" >> "${LOGDIR}/codesign.log" 2>&1
check_rc "sign_app_hardened_local_entitlements" "$?" "see codesign.log"
codesign --verify --deep --strict "${APP}" >> "${LOGDIR}/codesign.log" 2>&1
check_rc "codesign_verify_deep_strict" "$?" "see codesign.log"
{
    echo "== codesign -dv app"; codesign -dv --verbose=4 "${APP}" 2>&1
    echo "== signed entitlements app"; codesign -d --entitlements :- "${APP}" 2>&1
    echo "== codesign -dv Helpers/cr"; codesign -dv --verbose=4 "${CONTENTS}/Helpers/cr" 2>&1
    echo "== signed entitlements Helpers/cr (expect none)"; codesign -d --entitlements :- "${CONTENTS}/Helpers/cr" 2>&1
} > "${LOGDIR}/signing.log" 2>&1
grep -q 'flags=0x10000(runtime)' "${LOGDIR}/signing.log" && grep -q 'TeamIdentifier=3NSJ73VV26\|TeamIdentifier=[A-Z0-9]\{10\}' "${LOGDIR}/signing.log" \
    && record PASS "signed_hardened_with_team_identifier" || record FAIL "signed_hardened_with_team_identifier" "see signing.log"
grep -q 'com.apple.security.app-sandbox' "${LOGDIR}/signing.log" && record PASS "app_is_sandboxed" || record FAIL "app_is_sandboxed" "no app-sandbox entitlement"
if grep -Eq 'application-identifier|team-identifier|keychain-access-groups|icloud|aps-environment' "${LOGDIR}/signing.log"; then
    record FAIL "no_restricted_entitlements_signed" "restricted entitlement present, see signing.log"
else record PASS "no_restricted_entitlements_signed"; fi
[[ ! -e "${CONTENTS}/embedded.provisionprofile" ]] && record PASS "no_provisioning_profile_embedded" || record FAIL "no_provisioning_profile_embedded" "profile present"

if [[ "${VERIFY}" != "1" ]]; then finish; fi

# ---------------------------------------------------------------- launch + probe (own process only)
HOME_DIR="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"; HOME_DIR="${HOME_DIR:-$HOME}"
ENDPOINT="${HOME_DIR}/Library/Containers/${BUNDLE_ID}/Data/m/s"
"${APP}/Contents/MacOS/ClipboardRouter" --clipboard-router-ui-acceptance --ui-acceptance-run-id "${RUN_ID}" 2> "${LOGDIR}/app.stderr.log" > "${LOGDIR}/app.stdout.log" &
APID=$!
READY=0
for _ in $(seq 1 120); do
    grep -q UI_ACCEPTANCE_READY "${LOGDIR}/app.stderr.log" 2>/dev/null && { READY=1; break; }
    kill -0 "${APID}" 2>/dev/null || break
    sleep 0.5
done
if [[ "${READY}" == "1" ]]; then
    record PASS "app_launches_with_acceptance_arguments" "UI_ACCEPTANCE_READY, pid ${APID}, run id ${RUN_ID}"
else
    record FAIL "app_launches_with_acceptance_arguments" "no UI_ACCEPTANCE_READY (alive=$(kill -0 "${APID}" 2>/dev/null && echo yes || echo no)); see app.stderr.log. A system prompt may be pending: do not click it from automation."
    stop_app; finish
fi
sleep 1
# Agent Access defaults to OFF in the isolated defaults suite and this script never flips it:
# the app-side listener (and thus app-side availability) can only be confirmed by the human
# enabling the toggle. Absence of the socket here is therefore EXPECTED.
if [[ -S "${ENDPOINT}" ]]; then
    record PASS "agent_access_listener_socket_present_before_toggle" "unexpected but benign (previous opt-in remembered in suite)"
else
    record INCOMPLETE "agent_access_app_side_availability" "listener is off until the toggle in Settings > Agent Access is enabled by a human; verify manually (see README, Manual click-through)"
fi
# `cr mcp` from inside the acceptance bundle: initialize + tools/list never touch the app and
# prove only that cr resolved its in-bundle identity (cr exits 69 for identity/channel problems).
# tools/call with no listener must fail closed with a content-free connection reason.
bounded_probe() { "${WATCHDOG}" 60 "$1" "${PY}" -I "${HARNESS}/mcp_probe.py" --cr "${CONTENTS}/Helpers/cr" --timeout 20 --report "$2" --stderr-log "$3" "${@:4}"; }
bounded_probe "${LOGDIR}/probe-no-listener.log" "${LOGDIR}/probe-no-listener.report.json" "${LOGDIR}/probe-no-listener.cr.err" --profile deny_pairing
PROBE_RC=$?
if [[ -S "${ENDPOINT}" ]]; then
    record INCOMPLETE "cr_mcp_from_acceptance_bundle" "listener already up; probe left a pairing request pending, see probe log"
elif grep -Eq 'initialize_succeeded' "${LOGDIR}/probe-no-listener.log" && grep -q '^PASS initialize_succeeded' "${LOGDIR}/probe-no-listener.log" \
     && grep -q '^PASS tools_list_exactly_four_expected_names' "${LOGDIR}/probe-no-listener.log" \
     && grep -q '^PASS denied_every_tool_call_is_error' "${LOGDIR}/probe-no-listener.log" \
     && grep -q '^PASS denied_no_content_in_any_result' "${LOGDIR}/probe-no-listener.log"; then
    record PASS "cr_mcp_from_acceptance_bundle_initialize_tools_list_fail_closed" "initialize+tools/list ok; tool calls errored content-free with listener off (probe rc=${PROBE_RC}; cr stderr reasons: $(grep -Eo '\([a-z0-9_]+\)' "${LOGDIR}/probe-no-listener.cr.err" 2>/dev/null | sort -u | tr '\n' ' '))"
else
    record FAIL "cr_mcp_from_acceptance_bundle_initialize_tools_list_fail_closed" "see probe-no-listener.log"
fi
"${PY}" -I "${HARNESS}/mcp_probe.py" --print-forbidden > "${LOGDIR}/.forbidden.txt"
if grep -Fq -f "${LOGDIR}/.forbidden.txt" "${LOGDIR}/probe-no-listener.cr.err" "${LOGDIR}/app.stderr.log" 2>/dev/null; then
    record FAIL "no_synthetic_probe_strings_in_cr_stderr_or_app_stderr" "found"
else record PASS "no_synthetic_probe_strings_in_cr_stderr_or_app_stderr"; fi
rm -f "${LOGDIR}/.forbidden.txt"
LAUNCHED_PID="${APID}"
stop_app
if kill -0 "${LAUNCHED_PID}" 2>/dev/null; then record FAIL "app_quit" "pid ${LAUNCHED_PID} still running"
else record PASS "app_quit" "pid ${LAUNCHED_PID}; only the process this script started was signalled"; fi
finish
