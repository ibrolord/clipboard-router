<div align="center">

<img src="https://ibrolord.github.io/clipboard-router-releases/product/icon.png" width="96" alt="Clipboard Router">

# Clipboard Router

**Work from your clipboard toward 20× productivity.**

Clipboard Router is a macOS clipboard manager for people who copy and paste all day. The 20× target
applies to repetitive, clipboard-heavy workflows and is not a promise for every task.

[Download for macOS](https://github.com/ibrolord/clipboard-router-releases/releases/latest) ·
[Privacy](https://github.com/ibrolord/clipboard-router-releases/blob/main/PRIVACY.md)

<img src="https://raw.githubusercontent.com/ibrolord/clipboard-router-releases/main/landing/public/product/plate-hero.png" width="960" alt="Clipboard Router history listing recent clips with search and filters">

</div>

## What you get

- **Copy several items and paste them in order** — add each one to Paste Stack, switch apps once,
  then paste down the stack instead of going back for the next piece.
- **Recover something you copied earlier** — search past text, links, images, and files by content,
  app, domain, type, or date.
- **Transform content before pasting** — format JSON, remove tracking parameters from links, strip
  terminal noise, convert text to Markdown, or redact values.
- **Protect and share secrets** — Clipboard Router flags secret-like clips, keeps them in Vault
  behind authentication, and can encrypt a single clip for one recipient.

## Actions you control

A saved clip can start the next step. Folder triggers tag, file, or enrich a clip when it reaches a
watched folder, and you decide when that happens: new templates arrive switched off, external steps
wait for your review, and Clipboard Router never presses Send for you.

<p align="center">
<img src="https://raw.githubusercontent.com/ibrolord/clipboard-router-releases/main/landing/public/product/plate-actions-control.png" width="780" alt="A custom action listed as manual and switched off until it is enabled">
</p>

## Privacy

Ordinary history and saved clips stay on your Mac, and the current build ships no analytics
transport. Turn on Private Session and new clips live in memory until you end it, leaving nothing in
history, search, or disk.

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
