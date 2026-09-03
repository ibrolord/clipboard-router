<div align="center">

<img src="https://ibrolord.github.io/clipboard-router-releases/product/icon.png" width="96" alt="Clipboard Router">

# Clipboard Router

**Work from your clipboard toward 20× productivity.**

Clipboard Router is a macOS clipboard manager for people who copy and paste all day. It keeps
captured clips ready to reuse, lets you run reviewed actions, and gives you explicit controls for
sensitive clips. The 20× target applies to repetitive, clipboard-heavy workflows and is not a
promise for every task.

[Download for macOS](https://github.com/ibrolord/clipboard-router-releases/releases/latest) ·
[Use cases](#use-cases) ·
[All features](#all-features) ·
[Privacy](https://github.com/ibrolord/clipboard-router-releases/blob/main/PRIVACY.md)

<img src="https://raw.githubusercontent.com/ibrolord/clipboard-router-releases/main/landing/public/product/plate-hero.png" width="960" alt="Clipboard Router history listing recent clips with search and filters">

</div>

## What you get

- **Copy several items and paste them in order** — add each one to Paste Stack, then copy them back
  to the system clipboard in order as you paste.
- **Recover something you copied earlier** — search past text, links, images, and files by content,
  app, domain, type, or date.
- **Transform content before pasting** — trim whitespace, normalize line endings, change case, wrap
  text as a Markdown quote or code block, format JSON, strip terminal ANSI codes, or URL-decode text.
- **Protect and share secrets** — Clipboard Router flags secret-like clips for review, encrypts clips
  you deliberately move to Vault, and can encrypt eligible text or URLs for a public key you have
  verified out of band.

## Use cases

- **Research:** Collect excerpts and links in Projects or Smart Views so your sources are searchable
  when it is time to write.
- **Debugging:** Group copied logs, stack traces, and snippets into a Developer Project, then create
  a reviewed Markdown bundle for your IDE.
- **Text cleanup:** Trim whitespace, normalize line endings, change case, wrap text as a Markdown
  quote or code block, format JSON, strip terminal ANSI codes, or URL-decode text before pasting.
- **Repetitive operations:** Let Auto Organize suggest where clips belong, run reviewed local steps
  from folders, and copy queued items back in order with Paste Stack.
- **Cross-app actions:** Turn copied links, email addresses, phone numbers, and dates into reviewed
  app actions, Contacts entries, or Calendar drafts.
- **Secret handling:** Detect secret-like clips, move eligible items into Vault, or encrypt eligible
  text or URLs for a public key you have verified out of band.

## Actions you control

A saved clip can start the next step. Run an Action yourself or when a saved clip enters a chosen
folder. Actions can tag or file the clip, create a follow-up note, open a website or signed app, or
add on-device AI enrichment. New templates start switched off, external steps wait for review, and
Clipboard Router never presses Send for you.

<p align="center">
<img src="https://raw.githubusercontent.com/ibrolord/clipboard-router-releases/main/landing/public/product/plate-actions-control.png" width="780" alt="A custom action listed as manual and switched off until it is enabled">
</p>

## All features

<details>
<summary>Capture and find</summary>

- **Searchable clipboard history** — Capture text, URLs, RTF, HTML, images, and file references in
  their original forms.
- **Menu-bar Quick Paste** — Preview or copy pinned and recent clips from the menu bar, or paste
  into the previously active app.
- **Advanced search filters** — Search by content, app, domain, type, device, coarse location,
  secret category, date, folder, tag, or recency.
- **Smart Views** — Save and manage reusable searches that stay on your Mac.
- **OCR, previews, and clip details** — Read image text locally and inspect previews, provenance,
  dimensions, size, word count, duplicates, and paste count.
- **Capture context** — Optionally add a Mac label or coarse location. Exact coordinates are never
  stored.
- **App exclusions and pause controls** — Exclude apps from capture or pause clipboard monitoring at
  any time.

</details>

<details>
<summary>Save and organize</summary>

- **Saved clips and editable notes** — Save clips, create notes, or turn text and URLs into notes
  without changing History.
- **Nested folders, tags, and drag-and-drop** — Use unlimited nested folders and tags, then move
  items by menu or drag-and-drop.
- **Bulk library actions** — Review a selection before saving, moving, tagging, pinning, or
  exporting it.
- **Auto Organize** — Preview local filing rules by type, domain, app, entity, or safe pattern, then
  undo changes.

</details>

<details>
<summary>Combine and automate</summary>

- **Combine Clips** — Combine several eligible clips into one reviewed piece of context.
- **Paste Stack** — Queue clips and copy them back to the system clipboard in order as you paste.
- **Deterministic transforms** — Trim whitespace, normalize line endings, change case, wrap text as
  a Markdown quote or code block, format JSON, strip terminal ANSI codes, or URL-decode text.
- **Reviewed Custom Actions** — Build reviewed steps for tagging, moving, enrichment, web tasks, and
  app handoffs.
- **Folder triggers and durable recovery** — Run local tagging and filing steps when a clip enters a
  watched folder, queue external or review-required steps for approval, and recover after relaunch
  without repeating uncertain work.
- **Archive export and macOS sharing** — Export reviewed material as an archive or share it through
  macOS.

</details>

<details>
<summary>Act across apps</summary>

- **Actionable links, emails, phone numbers, and dates** — Turn detected links, emails, phone
  numbers, and dates into explicit actions.
- **Verified ChatGPT, Claude, and Codex routing** — Confirm the signed destination app before
  changing the clipboard, with no silent website fallback.
- **Contacts and Calendar drafts** — Review drafts before granting permission or creating a contact
  or event.
- **Salesforce and HubSpot connectors** (Engineering preview) — Not available in v0.1.0; provider
  authorization and production verification remain before release.
- **Live link previews** — Load previews only when requested, with clear handling for redirects,
  errors, offline pages, and unsafe actions.

</details>

<details>
<summary>Assistant and insert</summary>

- **On-device Assistant** — Draft and analyze clips with Apple Foundation Models on supported macOS
  26 Macs.
- **Hosted Assistant** (Engineering preview) — Not available in v0.1.0; hosted AI remains an
  engineering preview.
- **Assistant workflows** — Use chat and presets for answers, rewrites, formatting, drafts,
  enrichment, and opt-in research. Review every result.
- **Insert Palette and aliases** — Insert saved clips or notes through local semicolon aliases
  without duplicating their contents.
- **System-wide Text Expansion** — Expand exact aliases after Accessibility access, block secure
  fields, and immediately restore the alias with Escape.

</details>

<details>
<summary>Protect sensitive content</summary>

- **Clipboard Health and quarantine** — Detect secret-like values in text and OCR, then review
  whether to keep, delete, or move them to Vault.
- **Private Session** — Keep new clips in memory, then destroy them when the session is cleared or
  ended.
- **Vault** — Encrypt selected text, rich text, HTML, images, and bounded file-reference payloads
  behind authentication.
- **Portable and encrypted sharing** — Export eligible text or URLs as clearly labeled Base64, or
  encrypt them for a public key you have verified out of band.

</details>

<details>
<summary>Share and collaborate</summary>

- **iCloud saved-library sync** (Engineering preview) — Not available in v0.1.0; future support is
  limited to eligible saved clips and folders.
- **Collaborative folders and roles** (Engineering preview) — Not available in v0.1.0; role-based
  folder sharing remains an engineering preview.
- **Visible sync status** (Engineering preview) — Not available in v0.1.0; sync-state visibility
  remains an engineering preview.

</details>

<details>
<summary>Built for macOS</summary>

- **Global shortcuts and multi-display placement** — Set separate search and note shortcuts, detect
  conflicts, and open search on the display under your pointer.
- **Launch at Login** — Start Clipboard Router through the macOS-managed login item.
- **Native Mac experience** — Use a signed, notarized Apple-silicon app with shortcuts,
  drag-and-drop, and a three-column library.
- **Bundled `cr` command-line tool** — Run matching analyze and transform pipelines from Terminal
  without changing PATH.

</details>

<details>
<summary>Specialized workflows</summary>

- **Sales Workspaces** — Create a local structure for account, contact, and follow-up research.
- **Developer Projects and Debug Bundles** — Group project clips, build reviewed Markdown debug
  context, ask the Assistant, and hand bundles to an IDE.

</details>

## Privacy

Clipboard Router stores captured history and saved clips in local app data, and v0.1.0 sends no
analytics. During a Private Session, new clips stay out of Clipboard Router history and disk and
remain in memory until you clear or end the session. Other Mac apps may still read plaintext while
it is on the shared system pasteboard.

<p align="center">
<img src="https://raw.githubusercontent.com/ibrolord/clipboard-router-releases/main/landing/public/product/plate-privacy-empty.png" width="720" alt="Private Session showing that it has recorded nothing yet">
</p>

## Install

Clipboard Router 0.1.0 runs on Macs with Apple silicon on macOS 14 or later.

```bash
brew install --cask ibrolord/tap/clipboard-router
```

You can also [download the app directly](https://github.com/ibrolord/clipboard-router-releases/releases/download/v0.1.0/Clipboard-Router-0.1.0-arm64.zip).
That build is signed with an Apple Developer ID certificate, notarized by Apple, and stapled.

<details>
<summary>Verify the direct download</summary>

```text
SHA-256
44d4c15cee3d5f155bdad65089434a93dc19baf1fe03dd247db7f9d50046cda6
```

</details>

## Build from source

You need macOS 14 or later and a Swift 6-capable Xcode toolchain.

```bash
git clone https://github.com/ibrolord/clipboard-router.git
cd clipboard-router
swift build
swift test
swift run ClipboardRouter
```

Packaging, integrations, signing, and release checks live in the
[development and release reference](docs/DEVELOPMENT.md).

## Contribute

Read the [contribution guide](CONTRIBUTING.md) before opening a pull request, and the
[security policy](SECURITY.md) before reporting a vulnerability.

Found a bug? [Open an issue](https://github.com/ibrolord/clipboard-router/issues) with your
Clipboard Router version, macOS version, Mac model, and the steps to reproduce it. Leave out
clipboard contents and credentials.

Clipboard Router is free software under the [MIT License](LICENSE).
