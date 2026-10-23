import AppKit
import ClipboardRouterAgentAccess
import ClipboardRouterCore
import SwiftUI

/// Settings pane for local AI agent (MCP) access. Everything an agent can read is chosen
/// here explicitly; every connection and every Vault item needs an explicit approval.
struct AgentAccessSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var access: AgentAccessController
    @State private var clipFilter = ""

    init(model: AppModel) {
        self.model = model
        self.access = model.agentAccess
    }

    var body: some View {
        Form {
            Section {
                Toggle("Allow local AI agents to read clips you choose", isOn: Binding(
                    get: { access.isEnabled },
                    set: { access.setEnabled($0) }
                ))
                .disabled(access.availability != .available)
                .accessibilityIdentifier("agentAccess.enable")
                if case let .unavailable(reason) = access.availability {
                    Label(reason, systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                }
                Text("Each connection needs your approval in this window. Agents only see the saved clips and folders you select below, never your history, Private Session or Vault list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let message = access.message {
                    Text(message).font(.callout)
                }
            } header: {
                Text("Agent Access")
            }

            if !access.pendingPairings.isEmpty {
                Section("Connection requests") {
                    ForEach(access.pendingPairings) { session in
                        PairingRequestRow(session: session, access: access)
                    }
                }
            }

            if !access.pendingVaultRequests.isEmpty {
                Section("Vault requests") {
                    ForEach(access.pendingVaultRequests) { request in
                        AgentVaultRequestRow(request: request, model: model, access: access)
                    }
                }
            }

            Section("Connected agents") {
                if access.activeSessions.isEmpty {
                    Text("No agents are connected.").foregroundStyle(.secondary)
                } else {
                    ForEach(access.activeSessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.displayName)
                                Text("Name reported by the agent, not verified · code \(session.pairingCode) · \(session.disclosures) item(s) shared")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke") { access.revoke(session.id) }
                                .accessibilityIdentifier("agentAccess.revoke.\(session.pairingCode)")
                        }
                    }
                    Button("Revoke All", role: .destructive) { access.revokeAll() }
                }
                Text("Revoking stops future reads. Text an agent already received cannot be recalled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shared with agents") {
                AgentScopeEditor(model: model, access: access, filter: $clipFilter)
            }

            Section("Set up an agent") {
                Text("Configure your MCP client to run this command (stdio):")
                Text(Self.helperCommand)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Text("Use the helper inside this app (or a symlink to it). A copied `cr` is refused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("agentAccess.settings")
    }

    static var helperCommand: String {
        "\"\(Bundle.main.bundleURL.path)/Contents/Helpers/cr\" mcp"
    }
}

/// Menu-bar notice for a waiting agent request. Clipboard Router is a menu-bar app without a
/// Dock icon, so this is the visible cue; nothing is approved from here.
struct AgentAccessMenuBanner: View {
    @ObservedObject var access: AgentAccessController
    let open: () -> Void

    var body: some View {
        let pairings = access.pendingPairings.count
        let vault = access.pendingVaultRequests.count
        if pairings + vault > 0 {
            Button(action: open) {
                Label(
                    vault > 0 ? "An agent is asking for a Vault item — review" : "An agent is asking to connect — review",
                    systemImage: "exclamationmark.bubble"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .accessibilityIdentifier("agentAccess.menuBanner")
        }
    }
}

private struct PairingRequestRow: View {
    let session: AgentAccessSessionInfo
    @ObservedObject var access: AgentAccessController

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(session.pairingCode)
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .accessibilityLabel("Pairing code \(session.pairingCode)")
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                Text("Approve only if your agent shows the same code. The name is reported by the agent and is not verified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Deny") { access.denyPairing(session.id) }
                .accessibilityIdentifier("agentAccess.deny.\(session.pairingCode)")
            Button("Approve") { access.approvePairing(session.id) }
                .accessibilityIdentifier("agentAccess.approve.\(session.pairingCode)")
        }
    }
}

private struct AgentVaultRequestRow: View {
    let request: VaultRequestInfo
    @ObservedObject var model: AppModel
    @ObservedObject var access: AgentAccessController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(request.displayName) (code \(request.pairingCode)) asks for one Vault item.")
            Text("Reason given by the agent (unverified): “\(request.purpose)”")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !model.isVaultUnlocked {
                HStack {
                    Text("Unlock the Vault to choose an item. Unlocking does not share anything.")
                        .font(.caption)
                    Spacer()
                    Button("Unlock Vault") { model.unlockVault() }
                }
            } else if let preview = access.vaultPreview, preview.requestKey == request.key {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(preview.itemName) · \(preview.kind == .url ? "Link" : "Text")").font(.headline)
                    ScrollView {
                        Text(preview.text)
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                    Text("Once shared, the agent keeps this text. It cannot be recalled.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    HStack {
                        Button("Cancel") { access.cancelVaultPreview() }
                        Spacer()
                        Button("Deny Request") { access.denyVaultRequest(request.key) }
                        Button("Share This Item Once") { Task { await access.approveVaultPreview() } }
                            .accessibilityIdentifier("agentAccess.vault.approve")
                    }
                }
            } else {
                let candidates = model.vaultSummaries.filter { $0.contentType == .plainText || $0.contentType == .url }
                if candidates.isEmpty {
                    Text("No text or link items in the Vault.").foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { summary in
                        Button {
                            Task { await access.previewVaultItem(requestKey: request.key, itemID: summary.id) }
                        } label: {
                            Label(summary.name, systemImage: summary.contentType == .url ? "link" : "doc.text")
                        }
                        .buttonStyle(.link)
                    }
                }
                HStack {
                    Spacer()
                    Button("Deny Request") { access.denyVaultRequest(request.key) }
                        .accessibilityIdentifier("agentAccess.vault.deny")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AgentScopeEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var access: AgentAccessController
    @Binding var filter: String

    var body: some View {
        let snapshot = model.snapshot
        let folders = snapshot.folders.sorted { $0.sortOrder < $1.sortOrder }
        let clips = snapshot.savedClips
            .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(access.scope.folderIDs.count) folder(s), \(access.scope.savedClipIDs.count) clip(s) selected")
                Spacer()
                if !access.scope.isEmpty {
                    Button("Clear") { access.clearScope() }
                }
            }
            Text("Only plain text and links are shared. Sensitive clips, clips with secrets in their title, and clips in collaborative shared folders are always withheld.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !folders.isEmpty {
                Text("Folders (includes current and future clips and subfolders)").font(.subheadline.weight(.semibold))
                ForEach(folders) { folder in
                    Toggle(folder.name, isOn: Binding(
                        get: { access.scope.folderIDs.contains(folder.id) },
                        set: { access.setFolder(folder.id, included: $0) }
                    ))
                }
            }
            TextField("Filter saved clips", text: $filter)
            ForEach(clips.prefix(200)) { clip in
                let eligibility = access.eligibility(of: clip, in: snapshot)
                Toggle(isOn: Binding(
                    get: { access.scope.savedClipIDs.contains(clip.id) },
                    set: { access.setClip(clip.id, included: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(clip.name).lineLimit(1)
                        if eligibility != .notSelected {
                            Text(eligibility.explanation)
                                .font(.caption)
                                .foregroundStyle(eligibility == .shared ? Color.secondary : Color.orange)
                        }
                    }
                }
            }
            if clips.count > 200 {
                Text("Showing 200 of \(clips.count). Use the filter to find others.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
