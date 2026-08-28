# Clipboard Router completion acceptance registry

This registry separates three claims that must not be conflated:

- **Source-proven**: production code compiles and focused automated tests exercise the contract.
- **Packaged-proven**: the fresh `.app` was launched and the user-visible workflow completed through the real macOS UI.
- **External-proven**: a signed customer artifact completed the workflow against the real Apple/provider service.

`PASS` requires the evidence named in the row. A source test cannot satisfy a packaged or external gate.

## Local product journeys

| Journey | Source gate | Packaged gate | Current status |
|---|---|---|---|
| Menu-bar capture, search, pinned/recent rows, configurable 1–1,000 limit | Full Swift test suite; clip-limit model tests | Open real status item; render rows; scroll/copy row 1, 100, and 1,000; relaunch persistence | Source PASS; historical packaged evidence exists, but the current exact artifact is UI-NOT-PROVEN because the latest run was stopped by the locked-console preflight |
| Persistent Library desktop app | Library presenter/reopen tests | Open from menu, close/minimize, reopen from menu and Dock/App Switcher | Source PASS; historical packaged receipts exist, but current exact-artifact UI is NOT PROVEN because the locked-console preflight prevents menu interaction |
| Settings discoverability and layout | Settings parsing/navigation tests | Open from Library and menu; visit seven tabs at minimum/normal/large sizes; verify clip limit persistence | Source PASS; historical 24-image matrix and packaged limit evidence are retained, but current exact-artifact UI proof is not rerun on the latest source because the console is locked |
| Menu-bar continuation actions | Continuation and presenter tests | From a clip, open and complete/cancel Edit, Note, Folder, Vault, Shortcut, Project, Calendar, AI, app browser, flow, Share, and Export after menu closes | Source PASS; historical packaged receipts cover a subset, but current exact-artifact UI proof is NOT PROVEN because the locked-console preflight prevents menu interaction |
| Library/menu action parity | Shared action-catalog tests | Compare actual rendered inventory/order/enabled reasons for representative clip states and activate every action | Source inventory PASS; packaged activation pending |
| Notes and clip editing | Core/app workflow tests | Create note, convert History without mutation, edit saved copy, relaunch | Source PASS; historical packaged receipts cover New Note and saved-copy edit, but conversion/relaunch and current exact-artifact UI are NOT PROVEN |
| Assistant | Hosted/on-device boundary and preset tests | Open Ask/Extract/Rewrite/Format/Follow-up/Research; preserve compact sheet; cancel; copy/save reviewed result; show unconfigured/error states | Source PASS; historical packaged receipts cover the persistent Rewrite/no-send boundary; the current exact-artifact UI is NOT PROVEN and live engines remain external |
| App browser and Copy & Open | discovery/signature/clipboard tests | Search installed apps, choose, cancel, stale/failure state, successful verified launch | Source PASS; historical packaged receipts cover presentation/search/cancel; current exact-artifact launch and failure states are NOT PROVEN |
| Actionable link/email/phone/date | detector/executor tests | Open reviewed URL/email/call drafts; save Contact; create Calendar draft; cancel/permission errors | Source PASS; Contacts/Calendar system writes external |
| Custom actions and safe regex | matcher/flow tests | Create literal and regex matchers; preview; edit; reject unsafe regex; run once | Source PASS; historical v3 packaged run attempted but follow-up-note rendering and definition/relaunch checks failed; current exact artifact NOT PROVEN while console is locked |
| Multi-step flows and folder triggers | flow engine, durable ledger, app tests | Create `tag -> move -> open/review`; trigger on local folder entry; resume after relaunch; truthful partial failure | Source PASS; historical v3 packaged run attempted but follow-up-note rendering/relaunch failed; current exact artifact NOT PROVEN while console is locked |
| CRM review and receipts | connector/app tests | Unconfigured setup CTA; review fields; cancel; local error/reconcile UI | Source PASS; live Salesforce/HubSpot external |
| Auto Organize | Core/app CRUD, stale/atomic tests | Create/edit/reorder/pause/delete literal and regex rules; Apply Once/Always/Never; undo; relaunch | Source PASS; historical v3 packaged run attempted but Always to Suggest and edited-rule relaunch failed; current exact artifact NOT PROVEN while console is locked |
| Smart Views and bulk actions | Core/app tests | Create/edit/pin/reorder/delete saved view; multi-select and execute bulk save/move/tag/pin/export | Source PASS; historical v3 packaged run attempted but three-row selection did not advance; current exact artifact NOT PROVEN while console is locked |
| Sales workspace, tags, folder handoff | sales feature tests | Create workspace, tag/move research, review omission report, export Markdown/CSV/JSON | Source PASS; historical v3 packaged run attempted but New Sales Workspace discovery and relaunch persistence failed; current exact artifact NOT PROVEN while console is locked |
| Developer projects and Debug Bundles | workspace/platform/CLI/app tests | Create/select/activate project; capture app scope; build/reorder/save/share bundle; IDE handoff | Source PASS; historical v3 packaged run attempted but Debug Bundle reorder and relaunch persistence failed; current exact artifact NOT PROVEN while console is locked |
| Quick Paste, aliases, and text expansion | Core/platform/app tests | Search/paste; create/edit alias; supported editor expansion; secure/excluded blocking; Escape restoration | Source PASS; system Accessibility run external |
| Clipboard Health, Private Session, Vault | secret/Vault/app tests | Quarantine/Keep/Delete/Vault actions; no plaintext; lock/relaunch/secure paste; private teardown | Source PASS; signed Keychain/authentication run external |
| Live link preview | pinned Network.framework transport and policy tests | Explicit Load only; blocked action URL; redirect/error/offline/clear state; no selection-time request | Source PASS; packaged pending |
| Start at Login | service/model tests | Toggle installed app; approve if required; logout/login; one process/status item; disable and repeat | Source PASS; installed signed run external |
| Capture context | Core/platform/app tests | Explicit consent; no prompt on refresh; coarse local label only; disable/clear; denied state | Source PASS; real TCC/location run external |
| Accessibility | labels and focused unit tests | Keyboard-only critical journeys, VoiceOver labels/order, Reduce Motion, Increase Contrast, text scaling | Source PASS; historical AX evidence exists, but current exact-artifact packaged accessibility is NOT PROVEN because the screen-locked preflight prevents the run |
| Performance and reliability | 10k search fixture and restart tests | Warm menu latency, bottom-scroll latency, peak memory/CPU, crash/relaunch recovery on exact artifact | Source PASS for 10k search and 1k deferred menus; historical packaged evidence exists, but current exact-artifact latency/memory/relaunch budgets are NOT PROVEN because the locked-console preflight prevents the run |

## External release gates

| Capability | Required evidence | Current status |
|---|---|---|
| Customer distribution | Universal Developer ID app, secure timestamp, notarization, staple, Gatekeeper, clean install, signature-bound manifest and source revision | NOT PROVEN; current artifact is arm64 ad-hoc engineering build |
| Personal iCloud sync | Signed container/profile/schema; two Macs on one account; text/rich/image/offline/conflict/quota/push; pasteboards unchanged | NOT PROVEN |
| Shared workspaces | Two Macs/two accounts; invite/accept; owner/editor/viewer; revoke/account switch/conflict/recovery | NOT PROVEN |
| Hosted Assistant | Real Keychain credential, explicit consent, provider request/stream/citations/rate-limit/error, `store=false`, reviewed save | NOT PROVEN |
| Apple Intelligence | Supported macOS 26 Mac with model ready; Ask/Rewrite/Extract/Format/Follow-up/Research quality and failure states | NOT PROVEN |
| Salesforce | Sandbox external app, PKCE callback, scopes, create/update/duplicate/refresh/revoke/reconcile | NOT PROVEN |
| HubSpot | Deployed HTTPS broker holding client secret, test account, OAuth/scopes and write lifecycle | NOT PROVEN |
| Direct licensing | Staging trial/activation/restore/revocation/outage service and production P-256 key | NOT PROVEN |
| Contacts, Calendar, Location, Accessibility, Launch at Login | Signed installed artifact; isolated TCC states and actual records/session restart | NOT PROVEN |

## Evidence required for final sign-off

Current local evidence:

- Current source suite: 725 XCTest + 5 Swift Testing tests, zero failures. Release compilation and local artifact verification pass.
- `.artifacts/ClipboardRouter-UIAcceptance.app`: fresh arm64 ad-hoc engineering artifact rebuilt from the current source; `Scripts/verify_release.sh --profile local` passes, binds the embedded and adjacent manifests, and includes a deterministic `sourceTreeHash`.
- `Scripts/run_packaged_ui_acceptance.sh`: latest fresh run performs package verification, then exits 77 before UI interaction because `SessionAvailability` reports a locked screen. No current packaged workflow is claimed from that run.
- Historical `.artifacts/ui-acceptance/` reports remain useful as historical receipts only; they are not current-source proof. In addition to the schema-v3 workflow failures, post-schema-v3 attempts `20260816T072611Z-8240` and `20260816T072703Z-19858` failed before any case because Finder did not become frontmost, and `20260816T072936Z-42509` failed before any case because the status item did not open the menu. These are disclosed launch/runner failures, not passes or environmental skips.
- `.artifacts/settings-visual/final-20260815-v2/`: 24 composited native Settings PNGs plus manifest and verified hashes.
- `design-audit/completion-2026-08-15/surface-visual-evidence/`: menu, Library, Note, Edit, and compact Assistant app-only PNG evidence plus verified hashes.
- `package-production.log` and `release-local.log`: fresh `com.clipboardrouter.ClipboardRouter` local artifact and bundled CLI verified.
- `evidence-sha256.txt`: exact hashes for the local app executable, CLI, manifest, passing report, AX dump, and screenshot.
- Independent Claude Opus Max review: current overall verdict **FIX**. Source/release gates are locally green, but historical packaged workflow failures are real attempted failures and interactive UI is **NOT PROVEN** while the console is locked. External gates remain **NOT PROVEN**.

Final customer sign-off still requires performance measurements, the broader packaged action/layout/accessibility matrices, and external-provider receipts where applicable. The independent Claude Opus Max review is complete; it classifies source/release engineering as locally green but the overall completion claim as FIX until the local workflow failures are repaired and one fresh schema-v3 packaged run passes against the exact artifact. Interactive UI and external gates remain NOT PROVEN.
