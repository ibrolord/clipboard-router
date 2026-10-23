# Security policy

Clipboard Router handles clipboard content, so security reports may themselves
contain sensitive information. Do not place clipboard contents, credentials,
private keys, personal data, or working exploit payloads in a public issue.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting feature on this repository. Include
the affected version or commit, macOS version, impact, minimal reproduction, and
any suggested mitigation. Use synthetic data wherever possible.

If private vulnerability reporting is unavailable, open a public issue that
contains no sensitive details and asks the maintainer to establish a private
contact channel.

## Supported versions

Security fixes target the latest published release and the current `main`
branch. Older releases may not receive backports.

## Scope notes

- Ordinary history is local application data; it is not Vault-encrypted content.
- Vault protects deliberately stored content at rest but cannot protect
  plaintext a user intentionally places on the shared macOS pasteboard.
- Optional hosted services and sync paths remain opt-in and must preserve the
  eligibility checks documented in the source and README.

## Agent Access (local MCP)

Agent Access is off by default and available only in direct-download builds; see
[docs/AGENT_ACCESS.md](docs/AGENT_ACCESS.md).

- Threat model: any process running as the same user can launch the genuine, signed `cr`
  helper. That is why per-connection pairing (a 6-digit code approved in the app) is mandatory.
  Client names are reported by the agent and are not verified.
- Protected: the app and helper verify each other by kernel audit token (same user, same-team
  Apple-anchored signature, exact identifiers and paths, hardened runtime, no dangerous
  entitlements) before any byte is exchanged; the socket is in the app's sandbox container;
  framing and stdio are bounded; only user-selected plain text and links are shared; sensitive
  clips, files, images, rich text, collaborative-folder clips, History, Private Session,
  quarantine, and the Vault list are withheld. Vault items need a per-item approval in the app.
- Not protected: content an agent has already received cannot be recalled, and the agent's model
  provider may receive it. Revoking before the app hands content to the helper releases nothing.
- Report suspected bypasses through private vulnerability reporting, using synthetic data.
