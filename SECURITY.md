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
