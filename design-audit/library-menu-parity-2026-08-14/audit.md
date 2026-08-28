# Library action parity audit

## Step 1 — Reported menu-bar actions

Health before fix: inconsistent.

- Reference: `00-menu-bar-reference.png`
- History clips exposed `Pin & Save` and a visible Vault affordance in the menu-bar surface.

## Step 2 — Reported Library actions

Health before fix: incomplete.

- Reference: `01-library-gap-reference.png`
- The equivalent Library context menu omitted `Pin & Save` and the Vault affordance.

## Step 3 — Rebuilt packaged Library menu

Health after fix: pass.

- Exact artifact: `.artifacts/ClipboardRouter.app`
- Packaged accessibility inspection exposed the following actions for an ordinary History item:
  `Copy`, `Save to Folder`, `Pin & Save`, disabled `Move to Vault…` with its signing reason,
  `Share Clip…`, `Export Clip…`, `Copy & Open…`, `Clip Tools`, and `Delete`.
- Editing, note conversion, Quick Actions, and AI remain content- and safety-dependent rather than
  being presented as working actions for unsupported image, file, sensitive, or rich-media items.

## Step 4 — Show in Library handoff

Health after fix: pass at source and packaged build gates; direct status-item automation is limited.

- Every menu-bar Library handoff now uses `LibraryWindowPresenter`.
- It promotes the accessory process to the regular desktop activation policy, opens the Library,
  unhides and activates the app, deminiaturizes the Library window, and explicitly makes it key.
- The release artifact passed local signature/entitlement verification.
- Computer Use could inspect the packaged Library window and its context menu, but could not target
  the macOS status item directly; a human click remains the final status-item-specific check.

## Accessibility notes

- The repaired context menu exposes system labels and disabled-state help through macOS accessibility.
- Screenshot evidence alone does not establish a complete VoiceOver or keyboard-navigation pass.
