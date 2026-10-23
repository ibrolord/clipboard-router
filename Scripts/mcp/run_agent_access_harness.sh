#!/usr/bin/env bash
# Agent-access (cr mcp) acceptance harness. Single entry point.
#
# Builds the real release `cr`, compiles a SYNTHETIC app stand-in (Fixture) from the
# production Sources/ClipboardRouterAgentAccess/*.swift, assembles team-signed fixture apps
# and runs positive/negative/cold-start/non-FDA-host checks against the real `cr mcp`.
# Synthetic data only: it never touches the real app, its container, the Vault, Keychain,
# CloudKit, or any real clipboard. See Scripts/mcp/README.md for what each check proves.
#
# Usage: run_agent_access_harness.sh [--team-identity "Apple Development: NAME (ID)"]
#                                    [--cold-runs N (0..3, default 3)] [--clients]
# Logs: <repo>/.artifacts/mcp-logs/harness/<UTC timestamp>/ (summary.txt is the verdict).
# Exit status: 0 only if every executed check passed. PENDING and INCOMPLETE are reported
# distinctly (they are NOT passes) and do not by themselves fail the run. Only one harness
# instance may run at a time (the fixtures use fixed container ids): a lock directory guards it.
set -uo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness"
REPO="$(cd "${HARNESS}/../../.." && pwd)"
PY="$(command -v python3)"
TEAM_IDENTITY="${CR_HARNESS_IDENTITY:-}"
COLD_RUNS=3
CLIENTS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --team-identity) TEAM_IDENTITY="${2:-}"; shift 2 ;;
        --cold-runs) COLD_RUNS="${2:-}"; shift 2 ;;
        --clients) CLIENTS=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
case "${COLD_RUNS}" in 0|1|2|3) ;; *) echo "--cold-runs must be 0..3" >&2; exit 2 ;; esac
if [[ -z "${TEAM_IDENTITY}" ]]; then
    TEAM_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
if [[ -z "${TEAM_IDENTITY}" ]]; then echo "no team signing identity found (use --team-identity)" >&2; exit 2; fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOCKDIR="${REPO}/.artifacts/mcp-logs/harness/.run.lock"
mkdir -p "${REPO}/.artifacts/mcp-logs/harness"
if ! mkdir "${LOCKDIR}" 2>/dev/null; then
    OWNER="$(cat "${LOCKDIR}/pid" 2>/dev/null || true)"
    if [[ -n "${OWNER}" ]] && kill -0 "${OWNER}" 2>/dev/null; then
        echo "another harness instance (pid ${OWNER}) is running against the same fixtures; refusing to start" >&2
        exit 2
    fi
    echo "removing stale harness lock (owner '${OWNER}' not running)" >&2
    rm -rf -- "${LOCKDIR}"
    mkdir "${LOCKDIR}" 2>/dev/null || { echo "could not take harness lock" >&2; exit 2; }
fi
echo "$$" > "${LOCKDIR}/pid"
LOGDIR="${REPO}/.artifacts/mcp-logs/harness/${STAMP}"
mkdir -p "${LOGDIR}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cr-agent-harness.XXXXXX")"
RESULTS="${LOGDIR}/results.tsv"
: > "${RESULTS}"
BUILD_PATH="${CR_HARNESS_BUILD_PATH:-/tmp/cr-harness-build}"
MAIN_ID="com.clipboardrouter.agentaccess.fixture"
HOME_DIR="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
HOME_DIR="${HOME_DIR:-$HOME}"
FPID=""

stop_fixture() {
    if [[ -n "${FPID}" ]]; then
        kill -TERM "${FPID}" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "${FPID}" 2>/dev/null || break; sleep 0.5; done
        kill -KILL "${FPID}" 2>/dev/null || true
        wait "${FPID}" 2>/dev/null || true
        FPID=""
    fi
}
cleanup() {
    stop_fixture
    rm -rf -- "${WORK}"
    [[ "$(cat "${LOCKDIR}/pid" 2>/dev/null)" == "$$" ]] && rm -rf -- "${LOCKDIR}"
}
trap cleanup EXIT

record() { # PASS|FAIL|PENDING|INCOMPLETE name [detail]
    printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "${RESULTS}"
    echo "$1 $2${3:+  ($3)}"
}
check_rc() { # name rc detail
    if [[ "$2" == "0" ]]; then record PASS "$1"; else record FAIL "$1" "${3:-rc=$2}"; fi
}
check_grep() { # name pattern file
    if grep -Eq -- "$2" "$3" 2>/dev/null; then record PASS "$1"; else record FAIL "$1" "pattern '$2' not in $(basename "$3")"; fi
}
check_no_grep() { # name pattern file
    if grep -Eq -- "$2" "$3" 2>/dev/null; then record FAIL "$1" "unexpected '$2' in $(basename "$3")"; else record PASS "$1"; fi
}
bounded() { "${HARNESS}/watchdog.sh" "$@"; } # seconds log command...

"${PY}" -I "${HARNESS}/mcp_probe.py" --print-forbidden > "${WORK}/forbidden.txt"
scan_leaks() { # name file...
    local name="$1"; shift
    local f hits=""
    for f in "$@"; do
        if [[ -s "${f}" ]] && grep -Fq -f "${WORK}/forbidden.txt" "${f}"; then hits="${hits} $(basename "${f}")"; fi
    done
    if [[ -z "${hits}" ]]; then record PASS "${name}"; else record FAIL "${name}" "forbidden string in:${hits}"; fi
}

client_verdict() { # client taplog outfile crerr canary
    local client="$1" tap="$2" out="$3" err="$4" canary="$5"
    local tap_ok=1 canary_ok=1
    "${PY}" -I "${HARNESS}/check_tap_log.py" "${tap}" > "${LOGDIR}/client-${client}.tapcheck.log" 2>&1 && tap_ok=0
    grep -Fq "${canary}" "${out}" 2>/dev/null && canary_ok=0
    if [[ "${tap_ok}" == 0 && "${canary_ok}" == 0 ]]; then
        record PASS "client_interop_${client}"
    elif [[ ! -s "${tap}" ]] || ! grep -q '"method": "initialize"' "${tap}" 2>/dev/null; then
        record PENDING "client_interop_${client}" "client never reached the server (login/network/flags?): $(head -c 160 "${out}" 2>/dev/null | tr '\n' ' ')"
    else
        record FAIL "client_interop_${client}" "tap_ok=$((1-tap_ok)) canary_in_output=$((1-canary_ok)); see client-${client}.*"
    fi
}

# ---------------------------------------------------------------- build
echo "== logs: ${LOGDIR}"
echo "== identity: ${TEAM_IDENTITY}"
bounded 900 "${LOGDIR}/build-cr.log" swift build --scratch-path "${BUILD_PATH}" -c release --product cr --package-path "${REPO}"
rc=$?
check_rc "build_real_cr_release" "${rc}" "see build-cr.log (rc=${rc})"
[[ "${rc}" == "0" ]] || { echo "cannot continue"; exit 1; }
CR_BIN="${BUILD_PATH}/release/cr"

SWIFTC=(/usr/bin/xcrun swiftc -swift-version 6 -O -target arm64-apple-macos14.0)
PROD=("${REPO}"/Sources/ClipboardRouterAgentAccess/*.swift)
mkdir -p "${WORK}/bin"
bounded 600 "${LOGDIR}/build-fixture.log" "${SWIFTC[@]}" -module-name agentaccess_fixture "${PROD[@]}" "${HARNESS}/Fixture/main.swift" -o "${WORK}/bin/agentaccess-fixture"
check_rc "compile_fixture_from_production_sources" "$?" "see build-fixture.log"
bounded 600 "${LOGDIR}/build-peer.log" "${SWIFTC[@]}" -module-name peer "${PROD[@]}" "${HARNESS}/Peer/main.swift" -o "${WORK}/bin/peer"
check_rc "compile_test_peer_from_production_sources" "$?" "see build-peer.log"
bounded 300 "${LOGDIR}/build-testhost.log" "${SWIFTC[@]}" -module-name testhost "${HARNESS}/TestHost/main.swift" -o "${WORK}/bin/testhost"
check_rc "compile_test_host" "$?" "see build-testhost.log"
[[ -x "${WORK}/bin/agentaccess-fixture" && -x "${WORK}/bin/peer" ]] || { echo "build failed"; exit 1; }

"${PY}" -I "${HARNESS}/stdio_tap.py" --self-test > "${LOGDIR}/tap-self-test.log" 2>&1
check_rc "stdio_tap_self_test" "$?" "see tap-self-test.log"

# ---------------------------------------------------------------- app assembly
sign_cr() { # app mode(team|adhoc)
    local ident="-"; [[ "$2" == team ]] && ident="${TEAM_IDENTITY}"
    codesign --force --sign "${ident}" --timestamp=none --identifier com.clipboardrouter.cr --options runtime "$1/Contents/Helpers/cr" >> "${LOGDIR}/codesign.log" 2>&1
}
make_app() { # name bundle-id channel(direct|macAppStore|missing) sign(team|adhoc) entitlements(sandbox|none)
    local name="$1" bid="$2" channel="$3" mode="$4" ents="$5"
    local app="${WORK}/${name}.app" entry=""
    mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Helpers"
    case "${channel}" in
        direct) entry='<key>ClipboardRouterDistributionChannel</key><string>direct</string>' ;;
        macAppStore) entry='<key>ClipboardRouterDistributionChannel</key><string>macAppStore</string>' ;;
    esac
    sed -e "s#@BUNDLE_ID@#${bid}#" -e "s#@CHANNEL_ENTRY@#${entry}#" "${HARNESS}/Fixture/Info.plist.template" > "${app}/Contents/Info.plist"
    cp "${WORK}/bin/agentaccess-fixture" "${app}/Contents/MacOS/agentaccess-fixture"
    cp "${CR_BIN}" "${app}/Contents/Helpers/cr"
    sign_cr "${app}" "${mode}"
    local ident="-"; [[ "${mode}" == team ]] && ident="${TEAM_IDENTITY}"
    local args=(--force --sign "${ident}" --timestamp=none --options runtime)
    [[ "${ents}" == sandbox ]] && args+=(--entitlements "${HARNESS}/Fixture/sandbox.entitlements")
    codesign "${args[@]}" "${app}" >> "${LOGDIR}/codesign.log" 2>&1
    codesign --verify --strict --deep "${app}" >> "${LOGDIR}/codesign.log" 2>&1
}
app_id() { echo "$1"; }
endpoint_of() { echo "${HOME_DIR}/Library/Containers/$1/Data/m/s"; }

start_fixture() { # app log args...  -> 0 if listening
    local app="$1" log="$2"; shift 2
    : > "${log}"
    "${app}/Contents/MacOS/agentaccess-fixture" "$@" 2> "${log}" &
    FPID=$!
    local i
    for i in $(seq 1 60); do
        grep -Eq 'fixture_listening|fixture_identity_failed|fixture_listen_failed|spoof_listening|spoof_listen_failed' "${log}" && break
        kill -0 "${FPID}" 2>/dev/null || break
        sleep 0.25
    done
    grep -Eq 'fixture_listening|spoof_listening' "${log}"
}

probe() { # name cr profile [extra args...]; report -> $LOGDIR/<name>.*
    local name="$1" cr="$2" profile="$3"; shift 3
    bounded 150 "${LOGDIR}/${name}.probe.log" "${PY}" -I "${HARNESS}/mcp_probe.py" --cr "${cr}" --profile "${profile}" \
        --report "${LOGDIR}/${name}.report.json" --stderr-log "${LOGDIR}/${name}.cr.err" "$@"
    check_rc "${name}" "$?" "see ${name}.probe.log"
}

make_app Fixture "${MAIN_ID}" direct team sandbox
APP="${WORK}/Fixture.app"
CR="${APP}/Contents/Helpers/cr"
{
    echo "== codesign -dv Fixture.app"; codesign -dv "${APP}" 2>&1
    echo "== codesign -dv Helpers/cr"; codesign -dv "${CR}" 2>&1
    echo "== entitlements Fixture.app"; codesign -d --entitlements :- "${APP}" 2>&1
    echo "== entitlements Helpers/cr (expect none)"; codesign -d --entitlements :- "${CR}" 2>&1
} > "${LOGDIR}/assembly.log" 2>&1
check_grep "fixture_app_signed_hardened_team" 'flags=0x10000\(runtime\)' "${LOGDIR}/assembly.log"
check_grep "fixture_app_sandboxed" 'com.apple.security.app-sandbox' "${LOGDIR}/assembly.log"

# ---------------------------------------------------------------- C. positive
echo "== C. positive round trips"
FLOG="${LOGDIR}/fixture-approve.log"
if start_fixture "${APP}" "${FLOG}" --pairing approve --vault approve --run-seconds 240; then
    record PASS "fixture_listening_signed_sandboxed"
    probe "positive_approve" "${CR}" approve
    ln -s "${CR}" "${WORK}/cr-symlink"
    probe "symlink_to_in_bundle_cr_works" "${WORK}/cr-symlink" approve
    stop_fixture
    scan_leaks "no_content_in_fixture_log_or_cr_stderr_approve" "${FLOG}" "${LOGDIR}/positive_approve.cr.err" "${LOGDIR}/symlink_to_in_bundle_cr_works.cr.err"
else
    record FAIL "fixture_listening_signed_sandboxed" "see fixture-approve.log"; stop_fixture
fi
FLOG="${LOGDIR}/fixture-vault-deny.log"
# Regression check from client interop: Codex's initialize capabilities (experimental,
# elicitation form/url) must be accepted. Needs no fixture (initialize never touches the app).
probe "initialize_accepts_codex_capability_shape" "${CR}" initialize_codex_shape
probe "initialize_accepts_experimental_only_capability" "${CR}" initialize_experimental_only
if start_fixture "${APP}" "${FLOG}" --pairing approve --vault deny --run-seconds 120; then
    probe "vault_denied" "${CR}" vault_deny
    stop_fixture
    scan_leaks "no_content_in_logs_vault_deny" "${FLOG}" "${LOGDIR}/vault_denied.cr.err"
else record FAIL "fixture_listening_vault_deny" "see log"; stop_fixture; fi
FLOG="${LOGDIR}/fixture-pairing-deny.log"
if start_fixture "${APP}" "${FLOG}" --pairing deny --run-seconds 120; then
    probe "pairing_denied" "${CR}" deny_pairing
    stop_fixture
    scan_leaks "no_content_in_logs_pairing_deny" "${FLOG}" "${LOGDIR}/pairing_denied.cr.err"
else record FAIL "fixture_listening_pairing_deny" "see log"; stop_fixture; fi
FLOG="${LOGDIR}/fixture-pairing-never.log"
if start_fixture "${APP}" "${FLOG}" --pairing never --pairing-timeout 3 --run-seconds 120; then
    probe "pairing_never_decided_expires" "${CR}" deny_pairing
    stop_fixture
    scan_leaks "no_content_in_logs_pairing_expiry" "${FLOG}" "${LOGDIR}/pairing_never_decided_expires.cr.err"
else record FAIL "fixture_listening_pairing_never" "see log"; stop_fixture; fi

# ---------------------------------------------------------------- D. negatives
echo "== D. negative checks"
# D1 ad-hoc fixture never listens.
make_app Adhoc "${MAIN_ID}.adhoc" direct adhoc sandbox
ALOG="${LOGDIR}/fixture-adhoc.log"
if start_fixture "${WORK}/Adhoc.app" "${ALOG}" --run-seconds 20; then
    record FAIL "adhoc_fixture_never_listens" "fixture listened"
else
    check_grep "adhoc_fixture_never_listens_reason_unsigned_or_ad_hoc_build" 'fixture_identity_failed reason=unsigned_or_ad_hoc_build' "${ALOG}"
    check_no_grep "adhoc_fixture_no_listener_event" 'listener_started|fixture_listening' "${ALOG}"
fi
stop_fixture
bounded 20 "${LOGDIR}/adhoc-fixture-endpoint-connect.log" "${WORK}/bin/peer" "$(endpoint_of "${MAIN_ID}.adhoc")"
check_grep "adhoc_fixture_endpoint_not_connectable" 'peer_connect_failed' "${LOGDIR}/adhoc-fixture-endpoint-connect.log"
# D2 ad-hoc cr exits 69.
probe "adhoc_cr_exits_69_unsigned_or_ad_hoc_build" "${WORK}/Adhoc.app/Contents/Helpers/cr" exit_unavailable --expect-reason unsigned_or_ad_hoc_build
# D3 copied cr outside bundle.
mkdir -p "${WORK}/outside"; cp "${CR}" "${WORK}/outside/cr"
probe "copied_cr_outside_bundle_helper_not_inside_app_bundle" "${WORK}/outside/cr" exit_unavailable --expect-reason helper_not_inside_app_bundle
# D4 channel variants (team-signed, sandboxed; only the signed marker differs).
make_app StoreChannel "${MAIN_ID}.store" macAppStore team sandbox
make_app NoChannel "${MAIN_ID}.nochannel" missing team sandbox
probe "channel_macAppStore_cr_exits_69" "${WORK}/StoreChannel.app/Contents/Helpers/cr" exit_unavailable --expect-reason distribution_channel_not_direct
probe "channel_missing_cr_exits_69" "${WORK}/NoChannel.app/Contents/Helpers/cr" exit_unavailable --expect-reason distribution_channel_not_direct
for variant in StoreChannel NoChannel; do
    VLOG="${LOGDIR}/fixture-${variant}.log"
    start_fixture "${WORK}/${variant}.app" "${VLOG}" --run-seconds 20 >/dev/null; stop_fixture
    check_grep "channel_${variant}_fixture_refuses_to_listen" 'fixture_identity_failed reason=distribution_channel_not_direct' "${VLOG}"
done

# D5 unsandboxed same-team same-identifier hardened spoof at the real endpoint path.
SPOOF="${WORK}/spoof-main"
cp "${WORK}/bin/agentaccess-fixture" "${SPOOF}"
codesign --force --sign "${TEAM_IDENTITY}" --timestamp=none --identifier "${MAIN_ID}" --options runtime "${SPOOF}" >> "${LOGDIR}/codesign.log" 2>&1
{ echo "== codesign -dv spoof"; codesign -dv "${SPOOF}" 2>&1; echo "== codesign -d --entitlements :- spoof (expect none)"; codesign -d --entitlements :- "${SPOOF}" 2>&1; } > "${LOGDIR}/spoof-signing.log" 2>&1
check_no_grep "spoof_has_no_sandbox_entitlement" 'app-sandbox' "${LOGDIR}/spoof-signing.log"
check_grep "spoof_is_hardened_team_signed" 'flags=0x10000\(runtime\)' "${LOGDIR}/spoof-signing.log"
SLOG="${LOGDIR}/spoof-standalone.log"
: > "${SLOG}"
"${SPOOF}" --spoof-listen "$(endpoint_of "${MAIN_ID}")" --run-seconds 40 2> "${SLOG}" &
FPID=$!
for _ in $(seq 1 40); do grep -Eq 'spoof_listening|spoof_listen_failed' "${SLOG}" && break; kill -0 "${FPID}" 2>/dev/null || break; sleep 0.25; done
if grep -q spoof_listening "${SLOG}"; then
    probe "spoof_unsandboxed_real_cr_reports_peer_entitlement_missing" "${CR}" refuse_connect --expect-reason peer_entitlement_missing --timeout 30
    wait "${FPID}" 2>/dev/null; FPID=""
    check_grep "spoof_received_zero_bytes" 'spoof_bytes_received=0' "${SLOG}"
else
    SPOOF_BIND="$(grep spoof_listen_failed "${SLOG}" | head -1)"
    record PASS "spoof_unsandboxed_cannot_bind_inside_real_container" "${SPOOF_BIND}"
    wait "${FPID}" 2>/dev/null; FPID=""
fi
# Variant: an UNSANDBOXED same-team hardened app (bundle id == its own spoof id, so cr's
# requirement and bundle checks pass) whose main executable listens at the endpoint cr derives
# for it. The real containers are protected from unsandboxed writes (EPERM above), so this uses
# a stub container directory (see README: the stub is adopted by containermanagerd and cannot
# be removed from user space; the script reuses it and removes only its Data directory).
SPOOF_ID="${MAIN_ID}.spooftry"
make_app SpoofBundle "${SPOOF_ID}" direct team none
codesign -d --entitlements :- "${WORK}/SpoofBundle.app" > "${LOGDIR}/spoofbundle-entitlements.log" 2>&1
check_no_grep "spoof_bundle_has_no_sandbox_entitlement" 'app-sandbox' "${LOGDIR}/spoofbundle-entitlements.log"
SPOOF_DATA="${HOME_DIR}/Library/Containers/${SPOOF_ID}/Data"
mkdir -p "${SPOOF_DATA}"
SBLOG="${LOGDIR}/spoof-bundle-main.log"
: > "${SBLOG}"
"${WORK}/SpoofBundle.app/Contents/MacOS/agentaccess-fixture" --spoof-listen "$(endpoint_of "${SPOOF_ID}")" --run-seconds 40 2> "${SBLOG}" &
FPID=$!
for _ in $(seq 1 40); do grep -Eq 'spoof_listening|spoof_listen_failed' "${SBLOG}" && break; kill -0 "${FPID}" 2>/dev/null || break; sleep 0.25; done
if grep -q spoof_listening "${SBLOG}"; then
    probe "spoof_bundle_real_cr_reports_peer_entitlement_missing" "${WORK}/SpoofBundle.app/Contents/Helpers/cr" refuse_connect --expect-reason peer_entitlement_missing --timeout 30
    wait "${FPID}" 2>/dev/null; FPID=""
    check_grep "spoof_bundle_received_zero_bytes" 'spoof_bytes_received=0' "${SBLOG}"
else
    record FAIL "spoof_bundle_could_not_bind_endpoint" "$(grep spoof_listen_failed "${SBLOG}" | head -1)"
    stop_fixture
fi
case "${SPOOF_DATA}" in "${HOME_DIR}/Library/Containers/${MAIN_ID}.spooftry/Data") rm -rf -- "${SPOOF_DATA}" ;; esac

# D6 foreign peers refused by the fixture before any reply.
# The sandboxed fixture can only read peer code that lives inside its own bundle: a peer
# elsewhere fails earlier with peer_code_unavailable_100001 (EPERM; also fail-closed). To
# reach the requirement check, the foreign peers live inside PeerHost.app, a copy of the
# fixture with the same identifier (hence the same container/endpoint).
make_app PeerHost "${MAIN_ID}" direct team sandbox
make_peer() { # name identifier mode
    local ident="-"; [[ "$3" == team ]] && ident="${TEAM_IDENTITY}"
    cp "${WORK}/bin/peer" "${WORK}/PeerHost.app/Contents/Helpers/$1"
    codesign --force --sign "${ident}" --timestamp=none --identifier "$2" --options runtime "${WORK}/PeerHost.app/Contents/Helpers/$1" >> "${LOGDIR}/codesign.log" 2>&1
}
make_peer peer-foreign-team com.clipboardrouter.agentaccess.foreignpeer team
make_peer peer-adhoc-same-id com.clipboardrouter.cr adhoc
# Genuine identifier, team-signed, hardened: only the entitlement / location differ.
cp "${WORK}/bin/peer" "${WORK}/PeerHost.app/Contents/Helpers/peer-get-task-allow"
codesign --force --sign "${TEAM_IDENTITY}" --timestamp=none --identifier com.clipboardrouter.cr --options runtime \
    --entitlements "${HARNESS}/Peer/get-task-allow.entitlements" "${WORK}/PeerHost.app/Contents/Helpers/peer-get-task-allow" >> "${LOGDIR}/codesign.log" 2>&1
check_rc "peer_get_task_allow_signed" "$?" "codesign refused get-task-allow; see codesign.log"
make_peer peer-wrong-path com.clipboardrouter.cr team
codesign --force --sign "${TEAM_IDENTITY}" --timestamp=none --options runtime --entitlements "${HARNESS}/Fixture/sandbox.entitlements" "${WORK}/PeerHost.app" >> "${LOGDIR}/codesign.log" 2>&1
PLOG="${LOGDIR}/fixture-foreign-peers.log"
if start_fixture "${WORK}/PeerHost.app" "${PLOG}" --pairing approve --run-seconds 90; then
    for peer in peer-foreign-team peer-adhoc-same-id peer-get-task-allow peer-wrong-path; do
        bounded 30 "${LOGDIR}/${peer}.out.log" "${WORK}/PeerHost.app/Contents/Helpers/${peer}" "$(endpoint_of "${MAIN_ID}")"
        check_grep "${peer}_gets_zero_bytes" 'peer_bytes_received=0' "${LOGDIR}/${peer}.out.log"
    done
    sleep 1
    stop_fixture
    check_grep "foreign_peers_logged_peer_requirement_failed" 'event=reject reason=peer_requirement_failed' "${PLOG}"
    if [[ "$(grep -c 'event=reject reason=peer_requirement_failed' "${PLOG}")" == "2" ]]; then record PASS "foreign_peers_two_requirement_rejections"; else record FAIL "foreign_peers_two_requirement_rejections" "count != 2"; fi
    check_grep "peer_get_task_allow_logged_peer_entitlement_forbidden" 'event=reject reason=peer_entitlement_forbidden' "${PLOG}"
    check_grep "peer_wrong_path_logged_peer_path_mismatch" 'event=reject reason=peer_path_mismatch' "${PLOG}"
    if [[ "$(grep -c 'event=reject' "${PLOG}")" == "4" ]]; then record PASS "foreign_peers_four_rejections_total"; else record FAIL "foreign_peers_four_rejections_total" "count != 4"; fi
    check_no_grep "foreign_peers_never_opened_session" 'session_opened|pairing_decided' "${PLOG}"
    scan_leaks "no_content_in_foreign_peer_logs" "${PLOG}" "${LOGDIR}"/peer-*.out.log
else record FAIL "fixture_listening_for_foreign_peers" "see log"; stop_fixture; fi

# ---------------------------------------------------------------- E. cold first run
echo "== E. cold first-run investigation (${COLD_RUNS} run(s))"
COLD_SEQ=""; [[ "${COLD_RUNS}" -ge 1 ]] && COLD_SEQ="$(seq 1 "${COLD_RUNS}")"
for n in ${COLD_SEQ}; do
    CID="${MAIN_ID}.cold${n}"
    PRE="no"; [[ -e "${HOME_DIR}/Library/Containers/${CID}" ]] && PRE="yes"
    make_app "Cold${n}" "${CID}" direct team sandbox
    CLOG="${LOGDIR}/cold${n}-fixture.log"
    echo "cold run ${n}: container_preexisting=${PRE}" > "${LOGDIR}/cold${n}-note.txt"
    if start_fixture "${WORK}/Cold${n}.app" "${CLOG}" --pairing approve --vault approve --run-seconds 120; then
        probe "cold${n}_first_run_round_trip" "${WORK}/Cold${n}.app/Contents/Helpers/cr" approve
        stop_fixture
        "${PY}" -I "${HARNESS}/summarize_cold.py" "${CLOG}" "${LOGDIR}/cold${n}_first_run_round_trip.report.json" "${LOGDIR}/cold${n}_first_run_round_trip.cr.err" > "${LOGDIR}/cold${n}-summary.txt" 2>&1
        scan_leaks "no_content_in_cold${n}_logs" "${CLOG}" "${LOGDIR}/cold${n}_first_run_round_trip.cr.err"
    else record FAIL "cold${n}_fixture_listening" "see cold${n}-fixture.log"; stop_fixture; fi
done

# ---------------------------------------------------------------- F. non-FDA host
echo "== F. non-FDA ad-hoc host"
# A genuinely fresh identity per run: a new bundle id (never seen by LaunchServices/TCC) with a
# fresh ad-hoc cdhash, launched by `open -n` so the host (not this shell) is the responsible
# process. "Never requested FDA" is true by construction (TCC is not inspected or modified);
# the responsible-process and launchd-parent conditions are measured by the host itself and
# verified from its result artifact. Anything not established is INCOMPLETE, never PASS.
RUNID="${STAMP}-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
HOST_BUNDLE_ID="com.clipboardrouter.agentaccess.testhost.$(printf '%s' "${RUNID}" | tr 'A-Z_' 'a-z-')"
HOSTAPP="${WORK}/TestHost-${RUNID}.app"
mkdir -p "${HOSTAPP}/Contents/MacOS"
sed -e "s#@BUNDLE_ID@#${HOST_BUNDLE_ID}#" "${HARNESS}/TestHost/Info.plist" > "${HOSTAPP}/Contents/Info.plist"
cp "${WORK}/bin/testhost" "${HOSTAPP}/Contents/MacOS/testhost"
codesign --force --sign - --timestamp=none --identifier "${HOST_BUNDLE_ID}" "${HOSTAPP}" >> "${LOGDIR}/codesign.log" 2>&1
codesign --verify --strict "${HOSTAPP}" >> "${LOGDIR}/codesign.log" 2>&1
check_rc "testhost_fresh_adhoc_identity_signed" "$?" "see codesign.log"
HLOG="${LOGDIR}/fixture-for-host.log"
if start_fixture "${APP}" "${HLOG}" --pairing approve --vault approve --run-seconds 150; then
    HRES="/tmp/cr-testhost-${RUNID}.json"
    HNONCE="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    rm -f -- "${HRES}" "${LOGDIR}/host-probe.report.json"
    LAUNCH_EPOCH="$("${PY}" -I -c 'import time; print(time.time())')"
    echo "run_id=${RUNID} bundle_id=${HOST_BUNDLE_ID} launch_epoch=${LAUNCH_EPOCH}" > "${LOGDIR}/host-identity.txt"
    bounded 140 "${LOGDIR}/host-open.log" /usr/bin/open -n -W "${HOSTAPP}" --args "${HRES}" "${LOGDIR}/host-probe.report.json" "${HNONCE}" \
        "${PY}" -I "${HARNESS}/mcp_probe.py" \
        --cr "${CR}" --profile approve --timeout 40 --report "${LOGDIR}/host-probe.report.json" --stderr-log "${LOGDIR}/host-probe.cr.err"
    OPEN_RC=$?
    stop_fixture
    cp "${HRES}" "${LOGDIR}/host-result.json" 2>/dev/null
    rm -f -- "${HRES}"
    "${PY}" -I "${HARNESS}/check_host_result.py" "${LOGDIR}/host-result.json" "${HNONCE}" "${LAUNCH_EPOCH}" "${HOST_BUNDLE_ID}" > "${LOGDIR}/host-verdict.txt" 2>&1
    HV=$?
    HV_TEXT="$(head -c 300 "${LOGDIR}/host-verdict.txt")"
    if [[ "${OPEN_RC}" == "124" ]]; then
        record FAIL "non_fda_host_round_trip" "timed out (possible privacy prompt or hang); release gate pending"
    elif [[ "${HV}" == "0" ]]; then
        record PASS "non_fda_host_round_trip" "${HV_TEXT#PASS } (open rc=${OPEN_RC}; verified from artifact, not from open)"
    elif [[ "${HV}" == "3" ]]; then
        record INCOMPLETE "non_fda_host_round_trip" "${HV_TEXT#INCOMPLETE } (open rc=${OPEN_RC})"
    else
        record FAIL "non_fda_host_round_trip" "${HV_TEXT#FAIL } (open rc=${OPEN_RC}); release gate pending"
    fi
    scan_leaks "no_content_in_host_run_logs" "${HLOG}" "${LOGDIR}/host-probe.cr.err" "${LOGDIR}/host-result.json"
else record FAIL "fixture_listening_for_host" "see log"; stop_fixture; fi

# ---------------------------------------------------------------- H. client interop
if [[ "${CLIENTS}" == "1" ]]; then
    echo "== H. client interop"
    CANARY="CR-SYNTHETIC-CANARY-7f3a"
    PROMPT="Use only the clipboard_fixture MCP server. First call the list_shared_clips tool. Then call get_shared_clip with the id of the clip titled CR-SYNTHETIC-TITLE-ALPHA. Print the returned clip text exactly and nothing else."
    ILOG="${LOGDIR}/fixture-clients.log"
    if start_fixture "${APP}" "${ILOG}" --pairing approve --vault approve --run-seconds 600; then
        # --- Claude
        CWORK="$(mktemp -d "${WORK}/claude.XXXXXX")"
        CCFG="${CWORK}/mcp.json"
        TAPLOG="${LOGDIR}/client-claude.tap.log"
        "${PY}" -I -c 'import json,sys; json.dump({"mcpServers":{"clipboard_fixture":{"command":sys.argv[1],"args":["-I",sys.argv[2],"--child-stderr",sys.argv[3],sys.argv[4],sys.argv[5],"mcp"]}}},open(sys.argv[6],"w"))' \
            "${PY}" "${HARNESS}/stdio_tap.py" "${LOGDIR}/client-claude.cr.err" "${TAPLOG}" "${CR}" "${CCFG}"
        (cd "${CWORK}" && bounded 240 "${LOGDIR}/client-claude.out.json" env -u CLAUDE_CODE_SAFE_MODE CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
            /opt/homebrew/bin/claude --restricted --setting-sources "" --strict-mcp-config --mcp-config "${CCFG}" \
            --settings '{"disableAllHooks":true,"autoMemoryEnabled":false}' --tools "" --disable-slash-commands --no-chrome \
            --allowedTools "mcp__clipboard_fixture__*" --permission-mode dontAsk --permission-prompts none --no-session-persistence \
            --output-format stream-json --verbose -p "${PROMPT}")
        client_verdict claude "${TAPLOG}" "${LOGDIR}/client-claude.out.json" "${LOGDIR}/client-claude.cr.err" "${CANARY}"
        # --- Codex
        XWORK="$(mktemp -d "${WORK}/codex.XXXXXX")"
        TAPLOG="${LOGDIR}/client-codex.tap.log"
        (cd "${XWORK}" && bounded 240 "${LOGDIR}/client-codex.out.json" codex --no-daemon -a never exec --ignore-user-config --ignore-rules --ephemeral \
            --skip-git-repo-check --strict-config -C "${XWORK}" --sandbox read-only --json --disable apps --disable plugins --disable hooks \
            --disable memories --disable shell_tool --disable multi_agent -c project_doc_max_bytes=0 -c skills.include_instructions=false \
            -c memories.use_memories=false -c memories.generate_memories=false -c 'web_search="disabled"' \
            -c 'mcp_servers.clipboard_fixture.command="'"${PY}"'"' \
            -c 'mcp_servers.clipboard_fixture.args=["-I","'"${HARNESS}/stdio_tap.py"'","--child-stderr","'"${LOGDIR}/client-codex.cr.err"'","'"${TAPLOG}"'","'"${CR}"'","mcp"]' \
            -c mcp_servers.clipboard_fixture.required=true \
            -c 'mcp_servers.clipboard_fixture.enabled_tools=["list_shared_clips","get_shared_clip"]' "${PROMPT}")
        client_verdict codex "${TAPLOG}" "${LOGDIR}/client-codex.out.json" "${LOGDIR}/client-codex.cr.err" "${CANARY}"
        stop_fixture
        # The raw helper (cr) stderr of each client run was teed by stdio_tap.py --child-stderr
        # into its own artifact. It must exist and, like the fixture (broker) log and the
        # metadata-only tap logs, hold no canary/title/purpose/probe-client-name, and no real
        # client name (claude/codex).
        for c in claude codex; do
            [[ -e "${LOGDIR}/client-${c}.cr.err" ]] && record PASS "client_${c}_cr_stderr_artifact_exists" \
                || record FAIL "client_${c}_cr_stderr_artifact_exists" "tap did not create client-${c}.cr.err"
            if grep -Eiq 'claude|codex' "${LOGDIR}/client-${c}.cr.err" "${ILOG}" 2>/dev/null; then
                record FAIL "no_client_name_in_${c}_cr_stderr_or_fixture_log" "client name present"
            else record PASS "no_client_name_in_${c}_cr_stderr_or_fixture_log"; fi
        done
        scan_leaks "no_content_in_client_fixture_log_cr_stderr_and_tap_logs" "${ILOG}" \
            "${LOGDIR}/client-claude.cr.err" "${LOGDIR}/client-codex.cr.err" "${LOGDIR}/client-claude.tap.log" "${LOGDIR}/client-codex.tap.log"
        # Client output legitimately holds the granted clip (canary) and ALPHA title; it must not
        # hold anything that was never granted or requested (excluded clip, second clip, Vault, purpose).
        for c in claude codex; do
            if grep -Eq 'CR-SYNTHETIC-EXCLUDED-b05c|CR-SYNTHETIC-TITLE-EXCLUDED|CR-SYNTHETIC-VAULT-91c2|CR-PROBE-PURPOSE-5c8e|CR-SYNTHETIC-SECOND-4e8d' "${LOGDIR}/client-${c}.out.json" 2>/dev/null; then
                record FAIL "no_ungranted_content_in_${c}_output" "ungranted synthetic string in client output"
            else record PASS "no_ungranted_content_in_${c}_output"; fi
        done
    else record FAIL "fixture_listening_for_clients" "see log"; stop_fixture; fi
fi

# ---------------------------------------------------------------- verdict
{
    echo "harness run ${STAMP}  identity: ${TEAM_IDENTITY}"
    echo "PASS=$(grep -c '^PASS' "${RESULTS}") FAIL=$(grep -c '^FAIL' "${RESULTS}") PENDING=$(grep -c '^PENDING' "${RESULTS}") INCOMPLETE=$(grep -c '^INCOMPLETE' "${RESULTS}")"
    cat "${RESULTS}"
} > "${LOGDIR}/summary.txt"
echo "== summary: ${LOGDIR}/summary.txt"
sed -n 2p "${LOGDIR}/summary.txt"
[[ "$(grep -c '^FAIL' "${RESULTS}")" == "0" ]]
