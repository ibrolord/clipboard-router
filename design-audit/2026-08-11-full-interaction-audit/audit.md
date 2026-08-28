# Clipboard Router full interaction audit

Date: 2026-08-11

Surface: native macOS Library, command menus, Settings, clip menus, Quick Paste, Workflows, folder actions, sync, and Private Session.

## Outcome

The click-through found and corrected inconsistent behavior that a build-only review missed:

- Replaced the multi-window `WindowGroup` with a single Library window. The File menu no longer creates duplicate Library windows sharing one `AppModel`.
- Disabled empty pinned-note commands and renamed the preferred-app command to match Copy & Open.
- Reordered row, detail, and menu-bar actions around one hierarchy: edit/organize/protect, share/export, optional tools, Assistant, delete.
- Replaced the row menu's legacy hard-coded AI-app picker with the searchable verified application browser.
- Standardized `Automation` versus `One-click Destination` language.
- Made unavailable CloudKit folder sharing visibly disabled with an explanatory help message.
- Corrected the active Private Session empty-state copy.
- Rebuilt Workflows with a grouped form so its accessibility hierarchy no longer cycles or crashes the inspection service.
- Corrected export format capitalization (`Markdown`, `CSV`, `JSON`).
- Reworked onboarding around Find, Keep, Protect, and Share/Act; optional AI routing no longer gets its own final spotlight.

## Interaction steps

1. Library navigation — healthy after fixes. History, Saved, Vault, dynamic Browse filters, Clipboard Health, Workflows, iCloud Sync, and Private Session all selected the expected state.
2. Library command menus — healthy after fixes. Duplicate-window creation is removed; pinned-note commands are disabled when their target does not exist.
3. Saved note creation and editing — healthy. The note editor reports its local/sync boundary and the saved note exposes Copy, Edit, semantic actions, and Details.
4. Clip row and detail menus — healthy after fixes. Organization and protection actions precede sharing and optional tools; Copy & Open uses the same app browser from both surfaces.
5. Quick Paste — healthy. Empty, search, result, preview, copy/paste, paste options, and shortcut editing states are coherent and keyboard-labelled.
6. Folder actions — healthy with an environment limitation. New folder, subfolder, rename, drag/drop targets, and research handoff opened correctly. Sharing is now disabled with an explanation in an unsigned build.
7. Workflows — healthy after fixes. Context Pack, Paste Stack, paste-permission status, and transform states have a finite accessible hierarchy.
8. iCloud Sync — truthful blocked state. The unsigned QA build explains why CloudKit is unavailable and keeps its controls disabled.
9. Private Session — healthy after fixes. The active empty state now says new clips stay only in memory, and ending the session confirms that its in-memory clips were cleared.
10. Settings — healthy. General, Automations, Apps, AI, iCloud, and Privacy tabs expose their expected controls and safety copy.

## Evidence

- `04-icloud-sync.png` — truthful unsigned-build sync state.
- `05-private-session-empty-state-bug.png` — original incorrect active-session copy.
- `06-final-organized-library.png` — final Library hierarchy.
- `07-final-note-detail.png` — final saved-note detail hierarchy.
- `08-final-workflows.png` — final Workflows layout and accessible control hierarchy.
- `09-final-private-session.png` — corrected active Private Session empty state.

## Verification

- `swift build --disable-sandbox` passed.
- `swift test --disable-sandbox --filter ClipboardRouterAppTests` passed: 77 tests.
- `swift test --disable-sandbox` passed: 381 XCTest tests plus 5 Swift Testing tests.
- `swift build -c release --disable-sandbox` passed.
- Ad-hoc packaged release passes `codesign --verify --deep --strict`.

## Limits

- The native macOS status-item window is not exposed as a target by the available Computer Use service when the Library window is also present. Its shared policies, action ordering, presentation-surface routing, and menu-bar integration tests were verified, but this run does not claim a fresh pixel-level click of every status-item submenu.
- Delete, Clear History, publishing a team template, enabling sync, requesting protected macOS permissions, writing Contacts/Calendar, and sending a hosted Assistant request were stopped before their consequential final action.
- CloudKit collaboration still requires a correctly signed Apple build and a live two-account/two-Mac verification matrix.
