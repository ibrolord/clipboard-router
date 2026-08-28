import ClipboardRouterCore
import ClipboardRouterSecurity
import ClipboardRouterSync
import SwiftUI

struct FeatureSectionListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            switch model.selectedSection {
            case .clipboardHealth:
                Label("Review sensitive clips", systemImage: "shield.checkered")
                    .badge(model.clipboardHealth.quarantinedClipCount)
                ForEach(model.quarantineReceipts) { receipt in
                    Label(
                        receipt.detections.first.map { humanized($0.category.rawValue) }
                            ?? "Sensitive clip",
                        systemImage: "exclamationmark.shield"
                    )
                }
            case .workflows:
                Label("Combine Clips", systemImage: "square.stack.3d.up")
                    .badge(model.combinedClips?.items.count ?? 0)
                Label("Paste Stack", systemImage: "square.stack.3d.up")
                    .badge(model.pasteStackItems.count)
            case .sync:
                Label(syncTitle, systemImage: syncSymbol)
                Label(
                    model.syncContainerIdentifier == nil
                        ? "\(model.snapshot.savedClips.count + model.snapshot.folders.count) eligible saved items"
                        : "\(model.pendingSavedLibraryEntityCount) pending",
                    systemImage: model.syncContainerIdentifier == nil ? "tray" : "tray.full"
                )
            case .automaticOrganization:
                Label(
                    "\(model.automaticOrganizationSnapshot.rules.count) rules",
                    systemImage: "wand.and.stars"
                )
                Label(
                    "\(model.automaticOrganizationSnapshot.receipts.count) undo receipts",
                    systemImage: "arrow.uturn.backward"
                )
            default:
                EmptyView()
            }
        }
        .listStyle(.inset)
    }

    private var syncTitle: String {
        switch model.syncSnapshot.status {
        case .disabled: "iCloud sync is off"
        case .idle: "Saved library is up to date"
        case .syncing: "Syncing saved library"
        case .offline: "Offline; changes are queued"
        case .accountUnavailable: "iCloud account unavailable"
        case .failed: "Sync needs attention"
        }
    }

    private var syncSymbol: String {
        model.isSavedLibrarySyncEnabled ? "icloud" : "icloud.slash"
    }
}

struct ClipboardHealthDashboardView: View {
    private enum DeletionTarget: Identifiable {
        case one(UUID)
        case all([UUID])
        var id: String {
            switch self {
            case let .one(id): "one-\(id.uuidString)"
            case let .all(ids): "all-\(ids.map(\.uuidString).sorted().joined(separator: "-"))"
            }
        }
    }

    @ObservedObject var model: AppModel
    @State private var quarantinedClipToKeep: UUID?
    @State private var deletionTarget: DeletionTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dashboardHeader(
                "Clipboard Health",
                subtitle: "New sensitive values wait in memory for review. Older retained items stay masked."
            )
            Divider()
            if model.quarantineReceipts.isEmpty {
                if model.persistedSensitiveItemCount > 0 {
                    ContentUnavailableView {
                        Label("Previously stored sensitive items need review", systemImage: "exclamationmark.shield")
                    } description: {
                        Text("New detections are quarantined in memory. \(model.persistedSensitiveItemCount) older item(s) remain masked in ordinary storage until you review them.")
                    } actions: {
                        Button("Open Sensitive Review") {
                            model.applySmartView(.sensitiveReview)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView(
                        "No sensitive clips waiting",
                        systemImage: "checkmark.shield",
                        description: Text("Nothing is waiting in quarantine or marked for review in ordinary storage.")
                    )
                }
            } else {
                List {
                    Section {
                        HStack {
                            Button("Vault All Eligible", systemImage: "lock") {
                                model.moveAllEligibleQuarantinedClipsToVault()
                            }
                            .disabled(model.vaultAvailabilityMessage != nil)
                            Spacer()
                            Button("Delete All…", systemImage: "trash", role: .destructive) {
                                deletionTarget = .all(model.quarantineReceipts.map(\.id))
                            }
                        }
                    } footer: {
                        Text("Rich or binary clips remain for individual review because this Vault version fails closed instead of discarding representations.")
                    }
                    Section("Category counts") {
                        ForEach(
                            model.clipboardHealth.categoryCounts.keys.sorted {
                                $0.rawValue < $1.rawValue
                            },
                            id: \.self
                        ) { category in
                            LabeledContent(
                                humanized(category.rawValue),
                                value: "\(model.clipboardHealth.count(for: category))"
                            )
                        }
                    }
                    Section("Review") {
                        ForEach(model.quarantineReceipts) { receipt in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(
                                        receipt.detections.map {
                                            humanized($0.category.rawValue)
                                        }.joined(separator: ", "),
                                        systemImage: "exclamationmark.shield.fill"
                                    )
                                    .foregroundStyle(.orange)
                                    Spacer()
                                    Text(receipt.detectedAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button("Encrypt & Share…", systemImage: "lock.shield") {
                                        model.presentEncryptedShareForQuarantine(id: receipt.id)
                                    }
                                    .help("Encrypt this quarantined value for an authenticated recipient without placing it in History")
                                    Button("Keep Masked in History…") {
                                        quarantinedClipToKeep = receipt.id
                                    }
                                    Button("Move to Vault") {
                                        model.moveQuarantinedClipToVault(id: receipt.id)
                                    }
                                    .disabled(model.vaultAvailabilityMessage != nil)
                                    Spacer()
                                    Button("Delete…", role: .destructive) {
                                        deletionTarget = .one(receipt.id)
                                    }
                                }
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .confirmationDialog(
            "Keep this sensitive value in History?",
            isPresented: Binding(
                get: { quarantinedClipToKeep != nil },
                set: { if !$0 { quarantinedClipToKeep = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Keep Masked in History") {
                if let id = quarantinedClipToKeep { model.keepQuarantinedClip(id: id) }
                quarantinedClipToKeep = nil
            }
            Button("Cancel", role: .cancel) { quarantinedClipToKeep = nil }
        } message: {
            Text("The full value will be persisted locally in ordinary History, but its preview remains masked. Vault is the safer choice for long-term retention.")
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                switch deletionTarget {
                case let .one(id): model.deleteQuarantinedClip(id: id)
                case let .all(ids): model.deleteQuarantinedClips(ids: ids)
                case nil: break
                }
                deletionTarget = nil
            }
            Button("Cancel", role: .cancel) { deletionTarget = nil }
        } message: {
            Text("This removes the quarantined value from Clipboard Router. This cannot be undone.")
        }
    }

    private var deletionTitle: String {
        switch deletionTarget {
        case .one: "Delete this sensitive clip?"
        case let .all(ids): "Delete all \(ids.count) sensitive clips?"
        case nil: "Delete sensitive clips?"
        }
    }
}

struct WorkflowDashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dashboardHeader(
                "Actions",
                subtitle: "Build repeatable next steps, or assemble clips for a focused paste session."
            )
            Divider()
            Picker("Actions workspace", selection: $model.actionsWorkspaceMode) {
                ForEach(ActionsWorkspaceMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("uiAcceptance.actions.workspaceMode")
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()

            if model.actionsWorkspaceMode == .automations {
                AutomationSettings(model: model)
            } else {
                Form {
                Section("One-click paste") {
                    HStack(alignment: .center, spacing: 12) {
                        Label(
                            model.pasteAutomationAccess == .trusted
                                ? "Accessibility enabled"
                                : "Accessibility permission is optional",
                            systemImage: model.pasteAutomationAccess == .trusted
                                ? "checkmark.shield" : "keyboard"
                        )
                        Spacer()
                        if model.pasteAutomationAccess != .trusted {
                            Button("Request Access…") {
                                model.requestPasteAutomationAccess()
                            }
                        }
                    }
                    Text("The menu-bar paste button copies the clip, then sends Command-V only to the app that was active before the menu opened. Without permission, the clip stays copied for manual paste.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Combine Clips") {
                    if let pack = model.combinedClips {
                        ForEach(Array(pack.items.enumerated()), id: \.element.id) { index, item in
                            HStack {
                                Text(verbatim: String(index + 1) + ". " + item.title)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    model.removeFromCombinedClips(itemID: item.id)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(item.title) from Combine Clips")
                            }
                        }
                        HStack {
                            Button("Review and Use…", systemImage: "rectangle.and.text.magnifyingglass") {
                                model.prepareCombinedClipsReview()
                            }
                            .buttonStyle(.borderedProminent)
                            Spacer()
                            Button("Clear", role: .destructive) { model.clearCombinedClips() }
                        }
                    } else {
                        Text("Add clips from their More menus, then review them together before copying, using AI, saving a note, or sharing.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Debug Bundle") {
                    HStack {
                        Label(
                            model.activeDeveloperProject?.name ?? "No Active Project",
                            systemImage: "hammer"
                        )
                        .foregroundStyle(model.activeDeveloperProject == nil ? .secondary : .primary)
                        Spacer()
                        Button("Projects…") {
                            model.selectLibrarySection(.developerProjects)
                        }
                    }
                    if let pack = model.debugBundlePack {
                        ForEach(Array(pack.items.enumerated()), id: \.element.id) { index, item in
                            HStack {
                                Text(verbatim: String(index + 1) + ". " + item.title)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    model.moveDebugBundleItem(itemID: item.id, offset: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == pack.items.startIndex)
                                .help("Move earlier")
                                .accessibilityLabel("Move \(item.title) earlier in Debug Bundle")
                                .accessibilityIdentifier(
                                    DebugBundleAccessibility.moveEarlier(item.id)
                                )
                                Button {
                                    model.moveDebugBundleItem(itemID: item.id, offset: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == pack.items.index(before: pack.items.endIndex))
                                .help("Move later")
                                .accessibilityLabel("Move \(item.title) later in Debug Bundle")
                                .accessibilityIdentifier(
                                    DebugBundleAccessibility.moveLater(item.id)
                                )
                                Button {
                                    model.removeFromDebugBundle(itemID: item.id)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(item.title) from Debug Bundle")
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Debug Bundle item \(index + 1), \(item.title)")
                            .accessibilityIdentifier(DebugBundleAccessibility.item(item.id))
                        }
                        HStack {
                            Button("Review Bundle…", systemImage: "ladybug") {
                                model.prepareDebugBundleReview()
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier(DebugBundleAccessibility.review)
                            Spacer()
                            Button("Clear", role: .destructive) { model.clearDebugBundle() }
                                .accessibilityIdentifier(DebugBundleAccessibility.clear)
                        }
                    } else {
                        Text("Add code, errors, logs, commands, or text from a clip's More > Clip Tools menu, then review the exact Markdown before using it.")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier(DebugBundleAccessibility.workspace)
                .accessibilityValue(debugBundleWorkspaceValue)

                Section("Paste Stack — copy first") {
                    if model.pasteStackItems.isEmpty {
                        Text("Add clips to create a first-in, first-out copy queue.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.pasteStackItems.enumerated()), id: \.element.id) {
                            index, clip in
                            PasteStackRow(
                                clip: clip,
                                isCurrent: index == model.pasteStackCurrentIndex
                            )
                        }
                        HStack {
                            Button("Previous", systemImage: "chevron.left") {
                                model.previousPasteStackItem()
                            }
                            Button("Copy Next", systemImage: "doc.on.doc") {
                                model.copyNextPasteStackItem()
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Skip", systemImage: "forward") {
                                model.skipPasteStackItem()
                            }
                            Button("Restart", systemImage: "arrow.counterclockwise") {
                                model.restartPasteStack()
                            }
                            Spacer()
                            Button("Clear", role: .destructive) { model.clearPasteStack() }
                        }
                        .disabled(model.isPasteStackWriteInFlight)
                        if model.isPasteStackWriteInFlight {
                            ProgressView("Writing the current clip to the clipboard…")
                                .controlSize(.small)
                        }
                        Text("The stack advances only after macOS confirms the clipboard write. It never claims or performs a direct paste.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let preview = model.transformPreview {
                    Section("Transform Preview — \(preview.title)") {
                        Text(preview.transformedText)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                        HStack {
                            Button("Copy Result", systemImage: "doc.on.doc") {
                                model.copyTransformPreview()
                            }
                            Spacer()
                            Button("Dismiss") { model.dismissTransformPreview() }
                        }
                        Text("Transforms are deterministic and local. The source clip is immutable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
                .formStyle(.grouped)
            }
        }
    }

    private var debugBundleWorkspaceValue: String {
        let project = model.activeDeveloperProject?.name ?? "No active project"
        let itemCount = model.debugBundlePack?.items.count ?? 0
        return "\(project), \(itemCount) item\(itemCount == 1 ? "" : "s")"
    }
}

private struct PasteStackRow: View {
    let clip: PresentedClip
    let isCurrent: Bool

    var body: some View {
        HStack {
            Image(systemName: isCurrent ? "arrow.right.circle.fill" : "circle")
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            Text(clip.title).lineLimit(1)
        }
    }
}

struct SyncDashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Saved clips and folders") {
                Toggle(
                    "Sync with iCloud",
                    isOn: Binding(
                        get: { model.isSavedLibrarySyncEnabled },
                        set: { model.setSavedLibrarySyncEnabled($0) }
                    )
                )
                .disabled(model.syncContainerIdentifier == nil && !model.isSavedLibrarySyncEnabled)
                Label(
                    "History, Vault, quarantine, and Private Sessions are never synced.",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Live status") {
                LabeledContent("State", value: syncState)
                if model.syncContainerIdentifier == nil {
                    LabeledContent(
                        "Eligible saved items",
                        value: "\(model.snapshot.savedClips.count + model.snapshot.folders.count)"
                    )
                } else {
                    LabeledContent(
                        "Pending changes",
                        value: "\(model.pendingSavedLibraryEntityCount)"
                    )
                }
                if let last = model.syncLastSuccessfulDate {
                    LabeledContent("Last successful sync") { Text(last, style: .relative) }
                }
                LabeledContent(
                    "CloudKit container",
                    value: model.syncContainerIdentifier ?? "Not configured in this build"
                )
                if let message = model.syncAvailabilityMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                    model.synchronizeSavedLibrary()
                }
                .disabled(!model.isSavedLibrarySyncEnabled || model.syncContainerIdentifier == nil)
            }
            if model.hasPendingSyncAccountChange {
                Section("iCloud account changed") {
                    Label(
                        "Sync is paused before upload because macOS reported a different iCloud account.",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                    .foregroundStyle(.orange)
                    LabeledContent("Previously approved", value: model.approvedSyncAccountLabel)
                    LabeledContent("Newly detected", value: model.pendingSyncAccountLabel)
                    Text("Confirm only if you intend to upload queued saved clips and folders to the newly detected account. History and Vault are never included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Keep Sync Paused") { model.keepSyncAccountChangePaused() }
                        Spacer()
                        Button("Confirm New Account and Sync") {
                            model.confirmPendingSyncAccountChange()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            Section("Saved-item states") {
                LabeledContent("Synced", value: "\(stateCount(.synced))")
                LabeledContent("Queued or uploading", value: "\(stateCount(.pending))")
                LabeledContent("Local only", value: "\(stateCount(.localOnly))")
                LabeledContent("Needs attention", value: "\(stateCount(.attention))")
                Text("Rich text and images sync with verified, content-addressed assets. File references remain Local Only unless their bytes are explicitly imported. History, Vault, quarantine, and Private Sessions never enter this sync log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.snapshot.folders.isEmpty && model.snapshot.savedClips.isEmpty {
                    Text("Save a clip to see its individual sync state.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.snapshot.folders.sorted { $0.sortOrder < $1.sortOrder }) { folder in
                        syncEntityRow(
                            name: folder.name,
                            symbol: "folder",
                            state: model.syncSnapshot.entityStates[folder.id]
                        )
                    }
                    ForEach(model.snapshot.savedClips.sorted { $0.modifiedAt > $1.modifiedAt }) { clip in
                        syncEntityRow(
                            name: clip.name,
                            symbol: "doc",
                            state: model.syncSnapshot.entityStates[clip.id]
                        )
                    }
                }
            }
            Section("Collaborative folders") {
                if model.sharedFolderSnapshots.isEmpty {
                    Label("No shared folders", systemImage: "person.2.slash")
                    Text("Open a saved folder's menu and choose Share Folder. Clipboard Router checks signed CloudKit capability before creating anything.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(
                        model.sharedFolderSnapshots.values.sorted {
                            $0.location.title.localizedStandardCompare($1.location.title)
                                == .orderedAscending
                        },
                        id: \.location.folderID
                    ) { shared in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(shared.location.title, systemImage: "person.2.fill")
                                    .font(.body.weight(.semibold))
                                Spacer()
                                Text(shared.currentRole.rawValue.capitalized)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            LabeledContent("Folder sync", value: sharedStatus(shared.status))
                            if !shared.recoveryCopies.isEmpty {
                                Label(
                                    "\(shared.recoveryCopies.count) recoverable conflict \(shared.recoveryCopies.count == 1 ? "copy" : "copies") retained",
                                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                            ForEach(shared.participants) { participant in
                                HStack {
                                    Text(participant.displayName)
                                    Spacer()
                                    Text("\(participant.role.rawValue.capitalized) · \(participant.acceptance.rawValue.capitalized)")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }
                            HStack {
                                Button("Refresh", systemImage: "arrow.clockwise") {
                                    model.refreshSharedFolder(id: shared.location.folderID)
                                }
                                Button("Manage Sharing…", systemImage: "person.badge.plus") {
                                    model.presentSharedFolderInvitationSurface(
                                        folderID: shared.location.folderID
                                    )
                                }
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }
                if let message = model.sharedFolderMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                Text("Sharing scope: the selected folder, eligible saved clips, clip titles, timestamps, and attached source-app/device context. History, Vault, quarantine, sensitive clips, binary assets, and device-local file references are excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Live invitation delivery and cross-account propagation still require a correctly signed iCloud build and two real Apple accounts; this screen reports only observed CloudKit results.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Pilot measurement") {
                Label(
                    "Metrics stay on this Mac and use only coarse enums and counts. Clip content, searches, URLs, apps, folders, tags, people, and Vault activity are excluded.",
                    systemImage: "chart.bar.doc.horizontal"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Export Content-Blind Metrics…", systemImage: "square.and.arrow.up") {
                    model.exportProductMetrics()
                }
            }
        }
        .formStyle(.grouped)
    }

    private enum StateGroup { case synced, pending, localOnly, attention }

    private func stateCount(_ group: StateGroup) -> Int {
        let liveIDs = Set(model.snapshot.folders.map(\.id) + model.snapshot.savedClips.map(\.id))
        return model.syncSnapshot.entityStates.reduce(into: 0) { count, entry in
            guard liveIDs.contains(entry.key) else { return }
            let state = entry.value
            switch (group, state) {
            case (.synced, .synced), (.pending, .queued), (.pending, .preparingAssets),
                 (.pending, .uploadingAssets), (.pending, .downloadingAssets),
                 (.pending, .uploading),
                 (.localOnly, .localOnly), (.attention, .conflict), (.attention, .failed):
                count += 1
            default:
                break
            }
        }
    }

    private var syncState: String {
        if model.hasPendingSyncAccountChange { return "Waiting for account confirmation" }
        return switch model.syncSnapshot.status {
        case .disabled: "Off"
        case .idle: "Up to date"
        case .syncing: "Syncing"
        case .offline: "Offline — queued"
        case .accountUnavailable: "Account unavailable"
        case .failed: "Needs attention"
        }
    }

    private func syncEntityRow(
        name: String,
        symbol: String,
        state: SyncEntityState?
    ) -> some View {
        HStack {
            Label(name, systemImage: symbol).lineLimit(1)
            Spacer()
            Text(syncEntityStateText(state))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func syncEntityStateText(_ state: SyncEntityState?) -> String {
        guard let state else { return model.isSavedLibrarySyncEnabled ? "Waiting" : "Sync off" }
        return switch state {
        case let .localOnly(reason): "Local only: \(reason.rawValue)"
        case .queued: "Queued"
        case .preparingAssets: "Preparing attachments"
        case .uploadingAssets: "Uploading attachments"
        case .downloadingAssets: "Recovering attachments"
        case .uploading: "Uploading"
        case let .synced(date, _): "Synced \(date.formatted(.relative(presentation: .named)))"
        case .conflict: "Conflict"
        case let .failed(message): "Failed: \(message)"
        }
    }

    private func sharedStatus(_ status: SharedFolderSessionStatus) -> String {
        switch status {
        case .idle: "Ready"
        case .syncing: "Syncing"
        case let .synced(date): "Synced at \(date.formatted(date: .omitted, time: .shortened))"
        case let .failed(message): "Needs attention: \(message)"
        }
    }
}

@ViewBuilder
private func dashboardHeader(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.title2.weight(.semibold))
        Text(subtitle).font(.callout).foregroundStyle(.secondary)
    }
    .padding(20)
}

private func humanized(_ value: String) -> String {
    value.reduce(into: "") { result, character in
        if character.isUppercase, !result.isEmpty { result.append(" ") }
        result.append(character)
    }.capitalized
}
