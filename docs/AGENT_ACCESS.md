# Agent Access (local MCP)

Agent Access lets an AI agent that speaks the Model Context Protocol (MCP), such as Claude Code or
Codex, read a small set of clips that you choose, on your Mac, through the `cr mcp` helper. It is
off by default and every connection needs your approval in the app.

## Availability

- Direct-download builds (and the Homebrew cask, which installs the same build) only.
- Not available in the Mac App Store build. The Agent Access tab is hidden there and the helper
  cannot run it.
- Requires a team-signed release build. Unsigned or ad-hoc local builds fail closed (see
  [Troubleshooting](#troubleshooting)).
- The private socket lives at `<app container>/Data/m/s`. Home folder paths longer than 39 bytes
  (for example `/Users/` followed by more than 32 characters) are unsupported; Settings shows an
  explanation instead of starting Agent Access.

## What is shared

Agent Access is off until you turn it on in **Settings > Agent Access**. There you enable it and
choose individual saved clips and/or folders. Selecting a folder shares its current and future
saved clips and its current and future subfolders until you deselect it.

- Only plain text and links are shared.
- Sensitive clips (including those with secrets detected in the title), files, images, and rich
  text are withheld.
- Clips in collaborative shared folders are always withheld. A folder that became collaborative
  stays withheld until the app is relaunched.
- History, Private Session, quarantine, and the Vault list are never exposed.
- Agents see the app's current local saved library. Clips that already synced are available
  offline, and agent access never triggers a sync.

## Set up an agent

Point your MCP client at the helper inside the app bundle, using stdio:

```text
"/Applications/Clipboard Router.app/Contents/Helpers/cr" mcp
```

A copied `cr` binary (for example one placed by `install-cr.sh`) is refused. Use the in-bundle
helper, or a symlink to it.

These are examples for you to add yourself; Clipboard Router does not edit any agent's
configuration.

Claude Code:

```bash
claude mcp add clipboard-router -- "/Applications/Clipboard Router.app/Contents/Helpers/cr" mcp
```

or in a JSON config:

```json
{
  "mcpServers": {
    "clipboard_router": {
      "command": "/Applications/Clipboard Router.app/Contents/Helpers/cr",
      "args": ["mcp"]
    }
  }
}
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.clipboard_router]
command = "/Applications/Clipboard Router.app/Contents/Helpers/cr"
args = ["mcp"]
tool_timeout_sec = 180
```

A Vault request waits up to 2 minutes for you to pick and approve an item. Some clients cancel tool
calls sooner by default (Codex uses a per-server `tool_timeout_sec`), so set the client's tool timeout
above 120 seconds. If the client cancels first, the request is cancelled in the app and nothing is shared.

## Pairing and sessions

Every connection shows a 6-digit code, both in the agent's tool result or error output (and `cr`
stderr) and in the app. Approve only if the two codes match. The client name shown is reported by
the agent and is not verified. A pending pairing request expires if not answered (two minutes).

A session ends on screen lock, sleep, app quit, disabling Agent Access, revoking it in Settings,
or after 8 hours. Idle connections close after 15 minutes. After any of these, the next tool call
opens a new connection that must be paired again.

## Tools

| Tool | Returns |
| --- | --- |
| `list_shared_clips` | Metadata for shared clips: id, title, kind, byte count, modified time. `limit` 1 to 100, default 50. No clip text. |
| `get_shared_clip` | The text of one shared clip by the id from `list_shared_clips`. |
| `request_vault_item` | Asks you for one text or link Vault item; see below. Takes only a `purpose` (at most 280 characters). |
| `sync_status` | Whether the local snapshot is ready, plus sync and projection state. `lastProjection` and its timestamp describe past activity only; they are not a freshness guarantee. |

## Vault requests

`request_vault_item` carries only a purpose. The agent cannot name, search, or list Vault items.
In the app you pick one text or link item, review it, and click **Share This Item Once**.
Unlocking the Vault never shares anything. The request is cancelled if the app goes to the
background, the Vault locks, the Mac sleeps or locks, or after 2 minutes. Each connection can have
only one pending request at a time (up to 4 connections). The Vault stays device-local.

## What disclosure means

Content is released at the moment the app hands it to the verified `cr` helper. If you revoke
before that moment, nothing is released. Text an agent has already received cannot be recalled,
and the agent's model provider may receive whatever you share. Share only what you are willing to
send to that provider.

## Security model

- Transport: an `AF_UNIX` socket inside the app's sandbox container (directory mode 0700, socket
  0600).
- Mutual verification: before any byte is exchanged, each side checks the other through the kernel
  audit token. Checks include same user; an Apple-anchored signature from the same team; exact
  identifiers (`com.clipboardrouter.cr` for the helper, the app's bundle identifier for the app);
  exact paths; hardened runtime; no `get-task-allow`, disabled library validation, dyld
  environment, JIT, debugger, or inherit entitlements; and a sandboxed app.
- Channel marker: the app's signed distribution marker must be exactly `direct`. Missing, unknown,
  and Mac App Store values are denied.
- Bounded I/O: the app↔helper socket uses size-limited frames with deadlines on every read and
  write; the helper's stdio side is bounded by size (1 MiB lines) and request admission caps rather
  than deadlines. Nothing is retried after an uncertain write.
- Logs contain only event names, reason codes, and timings, never clip content.
- Not protected: any process running as you can launch the genuine helper, which is why
  per-connection pairing is mandatory. Pairing proves you approved a connection, not which agent
  is on the other end.

## Troubleshooting

When `cr mcp` cannot start it prints `cr mcp: unavailable (<reason>)` to stderr.

| Reason | Meaning |
| --- | --- |
| `unsigned_or_ad_hoc_build` | The build has no team signature. Use a release build. |
| `helper_not_inside_app_bundle` | `cr` is not at `<App>.app/Contents/Helpers/cr`. Use the in-bundle helper or a symlink to it. |
| `distribution_channel_not_direct` | The app is not a direct-download build. |
| `app_bundle_signature_invalid_<status>` | The app bundle failed signature validation. |
| `app_bundle_info_unavailable` | The app's signed Info.plist could not be read. |
| `unexpected_signing_identifier` | The helper's signing identifier is not `com.clipboardrouter.cr`. |
| `hardened_runtime_missing` | The helper is not signed with the hardened runtime. |
| `forbidden_entitlement` | The helper carries a disallowed entitlement. |
| `app_not_sandboxed` | The app is not sandboxed. |
| `container_home_mismatch` | The app's home folder is not its own sandbox container. |
| `self_signing_unavailable_<status>` | The helper could not read its own signature. |
| `invalid_identifier_characters` | An identifier contains unexpected characters. |
| `endpoint_path_too_long` | Your home folder path is too long for the socket path. |
| `endpoint_directory_unsafe`, `endpoint_not_owned_socket`, `endpoint_in_use` | The socket directory or file has unsafe ownership or permissions, or another listener holds it. |
| `socket_<call>_errno_<n>` | A socket call failed; the app is often not running or Agent Access is off. |
| `peer_credentials_unavailable`, `peer_user_mismatch`, `peer_token_unavailable` | The other end could not be identified as the same user. |
| `peer_code_unavailable_<status>`, `invalid_requirement_<status>`, `peer_requirement_failed_<status>`, `peer_signing_info_unavailable_<status>`, `peer_signature_invalid` | The other end failed code-signature verification. |
| `peer_not_hardened`, `peer_debugged`, `peer_path_mismatch`, `peer_entitlement_forbidden`, `peer_entitlement_missing` | The other end failed a hardening, debugging, path, or entitlement check. |
| `frame_empty`, `frame_too_large`, `peer_closed`, `timed_out` | The connection broke or misbehaved. |

If tool calls report that Clipboard Router is not running or Agent Access is off, open the app and
check Settings > Agent Access.

## Known limitations

- Pairing is per connection: reconnecting requires approving again.
- The MCP Swift SDK is pinned to 0.12.1, which supports protocol versions up to 2025-11-25.
- A small shim in `cr mcp` accepts object-valued experimental client capabilities that the SDK
  would otherwise reject (needed for Codex).
- Client names are self-reported and not verified.
