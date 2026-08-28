# Clipboard Router interaction and polish audit

Date: 2026-08-11  
Build audited: private local build artifact; not published
Release artifact: private local build artifact; not published

## Outcome

The primary journey now reads as **Find → Keep → Use → Protect**. Library navigation remains visible across History, Saved, Notes, Actions, Clipboard Health, Vault, and iCloud. Collection views keep the familiar list-and-detail layout, while dashboards use the full content area instead of exposing a misleading empty or static middle column.

The pass also fixed functional inconsistencies found by clicking through the app: Assistant engine availability, direct Cloud setup routing, async installed-app discovery, application selection, clip-to-note discoverability, dynamic secret masking, workflow safety, Keychain validation, and duplicated or stale action presentation.

## Journey audit

1. **First run and capture** — onboarding explains capture, privacy, organization, and explicit actions. Capture can be paused from the sidebar with a visible status.
2. **Library and navigation** — the persistent sidebar now follows the journey explicitly: Find contains History and Browse; Keep contains Saved, Notes, Pinned, folders, iCloud Sync, and export; Use contains Actions; Protect contains Clipboard Health, Vault, and Private Session. Settings is directly accessible from the bottom of the sidebar.
3. **Find** — the toolbar search covers content and metadata; Browse expands into Today, Frequently Used, Links, Images, Files, PDFs, Unfiled Saved, Apps, and Domains. App and domain facets remain collapsed until needed.
4. **Keep and organize** — plain clips expose Save, Make Note, Edit a Saved Copy, folder placement, pinning, tags, drag-and-drop, sharing, and export. Rich or media-backed content fails closed where note conversion would lose information.
5. **Notes** — Notes has a visible Create Note control with the `⌘⇧N` hint. The editor supports title, Markdown body, and folder choice. Converting History to a note leaves the original History item unchanged.
6. **Use** — the detail view leads with Copy, one contextual action, and More. More groups organization before advanced workflows. Quick Paste focuses on saved clips and notes, supports search and shortcuts, and keeps alternate paste delivery behind Paste Options.
7. **Assistant** — a plain-text clip exposes Ask Assistant. On-device processing completed a real synthetic request and returned a draft. Cloud mode clearly reports that it is unconfigured and routes Set Up Cloud directly to Settings > Assistant. No Cloud request is sent without an explicit configured key and Send click.
8. **Actions** — Actions now renders beside the persistent sidebar, without the former Context Pack/Paste Stack phantom column. Custom Actions and One-click Destinations have distinct empty states and creation controls. Application targets open a searchable signed-app browser and do not preselect an unrelated app.
9. **AI handoffs and apps** — Settings > AI Handoffs discovers installed applications asynchronously, remains responsive while verification runs, and explains that handoff copies and opens without submitting. The general Copy & Open browser remains available from clip actions.
10. **Protect** — Clipboard Health distinguishes quarantine from retained masked items. Dynamic secret detection also protects legacy items missing stored sensitivity metadata from preview, menu search, workflows, sharing, and unconfirmed export.
11. **Private Session** — starting and ending the session produced clear status feedback. New content stays memory-only and is destroyed when the session ends.
12. **Vault** — the local QA build truthfully reports that Vault requires an Apple Developer-signed build. The ordinary Library remains usable and Vault content stays hidden.
13. **iCloud** — the local-only build truthfully disables iCloud, explains what can sync, and keeps History, Vault, quarantine, Private Session, rich assets, and local file references outside the sync path.
14. **General health** — keyboard labels, VoiceOver descriptions, disabled states, loading states, empty states, and confirmation boundaries were inspected. The final automated run passed 385 XCTest cases plus 5 Swift Testing cases.

## Evidence

- [Polished Library](10-library-final.png)
- [Actions hub](07-actions-hub-final.png)
- [Application browser](08-one-click-app-browser-final.png)
- [On-device Assistant response](06-assistant-response-final.png)
- [Assistant settings](09-assistant-settings-final.png)
- [Clipboard Health](11-clipboard-health-final.png)

## Verification

- `swift test`: 385 XCTest tests passed, 0 failures; 5 Swift Testing tests passed.
- Release bundle passes `codesign --verify --deep --strict` and `Scripts/verify_release.sh --profile local`.
- Bundle ID: `com.clipboardrouter.ClipboardRouter`; version `0.1.0 (1)`; minimum macOS `14.0`.
- The QA run used a separately named local-only build. Screenshots retained for handoff omit private clip contents, and the audit did not intentionally delete ordinary saved data.

## Boundaries not claimed as complete

- Cloud Assistant was not called because no test credential was installed and doing so would transmit clip content externally.
- iCloud and shared-folder propagation were not tested across two signed Macs and two Apple accounts; this local profile has no CloudKit entitlement.
- Vault unlock was not exercised because the local ad-hoc build correctly lacks the required Apple Developer signing capability.
- macOS permission prompts were not granted during this pass.
- Destructive delete/export-overwrite confirmations were inspected or covered by tests, not committed against user data.
- The macOS status-item popover could not be attached directly through the accessibility harness. Its shared model actions, sheets, and safety policies were validated through the Library surface and automated tests; this is not a claim of pixel-complete status-item traversal.

## Remaining non-blocking follow-up

- Surface a nonfatal migration warning when cleanup of a legacy fallback Keychain item fails. The protected credential is preserved and current save/load validation fails closed, so this is diagnostic polish rather than a release blocker.
