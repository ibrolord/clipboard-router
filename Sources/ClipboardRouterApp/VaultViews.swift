import ClipboardRouterCore
import ClipboardRouterPlatform
import ClipboardRouterSecurity
import SwiftUI

struct VaultListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vault").font(.title2.weight(.semibold))
                    Text(
                        model.vaultAvailabilityMessage != nil
                            ? "Unavailable"
                            : (model.isVaultUnlocked ? "\(model.vaultSummaries.count) encrypted clips" : "Locked")
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                if model.isVaultUnlocked {
                    Button("Lock", systemImage: "lock") { model.lockVault() }
                        .accessibilityHint("Immediately removes decrypted Vault content from the interface")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if let message = model.vaultAvailabilityMessage {
                // Vault availability is decided by code-signing entitlements, not by a setting,
                // so there is no in-app switch that turns it on. Offer the protections that do
                // work in this build instead of leaving the pane as a dead end.
                EmptyStateCard(
                    title: "Vault needs a signed build",
                    message: message,
                    systemImage: "exclamationmark.shield",
                    tint: .orange
                ) {
                    Button {
                        if model.isPrivateSessionActive {
                            model.selectLibrarySection(.privateSession)
                        } else {
                            model.startPrivateSession()
                        }
                    } label: {
                        if model.isStartingPrivateSession {
                            Label("Starting Private Session…", systemImage: "hourglass")
                        } else {
                            Text("Use Private Session")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isStartingPrivateSession)
                    .help("Keep new clips in memory only, with nothing written to disk")
                    Button("Clipboard Health") {
                        model.selectLibrarySection(.clipboardHealth)
                    }
                    .help("Review clips quarantined because they look like secrets")
                }
                .accessibilityIdentifier("uiAcceptance.vault.unavailable")
            } else if !model.isVaultUnlocked {
                EmptyStateCard(
                    title: "Vault locked",
                    message: "Unlock with Touch ID or your Mac password. Vault names and contents stay hidden while locked.",
                    systemImage: "lock.fill",
                    tint: .purple
                ) {
                    Button("Unlock Vault") { model.unlockVault() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Uses macOS owner authentication")
                }
            } else if model.vaultSummaries.isEmpty {
                EmptyStateCard(
                    title: "Vault is empty",
                    message: "Open a saved clip and choose Move to Vault. The ordinary saved copy and linked history are removed after encryption succeeds.",
                    systemImage: "lock.square",
                    tint: .purple
                )
            } else {
                List(
                    model.vaultSummaries,
                    selection: Binding(
                        get: { model.selectedVaultItemID },
                        set: { model.selectVaultItem(id: $0) }
                    )
                ) { item in
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: vaultSymbol(for: item.contentType))
                            .foregroundStyle(.purple)
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.body.weight(.medium)).lineLimit(2)
                            Text(item.modifiedAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    .tag(item.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Encrypted Vault item \(item.name)")
                }
                .listStyle(.inset)
            }
        }
    }
}

struct VaultDetailView: View {
    @ObservedObject var model: AppModel
    @State private var confirmsSecurePaste = false
    @State private var confirmsDelete = false
    @State private var pendingDestination: ExternalDestination?

    var body: some View {
        Group {
            if let message = model.vaultAvailabilityMessage {
                EmptyStateCard(
                    title: "Vault needs a signed build",
                    message: message,
                    systemImage: "exclamationmark.shield",
                    tint: .orange
                )
            } else if !model.isVaultUnlocked {
                EmptyStateCard(
                    title: "Vault content is hidden",
                    message: "Unlock Vault to choose an encrypted clip.",
                    systemImage: "eye.slash",
                    tint: .purple
                )
            } else if let item = model.selectedVaultItem {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.headline).lineLimit(1)
                            Text("\(vaultContentTypeName(item.content.type)) · Decrypted for this selection only")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Copy Original", systemImage: "clipboard") {
                            confirmsSecurePaste = true
                        }
                        .accessibilityHint("Copies locally and conditionally clears after \(model.securePasteTimeoutSeconds) seconds")
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            confirmsDelete = true
                        }
                    }
                    .padding(16)

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if item.content.type == .image {
                                Label(
                                    "Encrypted image · Original pixels restore only when copied",
                                    systemImage: "photo.on.rectangle.angled"
                                )
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                            } else if item.content.type == .fileURLs {
                                Label(
                                    "\(item.content.representations.files.count) encrypted file reference\(item.content.representations.files.count == 1 ? "" : "s")",
                                    systemImage: "doc.on.doc"
                                )
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                            } else if item.content.type == .richText {
                                Label(
                                    "Original RTF/HTML formatting restores when copied",
                                    systemImage: "doc.richtext"
                                )
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                            }
                            Text(item.content.text)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(22)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Explicit AI handoff")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 9) {
                            ForEach(DestinationRegistry.all) { destination in
                                Button {
                                    pendingDestination = destination
                                } label: {
                                    Label(destination.displayName, systemImage: destination.symbolName)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .accessibilityHint("Shows a privacy confirmation before Vault content leaves the app")
                            }
                        }
                        Text("Vault content is never sent automatically. Confirming copies it to the system clipboard and opens the selected app; you still choose whether to paste or submit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
                .confirmationDialog(
                    "Copy this decrypted Vault item?",
                    isPresented: $confirmsSecurePaste,
                    titleVisibility: .visible
                ) {
                    Button("Copy Original for \(model.securePasteTimeoutSeconds) Seconds") {
                        model.securePasteVaultItem(item)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The clipboard is restricted to this Mac. It clears after \(model.securePasteTimeoutSeconds) seconds only if the item is still there; Clipboard Router will never erase something you copied afterward.")
                }
                .confirmationDialog(
                    "Allow this Vault item to leave Vault?",
                    isPresented: Binding(
                        get: { pendingDestination != nil },
                        set: { if !$0 { pendingDestination = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    if let destination = pendingDestination {
                        Button("Copy and Open \(destination.displayName)") {
                            model.routeVaultItem(item, to: destination)
                            pendingDestination = nil
                        }
                    }
                    Button("Cancel", role: .cancel) { pendingDestination = nil }
                } message: {
                    Text("This places decrypted content on this Mac's clipboard and opens the external app. That app may retain it. Clipboard Router conditionally clears its unchanged clipboard value after \(model.securePasteTimeoutSeconds) seconds; it will not paste or submit.")
                }
                .confirmationDialog(
                    "Permanently delete this Vault item?",
                    isPresented: $confirmsDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete Vault Item", role: .destructive) {
                        model.deleteVaultItem(id: item.id)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes the encrypted item. It cannot be recovered from ordinary clipboard history.")
                }
            } else if model.selectedVaultItemID != nil {
                ProgressView("Decrypting selected item…")
            } else {
                EmptyStateCard(
                    title: "Select a Vault item",
                    message: "Only the selected item's content remains decrypted in the interface.",
                    systemImage: "lock.doc",
                    tint: .purple
                )
            }
        }
    }
}

private func vaultSymbol(for type: SupportedContentType) -> String {
    switch type {
    case .plainText: "lock.doc"
    case .url: "link.badge.plus"
    case .richText: "doc.richtext"
    case .image: "photo"
    case .fileURLs: "doc.on.doc"
    }
}

private func vaultContentTypeName(_ type: SupportedContentType) -> String {
    switch type {
    case .plainText: "Text"
    case .url: "Link"
    case .richText: "Rich text"
    case .image: "Image"
    case .fileURLs: "Files"
    }
}
