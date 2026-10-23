import AppKit
import ClipboardRouterAgentAccess
import ClipboardRouterCore
import ClipboardRouterSecurity
import Foundation
import os

/// Why one saved clip in the user's scope is or is not served to agents. Shown in the UI so
/// a selected-but-withheld clip is never a silent surprise.
enum AgentAccessClipEligibility: Equatable, Sendable {
    case shared
    case notSelected
    case sensitive
    case unsupportedType
    case tooLarge
    case collaborativeFolder

    var explanation: String {
        switch self {
        case .shared: "Shared with approved agents."
        case .notSelected: "Not shared."
        case .sensitive: "Withheld: it may contain a secret. Agents never receive sensitive clips."
        case .unsupportedType: "Withheld: only plain text and links can be shared."
        case .tooLarge: "Withheld: larger than 128 KB."
        case .collaborativeFolder: "Withheld: clips in shared (collaborative) folders are never shared with agents."
        }
    }
}

/// Pure, synchronous projection of the committed library snapshot onto the user's scope.
/// Runs inside `ClipboardLibrary` isolation and the authority lock, so it must not await.
struct AgentAccessScopeProjection: Sendable {
    var detector = SecretDetector()

    /// Shared-folder roots and managed folders (descendants are excluded too) and managed
    /// clip IDs. Owned by the authority so updates and the final evaluation share its lock.
    typealias Exclusions = AgentAccessExclusions

    static func descendants(of roots: Set<UUID>, in folders: [ClipFolder]) -> Set<UUID> {
        guard !roots.isEmpty else { return [] }
        let byParent = Dictionary(grouping: folders, by: \.parentFolderID)
        var result = roots
        var queue = Array(roots)
        while let parent = queue.popLast() {
            for child in byParent[parent] ?? [] where result.insert(child.id).inserted {
                queue.append(child.id)
            }
        }
        return result
    }

    func eligibility(
        of clip: SavedClip,
        scope: AgentAccessScope,
        selectedFolders: Set<UUID>,
        excludedFolders: Set<UUID>,
        exclusions: Exclusions
    ) -> AgentAccessClipEligibility {
        let selected = scope.savedClipIDs.contains(clip.id)
            || clip.folderID.map(selectedFolders.contains) == true
        guard selected else { return .notSelected }
        if exclusions.savedClipIDs.contains(clip.id) || clip.folderID.map(excludedFolders.contains) == true {
            return .collaborativeFolder
        }
        guard clip.sensitivity == nil else { return .sensitive }
        let representations = clip.content.representations
        guard clip.content.type == .plainText || clip.content.type == .url,
              representations.files.isEmpty,
              representations.referencedAssets.isEmpty
        else { return .unsupportedType }
        guard clip.content.text.utf8.count <= BrokerProtocol.maxContentBytes else { return .tooLarge }
        // Titles are scanned as well as bodies: a title can itself carry a secret.
        guard !detector.scan(clip.content).containsSecret,
              !detector.scan(text: clip.name).containsSecret
        else { return .sensitive }
        return .shared
    }

    /// Saved clips (never history, private-session or quarantine items, which are not in
    /// `savedClips`) that the scope currently shares, newest first.
    func sharedClips(
        in snapshot: ClipboardLibrarySnapshot,
        scope: AgentAccessScope,
        exclusions: Exclusions
    ) -> [SavedClip] {
        guard !scope.isEmpty else { return [] }
        let excludedFolders = Self.descendants(of: exclusions.folderIDs, in: snapshot.folders)
        let selectedFolders = Self.descendants(of: scope.folderIDs, in: snapshot.folders)
            .subtracting(excludedFolders)
        return snapshot.savedClips
            .filter {
                eligibility(of: $0, scope: scope, selectedFolders: selectedFolders, excludedFolders: excludedFolders, exclusions: exclusions) == .shared
            }
            .sorted { ($0.modifiedAt, $0.id.uuidString) > ($1.modifiedAt, $1.id.uuidString) }
    }

    static func kind(of clip: SavedClip) -> SharedContentKind {
        clip.content.type == .url ? .url : .text
    }
}

/// Thread-safe values the backend reads from connection threads.
final class AgentAccessSharedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _library: ClipboardLibrary?
    private var _status = SyncStatusReport(snapshotReady: false, sync: .disabled, lastProjection: .notAppliedThisLaunch, lastProjectionAtEpochSeconds: nil)

    var library: ClipboardLibrary? {
        get { lock.withLock { _library } }
        set { lock.withLock { _library = newValue } }
    }

    var status: SyncStatusReport {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
}

/// Serves saved clips from the committed `ClipboardLibrary` snapshot only. It never reads
/// history, the Vault, Keychain, CloudKit or the pasteboard, and never triggers sync.
struct AgentAccessLibraryBackend: AgentAccessBackend {
    let state: AgentAccessSharedState
    let projection: AgentAccessScopeProjection
    let notify: @Sendable (AgentAccessController.Notification) -> Void
    /// Test seam: suspends a read before it reaches the handoff.
    var beforeHandoff: (@Sendable () async -> Void)?
    /// Test seam: runs inside the committed-snapshot isolation immediately before the
    /// handoff (where an earlier design had already copied exclusions).
    var insideSnapshot: (@Sendable () -> Void)?

    func listSharedClips(_ channel: ReleaseChannel, limit: Int) async -> ReleaseOutcome {
        await beforeHandoff?()
        guard let library = state.library else { return .refused(.failure(.unavailable)) }
        let projection = projection
        let insideSnapshot = insideSnapshot
        return await library.withCommittedSnapshot { snapshot in
            // Scope and exclusions are evaluated under the authority lock at the handoff
            // itself, so an exclusion widened at any earlier instant always applies.
            insideSnapshot?()
            return channel.releaseScoped { scope, exclusions in
                .sharedClips(projection.sharedClips(in: snapshot, scope: scope, exclusions: exclusions)
                    .prefix(limit)
                    .map {
                        SharedClipSummary(
                            id: $0.id.uuidString.lowercased(),
                            title: $0.name,
                            kind: AgentAccessScopeProjection.kind(of: $0),
                            byteCount: $0.content.text.utf8.count,
                            modifiedAtEpochSeconds: Int64($0.modifiedAt.timeIntervalSince1970)
                        )
                    })
            }
        }
    }

    func getSharedClip(_ channel: ReleaseChannel, id: String) async -> ReleaseOutcome {
        await beforeHandoff?()
        guard let library = state.library else { return .refused(.failure(.unavailable)) }
        let projection = projection
        let requested = UUID(uuidString: id)
        let insideSnapshot = insideSnapshot
        return await library.withCommittedSnapshot { snapshot in
            insideSnapshot?()
            return channel.releaseScoped { scope, exclusions in
                // Out-of-scope, withheld and nonexistent IDs produce the identical result.
                guard let requested,
                      let clip = projection.sharedClips(in: snapshot, scope: scope, exclusions: exclusions)
                          .first(where: { $0.id == requested })
                else { return .failure(.notFound) }
                return .sharedClip(SharedClipContent(
                    id: clip.id.uuidString.lowercased(),
                    kind: AgentAccessScopeProjection.kind(of: clip),
                    text: clip.content.text
                ))
            }
        }
    }

    func syncStatus(_ channel: ReleaseChannel) async -> ReleaseOutcome {
        let report = state.status
        return channel.release { _ in .syncStatus(report) }
    }

    func vaultRequestOpened(_ info: VaultRequestInfo) async { notify(.vaultRequestOpened) }
    func pairingRequested(_ info: AgentAccessSessionInfo) async { notify(.pairingRequested) }
}

/// The one Vault item the user is reviewing for a pending agent request. Plaintext lives
/// only in memory for the foreground sheet and is cleared on lock, background, approval,
/// denial or dismissal.
struct AgentVaultPreview: Equatable {
    let requestKey: VaultRequestKey
    let itemID: UUID
    let itemName: String
    let kind: SharedContentKind
    let text: String
}

@MainActor
final class AgentAccessController: ObservableObject {
    enum Notification: Sendable { case pairingRequested, vaultRequestOpened }

    enum Availability: Equatable {
        case available
        case unavailable(String)
    }

    static let enabledKey = "agentAccess.enabled.v1"
    static let scopeKey = "agentAccess.scope.v1"

    @Published private(set) var availability: Availability = .unavailable("Checking…")
    @Published private(set) var isEnabled = false
    @Published private(set) var scope = AgentAccessScope.empty
    @Published private(set) var sessions: [AgentAccessSessionInfo] = []
    @Published private(set) var pendingVaultRequests: [VaultRequestInfo] = []
    @Published private(set) var vaultPreview: AgentVaultPreview?
    @Published private(set) var message: String?
    /// Incremented when a new pairing or Vault request needs the user's attention.
    @Published private(set) var attentionCounter = 0

    let authority: AgentAccessAuthority
    let shared = AgentAccessSharedState()
    let projection = AgentAccessScopeProjection()
    private let defaults: UserDefaults
    private let resolveIdentity: () throws -> AppIdentityContext
    private let isAppActive: () -> Bool
    private let requestAttention: () -> Void
    private let vaultLibrary: () -> VaultLibrary?
    private var listener: AgentAccessListener?
    private var identity: AppIdentityContext?
    private var pendingApproval: (key: VaultRequestKey, approval: VaultAgentHandoffApproval)?
    private var previewGeneration = 0
    private let limits: TransportLimits
    var beforeHandoff: (@Sendable () async -> Void)?

    init(
        defaults: UserDefaults,
        limits: TransportLimits = .standard,
        clock: @escaping AgentAccessAuthority.Clock = { DispatchTime.now().uptimeNanoseconds },
        isMacAppStore: Bool,
        resolveIdentity: @escaping () throws -> AppIdentityContext = { try AppIdentityContext.resolve() },
        isAppActive: @escaping () -> Bool = { NSApp?.isActive == true },
        requestAttention: @escaping () -> Void = { _ = NSApp?.requestUserAttention(.criticalRequest) },
        vaultLibrary: @escaping () -> VaultLibrary?
    ) {
        self.defaults = defaults
        self.limits = limits
        self.resolveIdentity = isMacAppStore
            ? { throw AgentAccessIdentityError.distributionChannelNotDirect }
            : resolveIdentity
        self.isAppActive = isAppActive
        self.requestAttention = requestAttention
        self.vaultLibrary = vaultLibrary
        let refresh = AgentAccessRefresh()
        authority = AgentAccessAuthority(limits: limits, clock: clock, onChange: { refresh.fire() })
        refresh.target = self
        // Off by default; a previous explicit opt-in is remembered.
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        scope = Self.loadScope(defaults)
        authority.setScope(scope)
    }

    // MARK: Lifecycle

    /// Called once the library is open. Starts listening only if the user opted in and this
    /// build is a team-signed, sandboxed, direct-channel app.
    func attach(library: ClipboardLibrary) {
        shared.library = library
        do {
            identity = try resolveIdentity()
            availability = .available
        } catch {
            identity = nil
            availability = .unavailable(Self.explain(error))
        }
        applyEnabled()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        applyEnabled()
    }

    private func applyEnabled() {
        guard isEnabled, let identity, availability == .available else {
            authority.setEnabled(false)
            listener?.stop()
            clearVaultPreview()
            refresh()
            return
        }
        authority.setEnabled(true)
        if listener == nil {
            let policy = identity.clientPolicy
            let backend = AgentAccessLibraryBackend(
                state: shared,
                projection: projection,
                notify: { [weak self] note in Task { @MainActor in self?.noteAttention(note) } },
                beforeHandoff: beforeHandoff
            )
            listener = AgentAccessListener(handler: BrokerConnectionHandler(
                limits: limits,
                authority: authority,
                backend: backend,
                authenticate: { fd in try CodeIdentityVerifier.authenticate(fd, policy: policy) },
                log: { event in AgentAccessLog.record(event) }
            ))
        }
        do {
            try listener?.start(endpoint: identity.endpoint)
            message = nil
        } catch {
            authority.setEnabled(false)
            message = "Agent Access could not start (\(Self.reasonCode(error)))."
        }
        refresh()
    }

    /// Screen lock, sleep and quit end every agent session; backgrounding and Vault lock end
    /// pending Vault requests (the app is a menu-bar app, so ordinary clip sessions survive
    /// switching apps).
    func handleLifecycle(_ event: VaultLifecycleEvent) {
        switch event {
        case .appDidEnterBackground:
            authority.cancelPendingVaultRequests(.appBackgrounded)
        case .screenDidLock:
            authority.revokeAllSessions(.screenLocked)
        case .systemWillSleep:
            authority.revokeAllSessions(.systemSleep)
        case .appWillTerminate:
            authority.setEnabled(false)
            listener?.stop()
        }
        clearVaultPreview()
        refresh()
    }

    func vaultDidLock() {
        authority.cancelPendingVaultRequests(.vaultLocked)
        clearVaultPreview()
        refresh()
    }

    // MARK: Scope

    func setClip(_ id: UUID, included: Bool) {
        var next = scope
        if included { next.savedClipIDs.insert(id) } else { next.savedClipIDs.remove(id) }
        applyScope(next)
    }

    func setFolder(_ id: UUID, included: Bool) {
        var next = scope
        if included { next.folderIDs.insert(id) } else { next.folderIDs.remove(id) }
        applyScope(next)
    }

    func clearScope() { applyScope(.empty) }

    private func applyScope(_ next: AgentAccessScope) {
        scope = next
        authority.setScope(next)
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.scopeKey) }
    }

    private static func loadScope(_ defaults: UserDefaults) -> AgentAccessScope {
        guard let data = defaults.data(forKey: scopeKey),
              let scope = try? JSONDecoder().decode(AgentAccessScope.self, from: data)
        else { return .empty }
        return scope
    }

    func eligibility(of clip: SavedClip, in snapshot: ClipboardLibrarySnapshot) -> AgentAccessClipEligibility {
        let exclusions = authority.currentExclusions
        let excludedFolders = AgentAccessScopeProjection.descendants(of: exclusions.folderIDs, in: snapshot.folders)
        let selectedFolders = AgentAccessScopeProjection.descendants(of: scope.folderIDs, in: snapshot.folders)
            .subtracting(excludedFolders)
        return projection.eligibility(of: clip, scope: scope, selectedFolders: selectedFolders, excludedFolders: excludedFolders, exclusions: exclusions)
    }

    /// Collaborative exclusions only ever widen during a launch: a folder that was shared at
    /// any point stays withheld until relaunch, so an exclusion can never be dropped ahead of
    /// the removal of collaborators' data.
    func addExclusions(folderIDs: Set<UUID>, savedClipIDs: Set<UUID>) {
        authority.widenExclusions(folderIDs: folderIDs, savedClipIDs: savedClipIDs)
    }

    func updateStatus(_ report: SyncStatusReport) {
        shared.status = report
    }

    // MARK: Sessions

    var pendingPairings: [AgentAccessSessionInfo] { sessions.filter { $0.state == .pendingApproval } }
    var activeSessions: [AgentAccessSessionInfo] { sessions.filter { $0.state == .approved } }

    func approvePairing(_ sessionID: String) {
        if !authority.decidePairing(sessionID, approve: true) {
            message = "That request is no longer waiting."
        }
        refresh()
    }

    func denyPairing(_ sessionID: String) {
        authority.decidePairing(sessionID, approve: false)
        refresh()
    }

    func revoke(_ sessionID: String) {
        authority.revokeSession(sessionID)
        refresh()
    }

    func revokeAll() {
        authority.revokeAllSessions(.userRevoked)
        clearVaultPreview()
        refresh()
    }

    // MARK: Vault handoff

    enum VaultHandoffError: Error, Equatable {
        case vaultUnavailable, requestEnded, unsupportedItem, notForeground, itemChanged
    }

    nonisolated static func supportsHandoff(_ item: VaultItem) -> Bool {
        let representations = item.content.representations
        return (item.content.type == .plainText || item.content.type == .url)
            && item.assets.isEmpty
            && representations.files.isEmpty
            && representations.referencedAssets.isEmpty
            && item.content.text.utf8.count <= BrokerProtocol.maxContentBytes
    }

    /// Decrypts one user-picked item for the foreground review sheet. Does not extend the
    /// Vault idle timeout and does not release anything.
    func previewVaultItem(requestKey: VaultRequestKey, itemID: UUID) async {
        clearVaultPreview()
        previewGeneration += 1
        let generation = previewGeneration
        guard authority.isVaultRequestPending(requestKey) else {
            message = "That Vault request is no longer waiting."
            return
        }
        guard let vault = vaultLibrary() else {
            message = "Unlock the Vault to choose an item."
            return
        }
        do {
            let preview = try await vault.agentHandoffPreview(id: itemID)
            guard generation == previewGeneration, authority.isVaultRequestPending(requestKey) else { return }
            guard Self.supportsHandoff(preview.item) else {
                message = "Only plain text and link items can be shared with an agent."
                return
            }
            pendingApproval = (requestKey, preview.approval)
            vaultPreview = AgentVaultPreview(
                requestKey: requestKey,
                itemID: itemID,
                itemName: preview.item.name,
                kind: preview.item.content.type == .url ? .url : .text,
                text: preview.item.content.text
            )
        } catch {
            message = "Unlock the Vault to choose an item."
        }
    }

    /// Approve once: releases exactly the previewed envelope, in the same unlock epoch,
    /// while the app is in the foreground. Unlocking alone never releases anything.
    @discardableResult
    func approveVaultPreview() async -> VaultReleaseOutcome? {
        guard let preview = vaultPreview, let pending = pendingApproval, pending.key == preview.requestKey else { return nil }
        guard isAppActive() else {
            message = "Bring Clipboard Router to the front to approve."
            return nil
        }
        guard let vault = vaultLibrary() else {
            clearVaultPreview()
            return nil
        }
        let authority = authority
        let key = pending.key
        // Clear plaintext from the UI before the release completes.
        clearVaultPreview()
        do {
            let outcome = try await vault.releaseApprovedAgentHandoff(pending.approval) { item, unlock in
                guard Self.supportsHandoff(item) else { return VaultReleaseOutcome.notPending }
                // The Vault deadline is re-checked under the authority lock right before the
                // send, in case it passed while waiting for that lock.
                return authority.releaseVault(key, stillUnlocked: { unlock.isStillUnlocked() }) {
                    VaultHandoff(kind: item.content.type == .url ? .url : .text, text: item.content.text)
                }
            }
            message = outcome == .handedOff
                ? "Shared one Vault item with the agent. It cannot be recalled from the agent."
                : "The Vault item was not shared (the request ended)."
            refresh()
            return outcome
        } catch {
            message = "The Vault item was not shared: the Vault locked or the item changed."
            refresh()
            return nil
        }
    }

    func denyVaultRequest(_ key: VaultRequestKey) {
        authority.denyVaultRequest(key)
        if vaultPreview?.requestKey == key { clearVaultPreview() }
        refresh()
    }

    func cancelVaultPreview() { clearVaultPreview() }

    private func clearVaultPreview() {
        previewGeneration += 1
        pendingApproval = nil
        vaultPreview = nil
    }

    // MARK: Refresh

    func refresh() {
        sessions = authority.sessionList
        pendingVaultRequests = authority.pendingVaultRequests
        if let preview = vaultPreview, !pendingVaultRequests.contains(where: { $0.key == preview.requestKey }) {
            clearVaultPreview()
        }
    }

    private func noteAttention(_: Notification) {
        refresh()
        attentionCounter += 1
        requestAttention()
    }

    static func reasonCode(_ error: any Error) -> String {
        if let error = error as? AgentAccessIdentityError { return error.reasonCode }
        if let error = error as? LocalIPCError { return error.reasonCode }
        return "unexpected"
    }

    static func explain(_ error: any Error) -> String {
        switch error as? AgentAccessIdentityError {
        case .distributionChannelNotDirect:
            return "Agent Access is available in the direct-download version of Clipboard Router."
        case .endpointPathTooLong:
            return "Agent Access is unavailable because this account's home folder path is too long (max \(AgentAccessEndpoint.maxHomePathBytes(appBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.clipboardrouter.ClipboardRouter")) bytes)."
        case .unsignedOrAdHoc, .notHardened, .unexpectedIdentifier, .selfSigningUnavailable:
            return "Agent Access requires a signed release build."
        case .appNotSandboxed:
            return "Agent Access requires the sandboxed app."
        case .containerHomeMismatch:
            return "Agent Access is unavailable because the app is not running in its own sandbox container."
        default:
            return "Agent Access is unavailable (\(reasonCode(error)))."
        }
    }
}

/// Coalesces authority change callbacks (any thread) into one MainActor refresh.
private final class AgentAccessRefresh: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false
    weak var target: AgentAccessController?

    func fire() {
        let shouldSchedule: Bool = lock.withLock {
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            self?.lock.withLock { self?.scheduled = false }
            self?.target?.refresh()
        }
    }
}

/// Content-free diagnostics: event names, reason codes and timings only.
enum AgentAccessLog {
    private static let logger = os.Logger(subsystem: "com.clipboardrouter.ClipboardRouter", category: "agent-access")

    static func record(_ event: AgentAccessEvent) {
        logger.info("\(event.line, privacy: .public)")
    }
}
