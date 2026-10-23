# Agent-access (`cr mcp`) acceptance harness

Single entry point: `Scripts/mcp/run_agent_access_harness.sh [--team-identity "Apple Development: NAME (ID)"] [--cold-runs N<=3] [--clients]`

Without `--team-identity` the first `Apple Development` code-signing identity in the login keychain is used
(signing only; `--timestamp=none`, no certificates are created, no network). Logs go to
`.artifacts/mcp-logs/harness/<UTC timestamp>/`; `summary.txt` is the verdict and the script exits non-zero on any
`FAIL`. Every external command is bounded by `harness/watchdog.sh`.
Verdicts are `PASS`, `FAIL`, `PENDING` (a client never reached the server) and `INCOMPLETE` (the check ran but a
required condition could not be established). `PENDING` and `INCOMPLETE` are never passes and are counted separately.
Only one harness may run at a time: the script takes `.artifacts/mcp-logs/harness/.run.lock` (a directory holding its pid;
a second instance exits 2, a stale lock whose pid is dead is replaced), because the fixtures use fixed container ids.

Separate entry point for the real app UI: `bash Scripts/mcp/package_agent_access_acceptance_app.sh` (see "Manual click-through").

## What it builds

| Piece | Source | Notes |
| --- | --- | --- |
| real `cr` | `swift build --scratch-path /tmp/cr-harness-build -c release --product cr` | the production CLI, unmodified |
| Fixture | `Sources/ClipboardRouterAgentAccess/*.swift` + `harness/Fixture/main.swift` | compiled together with `swiftc`; no copied transport code |
| Fixture.app | `harness/Fixture/Info.plist.template`, `sandbox.entitlements` | `ClipboardRouterDistributionChannel=direct`, sandboxed, hardened, team-signed; `Helpers/cr` = real `cr` signed `--identifier com.clipboardrouter.cr --options runtime` with no entitlements |
| Peer | production sources + `harness/Peer/main.swift` | TEST ONLY foreign client (no server verification) |
| TestHost.app | `harness/TestHost` | ad-hoc app, fresh bundle id every run, that spawns the probe under LaunchServices and writes a result artifact |

## What each check proves

Proven (signed production transport + identity derivation, against a synthetic stand-in):

* `positive_approve`, `symlink_to_in_bundle_cr_works`, `vault_denied`, `pairing_denied`,
  `pairing_never_decided_expires`: the real `cr mcp`, executed from inside a team-signed, hardened, sandboxed
  `.app` with the `direct` channel marker, completes the `AppIdentityContext`/`BridgeIdentityContext` mutual
  verification over the real `<container>/Data/m/s` socket and serves exactly the scoped synthetic clips, the
  exact canary, identical not-found for excluded and random ids, the Vault text only when approved, and nothing on
  deny/expiry. `mcp_probe.py` exits non-zero on any failed assertion.
* `no_content_in_*`: canary/title/purpose/client-name strings never appear in `cr` stderr or the fixture log.
* `adhoc_*`: ad-hoc fixture refuses to listen (`unsigned_or_ad_hoc_build`), ad-hoc `cr` exits 69 with the same reason.
* `copied_cr_outside_bundle_*`: exit 69 `helper_not_inside_app_bundle`. `channel_*`: `macAppStore` and missing
  marker give exit 69 `distribution_channel_not_direct` (and the fixture refuses to listen).
* `spoof_*`: an unsandboxed same-team, same-identifier, hardened listener is refused by the real `cr` with
  `peer_entitlement_missing` and receives 0 bytes. Binding that spoof inside a real sandbox container is denied
  (EPERM) in this environment, so it is run against a stub container directory of its own id
  (`...fixture.spooftry`). The EPERM result is recorded as `spoof_unsandboxed_cannot_bind_inside_real_container`.
* `peer-*`: a team-signed foreign identifier and an ad-hoc process using the genuine `com.clipboardrouter.cr`
  identifier are rejected by the fixture with `peer_requirement_failed` and receive 0 bytes. The peers must live
  inside the fixture's own bundle (`PeerHost.app`): code outside it is unreadable to the sandbox and fails earlier,
  but still closed, with `peer_code_unavailable_100001`.
* `peer-get-task-allow` / `peer-wrong-path`: team-signed, hardened peers using the genuine `com.clipboardrouter.cr`
  identifier are refused with `peer_entitlement_forbidden` (injection entitlement) and `peer_path_mismatch`
  (not `Contents/Helpers/cr`), each receiving 0 bytes.
* `initialize_accepts_*`: regression checks for the interop failure described under Findings.
* Cold runs (`E`): per-phase timings from both sides (`cold<N>-summary.txt`).
* Non-FDA host (`F`): the in-bundle `cr mcp` probe runs as a child of a dedicated ad-hoc `.app` whose bundle id is
  generated per run (`com.clipboardrouter.agentaccess.testhost.<runid>`, fresh cdhash) and which is launched with
  `open -n -W`. The `open` exit status is NOT evidence. The host writes `/tmp/cr-testhost-<runid>.json` (copied to
  `host-result.json`; unique path, deleted first, carries a random nonce and a `written_at` time) with
  `host_result=pass`, `exit_status=0`, `reason=exit`, the probe's full JSON report (`passed=true`) and
  `exact_synthetic_content_match=true` (the probe's exact-canary and exact-Vault-text checks). The host exits
  non-zero otherwise. `harness/check_host_result.py` asserts all of that plus nonce, freshness (mtime and
  `written_at` not older than the launch) and bundle id. PASS additionally needs what the host measures about
  itself: parent pid 1 (LaunchServices launch) and `responsibility_get_pid_responsible_for_pid` (private libSystem
  call, not a TCC read) naming the host as responsible for itself and for the probe. If any of those cannot be
  shown the check is `INCOMPLETE`, not PASS. "Never requested FDA" is true by construction (a never-before-seen
  bundle id and cdhash); TCC is not read or modified, so it is not independently measured. A blocked privacy prompt
  shows as a timeout (FAIL, "release gate pending").
* `stdio_tap.py` (self-test): metadata-only, byte-transparent, propagates EOF/exit status.
* Client interop (`--clients`): Claude Code and Codex are each run once with an isolated config and the tap in
  front of `cr mcp` (exact command lines are inline in `run_agent_access_harness.sh`, section H). PASS needs
  initialize, tools/list, `list_shared_clips` and `get_shared_clip` with isError false in the tap log AND the exact
  canary in the client's JSON output. A client that never reaches the server is recorded PENDING. The tap always
  runs with `--child-stderr`, so the raw `cr` stderr of each run is a dedicated artifact (`client-<name>.cr.err`,
  existence asserted). That artifact, the fixture (broker) log and the metadata-only tap logs must contain no
  canary/title/purpose/probe-client-name; `cr.err` and the fixture log must also not contain `claude`/`codex`;
  the client output must not contain anything never granted (excluded clip, second clip, Vault text, purpose).
  The client output necessarily contains the granted canary and the ALPHA title (they come from the prompt and
  the tool result), so no blanket "no canary" check is possible there.

NOT proven by the harness: the real app's UI, pairing sheet, scope picker, the real Vault, real clips, App
Store/TestFlight signing, notarized Developer ID builds, other macOS versions, or behaviour under a pristine TCC
database (the host check is fresh-identity by construction, not a TCC inspection). The fixture's Authority/Backend
wiring mirrors the documented contract but is not the app's code. The transport, identity derivation and `cr`
binary are production code; the app-side listener lifecycle, the controller and the SwiftUI pane are covered only
by the lead's unit tests and by the manual click-through below.

The acceptance-app script (below) additionally proves only: the real app + real `cr` build, are team-signed
hardened with only the non-restricted local entitlements (no application-identifier/team-identifier/keychain
groups/iCloud, no profile), launch under the acceptance gate and print `UI_ACCEPTANCE_READY`, and `cr mcp` from
inside that bundle resolves its identity, answers initialize/tools/list and fails closed (content-free
`socket_connect_errno_2`) while Agent Access is off. App-side availability, pairing and every tool result against
the real app are `INCOMPLETE` until a human enables the toggle and approves.

## Side effects

* Sandboxed fixture launches create synthetic containers `~/Library/Containers/com.clipboardrouter.agentaccess.fixture*`
  (main, `.adhoc`, `.store`, `.nochannel`, `.cold1-3`). They hold only `Data/m/s` while running (unlinked on stop).
  They are never removed.
* The spoof stub `~/Library/Containers/com.clipboardrouter.agentaccess.fixture.spooftry` is created by the script
  with `mkdir`; containermanagerd adopts it (a protected `.com.apple.containermanagerd.metadata.plist` appears)
  and it cannot be deleted from user space. Only its `Data` directory is removed after each run.
* Re-running reuses existing containers, so `--cold-runs` data is only a true first run the first time on a
  machine (`cold<N>-note.txt` records `container_preexisting`).
* Everything else lives in a `mktemp` directory removed on exit. The real app and its container are never touched.
* Each harness run registers one new LaunchServices record for its fresh TestHost bundle id (the `.app` itself is
  deleted with the temp directory; LaunchServices may keep a stale record) and creates `/tmp/cr-testhost-<runid>.json`
  (removed after copying into the log directory).
* `.artifacts/mcp-logs/harness/.run.lock` exists only while a run is active.
* The acceptance app creates (when launched, by the sandbox) `~/Library/Containers/com.clipboardrouter.ClipboardRouter.uiacceptance`
  (the filesystem is case-insensitive, so this is the same directory as the pre-existing `...UIAcceptance`
  container used by earlier acceptance runs), an isolated defaults suite `com.clipboardrouter.ClipboardRouter.uiacceptance.<run id>`
  and `<container tmp>/ClipboardRouterUIAcceptance/<run id>`. It builds into `/tmp/cr-acceptance-build` and writes
  a new `.artifacts/agent-access-acceptance/<UTC>/` per invocation (never overwritten, never auto-deleted).

## Limitations

Timing figures are from one machine. Signing uses a development certificate; hardened runtime is set but no
notarization is exercised. `mcp_probe.py` uses a restricted environment (`PATH`, `HOME` only). The
responsibility API used by the host check is a private libSystem symbol; if a future macOS removes it the check
degrades to `INCOMPLETE`. Pre-existing environment limits: unsandboxed processes cannot bind inside a real
sandbox container (EPERM) and the sandboxed fixture cannot read peer code outside its own bundle
(`peer_code_unavailable_100001`); both fail closed. The `...fixture.spooftry` stub container cannot be deleted
from user space (see Side effects). The acceptance script builds `ClipboardRouter` in release and takes several
minutes; the harness itself takes several minutes with `--clients`.

## Findings

* Codex interop (fixed): `cr mcp` used to answer `initialize` with JSON-RPC -32603 "The data couldn't be read
  because it isn't in the correct format" when the client sent `capabilities.experimental = {"codex/auth-change": {}}`
  (what Codex 0.163 sends); the MCP SDK's client-capability decoding is stricter than the spec. `cr` now drops
  object-valued `capabilities.experimental` before the SDK decodes it. Regression checks
  `initialize_accepts_experimental_only_capability` and `initialize_accepts_codex_capability_shape` and both client
  interop checks pass (run `20261022T171041Z`).
* Unsandboxed processes cannot bind inside a real sandbox container (EPERM), and the sandboxed fixture cannot
  read peer code outside its own bundle (`peer_code_unavailable_100001`); both are fail-closed.

## Manual click-through (real app UI, Settings > Agent Access)

Everything here uses synthetic fixture data only: the acceptance gate (`UIAcceptanceRuntime`) gives the app an
in-memory Vault and secure-share key store (no Keychain), an isolated defaults suite, a temp support directory and a
named pasteboard (your General pasteboard is not used). The build has no CloudKit or commerce configuration, no
provisioning profile and no URL scheme. Do not point it at, and do not expect it to show, any real clip or Vault item.
It is a different app from the real Clipboard Router (own bundle id and container).

1. Build the app from the repository root with a fresh package run (an app directory from an older checkout may predate
   fixes in the current source, so do not reuse one):
   `bash Scripts/mcp/package_agent_access_acceptance_app.sh [--team-identity "Apple Development: NAME (ID)"]`
   (add `--no-verify` to skip the automated launch/probe; its log is under `.artifacts/mcp-logs/acceptance-app/<UTC>/`).
   Each run writes a new `.artifacts/agent-access-acceptance/<UTC>/` directory and prints `== app:  <path>` at the end
   (also recorded as `app:` in the log's `summary.txt`). That printed path is the app to test.
2. Launch (the run id must match `[A-Za-z0-9._-]`):
   `APP="<path printed after '== app:' by the package script>"` (ends in `ClipboardRouter-AgentAccessAcceptance.app`)
   `open -n "$APP" --args --clipboard-router-ui-acceptance --ui-acceptance-run-id review-1`
   To see why the toggle is enabled or disabled without clicking, start the executable directly instead and read stderr:
   `"$APP/Contents/MacOS/ClipboardRouter" --clipboard-router-ui-acceptance --ui-acceptance-run-id review-1 2>"${TMPDIR:-/tmp}/agent-access-ui.err" &`
   It prints one content-free line, `AGENT_ACCESS_DIAGNOSTIC key=value ...` (fixed keys, `1`/`0` flags, and `resolve=ok` or the
   reason code), then `UI_ACCEPTANCE_READY`. The toggle is enabled exactly when `resolve=ok`. This line is emitted only in
   UI-acceptance mode, never in production. (`executablePathEqualsBundleExecutable=0` is expected: the signing path is the bundle.)
   Root cause of the earlier disabled toggle ("requires the sandboxed app"): the sandbox container directory keeps the letter case
   it was first created with (`...ClipboardRouter.UIAcceptance`) while the bundle id is `...uiacceptance`; the old exact-case
   suffix check failed (`homeHasExpectedSuffix=0`, `homeHasExpectedSuffixIgnoringCase=1`) and was reported as `app_not_sandboxed`.
   It is now a distinct `container_home_mismatch`. A case-only path alias is accepted only when `lstat` shows both the
   expected and the actual path are real directories (not symlinks) with identical device and inode; anything else fails closed.
   The app is a menu-bar app (no Dock icon): use its menu-bar item, then Settings, then the Agent Access pane.
   Without the two arguments the dedicated bundle id fails closed (it never falls through to production paths).
   If macOS shows a first-launch prompt (for example for a new signer), answer it yourself; nothing here automates it.
3. In Settings > Agent Access turn on "Allow local AI agents to read clips you choose". The toggle is disabled with a
   reason if availability is not met (team-signed, sandboxed, direct channel); that reason is what to report.
4. Under "Shared with agents" select one or more saved clips or folders (the fixture has a saved note named
   "Acceptance Editable Note"; history is never shared).
5. Synthetic Vault item: open the Library, select a saved clip, choose "Move to Vault" (add your own synthetic clip
   first, e.g. a note containing `SYNTHETIC-VAULT-TEST-1`). The Vault section's "Unlock Vault" uses a stub
   authenticator in this build (no Touch ID / password). Do not move real text in.
6. Point an MCP client at the helper inside the app (a symlink to it also works, a copy does not):
   command `"$APP/Contents/Helpers/cr"`, args `["mcp"]`. Without touching any global config, for Claude Code write a
   file `mcp.json` with `{"mcpServers":{"clipboard_fixture":{"command":"<APP>/Contents/Helpers/cr","args":["mcp"]}}}`
   (substitute the absolute value of `$APP` for `<APP>`)
   and run `claude --strict-mcp-config --mcp-config mcp.json`; for Codex pass
   `-c 'mcp_servers.clipboard_fixture.command="<APP>/Contents/Helpers/cr"' -c 'mcp_servers.clipboard_fixture.args=["mcp"]'`
   to a one-off `codex exec --ignore-user-config ...`. Equivalent interop command lines are in
   `run_agent_access_harness.sh` section H (they add the metadata-only `harness/stdio_tap.py` in front of `cr`).
7. When the client first calls a tool, `cr` prints `approve pairing code NNNNNN in Clipboard Router` on stderr and the
   pane shows a "Connection requests" row with the same code. Compare the code and click Approve or Deny yourself.
   Unapproved or expired requests return content-free errors. A Vault request appears under "Vault requests" and needs
   an unlocked Vault plus an explicit item choice.
8. Quit with the menu-bar Quit item. Removing synthetic state is optional: the container above and
   `<container tmp>/ClipboardRouterUIAcceptance/<run id>`.

Manual verification note (2026-10-22, synthetic data only): a maintainer completed this click-through by hand on a signed
acceptance build, including pairing approve/deny, scope changes, and a synthetic Vault share-once, deny and revoke. A later
build confirmed the same-inode case-alias check above. Local, git-ignored evidence: `.artifacts/mcp-real-ui-acceptance.md`.
This does not exercise real data: the automated harness alone does not prove the real UI, and real Touch ID/password
unlock, the real Keychain/Vault and live CloudKit/iCloud remain untested.
