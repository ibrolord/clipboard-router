# Clipboard Router visual QA

## Evidence

- Source and menu references: private local review inputs; not published with the repository.
- Final packaged implementation: `.artifacts/visual-final-main-window.png`
- Side-by-side comparison: `.artifacts/visual-comparison-main.png`
- Reference dimensions: 2170 x 1400 px.
- Captured implementation viewport: 1080 x 700 px.
- Comparison canvas: 2160 x 700 px, with the reference normalized to the implementation viewport.

## Full-view comparison

- The Security section and device-status footer are now separate layout regions. `Start Private Session`, `Capturing`, and the pause shortcut no longer collide with `Clipboard Health`.
- History remains readable at the narrower implementation viewport, with stable three-column proportions and no clipping at the bottom of the sidebar.
- Relative times render at minute granularity (`54 min`, `1 hr, 37 min`) with no live seconds countdown.
- The captured image appears as a thumbnail in History, and the Images smart view reports one item.
- Existing hierarchy, dark materials, SF Symbols, typography, dividers, and accent colors remain consistent with the reference.

## Focused checks

- Layout: passed. Footer has dedicated height and separation from the scrolling sidebar.
- Typography: passed. Existing macOS system typography and weights are preserved.
- Color and contrast: passed. No new low-contrast text or mismatched surfaces were observed.
- Image treatment: passed. The final package renders an actual image thumbnail instead of a text-only placeholder.
- Timestamp copy: passed. Seconds were removed without losing useful age context.
- Link presentation: implemented as a privacy-safe stored-metadata card with explicit Open Link; no automatic network fetch occurs.
- Menu actions: Pin/Pin & Save and Move to Vault are covered by model and workflow tests, including disabled, retry, collaboration, and confirmation-scope cases. The packaged library context menu was inspected live and showed Copy, Save to Folder, Share Clip, Export Clip, Workflows, and Open in AI in the intended management-first order. Menu-extra Vault confirmation remains automated rather than mutating the user's live library during QA.
- Organization actions: menu rows now expose Save to Folder or Move to Folder before secondary AI routing. Folder menus show complete nested paths and can create a new root folder. The library sidebar supports recursive subfolders and ID-only drag payloads for clips, notes, and folders.
- Notes: New Note is available from the toolbar and menu bar. Notes can be edited, pinned, searched, dragged, moved to folders, and moved to Vault without losing their note kind. Editing title, body, and folder is one atomic mutation. Secret-bearing manual notes fail closed before ordinary persistence with Vault guidance.
- Conversion: Convert to Note appears only for safe plain-text and URL clips. Rich, image, OCR, asset-backed, and file clips retain their original representations and cannot enter the lossy editable-note path.
- Keyboard workflow: separate configurable global shortcuts open clipboard search and New Note; `Command-K` focuses content-and-metadata search, `Command-Shift-N` creates a note, and numbered commands select pinned notes.
- Hover preview: menu rows now reveal a 360 x 280 full-content popover after a 350 ms stable hover. Text is selectable and independently scrollable, image clips use the existing local thumbnail loader, duplicate file names remain visible, and Private Session clips expose neither the popover nor a dead accessibility action. `Show Full Clip...` provides the keyboard and VoiceOver path; focused preview tests passed 8/8.
- Packaged UI inspection: the release artifact exposed Notes, nested folder disclosures, New Note, metadata search, image counts/thumbnails, separate Security and Workflows sections, and an unobstructed capture footer in the live accessibility tree and screenshot.
- Launch behavior: passed. The final packaged binary was monitored for 20 seconds with clean stderr; the earlier one-time `NSTableView` reentrancy warning no longer occurs.

## Comparison history

1. Reference showed a mangled bottom-left sidebar and no visible image count.
2. First packaged pass removed the overlap, rendered minute-only timestamps, and displayed the captured image thumbnail.
3. Final packaged pass retained those visual fixes after the Vault transaction, collaboration-safety, and launch-selection corrections.

## Earlier pass result

The visible reference regressions were resolved in the packaged artifact; protected menu interactions were covered by automated tests.

## August 10 note, editing, and routing pass

### Evidence

- Notes, routing, and menu-bar references: private local review inputs; not published with the repository.
- Final implementation screenshots: `.artifacts/design-qa/final-notes-view.png`, `.artifacts/design-qa/final-note-composer.png`, `.artifacts/design-qa/final-clip-detail.png`, and `.artifacts/design-qa/final-clip-editor.png` (1080 x 700 px each).
- Combined comparison inputs: `.artifacts/design-qa/comparison-notes.png` and `.artifacts/design-qa/comparison-routing.png` (2160 x 700 px each).

### Comparison and fixes

1. The reference Notes screen exposed no direct creation action and used a generic clip-empty state. The final screen has a visible `New Note` action in the Notes header, note-specific counts and copy, and a native composer that keeps the draft present until persistence succeeds.
2. The reference detail view gave ChatGPT, Claude, and Codex disproportionate visual weight. The final view consolidates them under a secondary `Open in…` menu and states that Clipboard Router copies and opens the chosen app but never submits content.
3. The first implementation pass put all workflow actions on one row; labels truncated at the 1080 x 700 QA viewport. The final pass separates organization/workflow controls from `Share…` and `Open in…`, so `Add to Context Pack`, `Add to Paste Stack`, `Transform`, `Share…`, and `Open in…` are all fully visible.
4. History text and URL items now expose `Edit a Saved Copy…`, explicitly preserving immutable History. Saved text, URL clips, and notes expose direct editing where collaboration permissions allow it. Rich, image, file, and Vault items remain outside the lossy editor path.
5. The final side-by-side comparison preserves the existing macOS materials, typography, spacing, hierarchy, and SF Symbols. No cropped controls, overlapping regions, or clipped labels remain in the inspected states.

### Verification

- Source verification passed with 305 XCTest tests and 5 Swift Testing tests, with zero failures.
- Focused editing and concurrency coverage passed: 13/13 core hierarchy tests and 48/48 application workflow tests.
- The packaged application passed bundle, minimum-system, entitlement-profile, and signature verification.
- The final application checksum is `21abfa51d5c680622d5a529bd47b97ea214f7a4f556e872dd10bf125b6856989`.
- Correctness and architecture reviews were run twice. Reported draft-loss, shared-permission, provenance, stale-write, and save/cancel race issues were corrected before this final comparison.

final result: passed
