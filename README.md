# Clipboard Router

[![CI](https://github.com/ibrolord/clipboard-router/actions/workflows/ci.yml/badge.svg)](https://github.com/ibrolord/clipboard-router/actions/workflows/ci.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Clipboard Router helps you work from your clipboard toward 20× productivity on repetitive
workflows. It is a native, open-source macOS app that keeps copied work searchable, turns repeated
steps into reviewable automations, and gives sensitive clips a safer place to go.

Download the signed app from the [release repository](https://github.com/ibrolord/clipboard-router-releases/releases/latest),
install it with `brew install --cask ibrolord/tap/clipboard-router`, or build it locally from this
repository.

### What the 20× goal means

The 20× figure is a product goal for specific, repetitive clipboard-heavy workflows, not a
guarantee across every kind of work. Evaluate it on the same task before and after Clipboard Router
by timing the path from the first copy to completed output and counting the app switches and manual
steps that saved searches or reviewed automations replace.

It includes a visible clip-scoped Assistant. Users can choose Apple's on-device Foundation Models
on supported macOS 26 Macs or explicitly configure a low-cost hosted model with their own API key,
stored only in this Mac's Keychain. No request is sent until the user presses Send, and AI output
is always an inert, unverified draft.

## Project status

Clipboard Router 0.1.0 is publicly available as a signed, notarized direct download and Homebrew
Cask. This repository contains the application source and its release-verification tooling.

A passing test suite proves the tested local contracts only. It does not prove Developer ID
distribution, notarization, live CloudKit propagation, compatibility with every destination
version, or production Vault security. Those release claims require verification against the exact
distributed artifact.

The product boundary is deliberately narrow:

- macOS desktop only, with macOS 14 as the tested compatibility floor for the selected modern SwiftUI implementation.
- Local clipboard history for plain text, URLs, RTF, HTML, images, and file references, with
  representation-preserving copy and local OCR for supported images.
- Deliberately saved clips and editable plain-text notes organized into unlimited nested folders.
- Explicit copy-and-open routing to installed or web AI destinations.
- A local encrypted Vault for deliberately protected clips.
- Opt-in iCloud sync for saved clips and folders, not the active clipboard.
- No mobile client or automatic prompt submission. Optional hosted AI is explicit, BYOK, and
  blocked for Vault, Private Session, sensitive, secret, located, file, and rich-media content. Collaborative-folder transport,
  invitation presentation/acceptance, roles, and status UI are implemented, but signed
  two-account CloudKit proof remains a release gate.

The implemented feature surface and its privacy boundaries are documented below. Product issues
and focused pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md) before starting work.

## Privacy and security boundary

Clipboard software has unusual access and deserves unusually literal claims.

- Ordinary history and saved clips are local application data. They are not described as Vault-encrypted content.
- Nothing is handed to ChatGPT, Claude, Codex, or a website until the user selects a route action.
- The reliable destination fallback copies the selected payload and opens the destination. The user still pastes or submits it. Opening an application is not reported as prompt submission.
- Material on the shared macOS pasteboard can be read by other running applications. Vault encryption at rest cannot protect a clip while the user has deliberately placed its plaintext on that pasteboard.
- Saved-library iCloud sync is opt-in. Automatic history and Vault items remain local by default. Sync never replaces another Mac's active pasteboard.
- Vault sync is not a release feature. Adding it would require client-side ciphertext-only design and an independent security review.
- Vault accepts supported, bounded typed payloads. RTF, HTML, and image representations are
  encrypted as authenticated Vault assets and restored before an interrupted move may remove its
  ordinary source. Bounded file-reference payloads are protected inside the encrypted Vault item,
  but the referenced files themselves remain external and device-local. Malformed, missing, or
  oversized representations fail closed without changing the ordinary copy. Vault remains Local
  Only and is never synchronized.
- Analytics, if enabled by the user, may record coarse product actions but must never include clip contents, search queries, saved names, folder names, source URLs, or Vault metadata.
- The optional hosted Assistant stores only the user's provider API key in a non-synchronizing
  Keychain item. Clipboard Router is not a general credential manager.

The bundled privacy manifest declares user content for opt-in sync and no tracking. This build has
no analytics transport. If any shipped data path changes, the manifest and App Store privacy
answers must be reviewed before release.

## Implemented feature surface

- Searchable menu-bar window with pinned and recent clips; click any row to copy its original
  representations. An optional adjacent action can send Command-V to the exact app that was
  frontmost before the menu opened; without Accessibility permission, the clip remains copied for
  manual paste. Row actions prioritize save/move, pin, sharing, and explicit Vault moves; full
  local previews remain available on hover.
- First-class notes can be created, edited, pinned, searched, moved by menu or drag-and-drop, and
  protected in Vault. Every eligible clip exposes a reviewed Make Note action. Plain-text and URL clips can be converted without mutating their History
  source; rich, image, and file-backed clips are not offered a lossy conversion.
- Folders support unlimited nesting, recursive paths in menus and search, and cycle-safe folder or
  item drag-and-drop. Collaborative permissions and private-sync exclusion inherit through the
  complete shared subtree.
- SQLite/WAL object store with same-transaction FTS5 indexing, verified one-time JSON migration,
  global hash deduplication, retention, quotas, and a 10,000-row search fixture.
- Search tokens and natural filters for source, domain, type, device, coarse-location label,
  secret category, relative/absolute date, and recent-item position.
- User Smart Views save any validated content-and-metadata query, can be renamed, pinned,
  reordered, edited, or deleted, and appear in both the Library sidebar and menu-bar search.
  Definitions are local-only and contain only a name, query, and ordering metadata; results and
  clip content are never copied into or team-synced with the definition. Library multi-selection
  supports reviewed bulk save, move, tag, pin/unpin, and portable export. History remains
  immutable, and per-item results disclose sensitive, read-only shared, cross-space, or
  non-portable failures instead of silently dropping them.
- Device and approximate-location capture context are independent, off-by-default consents.
  Device context adds the local Mac label, OS, and a stable app-installation ID. Location access
  is requested only from an explicit Privacy Settings action; each accepted reading is immediately
  reduced locally to an approximate area label derived from at most five geohash characters, with
  stale or inaccurate readings rejected. Clipboard Router performs no reverse geocoding or network
  city lookup, and exact coordinates are never persisted. Located clips remain Local Only and
  hosted-AI ineligible; Private Session, quarantine, and direct Vault capture paths never receive
  this optional context. Settings can refresh, disable, or delete the context from existing
  ordinary clips without removing source-app, URL, or domain provenance.
- Automatic Organization evaluates ordered local rules over content type, link domain, source app,
  detected entity, or bounded safe regex only after an ordinary local save commits. Each suggestion
  explains its match and supports Apply Once, Always Apply, Never Suggest, and stale-safe Undo;
  sync imports, Vault, sensitive/quarantined content, and Private Sessions fail closed.
- First-class text, URL, RTF, HTML, image, file-reference, OCR, size, timestamp, source-app, and
  source-domain metadata. Images receive bounded local thumbnails and retain their original
  dimensions, format, and encoded size. Character/word counts, pasteboard UTIs, duplicate capture
  count, and app-initiated paste count are visible. Saving a clip preserves its provenance.
- Clipboard Health: local secret detection across every textual representation and OCR, followed
  by process-memory quarantine with Keep, Delete, safe Vault eligibility review, and bulk
  Vault/Delete actions. An explicit Keep retains the sensitivity label and remains ineligible for
  user-facing export or sync in this build.
- Searchable installed/running-app exclusion picker, pause/resume, configurable global shortcut,
  Private Sessions, Combine Clips, Paste Stack, deterministic transforms, archive export, and
  ordinary macOS sharing.
- Assistant & Insert: multi-turn on-device or explicit Fast cloud chat, task presets for quick
  answers, enrichment, rewriting, formatting, follow-up drafts, and opt-in web research; a
  searchable signed-app browser; and a global Insert Palette with local `;aliases` that reference
  saved clips or notes without duplicating their contents. An off-by-default Text Expansion setting
  can recognize exact delimiter-completed aliases system-wide after explicit Accessibility access.
  It retains only the bounded current alias token, replaces through the focused AX text control
  without using the clipboard, supports immediate Escape restoration, and fails closed for secure
  or unknown controls, excluded apps, Clipboard Router, Private Session, sensitive/location-bearing
  items, Vault, and rich or file-backed content.
- Actionable Clips detect links, email addresses, phone numbers, and dates locally, then expose
  explicit Open, Compose, Calling App, Save Contact, Calendar Draft, local Research Assistant, and
  Find Related actions in both the menu bar and library. Calendar and Contacts access are requested
  only after the user reviews and confirms a draft.
- Local manual automations can be scoped by detected entity and saved folder. A user click can
  open an HTTPS template or copy the clip and open an explicitly chosen signed application;
  automations never run during capture or sync, and sensitive/private content is excluded.
- Custom actions support atomic tag/move organization followed by reviewed CRM/web handoff,
  follow-up-note, and on-device enrichment
  steps. Local folder-entry triggers run reversible local steps and queue external or generative
  steps for review. Team workspaces sync portable definitions as disabled templates; credentials,
  app bookmarks, run receipts, and active execution never sync.
- Authenticated CRM connectors support Salesforce and HubSpot Contacts, Companies, and follow-up
  Tasks. Every write opens an editable allowlisted-field review and requires an explicit Create or
  Update confirmation. Contact/Company creates run a duplicate lookup first; 401 refresh is bounded
  to one attempt, `Retry-After` is surfaced, terminal 4xx responses are not retried, and a timeout
  after a possible write produces a reconciliation receipt instead of a duplicate write. OAuth
  tokens are stored in a non-synchronizing, device-only Keychain item. Vault, sensitive, secret,
  location-bearing, image, file, rich-text, and Private Session sources fail closed.
- Folder-trigger runs use a durable local ledger, not a remote background-job service. Completed
  steps are never replayed. After relaunch, retry-safe local work returns for review and may resume
  deterministically; an external step whose outcome cannot be proven is marked uncertain and must
  be reconciled by the user before anything continues. Unknown external work is never blindly
  retried.
- Verified product-identity routing for ChatGPT, Claude, and Codex. The app resolves ambiguous
  installed applications before changing the clipboard and never silently substitutes a website
  after an installed-app launch fails.
- A provider-neutral direct-distribution licensing foundation supports signed trial, lifetime,
  and subscription claims scoped to an account and Mac. Tokens are P-256 verified before they
  replace the last credential and remain in a non-synchronizing Keychain item. Secure wall and
  monotonic clock checkpoints bound offline grace and fail closed on rollback. Expiry, revocation,
  or verification failure pauses only new premium creation, automations, cloud, and AI; search,
  copy, export, and delete remain available. Activation, restore, refresh, disconnect, and
  server-confirmed deactivation have dedicated Settings UI. Until the external configuration below
  is real, the UI labels the app **Engineering Build** and makes no purchase claim.
- Visible per-item saved-library sync state and fail-closed eligibility. History, Vault,
  quarantine, Private Sessions, file references, and untransported binary assets remain local.
- Collaborative saved folders use one zone-wide CloudKit share per folder, private/shared database
  routing, invitation acceptance, participant status, and owner/editor/viewer enforcement. The
  live adapter accepts no data until CloudKit identity, share metadata, record provenance, folder
  scope, and content eligibility all validate.
- Separate global shortcuts detect conflicts and are configurable for clipboard search and note
  creation. Search positions the library on the display containing the pointer instead of
  assuming the primary monitor. `Command-K` focuses content-and-metadata search, `Command-Shift-N`
  creates a note, and numbered shortcuts select pinned notes.

## Requirements

- A Mac running macOS 14 or later.
- Xcode with a Swift 6-capable toolchain.
- Command Line Tools selected with `xcode-select`.
- No Apple Developer account is required for local tests or an ad-hoc local build.
- Calendar, Contacts, and Location permissions are optional and requested only from their explicit
  reviewed actions. Denial or restriction leaves clipboard capture, search, organization, and
  automation working without the affected metadata or system action.
- A paid Apple Developer membership, registered identifiers, a CloudKit container, a matching provisioning profile, and a code-signing identity are required for a live iCloud build.
- A Developer ID Application certificate and notarization credentials are required for public direct distribution.
- A production direct-distribution build additionally requires a real commerce-provider product
  mapping, an HTTPS licensing service, and the service's P-256 public verification key. This
  repository deliberately bundles none of those credentials or purchase claims.

### Licensing service contract

The provider-neutral client expects idempotent HTTPS `POST` endpoints at
`v1/licenses/trial`, `activate`, `restore`, `refresh`, and `deactivate`. The first four return a
bounded JSON object containing a signed `crl1` token. The backend must own trial eligibility,
purchase/refund state, device-seat policy, subscription renewal, and revocation, and must keep the
private signing key in server-side protected key management. Configure the packaged app only after
setting all of `ClipboardRouterLicenseServiceURL`, `ClipboardRouterCommerceProviderIdentifier`,
and `ClipboardRouterLicensePublicKeyDERBase64` to production values. The public key is bundled;
license keys and returned tokens are not.

Confirm the toolchain:

```bash
swift --version
xcodebuild -version
```

## Build and test

From this directory:

```bash
swift build
swift test
```

Or run the repository verification wrapper:

```bash
./Scripts/verify_source.sh
```

`verify_source.sh` checks shell syntax, every plist, the Swift package manifest, and the Swift tests. It also runs `shellcheck` when that optional tool is installed.

During development, launch the SwiftPM executable with:

```bash
swift run ClipboardRouter
```

## Package a local application

The default package is sandboxed, ad-hoc signed, and contains no iCloud entitlement. It is useful for UI and ordinary clipboard testing, but does not prove the user-presence Keychain path required by Vault:

```bash
./Scripts/package_app.sh
./Scripts/verify_release.sh --profile local .artifacts/ClipboardRouter.app
open .artifacts/ClipboardRouter.app
```

Packaging builds and signs both the app and the version-matched `cr` command. The CLI lives at
`.artifacts/ClipboardRouter.app/Contents/Helpers/cr`; it is not copied into a system directory and
Clipboard Router never edits `PATH`. Run it in place:

```bash
.artifacts/ClipboardRouter.app/Contents/Helpers/cr --help
printf 'fatal error: build failed\nmain.swift:42\n' \
  | .artifacts/ClipboardRouter.app/Contents/Helpers/cr analyze --format json -
printf '{"b":2,"a":1}\n' \
  | .artifacts/ClipboardRouter.app/Contents/Helpers/cr transform pretty-json -
```

To export it, choose the exact destination yourself. The bundled helper prompts before writing,
does not invoke `sudo`, requires the parent directory to exist, and refuses silent replacement:

```bash
mkdir -p "$HOME/.local/bin"
.artifacts/ClipboardRouter.app/Contents/Resources/install-cr.sh \
  --destination "$HOME/.local/bin/cr"
```

`--yes` confirms a non-interactive export only after `--destination` is supplied. Updating an
existing regular file additionally requires `--replace`. `/usr/local/bin` is never selected or
modified automatically.

Every package produces an adjacent `.artifacts/ClipboardRouter.app.release.json` manifest. Keep it
beside the app. It records the bundle ID, app and CLI version/build, requested and actual
architectures, UTC build time, Swift/Xcode/SDK toolchains, artifact SHA-256 hashes, and the real Git
revision plus dirty flag only when the source is actually in a Git checkout. No synthetic revision
is emitted. `verify_release.sh` requires and validates this manifest, both signatures, exact
app/CLI architecture and version agreement, and real help/analyze/transform CLI smokes.

Use `--overwrite` when deliberately replacing an existing artifact. Useful metadata overrides include:

```bash
./Scripts/package_app.sh \
  --version 0.1.0 \
  --build-number 1 \
  --bundle-id com.example.ClipboardRouter \
  --architectures arm64 \
  --overwrite
```

The architecture default is the current Mac's native architecture. Use `--architectures universal`
or `--architectures arm64,x86_64` for a universal artifact. The script builds both products for the
same requested slices and fails with a specific x86_64 toolchain/SDK message when that slice cannot
be produced. An arm64-only engineering artifact remains valid and is labeled truthfully in its
release manifest.

An ad-hoc signature is only for local engineering. It is not notarized, is not suitable for customer distribution, and cannot exercise production CloudKit entitlements.

To exercise the device-bound, user-presence Keychain path used by Vault without enabling iCloud, sign the local profile with the registered application identity and Team ID:

```bash
./Scripts/package_app.sh \
  --bundle-id com.example.ClipboardRouter \
  --team-id ABCDE12345 \
  --identity "Developer ID Application: Example Company (ABCDE12345)" \
  --overwrite
./Scripts/verify_release.sh --profile local .artifacts/ClipboardRouter.app
```

## Configure authenticated CRM connectors

Salesforce uses an External Client App configured as a public native client. Register
`clipboardrouter://oauth/salesforce` as its callback, enable authorization code with PKCE, grant
`api` and `refresh_token`, and do not require a client secret for the native token exchange or
refresh. Paste only the public client ID into Settings > CRM.

HubSpot currently requires confidential client credentials during token exchange and refresh.
Those credentials must never be embedded in Clipboard Router. Settings therefore keeps Connect
disabled until an HTTPS broker base URL is configured. The app calls these broker-relative paths:

- `POST /oauth/hubspot/exchange` with URL-encoded `grant_type`, authorization `code`, public
  `client_id`, `redirect_uri`, and PKCE `code_verifier`.
- `POST /oauth/hubspot/refresh` with URL-encoded `grant_type`, `refresh_token`, and public
  `client_id`.

The broker adds the provider secret server-side and returns the provider token JSON over HTTPS.
It must authenticate and rate-limit the installed client, validate the registered callback/client
pair, avoid logging codes or tokens, and return `access_token`, `refresh_token`, `expires_in`,
`scope`, and optional account/instance metadata. Clipboard Router never writes token values to
UserDefaults, sync definitions, metrics, or receipts.

The offline contract tests cover endpoint construction, PKCE/state validation, broker gating,
non-synchronizing credential boundaries, duplicate lookup, one refresh, rate limiting, terminal
errors, and uncertain-write reconciliation. They do not prove that a real Salesforce app, HubSpot
app, or production broker is correctly provisioned. Keep the customer-facing connection gate
closed until each provider completes a real sandbox authorization, refresh, create, update,
duplicate, revoke, and reconnect test with the exact signed application.

## Enable CloudKit for a signed build

CloudKit is not activated merely by compiling `CloudKit.framework` or passing unit tests. Before packaging, an Apple Developer team must:

1. Register the final macOS bundle identifier.
2. Create an iCloud container, for example `iCloud.com.example.ClipboardRouter`.
3. Associate that container and push notifications with the application identifier.
4. Create a macOS provisioning profile authorizing that bundle ID and container.
5. Install the matching Apple Development or Developer ID Application signing identity.
6. Create and deploy the CloudKit record schema used by the sync implementation.

Package a development-environment build for device testing:

```bash
./Scripts/package_app.sh \
  --icloud \
  --bundle-id com.example.ClipboardRouter \
  --team-id ABCDE12345 \
  --cloudkit-container iCloud.com.example.ClipboardRouter \
  --cloudkit-environment development \
  --provisioning-profile /absolute/path/ClipboardRouter-Development.provisionprofile \
  --identity "Apple Development: Example Name (ABCDE12345)"
```

Package a production-environment build only with a production-authorized profile and distribution identity:

```bash
./Scripts/package_app.sh \
  --icloud \
  --bundle-id com.example.ClipboardRouter \
  --team-id ABCDE12345 \
  --cloudkit-container iCloud.com.example.ClipboardRouter \
  --cloudkit-environment production \
  --provisioning-profile /absolute/path/ClipboardRouter-Distribution.provisionprofile \
  --identity "Developer ID Application: Example Company (ABCDE12345)"
```

Verify the signed artifact and the exact container:

```bash
./Scripts/verify_release.sh \
  --profile icloud \
  --bundle-id com.example.ClipboardRouter \
  --cloudkit-container iCloud.com.example.ClipboardRouter \
  .artifacts/ClipboardRouter.app
```

The packaging script checks that the provisioning profile belongs to the requested Team ID and contains the requested CloudKit container. Apple still decides whether the identity, profile, environment, schema, and account are valid together when signing and at runtime.

Production personal sync requires a real two-Mac test using the same iCloud account. Verify create, update, move, delete, offline recovery, conflict resolution, sign-out, quota failure, and the invariant that neither Mac's active pasteboard changes because of sync.

An iCloud-profile build now installs stable private- and shared-database subscriptions with
content-available notifications. Installation is idempotent, is recorded separately for each
container, development/production environment, and iCloud account, and repairs missing or
incompatible server subscriptions. A verified notification is only a refresh hint: the app runs
the existing token-based personal/shared fetch paths, coalesces bursts, and never writes remote
content to the active pasteboard. The bounded polling loops remain enabled as recovery because
Apple may delay or coalesce notifications.

Unit and package checks prove the subscription, routing, persistence, and entitlement contracts
offline. They do not prove that Apple accepted the signed app registration or delivered a push.
That still requires the signed two-Mac and two-account CloudKit tests below in both the selected
development or production environment.

Collaborative folders additionally require two separate real iCloud accounts and the deployed V2
shared schema. Verify invitation delivery, app relaunch acceptance, owner/editor/viewer behavior,
shared-database visibility, concurrent edits/tombstones, account switching, and offline recovery.

## Direct distribution and notarization

For a Developer ID-signed app, store notarization credentials in Keychain without putting secrets in the repository:

```bash
xcrun notarytool store-credentials clipboard-router-notary
```

Then submit, wait for the result, staple the ticket, and run Gatekeeper assessment:

```bash
./Scripts/notarize_app.sh \
  --keychain-profile clipboard-router-notary \
  .artifacts/ClipboardRouter.app

./Scripts/verify_release.sh \
  --profile icloud \
  --require-notarized \
  .artifacts/ClipboardRouter.app
```

The notarization script accepts only a Keychain profile name. It never accepts, stores, or prints Apple credentials. Notarization modifies the app by stapling a ticket and contacts Apple's service, so it is not part of offline verification.

## Customer-facing download archive

`Scripts/create_customer_archive.sh` turns a signed, notarized `.app` into the deterministic zip that customers actually download. It re-verifies the input with `verify_release.sh --require-notarized`, stages a copy renamed to the customer-facing display name (`Clipboard Router.app` by default — renaming does not change the code signature or stapled ticket, both of which are keyed to bundle contents, not path), builds the zip itself with sorted entries, fixed per-entry timestamps, and preserved POSIX permissions (so re-running it against the same input app produces a byte-identical archive), then extracts that zip into a clean temporary directory and re-runs `codesign --verify --deep --strict`, a Gatekeeper `spctl` assessment, and `stapler validate` against the *extracted* copy before publishing:

```bash
./Scripts/notarize_app.sh --keychain-profile clipboard-router-notary .artifacts/ClipboardRouter.app
./Scripts/create_customer_archive.sh --profile local .artifacts/ClipboardRouter.app
```

This writes `.artifacts/Clipboard-Router-<version>-<architectures>.zip` and an adjacent `.sha256` sidecar (`shasum -a 256` format). Use `--output` to control the path, `--display-name` to change the customer-facing app name, and `--overwrite` to replace an existing archive.

`--skip-notarization-check` builds an engineering-only archive from an unnotarized app for local pipeline testing. It tags the filename with `-UNNOTARIZED`, skips the Gatekeeper/staple requirement, and must never be distributed to customers — the script prints a warning to stderr every time it runs.

## Homebrew Cask

`Scripts/generate_homebrew_cask.sh` renders a Homebrew Cask definition for a customer archive produced above. It performs no network access, publishes to no tap, and never fabricates a homepage or download URL — both are required arguments the caller must supply from real, already-published release infrastructure:

```bash
./Scripts/generate_homebrew_cask.sh \
  --version 0.1.0 \
  --homepage "https://example.com/clipboard-router" \
  --arm64-url "https://example.com/releases/Clipboard-Router-0.1.0-arm64.zip" \
  --arm64-sha256 "$(awk '{print $1}' .artifacts/Clipboard-Router-0.1.0-arm64.zip.sha256)" \
  --output Casks/clipboard-router.rb
```

With only `--arm64-url`/`--arm64-sha256`, the generated cask is pinned to `depends_on arch: :arm64` for the current arm64 Sonoma-minimum artifact. Passing `--x86-64-url`/`--x86-64-sha256` as well produces a future universal-capable cask: identical arm64/x86_64 URL and sha256 pairs generate a single unrestricted download, and differing pairs generate `on_arm`/`on_intel` blocks that select the matching per-architecture archive. The generator validates its own output with `ruby -c` when Ruby is installed and is deterministic — identical arguments always produce identical output — which keeps it diffable in review and safe to regenerate in CI.

## Mac App Store packaging

`Scripts/package_mas.sh` builds, signs, and packages the SwiftPM app as a Mac App Store installer product (`.pkg`), using an explicit Apple Distribution (or 3rd Party Mac Developer Application) signing identity, a matching Mac App Store provisioning profile, and a separate Mac App Store installer-signing identity:

```bash
./Scripts/package_mas.sh \
  --bundle-id com.example.ClipboardRouter \
  --team-id ABCDE12345 \
  --app-identity "Apple Distribution: Example Company (ABCDE12345)" \
  --installer-identity "3rd Party Mac Developer Installer: Example Company (ABCDE12345)" \
  --provisioning-profile /absolute/path/ClipboardRouter-MacAppStore.provisionprofile \
  --version 0.1.0 \
  --build-number 1
```

It reuses `package_app.sh` to build and sign the app itself (so app-signing, entitlement, and provisioning-profile validation are identical to the direct-distribution path), then runs `verify_release.sh` against the signed app, rejects a Developer ID application or installer certificate outright, rejects a release build carrying the `com.apple.security.get-task-allow` debugger entitlement, and builds the installer with `productbuild --sign`. It then validates the installer package itself: `pkgutil --check-signature` must show a signature whose certificate chain contains the requested Team ID and must not be a Developer ID Installer/Application certificate, and `pkgutil --expand-full` must yield exactly one embedded `.app` that independently passes `codesign --verify --deep --strict`, matches the requested bundle identifier, and carries a provisioning profile that authorizes the app's actual signing certificate.

The script writes `.artifacts/mas/ClipboardRouter.pkg`, its sha256, and an adjacent evidence manifest (`.artifacts/mas/ClipboardRouter.pkg.release.json`) recording the bundle ID, version/build, Team ID, both signing identities, the provisioning profile's name and UUID, toolchain versions, and the Git source revision and dirty flag when available. Add `--icloud --cloudkit-container ID --cloudkit-environment development|production` for a CloudKit-enabled Mac App Store build, exactly as for `package_app.sh`.

This script never uploads anything and never touches App Store Connect: it does not create or edit Apple Developer identities, provisioning profiles, App Store Connect app records, or App Store metadata, and it never accepts, stores, or contacts App Store Connect credentials. The resulting `.pkg` is upload-ready — hand it to Transporter or Xcode Organizer — but still requires a complete App Store Connect listing (screenshots, description, age rating, export compliance, pricing) and Apple's review before release.

## Release evidence

A release candidate is not ready because it builds. At minimum, retain evidence for:

- `./Scripts/verify_source.sh` passing on the release source.
- `./Scripts/verify_release.sh` passing on the exact artifact distributed.
- For a direct-download release: `./Scripts/create_customer_archive.sh` passing (codesign, Gatekeeper,
  and stapled-ticket checks on the *extracted* customer archive, not just the pre-archive `.app`) and
  the published sha256 sidecar matching the file customers actually receive.
- For a Homebrew Cask update: the cask's `sha256`/`url` fields matching the exact archive and sidecar
  above, generated with `./Scripts/generate_homebrew_cask.sh` rather than hand-edited.
- For a Mac App Store release: `./Scripts/package_mas.sh` passing, the resulting `.pkg` uploaded through
  Transporter or Xcode Organizer, and a complete App Store Connect listing. This repository verifies the
  signed package and its embedded app; it does not verify App Store Connect metadata or Apple's review.
- A clean-install first-run and menu-bar launch on every supported macOS major version.
- Text and URL capture, duplicate suppression, pause, retention, deletion, concealed/transient types, and excluded applications.
- Search latency against the 10,000-clip reference fixture.
- Save, note edit/conversion, rename, nested folder move/deletion, drag-and-drop, and persistence
  after relaunch.
- Every destination's installed-app and web fallback, including the visible fact that no prompt is automatically submitted.
- Vault lock, authentication denial, encrypted-at-rest inspection, auto-lock, relaunch, deletion, and conditional secure-paste clearing.
- Signed two-Mac CloudKit tests when sync is included.
- Accessibility, keyboard navigation, VoiceOver labels, idle CPU, memory, and warm-open performance budgets.
- A content-blind analytics audit and a scan of logs, crash data, ordinary indexes, and CloudKit test records for prohibited plaintext.
- No known critical or high-severity security defect.

The source verifier executes the complete XCTest and Swift Testing suites. Passing them is necessary
evidence for the tested contracts, not evidence for the signed multi-device gates above.

The release verifier intentionally does not claim those runtime outcomes. It verifies the package and signature boundary; automated and manual product tests verify behavior.

## Packaging layout

```text
ClipboardRouter.app/
  Contents/
    Info.plist
    MacOS/ClipboardRouter
    Helpers/cr                    # separately signed, exact app version/build
    Resources/
      PrivacyInfo.xcprivacy
      install-cr.sh               # explicit user-selected export helper
    embedded.provisionprofile   # iCloud-signed builds only
```

The release manifest is adjacent to the bundle as `ClipboardRouter.app.release.json`, allowing it
to hash the final signed app executable and CLI without creating a self-referential bundle hash.

SwiftPM resource bundles matching `ClipboardRouter_*.bundle` are preserved beside the main bundle because command-line SwiftPM resource accessors look there. Do not rename the executable without updating `Info.plist`, the Swift product, and all packaging checks together.

## Script reference

- `Scripts/verify_source.sh`: source, manifest, plist, and test checks.
- `Scripts/package_app.sh`: architecture-aware SwiftPM app/CLI build, assembly, release manifest,
  entitlement selection, and code signing.
- `Scripts/verify_release.sh`: manifest hashes, app/CLI architecture/version/signature agreement,
  CLI smokes, bundle metadata, sandbox, profile separation, and optional notarization checks.
- `Resources/install-cr.sh`: explicit user-confirmed export of the packaged signed CLI.
- `Scripts/notarize_app.sh`: direct-distribution upload, wait, staple, and Gatekeeper assessment.
- `Scripts/create_customer_archive.sh`: deterministic customer-facing zip, sha256 sidecar, and
  post-extraction codesign/Gatekeeper/staple re-verification.
- `Scripts/generate_homebrew_cask.sh`: audit-friendly, deterministic Homebrew Cask generation from
  caller-supplied URLs and sha256 hashes; never fabricates a homepage or download URL.
- `Scripts/package_mas.sh`: Mac App Store `.pkg` build using an explicit Apple Distribution identity,
  matching provisioning profile, and Mac App Store installer identity, with package/entitlement
  validation and an evidence manifest.

Run any script with `--help` before using release credentials or production profiles.

## License

Clipboard Router is available under the [MIT License](LICENSE).
