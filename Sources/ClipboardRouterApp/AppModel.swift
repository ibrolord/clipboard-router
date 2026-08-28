import AppKit
import CloudKit
import ClipboardRouterCore
import ClipboardRouterPlatform
import ClipboardRouterSecurity
import ClipboardRouterSync
import Combine
import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers

enum LibrarySection: Hashable {
    case history
    case allSaved
    case folder(UUID)
    case searchResults
    case smartView(SmartViewID)
    case vault
    case clipboardHealth
    case privateSession
    case workflows
    case sync
    case developerProjects
    case automaticOrganization
}

enum ActionsWorkspaceMode: String, CaseIterable, Identifiable {
    case automations = "Custom Actions"
    case pasteTools = "Clip Tools"

    var id: Self { self }
}

enum RequestPresentationSurface: Equatable, Sendable {
    case library
    case menuBar
}

enum ApplicationDiscoveryRequest: Equatable {
    case start(generation: UInt64)
    case coalesced
    case reuseCached
}

struct ApplicationDiscoveryCoordinator {
    let cacheTTL: TimeInterval
    private(set) var inFlightGeneration: UInt64?
    private(set) var lastCompletedAt: Date?
    private var nextGeneration: UInt64 = 0

    init(cacheTTL: TimeInterval, lastCompletedAt: Date? = nil) {
        precondition(cacheTTL > 0)
        self.cacheTTL = cacheTTL
        self.lastCompletedAt = lastCompletedAt
    }

    mutating func request(at now: Date, force: Bool) -> ApplicationDiscoveryRequest {
        if inFlightGeneration != nil {
            return .coalesced
        }
        if !force, isCacheFresh(at: now) {
            return .reuseCached
        }
        nextGeneration &+= 1
        inFlightGeneration = nextGeneration
        return .start(generation: nextGeneration)
    }

    func isCurrent(generation: UInt64) -> Bool {
        inFlightGeneration == generation
    }

    mutating func complete(generation: UInt64, at date: Date) -> Bool {
        guard inFlightGeneration == generation else { return false }
        inFlightGeneration = nil
        lastCompletedAt = date
        return true
    }

    mutating func cancel(generation: UInt64) -> Bool {
        guard inFlightGeneration == generation else { return false }
        inFlightGeneration = nil
        return true
    }

    private func isCacheFresh(at now: Date) -> Bool {
        guard let lastCompletedAt else { return false }
        let age = now.timeIntervalSince(lastCompletedAt)
        return age >= 0 && age < cacheTTL
    }
}

/// A follow-up interaction started from MenuBarExtra must outlive the transient menu-bar window.
/// A dedicated AppKit window controller owns these requests independently from the Library.
struct MenuBarContinuationRequest: Identifiable {
    enum Action {
        case quickPaste
        case noteEditor(NoteEditorRequest)
        case clipEditor(ClipEditorRequest)
        case calendar(CalendarEventDraftRequest)
        case newFolder(PresentedClip)
        case vaultMove(clip: PresentedClip, summary: VaultMoveSummary)
        case shortcutEditor(PresentedClip)
        case encryptedShare(EncryptedShareRequest)
        case sensitiveExport(clip: PresentedClip, category: String)
        case newDeveloperProject(PresentedClip)
        case assistant(AIClipAssistantRequest)
        case contact(ContactDraftRequest)
    }

    let id = UUID()
    let action: Action
}

private extension SharedFolderSessionStatus {
    var successDate: Date? {
        if case let .synced(date) = self { return date }
        return nil
    }
}

private extension LibrarySection {
    var isOrdinarySearchPresentation: Bool {
        switch self {
        case .searchResults, .smartView:
            true
        default:
            false
        }
    }
}

enum SmartViewID: Hashable, Sendable {
    case notes
    case today
    case frequentlyUsed
    case links
    case images
    case files
    case pdfs
    case sensitiveReview
    case unfiledSaved
    case pinnedSaved
    case application(query: String, name: String)
    case domain(String)
    case user(UUID)
}

struct SmartViewDefinition: Identifiable, Equatable, Sendable {
    let id: SmartViewID
    let title: String
    let systemImage: String
    let query: String
    let count: Int
}

struct SearchQueryChip: Identifiable, Equatable, Sendable {
    let id: Int
    let token: String
    let label: String
}

enum AppModelOperationError: Error, LocalizedError, Equatable {
    case operationInProgress
    case historyClipRequired
    case ordinaryClipRequired
    case sensitiveExportConfirmationRequired
    case localFileArchiveUnsupported
    case clipArchiveOmitted
    case libraryUnavailable
    case collaborativeVaultMoveUnsupported
    case vaultMoveReconfirmationRequired
    case sensitiveNoteRequiresVault(category: String)
    case sensitiveClipEditRequiresVault(category: String)
    case generatedSensitiveContent
    case combinedClipsUnavailable
    case combinedClipsChanged
    case debugBundleUnavailable
    case debugBundleChanged
    case automaticOrganizationCrossSpace

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            "Please wait for the current library change to finish."
        case .historyClipRequired:
            "Only a clip from History can be saved into a new folder."
        case .ordinaryClipRequired:
            "Private Session clips cannot be persisted, exported, or shared."
        case .sensitiveExportConfirmationRequired:
            "This clip was flagged as sensitive. Confirm the warning before exporting it."
        case .localFileArchiveUnsupported:
            "Local file references cannot be packaged. Use Share Clip instead."
        case .clipArchiveOmitted:
            "The clip could not be included in the portable archive."
        case .libraryUnavailable:
            "Your clip library is not available yet."
        case .collaborativeVaultMoveUnsupported:
            "Move this clip out of its collaborative folder before moving it to your private Vault."
        case .vaultMoveReconfirmationRequired:
            "The History or Saved copies changed. Review the updated removal count and confirm the Vault move again."
        case let .sensitiveNoteRequiresVault(category):
            "Secret-like content was detected (\(category)). The note was not saved to your ordinary library, sync, or shared folders. Remove the secret, or store it in Vault instead."
        case let .sensitiveClipEditRequiresVault(category):
            "Secret-like content was detected (\(category)). The edited clip was not saved to your ordinary library, sync, or shared folders. Remove the secret, or store it in Vault instead."
        case .generatedSensitiveContent:
            "The generated draft may contain a secret. It was not saved. Review the result or move the source to Vault."
        case .combinedClipsUnavailable:
            "Add at least one eligible clip before opening Combine Clips."
        case .combinedClipsChanged:
            "One or more source clips changed, expired, or became sensitive. Review the collection again before using it."
        case .debugBundleUnavailable:
            "Add at least one eligible clip before reviewing a Debug Bundle."
        case .debugBundleChanged:
            "One or more Debug Bundle sources changed, expired, or became sensitive. Review the bundle again before using it."
        case .automaticOrganizationCrossSpace:
            "Automatic Organization cannot move items between personal and shared folder spaces."
        }
    }
}

struct PresentedClip: Identifiable, Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        case history
        case saved(folderID: UUID?)
        case privateSession
    }

    let id: UUID
    let title: String
    let content: ClipContent
    let date: Date
    let sourceBundleIdentifier: String?
    let origin: Origin
    var savedItemKind: SavedItemKind = .clip
    var captureContext: ClipCaptureContext? = nil
    var sensitivity: ClipSensitivityMetadata? = nil
    var isPinned = false
    var tags: [String] = []
    var pasteboardTypeIdentifiers: [String] = []
    var captureCount: Int?
    var pasteCount: Int?
    var lastPastedAt: Date?
}

/// Explicit source for the encrypted-share composer. A quarantine source keeps its content
/// process-local until the user encrypts it or moves it into Vault; it never becomes ordinary
/// History merely to make sharing possible.
struct EncryptedShareRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let content: ClipContent
    let quarantineID: UUID?

    init(clip: PresentedClip) {
        id = clip.id
        title = clip.title
        content = clip.content
        quarantineID = nil
    }

    init(quarantineID: UUID, content: ClipContent, title: String = "Quarantined secret") {
        id = quarantineID
        self.title = title
        self.content = content
        self.quarantineID = quarantineID
    }
}

struct CalendarEventDraftRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceClip: PresentedClip
    let draft: CalendarEventDraft

    init(sourceClip: PresentedClip, draft: CalendarEventDraft) {
        id = UUID()
        self.sourceClip = sourceClip
        self.draft = draft
    }
}

struct ContactDraftRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceClip: PresentedClip
    let draft: ContactDraft

    init(sourceClip: PresentedClip, draft: ContactDraft) {
        id = UUID()
        self.sourceClip = sourceClip
        self.draft = draft
    }
}

struct AIClipAssistantRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceClip: PresentedClip

    init(sourceClip: PresentedClip) {
        id = UUID()
        self.sourceClip = sourceClip
    }
}

struct CombinedClipsReviewRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let pack: ContextPack

    init(pack: ContextPack) {
        id = UUID()
        self.pack = pack
    }
}

enum AssistantEngine: String, CaseIterable, Identifiable, Sendable {
    case onDevice
    case fastCloud

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .onDevice: "On-device"
        case .fastCloud: "Fast · Cloud"
        }
    }
}

struct ApplicationBrowserRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceClip: PresentedClip

    init(sourceClip: PresentedClip) {
        id = UUID()
        self.sourceClip = sourceClip
    }
}

struct InsertAliasResult: Identifiable, Equatable, Sendable {
    let alias: InsertAlias?
    let clip: PresentedClip

    var id: UUID { alias?.id ?? clip.id }
    var trigger: String? { alias?.trigger }
}

struct ClipFlowRunReviewRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceClip: PresentedClip
    let flow: ClipFlow
    let plan: ClipFlowRunPlan
    let triggeredAutomatically: Bool
    let idempotencyKey: String

    init(
        id: UUID = UUID(),
        sourceClip: PresentedClip,
        flow: ClipFlow,
        triggeredAutomatically: Bool,
        idempotencyKey: String? = nil,
        createdAt: Date = Date()
    ) throws {
        self.id = id
        self.sourceClip = sourceClip
        self.flow = flow
        plan = try ClipFlowRunPlan(
            id: id,
            flow: flow,
            clipID: sourceClip.id,
            clipFingerprint: sourceClip.content.deduplicationFingerprint,
            createdAt: createdAt
        )
        self.triggeredAutomatically = triggeredAutomatically
        self.idempotencyKey = idempotencyKey ?? "manual:\(id.uuidString.lowercased())"
    }
}

struct HandoffReviewRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let projection: HandoffProjection

    init(projection: HandoffProjection) {
        id = UUID()
        self.projection = projection
    }
}

extension PresentedClip.Origin {
    var savedFolderID: UUID? {
        if case let .saved(folderID) = self { return folderID }
        return nil
    }

    var isSaved: Bool {
        if case .saved = self { return true }
        return false
    }
}

private struct VaultMovePlan: Sendable {
    let item: VaultItem
    let historyItem: HistoryItem?
    let savedClips: [SavedClip]
    let linkedHistoryItemID: UUID?

    var summary: VaultMoveSummary {
        VaultMoveSummary(
            historyItem: historyItem,
            savedClips: savedClips,
            linkedHistoryItemID: linkedHistoryItemID
        )
    }
}

struct VaultMoveSummary: Equatable, Sendable {
    let historyItem: HistoryItem?
    let savedClips: [SavedClip]
    let linkedHistoryItemID: UUID?

    var historyItemCount: Int { historyItem == nil ? 0 : 1 }
    var savedClipCount: Int { savedClips.count }

    var ordinaryCopyCount: Int { historyItemCount + savedClipCount }

    var confirmationMessage: String {
        let history = "\(historyItemCount) History \(historyItemCount == 1 ? "item" : "items")"
        let saved = "\(savedClipCount) Saved \(savedClipCount == 1 ? "copy" : "copies")"
        return "Clipboard Router encrypts the Vault item first, then removes \(history) and \(saved)."
    }
}

struct ClipContextMenuPolicy: Equatable {
    enum Organization: Equatable {
        case saveToFolder
        case moveToFolder
        case none
    }

    let organization: Organization
    let canShareClip: Bool
    let canExportClip: Bool
    let canUseWorkflows: Bool
    let canRouteToAI: Bool
    let showsSavedClipControls: Bool
    let canMutateSavedClip: Bool
    let folderID: UUID?
    let canManageFolderSharing: Bool
    let showsDelete: Bool
    let canDelete: Bool
}

enum ClipExportDecision: Equatable {
    case available
    case requiresSensitiveConfirmation(category: String)
    case unavailable(reason: String)

    var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    var unavailableReason: String? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }
}

struct OrdinaryClipArchiveSelection: Equatable {
    let clip: SavedClip
    let folders: [ClipFolder]
}

struct TransformPreview: Equatable, Sendable {
    let sourceClipID: UUID
    let title: String
    let transformedText: String
}

struct ApplicationExclusionOption: Identifiable, Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let applicationURL: URL
    let teamIdentifier: String?
    let isRunning: Bool

    /// A bundle identifier identifies a product, not one installed copy. Keep distinct paths so
    /// the user can choose deliberately when multiple signed copies are installed.
    var id: String { applicationURL.standardizedFileURL.path }
}

struct FolderDestination: Identifiable, Equatable, Sendable {
    let id: UUID
    let path: String
    let depth: Int
    let canAcceptItems: Bool
}

private struct PrivateSessionClip: Identifiable, Sendable {
    let id: UUID
    let candidate: CaptureCandidate
}

private struct QuarantineCaptureMetadata: Sendable {
    let sourceApplicationBundleIdentifier: String?
    let originatingDeviceIdentifier: String?
    let captureContext: ClipCaptureContext?
    let pasteboardTypeIdentifiers: Set<String>
    let capturedAt: Date
    let draft: PasteboardCaptureDraft?
    let ocrText: String?
    let privateSessionGeneration: UInt64?
}

struct VaultItemSummary: Identifiable, Equatable {
    let id: UUID
    let name: String
    let modifiedAt: Date
    let contentType: SupportedContentType
}

enum PasteboardAccessState: Equatable {
    case legacyNotReported
    case willAsk
    case asksOnAccess
    case allowed
    case denied

    var title: String {
        switch self {
        case .legacyNotReported: "Available"
        case .willAsk: "macOS will ask on first access"
        case .asksOnAccess: "macOS asks on clipboard access"
        case .allowed: "Allowed"
        case .denied: "Blocked by macOS"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: ClipboardLibrarySnapshot = .empty
    @Published private(set) var searchResults: [ClipSearchResult] = []
    @Published private(set) var activeSmartViewID: SmartViewID?
    @Published private(set) var userSmartViews: [UserSmartView] = []
    @Published private(set) var userSmartViewCounts: [UUID: Int] = [:]
    @Published private(set) var isReady = false
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var decryptedSharePreview: ClipContent?
    @Published private(set) var pendingEncryptedShareRequest: EncryptedShareRequest?
    @Published private(set) var encryptedShareEnvelope: String?
    @Published private(set) var vaultSummaries: [VaultItemSummary] = []
    @Published private(set) var selectedVaultItem: VaultItem?
    @Published private(set) var vaultEncryptedItemCount = 0
    @Published private(set) var isVaultUnlocked = false
    @Published private(set) var vaultAvailabilityMessage: String?
    @Published private(set) var syncSnapshot: SavedLibrarySyncSnapshot = .disabled
    @Published private(set) var syncAvailabilityMessage: String?
    @Published private(set) var syncContainerIdentifier: String?
    @Published private(set) var syncLastSuccessfulDate: Date?
    @Published private(set) var cloudPushInstallationStatus: CloudPushInstallationStatus =
        .notConfigured
    @Published private(set) var cloudPushRegistrationMessage: String?
    @Published private(set) var sharedFolderSnapshots: [UUID: SharedFolderSessionSnapshot] = [:]
    @Published private(set) var sharedFolderCapability: SharedCloudCapability =
        .unavailable(.configurationMissing)
    @Published private(set) var sharedFolderMessage: String?
    @Published private(set) var pendingHandoffReview: HandoffReviewRequest?
    @Published private(set) var pasteboardAccessState: PasteboardAccessState = .legacyNotReported
    @Published private(set) var pasteAutomationAccess: PasteAutomationAccess = .permissionRequired
    @Published private(set) var pasteTargetApplicationName: String?
    @Published private(set) var quarantineReceipts: [QuarantineReceipt] = []
    @Published private(set) var clipboardHealth: ClipboardHealthSummary = .empty
    @Published private(set) var isPrivateSessionActive = false
    @Published private(set) var isStartingPrivateSession = false
    @Published private(set) var privateSessionClips: [PresentedClip] = []
    @Published private(set) var combinedClips: ContextPack?
    @Published private(set) var debugBundlePack: ContextPack?
    @Published private(set) var developerWorkspaceSnapshot: DeveloperWorkspaceSnapshot = .empty
    @Published private(set) var developerTimeline: [DeveloperTimelineEntry] = []
    @Published var selectedDeveloperProjectID: UUID?
    @Published private(set) var pasteStackItems: [PresentedClip] = []
    @Published private(set) var pasteStackCurrentIndex: Int?
    @Published private(set) var isPasteStackWriteInFlight = false
    @Published private(set) var transformPreview: TransformPreview?
    @Published private(set) var applicationExclusionOptions: [ApplicationExclusionOption] = []
    @Published private(set) var destinationApplicationOptions: [ApplicationExclusionOption] = []
    @Published private(set) var isDiscoveringApplications = false
    @Published private(set) var isDiscoveringDestinationApplications = false
    @Published private(set) var menuSearchResults: [PresentedClip] = []
    @Published private(set) var menuBarClipLimit: Int
    @Published private(set) var clipAutomations: [ClipAutomation] = []
    @Published private(set) var clipFlows: [ClipFlow] = []
    @Published private(set) var automationRunSnapshot: AutomationRunLedgerSnapshot = .empty
    @Published private(set) var pendingContactDraft: ContactDraftRequest?
    @Published private(set) var pendingAIAssistant: AIClipAssistantRequest?
    @Published private(set) var pendingCombinedClipsReview: CombinedClipsReviewRequest?
    @Published private(set) var pendingDebugBundleReview: DeveloperDebugBundleReviewRequest?
    @Published private(set) var pendingApplicationBrowser: ApplicationBrowserRequest?
    @Published private(set) var pendingFlowReview: ClipFlowRunReviewRequest?
    private weak var menuBarContinuationPresenter: (any MenuBarContinuationPresenting)?
    @Published private(set) var liveLinkPreviewStates: [UUID: LiveLinkPreviewState] = [:]
    @Published private(set) var contactDraftPresentationSurface: RequestPresentationSurface = .library
    @Published private(set) var assistantPresentationSurface: RequestPresentationSurface = .library
    @Published private(set) var applicationBrowserPresentationSurface: RequestPresentationSurface = .library
    @Published private(set) var flowReviewPresentationSurface: RequestPresentationSurface = .library
    private var queuedFlowReviews: [ClipFlowRunReviewRequest] = []
    private var flowReviewPresentationSurfaces: [UUID: RequestPresentationSurface] = [:]
    private var consumedFlowRunIDs: Set<UUID> = []
    @Published private(set) var securePasteTimeoutSeconds: Int
    @Published private(set) var globalHotKeyChoice: GlobalHotKeyChoice
    @Published private(set) var createNoteHotKeyChoice: GlobalHotKeyChoice
    @Published private(set) var insertPaletteHotKeyChoice: GlobalHotKeyChoice
    @Published private(set) var launchAtLoginState: LaunchAtLoginState
    @Published private(set) var automaticOrganizationSnapshot = AutomaticOrganizationSnapshot.empty
    @Published private(set) var captureLocationAuthorization: CaptureLocationAuthorization =
        .notDetermined
    @Published private(set) var currentCoarseLocation: CoarseLocationContext?
    @Published private(set) var coarseLocationObservedAt: Date?
    @Published private(set) var isRefreshingCaptureLocation = false
    @Published private(set) var directLicenseStatus: DirectLicenseStatus =
        .unavailable(.engineeringBuild)
    @Published private(set) var directLicenseAccountID: String?
    @Published private(set) var directLicenseID: String?
    private var directLicenseNextBoundary: Date?
    @Published private(set) var isDirectLicenseOperationInProgress = false
    @Published private(set) var insertAliases: [InsertAlias] = []
    @Published private(set) var isTextExpansionEnabled = false
    @Published private(set) var textExpansionStatus: TextExpansionAccessStatus = .off
    @Published private(set) var crmConnectionDefinitions: [CRMConnectionDefinition] = []
    @Published private(set) var crmConnectionStates: [UUID: CRMConnectionState] = [:]
    @Published private(set) var pendingCRMReview: CRMReviewDraft?
    @Published private(set) var pendingCRMSetupClipID: UUID?
    @Published private(set) var crmWriteOutcome: CRMWriteOutcome?
    @Published private(set) var pendingBulkLibraryResult: BulkLibraryActionResult?
    @Published private(set) var isCRMWriteInFlight = false

    var unresolvedAutomationRunCount: Int {
        automationRunSnapshot.runs.filter {
            $0.status == .needsReview || $0.status == .uncertain
                || ($0.status == .failed && $0.canRetry)
        }.count
    }
    @Published private(set) var insertPalettePasteTargetToken: UUID? = nil
    @Published private(set) var isHostedAssistantConfigured = false
    @Published var isHostedAssistantConsentGranted: Bool {
        didSet {
            defaults.set(isHostedAssistantConsentGranted, forKey: Self.hostedAssistantConsentKey)
        }
    }
    @Published var hostedAssistantModel: String {
        didSet {
            let normalized = hostedAssistantModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized == hostedAssistantModel, Self.isValidHostedAssistantModel(normalized) {
                defaults.set(normalized, forKey: Self.hostedAssistantModelKey)
            }
        }
    }
    @Published private(set) var searchFocusRequestID: UInt64 = 0
    @Published private(set) var noteCreationRequestID: UInt64 = 0
    @Published private(set) var insertPaletteRequestID: UInt64 = 0
    @Published private(set) var noteCreationPresentationSurface: RequestPresentationSurface = .library
    @Published private(set) var insertPalettePresentationSurface: RequestPresentationSurface = .library
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var selectedSection: LibrarySection = .history
    @Published var actionsWorkspaceMode: ActionsWorkspaceMode = .automations
    @Published var selectedClipID: UUID? {
        didSet {
            if let selectedClipID {
                if !selectedClipIDs.contains(selectedClipID) {
                    selectedClipIDs = [selectedClipID]
                }
            } else {
                selectedClipIDs = []
            }
        }
    }
    @Published var selectedClipIDs: Set<UUID> = []
    @Published var selectedVaultItemID: UUID?
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Self.onboardingKey) }
    }
    @Published var preferredDestinationID: ExternalDestination.ID {
        didSet { defaults.set(preferredDestinationID.rawValue, forKey: Self.destinationKey) }
    }

    private static let onboardingKey = "hasCompletedOnboarding.v1"
    private static let destinationKey = "preferredDestination.v1"
    private static let syncDeviceIDKey = "savedLibrarySyncDeviceID.v1"
    private static let syncLastSuccessKey = "savedLibrarySyncLastSuccess.v1"
    private static let securePasteTimeoutKey = "securePasteTimeoutSeconds.v1"
    private static let globalHotKeyChoiceKey = "globalHotKeyChoice.v1"
    private static let createNoteHotKeyChoiceKey = "createNoteHotKeyChoice.v1"
    private static let insertPaletteHotKeyChoiceKey = "insertPaletteHotKeyChoice.v1"
    private static let menuBarClipLimitKey = "menuBarClipLimit.v1"
    private static let insertAliasesKey = "insertAliases.v1"
    private static let textExpansionEnabledKey = "textExpansionEnabled.v1"
    private static let crmConnectionDefinitionsKey = "crmConnectionDefinitions.v1"
    private static let hostedAssistantConsentKey = "hostedAssistantConsent.v1"
    private static let hostedAssistantModelKey = "hostedAssistantModel.v1"
    private static let metricsInstallationIDKey = "productMetricsInstallationID.v1"
    private static let captureContextInstallationIDKey = "captureContextInstallationID.v1"
    private static let directLicenseDeviceIDKey = "directLicenseDeviceID.v1"
    private static let clipAutomationsKey = "clipAutomations.v1"
    private static let clipFlowsKey = "clipFlows.v1"
    private static let suppressedTeamFlowIDsKey = "suppressedTeamFlowIDs.v1"
    static let cloudKitContainerInfoKey = "ClipboardRouterCloudKitContainerIdentifier"
    static let cloudKitEnvironmentInfoKey = "ClipboardRouterCloudKitEnvironment"
    static let cloudKitPushEnabledInfoKey = "ClipboardRouterCloudKitPushEnabled"
    static let sharedDebugBundleTag = "ClipboardRouter Debug Bundle"
    static let menuBarClipLimitRange = 1...1_000
    static let defaultMenuBarClipLimit = 15

    private let defaults: UserDefaults
    private let router: DestinationRouter
    private let destinationCatalog: DestinationApplicationCatalog
    private let clipActionDetector: ActionableClipDetector
    private var clipActionDetectionCache: [String: [DetectedClipEntity]] = [:]
    private let clipActionExecutor: ClipActionExecutor
    private let calendarEventCreator: any CalendarEventCreating
    private let contactCreator: any ContactCreating
    private let aiProcessor: any ClipAIProcessing
    private let hostedAssistant: any HostedAssistantResponding
    private let hostedAssistantCredentialStore: any HostedAssistantCredentialStoring
    private let liveLinkPreviewClient: any LiveLinkPreviewFetching
    private let actionBookmarks: any ApplicationBookmarking
    private let actionMetadataInspector: any ApplicationMetadataInspecting
    private let pasteboardReader: any PasteboardDraftReading
    private let pasteboardWriter: any PasteboardWriting
    private let typedPasteboardWriter: any TypedPasteboardWriting
    private let pasteboardAccessStateProvider: () -> PasteboardAccessState
    private let pasteAutomation: PasteAutomationController
    private let archiveService: ClipArchiveService
    private let assetStore: FileClipAssetStore
    let thumbnailLoader: ClipThumbnailLoader
    private let captureMaterializer: PasteboardCaptureMaterializer
    private let ocrService: any LocalOCRServicing
    private let secretDetector: SecretDetector
    private let secureShareService: SecureShareClipService
    private let hotKey: any GlobalHotKeyRegistering
    private let launchAtLoginService: any LaunchAtLoginServicing
    private let captureContextProvider: any CaptureContextProviding
    private let captureContextInstallationID: String
    private let directLicenseVerifier: any DirectLicenseTokenVerifying
    private let directLicenseCredentialStore: any DirectLicenseCredentialStoring
    private let directLicenseRepository: any DirectLicenseRepositoryClient
    private let directLicenseClock: any DirectLicenseClockProviding
    private let directLicenseDeviceID: String
    private let directLicenseStateMachine = DirectLicenseStateMachine()
    private let distributionChannelProvider: any DistributionChannelProviding
    private let textExpansionAccessibility: any TextExpansionAccessibilityControlling
    private let textExpansionEvents: any TextExpansionEventMonitoring
    private let crmCredentialStore: any CRMCredentialStoring
    private let crmTransport: any CRMHTTPTransport
    private let userSmartViewStore: any UserSmartViewPersisting
    private let supportDirectory: URL
    private let developerWorkspaceStore: any DeveloperWorkspacePersisting
    private let automaticOrganizationStore: any AutomaticOrganizationPersisting
    private let automationRunLedger: AutomationRunLedger
    private let automationWorkerID = UUID()
    private let automaticOrganizationEngine = AutomaticOrganizationEngine()
    private var developerWorkspace: DeveloperWorkspace?
    private let projectRootAccess = ProjectRootAccess()
    private let repositoryInspector = RepositoryInspector()
    private let ideHandoff = IDEHandoff()
    private let injectedLibraryPersistence: (any ClipboardLibraryPersisting)?
    private let vaultSession: VaultSession
    private let vaultAutoLock: VaultAutoLockCoordinator
    private let injectedVaultStore: (any VaultStore)?
    private let vaultAssetStore: any VaultEncryptedAssetStoring
    private let securePaste: SecurePasteController
    private let syncStore: JSONFileSavedLibrarySyncStateStore
    private let syncAssetStager: any SavedLibrarySyncAssetStaging
    private let syncDeviceID: String
    private let injectedCloudPushSubscriptionCoordinator: CloudPushSubscriptionCoordinator?
    private let cloudPushNotificationDecoder: any CloudPushNotificationDecoding
    private let injectedSharedFolderTransport: (any SharedFolderTransport)?
    private let cloudSharingPresenter: any CloudSharingPresenting
    private let quarantineStore: QuarantineStore
    private let metricsLedger: LocalProductMetricsLedger
    private let metricsInstallationID: UUID
    private let privateSession: PrivateSession<PrivateSessionClip>
    private var library: ClipboardLibrary?
    private var vaultLibrary: VaultLibrary?
    private var syncCoordinator: SavedLibrarySyncCoordinator?
    private var cloudPushSubscriptionCoordinator: CloudPushSubscriptionCoordinator?
    private var sharedFolderTransport: (any SharedFolderTransport)?
    private var cloudKitSharedFolderAdapter: CloudKitSharedFolderAdapter?
    private var sharedFolderSessions: [UUID: SharedFolderSession] = [:]
    private var pendingCloudKitShareMetadata: [CKShare.Metadata] = []
    private var shareAcceptanceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var applicationDiscoveryTask: Task<Void, Never>?
    private var applicationDiscoveryCoordinator = ApplicationDiscoveryCoordinator(
        cacheTTL: 5 * 60
    )
    private var ordinarySectionBeforeSearch: LibrarySection?
    private var menuSearchTask: Task<Void, Never>?
    private var smartViewCountTask: Task<Void, Never>?
    private var menuSearchQuery = ""
    private var vaultStateTask: Task<Void, Never>?
    private var vaultSelectionTask: Task<Void, Never>?
    private var syncRefreshTask: Task<Void, Never>?
    private var sharedFolderRefreshTask: Task<Void, Never>?
    private var sharedAccountFingerprint: String?
    private var isSharedFolderRefreshInProgress = false
    private var sharedFolderRefreshNeedsAnotherPass = false
    private var retentionPruneTask: Task<Void, Never>?
    private var directLicenseRefreshTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var quarantineExpirationTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var lastSecurePasteReceipt: SecurePasteReceipt?
    private var isSyncOptOutRequested = false
    private var syncProjectionGeneration: UInt64 = 0
    private var isSyncApplyInProgress = false
    private var syncApplyNeedsAnotherPass = false
    private var quarantineMetadata: [UUID: QuarantineCaptureMetadata] = [:]
    private var pasteStack: PasteStack<PresentedClip>
    private var privateSessionGeneration: UInt64 = 0
    private var pasteTargetProcessIdentifier: pid_t?
    private var pasteTargetBundleIdentifier: String?
    private var pasteTargetLaunchDate: Date?
    private var clipboardActionQueue: [@MainActor () async throws -> Void] = []
    private var isClipboardActionInFlight = false
    private var suppressedTeamFlowIDs: Set<UUID> = []
    private var liveLinkPreviewGenerations: [UUID: UInt64] = [:]
    private var pendingCRMOAuthRequest: CRMOAuthRequest?
    private var userSmartViewLibrary: UserSmartViewLibrary?

    private lazy var textExpansionController = TextExpansionController(
        accessibility: textExpansionAccessibility,
        events: textExpansionEvents,
        definitions: { [weak self] in self?.eligibleTextExpansionDefinitions ?? [] },
        isAllowed: { [weak self] focus in self?.isTextExpansionAllowed(in: focus) == true }
    )

    private lazy var crmOAuthCoordinator = CRMOAuthCoordinator(
        transport: crmTransport,
        credentials: crmCredentialStore
    )

    private lazy var crmWriteExecutor = CRMWriteExecutor(
        transport: crmTransport,
        credentials: crmCredentialStore,
        oauth: crmOAuthCoordinator
    )

    private lazy var cloudPushRefreshCoalescer = CloudPushRefreshCoalescer {
        [weak self] scopes in
        guard let self else { return }
        await self.performCloudPushRefresh(for: scopes)
    }

    private lazy var clipboardMonitor = ClipboardMonitor(
        pasteboard: pasteboardReader,
        applications: WorkspaceFrontmostApplicationProvider(),
        configuration: { [weak self] in
            guard let self else { return ClipboardMonitorConfiguration(isCaptureEnabled: false) }
            let policy = self.snapshot.settings.capturePolicy
            return ClipboardMonitorConfiguration(
                isCaptureEnabled: policy.isCaptureEnabled,
                excludedApplicationBundleIdentifiers: policy.excludedApplicationBundleIdentifiers
            )
        },
        onDraft: { [weak self] draft in
            self?.capture(draft)
        }
    )

    init(
        defaults: UserDefaults = .standard,
        router: DestinationRouter = DestinationRouter(),
        destinationCatalog: DestinationApplicationCatalog = DestinationApplicationCatalog(),
        clipActionExecutor: ClipActionExecutor = ClipActionExecutor(),
        calendarEventCreator: any CalendarEventCreating = SystemCalendarEventCreator(),
        contactCreator: any ContactCreating = SystemContactCreator(),
        aiProcessor: any ClipAIProcessing = OnDeviceClipAIProcessor(),
        hostedAssistant: any HostedAssistantResponding = OpenAIHostedAssistantClient(),
        hostedAssistantCredentialStore: any HostedAssistantCredentialStoring =
            KeychainHostedAssistantCredentialStore(),
        liveLinkPreviewClient: any LiveLinkPreviewFetching = LiveLinkPreviewClient(),
        actionBookmarks: any ApplicationBookmarking = SecurityScopedApplicationBookmarkStore(),
        actionMetadataInspector: any ApplicationMetadataInspecting = SystemApplicationMetadataInspector(),
        pasteboardReader: any PasteboardDraftReading = SystemPasteboardReader(),
        pasteboardWriter: any PasteboardWriting = SystemPasteboardWriter(),
        typedPasteboardWriter: (any TypedPasteboardWriting)? = nil,
        pasteboardAccessStateProvider: @escaping () -> PasteboardAccessState = {
            if #available(macOS 15.4, *) {
                switch NSPasteboard.general.accessBehavior {
                case .default: .willAsk
                case .ask: .asksOnAccess
                case .alwaysAllow: .allowed
                case .alwaysDeny: .denied
                @unknown default: .asksOnAccess
                }
            } else {
                .legacyNotReported
            }
        },
        pasteAutomation: PasteAutomationController = PasteAutomationController(),
        hotKey: any GlobalHotKeyRegistering = CarbonGlobalHotKeyRegistrar(),
        launchAtLoginService: any LaunchAtLoginServicing = SystemLaunchAtLoginService(),
        captureContextProvider: any CaptureContextProviding = SystemCaptureContextProvider(),
        directLicenseVerifier: any DirectLicenseTokenVerifying = P256DirectLicenseTokenVerifier(),
        directLicenseCredentialStore: any DirectLicenseCredentialStoring =
            KeychainDirectLicenseCredentialStore(),
        directLicenseRepository: any DirectLicenseRepositoryClient =
            BundleConfiguredDirectLicenseRepositoryClient(),
        directLicenseClock: any DirectLicenseClockProviding = SystemDirectLicenseClock(),
        distributionChannelProvider: any DistributionChannelProviding =
            BundleDistributionChannelProvider(),
        textExpansionAccessibility: any TextExpansionAccessibilityControlling =
            SystemTextExpansionAccessibilityController(),
        textExpansionEvents: any TextExpansionEventMonitoring =
            SystemTextExpansionEventMonitor(),
        crmCredentialStore: any CRMCredentialStoring = KeychainCRMCredentialStore(),
        crmTransport: any CRMHTTPTransport = URLSessionCRMHTTPTransport(),
        supportDirectory: URL? = nil,
        quarantineStore: QuarantineStore = QuarantineStore(),
        ocrService: any LocalOCRServicing = LocalVisionOCRService(),
        privateSessionCapacity: Int = 200,
        sharedFolderTransport: (any SharedFolderTransport)? = nil,
        cloudSharingPresenter: any CloudSharingPresenting = SystemCloudSharingPresenter(),
        cloudPushSubscriptionCoordinator: CloudPushSubscriptionCoordinator? = nil,
        cloudPushNotificationDecoder: any CloudPushNotificationDecoding =
            CloudKitPushNotificationDecoder(),
        vaultSession injectedVaultSession: VaultSession? = nil,
        vaultStore: (any VaultStore)? = nil,
        vaultAssetStore injectedVaultAssetStore: (any VaultEncryptedAssetStoring)? = nil,
        libraryPersistence: (any ClipboardLibraryPersisting)? = nil,
        userSmartViewStore: (any UserSmartViewPersisting)? = nil,
        automaticOrganizationStore: (any AutomaticOrganizationPersisting)? = nil,
        automationRunStore: (any AutomationRunLedgerPersisting)? = nil,
        secureShareKeyProvider: (any SecureShareKeyProvider)? = nil,
        secureShareReplayStore: (any SecureShareReplayStore)? = nil
    ) {
        self.defaults = defaults
        self.router = router
        self.destinationCatalog = destinationCatalog
        self.clipActionDetector = ActionableClipDetector()
        self.clipActionExecutor = clipActionExecutor
        self.calendarEventCreator = calendarEventCreator
        self.contactCreator = contactCreator
        self.aiProcessor = aiProcessor
        self.hostedAssistant = hostedAssistant
        self.hostedAssistantCredentialStore = hostedAssistantCredentialStore
        self.liveLinkPreviewClient = liveLinkPreviewClient
        self.actionBookmarks = actionBookmarks
        self.actionMetadataInspector = actionMetadataInspector
        self.pasteboardReader = pasteboardReader
        self.pasteboardWriter = pasteboardWriter
        self.pasteboardAccessStateProvider = pasteboardAccessStateProvider
        self.pasteAutomation = pasteAutomation
        self.hotKey = hotKey
        self.launchAtLoginService = launchAtLoginService
        self.captureContextProvider = captureContextProvider
        self.directLicenseVerifier = directLicenseVerifier
        self.directLicenseCredentialStore = directLicenseCredentialStore
        self.directLicenseRepository = directLicenseRepository
        self.directLicenseClock = directLicenseClock
        self.distributionChannelProvider = distributionChannelProvider
        let verifierConfigured = directLicenseVerifier.isConfigured
        let repositoryConfigured = directLicenseRepository.isConfigured
        self.directLicenseStatus = if verifierConfigured && repositoryConfigured {
            .unavailable(.noLicense)
        } else if !verifierConfigured && !repositoryConfigured {
            .unavailable(.engineeringBuild)
        } else {
            .unavailable(.verifierUnavailable)
        }
        self.captureLocationAuthorization = captureContextProvider.locationAuthorization
        self.currentCoarseLocation = captureContextProvider.cachedCoarseLocation
        self.coarseLocationObservedAt = captureContextProvider.cachedLocationDate
        if let existingContextID = defaults.string(forKey: Self.captureContextInstallationIDKey),
           !existingContextID.isEmpty
        {
            self.captureContextInstallationID = existingContextID
        } else {
            let generatedContextID = UUID().uuidString.lowercased()
            defaults.set(generatedContextID, forKey: Self.captureContextInstallationIDKey)
            self.captureContextInstallationID = generatedContextID
        }
        if let existingLicenseDeviceID = defaults.string(forKey: Self.directLicenseDeviceIDKey),
           !existingLicenseDeviceID.isEmpty
        {
            self.directLicenseDeviceID = existingLicenseDeviceID
        } else {
            let generatedLicenseDeviceID = UUID().uuidString.lowercased()
            defaults.set(generatedLicenseDeviceID, forKey: Self.directLicenseDeviceIDKey)
            self.directLicenseDeviceID = generatedLicenseDeviceID
        }
        self.textExpansionAccessibility = textExpansionAccessibility
        self.textExpansionEvents = textExpansionEvents
        self.crmCredentialStore = crmCredentialStore
        self.crmTransport = crmTransport
        self.launchAtLoginState = launchAtLoginService.state
        self.isTextExpansionEnabled = defaults.bool(forKey: Self.textExpansionEnabledKey)
        let storedMenuBarClipLimit = defaults.integer(forKey: Self.menuBarClipLimitKey)
        self.menuBarClipLimit = Self.menuBarClipLimitRange.contains(storedMenuBarClipLimit)
            ? storedMenuBarClipLimit
            : Self.defaultMenuBarClipLimit
        self.quarantineStore = quarantineStore
        self.injectedSharedFolderTransport = sharedFolderTransport
        self.cloudSharingPresenter = cloudSharingPresenter
        self.injectedCloudPushSubscriptionCoordinator = cloudPushSubscriptionCoordinator
        self.cloudPushNotificationDecoder = cloudPushNotificationDecoder
        self.injectedLibraryPersistence = libraryPersistence
        self.privateSession = try! PrivateSession(capacity: privateSessionCapacity)
        self.pasteStack = try! PasteStack()
        let supportDirectory = supportDirectory ?? Self.defaultSupportDirectory()
        self.supportDirectory = supportDirectory
        self.userSmartViewStore = userSmartViewStore ?? JSONFileUserSmartViewStore(
            fileURL: supportDirectory.appendingPathComponent("smart-views.json")
        )
        self.developerWorkspaceStore = JSONFileDeveloperWorkspaceStore(
            fileURL: supportDirectory.appendingPathComponent("developer-workspace.json")
        )
        self.automaticOrganizationStore = automaticOrganizationStore
            ?? JSONFileAutomaticOrganizationStore(
                fileURL: supportDirectory.appendingPathComponent("automatic-organization.json")
            )
        self.automationRunLedger = AutomationRunLedger(
            persistence: automationRunStore ?? JSONFileAutomationRunLedgerStore(
                fileURL: supportDirectory.appendingPathComponent("automation-runs.json")
            )
        )
        self.metricsLedger = LocalProductMetricsLedger(
            fileURL: supportDirectory.appendingPathComponent("product-metrics.json")
        )
        if let storedMetricsID = defaults.string(forKey: Self.metricsInstallationIDKey),
           let metricsID = UUID(uuidString: storedMetricsID)
        {
            self.metricsInstallationID = metricsID
        } else {
            let metricsID = UUID()
            defaults.set(metricsID.uuidString.lowercased(), forKey: Self.metricsInstallationIDKey)
            self.metricsInstallationID = metricsID
        }
        let assetStore = FileClipAssetStore(
            rootURL: supportDirectory.appendingPathComponent("clip-assets", isDirectory: true)
        )
        self.assetStore = assetStore
        self.thumbnailLoader = ClipThumbnailLoader(assetStore: assetStore)
        self.typedPasteboardWriter = typedPasteboardWriter
            ?? TypedSystemPasteboardWriter(assetStore: assetStore)
        self.archiveService = ClipArchiveService(assets: assetStore)
        self.captureMaterializer = PasteboardCaptureMaterializer(assetStore: assetStore)
        self.ocrService = ocrService
        self.secretDetector = SecretDetector()
        self.secureShareService = SecureShareClipService(
            keyProvider: secureShareKeyProvider ?? KeychainSecureShareKeyProvider(),
            replayStore: secureShareReplayStore
                ?? FileSecureShareReplayStore(
                    fileURL: supportDirectory.appendingPathComponent(
                        "secure-share-replay.json"
                    )
                )
        )
        let vaultSession = injectedVaultSession ?? VaultSession(
            authenticator: LocalAuthenticationAdapter(),
            keyProvider: KeychainVaultKeyProvider()
        )
        self.vaultSession = vaultSession
        self.vaultAutoLock = VaultAutoLockCoordinator(session: vaultSession)
        self.injectedVaultStore = vaultStore
        self.vaultAssetStore = injectedVaultAssetStore ?? FileVaultEncryptedAssetStore(
            rootURL: supportDirectory.appendingPathComponent("vault-assets", isDirectory: true)
        )
        let storedSecurePasteTimeout = defaults.integer(forKey: Self.securePasteTimeoutKey)
        let securePasteTimeout = [15, 30, 45, 60].contains(storedSecurePasteTimeout)
            ? storedSecurePasteTimeout : 45
        self.securePasteTimeoutSeconds = securePasteTimeout
        self.globalHotKeyChoice = defaults.string(forKey: Self.globalHotKeyChoiceKey)
            .flatMap(GlobalHotKeyChoice.init(rawValue:)) ?? .commandShiftV
        self.createNoteHotKeyChoice = defaults.string(forKey: Self.createNoteHotKeyChoiceKey)
            .flatMap(GlobalHotKeyChoice.init(rawValue:)) ?? .commandOptionN
        self.insertPaletteHotKeyChoice = defaults.string(
            forKey: Self.insertPaletteHotKeyChoiceKey
        ).flatMap(GlobalHotKeyChoice.init(rawValue:)) ?? .controlOptionV
        self.isHostedAssistantConsentGranted = defaults.bool(
            forKey: Self.hostedAssistantConsentKey
        )
        self.hostedAssistantModel = defaults.string(forKey: Self.hostedAssistantModelKey)
            .flatMap {
                let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return Self.isValidHostedAssistantModel(value) ? value : nil
            }
            ?? "gpt-5-nano"
        self.isHostedAssistantConfigured = ((try? hostedAssistantCredentialStore.loadAPIKey()) ?? nil) != nil
        if let aliasData = defaults.data(forKey: Self.insertAliasesKey),
           let decoded = try? JSONDecoder().decode([InsertAlias].self, from: aliasData)
        {
            var seenTriggers = Set<String>()
            var seenIDs = Set<UUID>()
            self.insertAliases = decoded.compactMap { alias in
                guard seenIDs.insert(alias.id).inserted,
                      seenTriggers.insert(InsertAlias.normalize(alias.abbreviation)).inserted,
                      let validated = try? InsertAlias(
                        id: alias.id,
                        name: alias.name,
                        abbreviation: alias.abbreviation,
                        savedClipID: alias.savedClipID,
                        delivery: alias.delivery
                      )
                else { return nil }
                return validated
            }
        }
        if let connectionData = defaults.data(forKey: Self.crmConnectionDefinitionsKey),
           let decoded = try? JSONDecoder().decode([CRMConnectionDefinition].self, from: connectionData)
        {
            var seen = Set<UUID>()
            self.crmConnectionDefinitions = decoded.filter { seen.insert($0.id).inserted }
        }
        self.securePaste = SecurePasteController(
            pasteboard: SystemSecurePasteboard(),
            clearDelay: TimeInterval(securePasteTimeout)
        )
        self.syncStore = JSONFileSavedLibrarySyncStateStore(
            fileURL: supportDirectory.appendingPathComponent("saved-library-sync.json")
        )
        self.syncAssetStager = FileSavedLibrarySyncAssetStager(
            rootURL: supportDirectory.appendingPathComponent(
                "saved-library-sync-assets",
                isDirectory: true
            )
        )
        if let existingDeviceID = defaults.string(forKey: Self.syncDeviceIDKey),
           !existingDeviceID.isEmpty
        {
            self.syncDeviceID = existingDeviceID
        } else {
            let generatedDeviceID = UUID().uuidString.lowercased()
            defaults.set(generatedDeviceID, forKey: Self.syncDeviceIDKey)
            self.syncDeviceID = generatedDeviceID
        }
        self.syncLastSuccessfulDate = defaults.object(
            forKey: Self.syncLastSuccessKey
        ) as? Date
        hasCompletedOnboarding = defaults.bool(forKey: Self.onboardingKey)
        preferredDestinationID = defaults.string(forKey: Self.destinationKey)
            .flatMap(ExternalDestination.ID.init(rawValue:)) ?? .chatGPT
        if let automationData = defaults.data(forKey: Self.clipAutomationsKey),
           let decoded = try? JSONDecoder().decode([ClipAutomation].self, from: automationData)
        {
            var seenIDs = Set<UUID>()
            clipAutomations = decoded.filter { seenIDs.insert($0.id).inserted }
        }
        if let flowData = defaults.data(forKey: Self.clipFlowsKey) {
            do {
                let decoded = try JSONDecoder().decode([ClipFlow].self, from: flowData)
                var seenIDs = Set<UUID>()
                clipFlows = decoded.filter { seenIDs.insert($0.id).inserted }
            } catch {
                defaults.set(flowData, forKey: "\(Self.clipFlowsKey).recovery")
                errorMessage = "Custom actions could not be loaded. The original data was kept for recovery."
            }
        }
        if let suppressedData = defaults.data(forKey: Self.suppressedTeamFlowIDsKey),
           let decoded = try? JSONDecoder().decode([UUID].self, from: suppressedData)
        {
            suppressedTeamFlowIDs = Set(decoded)
        }
    }

    var isCaptureEnabled: Bool {
        snapshot.settings.capturePolicy.isCaptureEnabled
    }

    var pendingSavedLibraryEntityCount: Int {
        Set(syncSnapshot.outbox.keys)
            .union(snapshot.pendingSavedLibraryMutations.map(\.id))
            .count
    }

    var isCaptureActive: Bool {
        hasCompletedOnboarding
            && isCaptureEnabled
            && clipboardMonitor.isRunning
            && pasteboardAccessState != .denied
    }

    var captureStatusTitle: String {
        if pasteboardAccessState == .denied { return "Access blocked" }
        return isCaptureActive ? "Capturing" : "Paused"
    }

    var captureStatusDetail: String {
        if pasteboardAccessState == .denied {
            return "Allow in System Settings"
        }
        return isCaptureActive ? "⌘⌥P to pause" : "Click to resume"
    }

    var selectedClip: PresentedClip? {
        guard let selectedClipID else { return nil }
        return clipsForSelectedSection.first(where: { $0.id == selectedClipID })
    }

    var selectedClipsForBulkAction: [PresentedClip] {
        clipsForSelectedSection.filter { selectedClipIDs.contains($0.id) }
    }

    func setSelectedClipIDs(_ ids: Set<UUID>) {
        let ordered = clipsForSelectedSection.filter { ids.contains($0.id) }
        let normalized = Set(ordered.map(\.id))
        let primary = selectedClipID.flatMap { normalized.contains($0) ? $0 : nil }
            ?? ordered.last?.id

        // AppKit can write the current selection back while NSTableView is still
        // servicing a selection/accessibility delegate callback. Republishing an
        // identical Set causes SwiftUI to update that table reentrantly and can
        // create a tight feedback loop.
        guard normalized != selectedClipIDs || primary != selectedClipID else { return }

        if normalized.isEmpty {
            if selectedClipID != nil {
                // `selectedClipID`'s observer clears the Set without a second write.
                selectedClipID = nil
            } else {
                selectedClipIDs = []
            }
            return
        }

        if normalized != selectedClipIDs { selectedClipIDs = normalized }
        if primary != selectedClipID { selectedClipID = primary }
    }

    /// Defers an accessibility-triggered row selection until AppKit has returned from
    /// its `NSTableView` accessibility delegate callback. Mutating the `List` binding
    /// synchronously from that callback causes AppKit's reentrant-delegate safeguard.
    /// Native `List` selection continues to own pointer and keyboard interactions.
    func requestAccessibilityClipSelection(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
            guard let self,
                  self.clipsForSelectedSection.contains(where: { $0.id == id })
            else { return }
            self.setSelectedClipIDs([id])
        }
    }

    /// Moves the Library to a note created by an editor after AppKit has finished the
    /// current control/accessibility callback. A menu-bar continuation can commit while
    /// its sheet is still dismissing; publishing both `List` selections synchronously at
    /// that point asks SwiftUI's backing `NSTableView`s to change selection from inside a
    /// delegate turn. Revalidate the durable note before applying the deferred selection.
    func requestPostEditorNotePresentation(_ id: UUID, status: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
            guard let self,
                  self.snapshot.savedClips.contains(where: { $0.id == id && $0.kind == .note })
            else { return }
            if self.selectedSection != .smartView(.notes) {
                self.selectedSection = .smartView(.notes)
            }
            self.setSelectedClipIDs([id])
            self.statusMessage = status
        }
    }

    var isOrdinarySearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedSection != .vault
            && selectedSection != .privateSession
    }

    var isOrdinarySearchAvailable: Bool {
        selectedSection != .vault && selectedSection != .privateSession
    }

    var activeSearchChips: [SearchQueryChip] {
        searchText
            .split(whereSeparator: \Character.isWhitespace)
            .enumerated()
            .map { index, value in
                let token = String(value)
                let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
                let label: String
                if parts.count == 2 {
                    let field = parts[0].replacingOccurrences(of: "_", with: " ").capitalized
                    label = "\(field): \(parts[1])"
                } else {
                    label = token
                }
                return SearchQueryChip(id: index, token: token, label: label)
            }
    }

    var activeSearchExplanation: [String] {
        (try? ClipSearchQuery.validate(searchText).explanations) ?? []
    }

    /// Precomputed when the library snapshot changes. SwiftUI reads this repeatedly while
    /// diffing the Library sidebar; rebuilding it in the getter rescanned every clip (including
    /// legacy secret detection) once per row and could pin the main thread on large histories.
    private(set) var staticSmartViews: [SmartViewDefinition] = []

    private func makeStaticSmartViews(
        for snapshot: ClipboardLibrarySnapshot
    ) -> [SmartViewDefinition] {
        let calendar = Calendar.current
        let todayCount = snapshot.history.filter { calendar.isDateInToday($0.lastCapturedAt) }.count
            + snapshot.savedClips.filter {
                calendar.isDateInToday($0.originallyCapturedAt ?? $0.createdAt)
            }.count
        let historyByID = Dictionary(uniqueKeysWithValues: snapshot.history.map { ($0.id, $0) })
        let frequentlyUsedCount = snapshot.history.filter { $0.captureCount >= 2 }.count
            + snapshot.savedClips.filter { saved in
                guard let sourceID = saved.sourceHistoryItemID,
                      let source = historyByID[sourceID]
                else { return false }
                return source.captureCount >= 2
            }.count
        let allContents = snapshot.history.map(\.content) + snapshot.savedClips.map(\.content)
        let linkCount = allContents.filter { $0.type == .url }.count
        let imageCount = allContents.filter { $0.type == .image }.count
        let fileCount = allContents.filter { $0.type == .fileURLs }.count
        let pdfCount = allContents.filter { content in
            content.representations.files.contains {
                $0.url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
            } || content.representations.referencedAssets.contains { $0.kind == .pdf }
        }.count
        let sensitiveCount = snapshot.history.filter {
            presentationSensitivityCategory(content: $0.content, stored: $0.sensitivity) != nil
        }.count + snapshot.savedClips.filter {
            presentationSensitivityCategory(content: $0.content, stored: $0.sensitivity) != nil
        }.count
        let todayQuery = "date:\(Self.searchDateToken(Date()))"

        return [
            SmartViewDefinition(id: .notes, title: "Notes", systemImage: "note.text", query: "kind:note", count: snapshot.savedClips.filter { $0.kind == .note }.count),
            SmartViewDefinition(id: .today, title: "Today", systemImage: "calendar", query: todayQuery, count: todayCount),
            SmartViewDefinition(id: .frequentlyUsed, title: "Frequently Used", systemImage: "repeat", query: "captures:>=2", count: frequentlyUsedCount),
            SmartViewDefinition(id: .links, title: "Links", systemImage: "link", query: "type:url", count: linkCount),
            SmartViewDefinition(id: .images, title: "Images", systemImage: "photo", query: "type:image", count: imageCount),
            SmartViewDefinition(id: .files, title: "Files", systemImage: "doc", query: "type:file", count: fileCount),
            SmartViewDefinition(id: .pdfs, title: "PDFs", systemImage: "doc.richtext", query: "type:pdf", count: pdfCount),
            SmartViewDefinition(id: .sensitiveReview, title: "Sensitive Review", systemImage: "exclamationmark.shield", query: "secret:*", count: sensitiveCount),
            SmartViewDefinition(id: .unfiledSaved, title: "Unfiled Saved", systemImage: "tray", query: "origin:saved folder:unfiled", count: snapshot.savedClips.filter { $0.folderID == nil }.count),
            SmartViewDefinition(id: .pinnedSaved, title: "Pinned Saved", systemImage: "pin", query: "origin:saved pinned:true", count: snapshot.savedClips.filter(\.isPinned).count),
        ]
    }

    var persistedSensitiveItemCount: Int {
        snapshot.history.filter {
            presentationSensitivityCategory(content: $0.content, stored: $0.sensitivity) != nil
        }.count + snapshot.savedClips.filter {
            presentationSensitivityCategory(content: $0.content, stored: $0.sensitivity) != nil
        }.count
    }

    var applicationSmartViews: [SmartViewDefinition] {
        struct AppFacet { var name: String; var count: Int }
        var facets: [String: AppFacet] = [:]
        func add(bundleID: String?, context: ClipCaptureContext?) {
            let display = context?.sourceApplicationName
                ?? bundleID?.components(separatedBy: ".").last
            guard let display, !display.isEmpty else { return }
            let exactValue = bundleID ?? display
            let queryValue = exactValue.replacingOccurrences(of: " ", with: "+")
            if var facet = facets[queryValue] {
                facet.count += 1
                facets[queryValue] = facet
            } else {
                facets[queryValue] = AppFacet(name: display, count: 1)
            }
        }
        snapshot.history.forEach { add(bundleID: $0.sourceApplicationBundleIdentifier, context: $0.captureContext) }
        snapshot.savedClips.forEach { add(bundleID: $0.sourceApplicationBundleIdentifier, context: $0.captureContext) }
        return facets
            .sorted { lhs, rhs in lhs.value.count == rhs.value.count ? lhs.value.name < rhs.value.name : lhs.value.count > rhs.value.count }
            .prefix(5)
            .map { queryValue, facet in
                SmartViewDefinition(
                    id: .application(query: queryValue, name: facet.name),
                    title: facet.name,
                    systemImage: "app",
                    query: "sourceexact:\(queryValue)",
                    count: facet.count
                )
            }
    }

    var domainSmartViews: [SmartViewDefinition] {
        var counts: [String: Int] = [:]
        for context in snapshot.history.map(\.captureContext) + snapshot.savedClips.map(\.captureContext) {
            guard let domain = context?.sourceDomain, !domain.isEmpty else { continue }
            counts[domain, default: 0] += 1
        }
        return counts
            .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value }
            .prefix(5)
            .map { domain, count in
                SmartViewDefinition(
                    id: .domain(domain),
                    title: domain,
                    systemImage: "globe",
                    query: "domainexact:\(domain)",
                    count: count
                )
            }
    }

    var userSmartViewDefinitions: [SmartViewDefinition] {
        userSmartViews.map { view in
            SmartViewDefinition(
                id: .user(view.id),
                title: view.name,
                systemImage: view.isPinned ? "pin.circle.fill" : "line.3.horizontal.decrease.circle",
                query: view.query,
                count: userSmartViewCounts[view.id] ?? 0
            )
        }
    }

    var menuMatchingSmartViews: [SmartViewDefinition] {
        let query = menuSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return userSmartViewDefinitions.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.query.localizedCaseInsensitiveContains(query)
        }
    }

    func smartViewDefinition(for id: SmartViewID) -> SmartViewDefinition? {
        (staticSmartViews + userSmartViewDefinitions + applicationSmartViews + domainSmartViews)
            .first { $0.id == id }
    }

    var canRouteSelectedClipToAI: Bool {
        selectedClip.map { clipContextMenuPolicy(for: $0).canRouteToAI } ?? false
    }

    func focusLibrarySearch() {
        searchFocusRequestID &+= 1
    }

    func toggleSelectedPin() {
        guard let selectedClip else { return }
        togglePinOrSave(selectedClip)
    }

    var pinnedNoteCount: Int {
        snapshot.savedClips.lazy.filter { $0.kind == .note && $0.isPinned }.count
    }

    func selectPinnedNote(at index: Int) {
        let notes = snapshot.savedClips
            .filter { $0.kind == .note && $0.isPinned }
            .sorted { ($0.pinnedAt ?? $0.modifiedAt) > ($1.pinnedAt ?? $1.modifiedAt) }
        guard notes.indices.contains(index) else { return }
        selectedSection = .smartView(.notes)
        selectedClipID = notes[index].id
    }

    var clipsForSelectedSection: [PresentedClip] {
        switch selectedSection {
        case .smartView(.notes):
            return snapshot.savedClips
                .filter { $0.kind == .note }
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .map { saved in
                    PresentedClip(
                        id: saved.id,
                        title: saved.name,
                        content: saved.content,
                        date: saved.modifiedAt,
                        sourceBundleIdentifier: saved.sourceApplicationBundleIdentifier,
                        origin: .saved(folderID: saved.folderID),
                        savedItemKind: saved.kind,
                        captureContext: saved.captureContext,
                        sensitivity: saved.sensitivity,
                        isPinned: saved.isPinned,
                        tags: saved.tags ?? [],
                        pasteboardTypeIdentifiers: saved.pasteboardTypeIdentifiers ?? []
                    )
                }
        case .smartView(.sensitiveReview):
            let history = snapshot.history.compactMap { item -> PresentedClip? in
                guard presentationSensitivityCategory(
                    content: item.content,
                    stored: item.sensitivity
                ) != nil else { return nil }
                return PresentedClip(
                    id: item.id,
                    title: Self.previewTitle(for: item.content),
                    content: item.content,
                    date: item.lastCapturedAt,
                    sourceBundleIdentifier: item.sourceApplicationBundleIdentifier,
                    origin: .history,
                    captureContext: item.captureContext,
                    sensitivity: item.sensitivity,
                    pasteboardTypeIdentifiers: item.pasteboardTypeIdentifiers ?? [],
                    captureCount: item.captureCount,
                    pasteCount: item.pasteCount,
                    lastPastedAt: item.lastPastedAt
                )
            }
            let saved = snapshot.savedClips.compactMap { item -> PresentedClip? in
                guard presentationSensitivityCategory(
                    content: item.content,
                    stored: item.sensitivity
                ) != nil else { return nil }
                return PresentedClip(
                    id: item.id,
                    title: item.name,
                    content: item.content,
                    date: item.modifiedAt,
                    sourceBundleIdentifier: item.sourceApplicationBundleIdentifier,
                    origin: .saved(folderID: item.folderID),
                    savedItemKind: item.kind,
                    captureContext: item.captureContext,
                    sensitivity: item.sensitivity,
                    isPinned: item.isPinned,
                    tags: item.tags ?? [],
                    pasteboardTypeIdentifiers: item.pasteboardTypeIdentifiers ?? []
                )
            }
            return (history + saved).sorted { $0.date > $1.date }
        case .searchResults, .smartView:
            return searchResults.map(presentedClip(for:))
        case .history:
            let resultIDs = Set(searchResults.map(\.id))
            let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return snapshot.history
                .filter { !isSearching || resultIDs.contains($0.id) }
                .map {
                    PresentedClip(
                        id: $0.id,
                        title: Self.previewTitle(for: $0.content),
                        content: $0.content,
                        date: $0.lastCapturedAt,
                        sourceBundleIdentifier: $0.sourceApplicationBundleIdentifier,
                        origin: .history,
                        captureContext: $0.captureContext,
                        sensitivity: $0.sensitivity,
                        pasteboardTypeIdentifiers: $0.pasteboardTypeIdentifiers ?? [],
                        captureCount: $0.captureCount,
                        pasteCount: $0.pasteCount,
                        lastPastedAt: $0.lastPastedAt
                    )
                }
        case .allSaved:
            let resultIDs = Set(searchResults.map(\.id))
            let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let historyByID = Dictionary(uniqueKeysWithValues: snapshot.history.map { ($0.id, $0) })
            return snapshot.savedClips
                .filter { !isSearching || resultIDs.contains($0.id) }
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .map {
                    let history = $0.sourceHistoryItemID.flatMap { historyID in
                        historyByID[historyID]
                    }
                    return PresentedClip(
                        id: $0.id,
                        title: $0.name,
                        content: $0.content,
                        date: $0.modifiedAt,
                        sourceBundleIdentifier: $0.sourceApplicationBundleIdentifier,
                        origin: .saved(folderID: $0.folderID),
                        savedItemKind: $0.kind,
                        captureContext: $0.captureContext,
                        sensitivity: $0.sensitivity,
                        isPinned: $0.isPinned,
                        tags: $0.tags ?? [],
                        pasteboardTypeIdentifiers: $0.pasteboardTypeIdentifiers ?? [],
                        captureCount: history?.captureCount,
                        pasteCount: history?.pasteCount,
                        lastPastedAt: history?.lastPastedAt
                    )
                }
        case let .folder(folderID):
            let resultIDs = Set(searchResults.map(\.id))
            let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let historyByID = Dictionary(uniqueKeysWithValues: snapshot.history.map { ($0.id, $0) })
            return snapshot.savedClips
                .filter { $0.folderID == folderID && (!isSearching || resultIDs.contains($0.id)) }
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .map {
                    let history = $0.sourceHistoryItemID.flatMap { historyID in
                        historyByID[historyID]
                    }
                    return PresentedClip(
                        id: $0.id,
                        title: $0.name,
                        content: $0.content,
                        date: $0.modifiedAt,
                        sourceBundleIdentifier: $0.sourceApplicationBundleIdentifier,
                        origin: .saved(folderID: $0.folderID),
                        savedItemKind: $0.kind,
                        captureContext: $0.captureContext,
                        sensitivity: $0.sensitivity,
                        isPinned: $0.isPinned,
                        tags: $0.tags ?? [],
                        pasteboardTypeIdentifiers: $0.pasteboardTypeIdentifiers ?? [],
                        captureCount: history?.captureCount,
                        pasteCount: history?.pasteCount,
                        lastPastedAt: history?.lastPastedAt
                    )
                }
        case .vault:
            // Vault text and names live in a separate encrypted store and never enter the
            // ordinary snapshot or search index.
            return []
        case .privateSession:
            return privateSessionClips
        case .clipboardHealth, .workflows, .sync, .developerProjects, .automaticOrganization:
            return []
        }
    }

    func start() async {
        if isReady { return }
        if let startupTask {
            await startupTask.value
            return
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performStart()
        }
        startupTask = task
        await task.value
        startupTask = nil
    }

    private func performStart() async {
        guard !isReady else { return }
        do {
            let legacyURL = supportDirectory.appendingPathComponent("library.json")
            let detector = SecretDetector()
            let store: any ClipboardLibraryPersisting = injectedLibraryPersistence
                ?? SQLiteFileClipboardLibraryStore(
                fileURL: supportDirectory.appendingPathComponent("library.sqlite3"),
                legacyJSONURL: legacyURL,
                legacyContentAdmission: { content in
                    !detector.scan(content).containsSecret
                }
            )
            library = try await ClipboardLibrary.open(persistence: store)
            do {
                let smartViews = try await UserSmartViewLibrary.open(
                    persistence: userSmartViewStore
                )
                userSmartViewLibrary = smartViews
                userSmartViews = await smartViews.snapshot()
            } catch {
                // Definitions contain queries and presentation metadata only. A corrupt local
                // definition file must never block clipboard capture or expose partial results.
                userSmartViews = []
                errorMessage = "Saved Smart Views could not be opened: \(error.localizedDescription)"
            }
            await refreshDirectLicenseState()
            do {
                automaticOrganizationSnapshot = try await automaticOrganizationStore.load()
            } catch {
                // Rules are local-only and never get a chance to run when their file is invalid.
                // Ordinary clipboard capture must remain available.
                automaticOrganizationSnapshot = .empty
                errorMessage = "Automatic Organization was disabled: \(error.localizedDescription)"
            }
            do {
                let workspace = try await DeveloperWorkspace.open(
                    persistence: developerWorkspaceStore
                )
                developerWorkspace = workspace
                developerWorkspaceSnapshot = await workspace.snapshot()
                selectedDeveloperProjectID = developerWorkspaceSnapshot.activeProjectID
                    ?? developerWorkspaceSnapshot.projects.first(where: { !$0.isArchived })?.id
                try await refreshDeveloperTimeline()
            } catch {
                // Project state is local-only and must never prevent ordinary clipboard use.
                errorMessage = "Developer Projects could not be opened: \(error.localizedDescription)"
            }
            refreshPasteboardAccessState()

            // Loading persisted sync consent is read-only and does not construct CloudKit.
            // A transport is created only below when this or a prior run explicitly opted in.
            await preparePersistedSyncState()
            await prepareSharedFolderState()
            await installCloudPushSubscriptions(forceVerification: true)

            let vaultCapability = VaultCapabilityChecker.currentProcess()
            if injectedVaultStore == nil, !vaultCapability.isAvailable {
                vaultAvailabilityMessage = vaultCapability.message
            } else {
                do {
                    let vault = try await VaultLibrary.open(
                        store: injectedVaultStore ?? JSONFileVaultStore(
                            fileURL: supportDirectory.appendingPathComponent("vault.encrypted.json")
                        ),
                        session: vaultSession,
                        assetStore: vaultAssetStore
                    )
                    vaultLibrary = vault
                    let encrypted = await vault.encryptedSnapshot()
                    vaultEncryptedItemCount = encrypted.envelopes.count
                    await vaultAutoLock.start()
                    beginVaultStateObservation()
                } catch {
                    // An unavailable Vault must not prevent ordinary local clipboard operation.
                    vaultAvailabilityMessage = error.localizedDescription
                }
            }
            installLifecycleObservers()

            try await refreshSnapshot()
            await restoreAutomationRunState()
            refreshTextExpansionState(promptIfNeeded: false)
            // A first-run install does not observe the clipboard until the user explicitly
            // completes onboarding. Starting at that moment also establishes a fresh baseline,
            // so content copied before consent is never imported retroactively.
            if hasCompletedOnboarding, pasteboardAccessState != .denied {
                clipboardMonitor.start()
            }
            do {
                try registerGlobalHotKey(globalHotKeyChoice)
                try registerCreateNoteHotKey(createNoteHotKeyChoice)
                try registerInsertPaletteHotKey(insertPaletteHotKeyChoice)
            } catch {
                // The app remains fully usable from its menu-bar item when a shortcut conflicts.
                statusMessage = "\(globalHotKeyChoice.displayName) is already in use. Choose another shortcut in Settings or open Clipboard Router from the menu bar."
            }
            isReady = true
            startRetentionPruneLoopIfNeeded()
            startDirectLicenseRefreshLoopIfNeeded()

            if directLicenseAccessPolicy.allows(.cloud),
               syncSnapshot.isEnabled,
               syncContainerIdentifier != nil
            {
                startSyncRefreshLoopIfNeeded()
                synchronizeSavedLibrary()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        if isReady,
           pasteboardAccessState != .denied,
           !clipboardMonitor.isRunning
        {
            clipboardMonitor.start()
        }
        statusMessage = "macOS may ask for permission when Clipboard Router first reads the General pasteboard."
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.refreshPasteboardAccessState()
        }
    }

    var isDirectLicenseCommerceConfigured: Bool {
        directLicenseVerifier.isConfigured && directLicenseRepository.isConfigured
    }

    var isDirectLicenseEngineeringBuild: Bool {
        !directLicenseVerifier.isConfigured && !directLicenseRepository.isConfigured
    }

    /// Mac App Store builds never embed direct-license commerce configuration, so they are
    /// indistinguishable from an engineering build by commerce configuration alone. This flag
    /// lets the UI show neither the "Engineering Build" label nor direct-license activation,
    /// settings, or purchase language, while premium capabilities remain unlocked exactly as
    /// the engineering-evaluation policy already unlocks them for `.unavailable(.engineeringBuild)`.
    var isMacAppStoreDistribution: Bool {
        distributionChannelProvider.channel == .macAppStore
    }

    var canExportBundledCommandLineTool: Bool {
        !isMacAppStoreDistribution
    }

    var directLicenseAccessPolicy: DirectLicenseAccessPolicy {
        let currentWallClock = directLicenseClock.observation().wallClock
        guard let boundary = directLicenseNextBoundary, currentWallClock >= boundary else {
            return DirectLicenseAccessPolicy(status: directLicenseStatus)
        }
        let expiredStatus: DirectLicenseStatus
        switch directLicenseStatus {
        case let .active(plan, expiresAt?):
            expiredStatus = .expired(plan: plan, expiredAt: expiresAt)
        case let .grace(plan, endsAt):
            expiredStatus = .expired(plan: plan, expiredAt: endsAt)
        default:
            expiredStatus = directLicenseStatus
        }
        return DirectLicenseAccessPolicy(status: expiredStatus)
    }

    var directLicenseDeviceDescription: String {
        "Device …\(directLicenseDeviceID.suffix(8))"
    }

    func startDirectLicenseTrial() {
        performDirectLicenseOperation {
            let token = try await self.directLicenseRepository.startTrial(
                deviceID: self.directLicenseDeviceID
            )
            try await self.acceptDirectLicenseToken(token)
            self.statusMessage = "Trial activated for this Mac."
        }
    }

    func activateDirectLicense(key: String) {
        performDirectLicenseOperation {
            let token = try await self.directLicenseRepository.activate(
                licenseKey: key,
                deviceID: self.directLicenseDeviceID
            )
            try await self.acceptDirectLicenseToken(token)
            self.statusMessage = "License activated for this Mac."
        }
    }

    func restoreDirectLicense(accountID: String) {
        performDirectLicenseOperation {
            let token = try await self.directLicenseRepository.restore(
                accountID: accountID,
                deviceID: self.directLicenseDeviceID
            )
            try await self.acceptDirectLicenseToken(token)
            self.statusMessage = "License restored for this Mac."
        }
    }

    func refreshDirectLicense() {
        performDirectLicenseOperation {
            guard let token = try await self.directLicenseCredentialStore.loadToken() else {
                throw DirectLicenseError.restoreRejected
            }
            do {
                let refreshed = try await self.directLicenseRepository.refresh(
                    token: token,
                    deviceID: self.directLicenseDeviceID
                )
                try await self.acceptDirectLicenseToken(refreshed)
                self.statusMessage = "License status refreshed."
            } catch DirectLicenseError.repositoryUnavailable {
                await self.refreshDirectLicenseState(serviceUnavailable: true)
                self.statusMessage = "The licensing service is unavailable. Your verified local license was not changed."
            }
        }
    }

    func disconnectDirectLicense() {
        performDirectLicenseOperation {
            try await self.directLicenseCredentialStore.deleteToken()
            // Preserve the secure last-seen clock checkpoint across license changes so a
            // disconnect cannot be used to reset trial or offline-grace rollback evidence.
            await self.refreshDirectLicenseState()
            self.statusMessage = "License disconnected from this Mac. Existing clips remain available."
        }
    }

    func deactivateDirectLicenseDevice() {
        performDirectLicenseOperation {
            guard let token = try await self.directLicenseCredentialStore.loadToken() else {
                throw DirectLicenseError.deactivationRejected
            }
            // Local credentials are removed only after the server confirms deactivation.
            try await self.directLicenseRepository.deactivate(
                token: token,
                deviceID: self.directLicenseDeviceID
            )
            try await self.directLicenseCredentialStore.deleteToken()
            // Deactivation removes entitlement, not the rollback-resistant clock history.
            await self.refreshDirectLicenseState()
            self.statusMessage = "This Mac was deactivated. Existing clips remain available."
        }
    }

    @discardableResult
    private func requireDirectLicense(_ capability: DirectLicenseCapability) -> Bool {
        guard directLicenseAccessPolicy.allows(capability) else {
            errorMessage = DirectLicenseError.premiumLicenseRequired.localizedDescription
            return false
        }
        return true
    }

    private func performDirectLicenseOperation(
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        guard isDirectLicenseCommerceConfigured else {
            statusMessage = "Engineering Build: no commerce provider, service domain, or public key is configured."
            return
        }
        guard !isDirectLicenseOperationInProgress else {
            errorMessage = DirectLicenseError.operationInProgress.localizedDescription
            return
        }
        isDirectLicenseOperationInProgress = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isDirectLicenseOperationInProgress = false }
            do {
                try await operation()
            } catch DirectLicenseError.repositoryUnavailable {
                await self.refreshDirectLicenseState(serviceUnavailable: true)
                self.statusMessage = DirectLicenseError.repositoryUnavailable.localizedDescription
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func acceptDirectLicenseToken(_ token: String) async throws {
        let claims = try directLicenseVerifier.verify(token)
        guard claims.deviceID == directLicenseDeviceID else {
            throw DirectLicenseError.invalidClaims
        }
        let checkpoint = try await directLicenseCredentialStore.loadClockCheckpoint()
        let observation = directLicenseClock.observation()
        let evaluation = directLicenseStateMachine.evaluate(
            evidence: .verified(claims),
            expectedDeviceID: directLicenseDeviceID,
            observation: observation,
            checkpoint: checkpoint,
            serverVerifiedAt: observation.wallClock
        )
        // Never replace the last verified credential when secure clock evidence is invalid.
        guard evaluation.status != .tampered else {
            try await directLicenseCredentialStore.saveClockCheckpoint(evaluation.nextCheckpoint)
            publishDirectLicenseEvaluation(evaluation)
            throw DirectLicenseError.invalidToken
        }
        // Scope, signature, claims, and secure-clock validation all happen before replacement.
        // Persist the non-secret clock first so a token write failure leaves the prior token intact.
        try await directLicenseCredentialStore.saveClockCheckpoint(evaluation.nextCheckpoint)
        try await directLicenseCredentialStore.saveToken(token)
        publishDirectLicenseEvaluation(evaluation)
    }

    private func refreshDirectLicenseState(serviceUnavailable: Bool = false) async {
        guard isDirectLicenseCommerceConfigured else {
            directLicenseStatus = isDirectLicenseEngineeringBuild
                ? .unavailable(.engineeringBuild)
                : .unavailable(.verifierUnavailable)
            directLicenseAccountID = nil
            directLicenseID = nil
            directLicenseNextBoundary = nil
            return
        }
        do {
            let checkpoint = try await directLicenseCredentialStore.loadClockCheckpoint()
            let evidence: DirectLicenseEvidence
            if let token = try await directLicenseCredentialStore.loadToken() {
                do { evidence = .verified(try directLicenseVerifier.verify(token)) }
                catch DirectLicenseError.verifierUnavailable { evidence = .verifierUnavailable }
                catch { evidence = .tampered }
            } else {
                evidence = .missing
            }
            let evaluation = directLicenseStateMachine.evaluate(
                evidence: evidence,
                expectedDeviceID: directLicenseDeviceID,
                observation: directLicenseClock.observation(),
                checkpoint: checkpoint,
                serviceUnavailable: serviceUnavailable
            )
            try await directLicenseCredentialStore.saveClockCheckpoint(evaluation.nextCheckpoint)
            publishDirectLicenseEvaluation(evaluation)
        } catch {
            directLicenseStatus = .tampered
            directLicenseAccountID = nil
            directLicenseID = nil
            directLicenseNextBoundary = nil
            stopSyncRefreshLoop()
            stopSharedFolderRefreshLoop()
        }
    }

    private func publishDirectLicenseEvaluation(_ evaluation: DirectLicenseEvaluation) {
        directLicenseStatus = evaluation.status
        directLicenseAccountID = evaluation.accountID
        directLicenseID = evaluation.licenseID
        directLicenseNextBoundary = switch evaluation.status {
        case let .active(_, expiresAt): expiresAt
        case let .grace(_, endsAt): endsAt
        default: nil
        }
        if directLicenseAccessPolicy.allows(.cloud) {
            if isReady {
                startSyncRefreshLoopIfNeeded()
                startSharedFolderRefreshLoopIfNeeded()
                if syncSnapshot.isEnabled, syncContainerIdentifier != nil {
                    synchronizeSavedLibrary()
                }
                Task { [weak self] in
                    await self?.installCloudPushSubscriptions(forceVerification: false)
                }
            }
        } else {
            stopSyncRefreshLoop()
            stopSharedFolderRefreshLoop()
        }
    }

    func updateSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            activeSmartViewID = nil
            if selectedSection.isOrdinarySearchPresentation {
                selectedSection = ordinarySectionBeforeSearch ?? .history
            }
            ordinarySectionBeforeSearch = nil
            selectedClipID = nil
            return
        }
        guard isOrdinarySearchAvailable else {
            searchResults = []
            return
        }
        if case .smartView = selectedSection,
           let activeSmartViewID,
           smartViewDefinition(for: activeSmartViewID)?.query != query
        {
            self.activeSmartViewID = nil
            selectedSection = .searchResults
        }
        if !selectedSection.isOrdinarySearchPresentation {
            ordinarySectionBeforeSearch = selectedSection
            selectedSection = .searchResults
            activeSmartViewID = nil
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, let library = self.library else { return }
            let results = await library.search(query: query, limit: 500)
            guard !Task.isCancelled,
                  self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query
            else { return }
            self.searchResults = results
            if self.selectedClipID.map({ id in !results.contains(where: { $0.id == id }) }) == true {
                self.selectedClipID = nil
            }
        }
    }

    func selectLibrarySection(_ section: LibrarySection) {
        // SwiftUI may write the current sidebar selection back while its backing
        // NSTableView is restoring selection. Avoid publishing unrelated state from
        // inside that delegate callback when the effective selection did not change.
        guard section != selectedSection else { return }
        if case let .smartView(id) = section {
            applySmartView(id)
            return
        }
        searchTask?.cancel()
        if !searchResults.isEmpty { searchResults = [] }
        if !searchText.isEmpty { searchText = "" }
        if activeSmartViewID != nil { activeSmartViewID = nil }
        ordinarySectionBeforeSearch = nil
        if selectedClipID != nil {
            selectedClipID = nil
        } else if !selectedClipIDs.isEmpty {
            selectedClipIDs = []
        }
        selectedSection = section
    }

    /// Defers an explicit sidebar accessibility action until AppKit has left its
    /// NSTableView delegate callback, then revalidates dynamic destinations.
    func requestAccessibilityLibrarySectionSelection(_ section: LibrarySection) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
            guard let self, self.isAvailableAccessibilityLibrarySection(section) else { return }
            self.selectLibrarySection(section)
        }
    }

    private func isAvailableAccessibilityLibrarySection(_ section: LibrarySection) -> Bool {
        switch section {
        case let .folder(id):
            return snapshot.folders.contains(where: { $0.id == id })
        case let .smartView(id):
            guard let definition = smartViewDefinition(for: id) else { return false }
            return id != .sensitiveReview || definition.count > 0
        case .privateSession:
            return isPrivateSessionActive
        case .searchResults:
            return false
        case .history, .allSaved, .vault, .clipboardHealth, .workflows, .sync,
             .developerProjects, .automaticOrganization:
            return true
        }
    }

    func openActionsWorkspace(_ mode: ActionsWorkspaceMode) {
        actionsWorkspaceMode = mode
        selectLibrarySection(.workflows)
        // Republish after the dashboard is active. In the packaged app, the section transition
        // and segment change can otherwise be coalesced while the destination view is being
        // constructed, leaving the previous segment visible. Do not override a subsequent user
        // choice made before this turn runs.
        Task { @MainActor [weak self] in
            guard let self,
                  self.selectedSection == .workflows,
                  self.actionsWorkspaceMode == mode else { return }
            self.actionsWorkspaceMode = mode
        }
    }

    func applySmartView(_ id: SmartViewID) {
        guard let definition = smartViewDefinition(for: id) else { return }
        if !selectedSection.isOrdinarySearchPresentation {
            ordinarySectionBeforeSearch = selectedSection
        }
        activeSmartViewID = id
        selectedSection = .smartView(id)
        selectedClipID = nil
        if id == .notes || id == .sensitiveReview {
            searchTask?.cancel()
            searchResults = []
            searchText = ""
            return
        }
        searchText = definition.query
        updateSearch()
    }

    func createUserSmartView(name: String, query: String, pinned: Bool) async -> Bool {
        guard let userSmartViewLibrary else {
            errorMessage = "Saved Smart Views are unavailable."
            return false
        }
        do {
            _ = try await userSmartViewLibrary.create(name: name, query: query, pinned: pinned)
            userSmartViews = await userSmartViewLibrary.snapshot()
            await refreshUserSmartViewCounts()
            statusMessage = "Smart View saved locally."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func renameUserSmartView(id: UUID, name: String) {
        guard let userSmartViewLibrary else { return }
        perform {
            try await userSmartViewLibrary.rename(id: id, name: name)
            self.userSmartViews = await userSmartViewLibrary.snapshot()
            self.statusMessage = "Smart View renamed."
        }
    }

    func updateUserSmartView(
        id: UUID,
        name: String,
        query: String,
        pinned: Bool
    ) async -> Bool {
        guard let userSmartViewLibrary else {
            errorMessage = "Saved Smart Views are unavailable."
            return false
        }
        guard !isBusy else {
            errorMessage = AppModelOperationError.operationInProgress.localizedDescription
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await userSmartViewLibrary.update(
                id: id,
                name: name,
                query: query,
                pinned: pinned
            )
            userSmartViews = await userSmartViewLibrary.snapshot()
            await refreshUserSmartViewCounts()
            if activeSmartViewID == .user(id) { applySmartView(.user(id)) }
            statusMessage = "Smart View updated."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateUserSmartViewQuery(id: UUID, query: String) {
        guard let userSmartViewLibrary else { return }
        perform {
            try await userSmartViewLibrary.updateQuery(id: id, query: query)
            self.userSmartViews = await userSmartViewLibrary.snapshot()
            await self.refreshUserSmartViewCounts()
            if self.activeSmartViewID == .user(id) { self.applySmartView(.user(id)) }
            self.statusMessage = "Smart View updated."
        }
    }

    func setUserSmartViewPinned(id: UUID, pinned: Bool) {
        guard let userSmartViewLibrary else { return }
        perform {
            try await userSmartViewLibrary.setPinned(id: id, pinned: pinned)
            self.userSmartViews = await userSmartViewLibrary.snapshot()
            self.statusMessage = pinned ? "Smart View pinned." : "Smart View unpinned."
        }
    }

    func moveUserSmartView(id: UUID, offset: Int) {
        guard let userSmartViewLibrary,
              canMoveUserSmartView(id: id, offset: offset),
              let index = userSmartViews.firstIndex(where: { $0.id == id })
        else { return }
        let destination = index + offset
        guard userSmartViews.indices.contains(destination) else { return }
        var ids = userSmartViews.map(\.id)
        ids.swapAt(index, destination)
        perform {
            try await userSmartViewLibrary.reorder(ids: ids)
            self.userSmartViews = await userSmartViewLibrary.snapshot()
            self.statusMessage = "Smart View reordered."
        }
    }

    func canMoveUserSmartView(id: UUID, offset: Int) -> Bool {
        guard let index = userSmartViews.firstIndex(where: { $0.id == id }) else { return false }
        let destination = index + offset
        guard userSmartViews.indices.contains(destination) else { return false }
        return userSmartViews[index].isPinned == userSmartViews[destination].isPinned
    }

    func deleteUserSmartView(id: UUID) {
        guard let userSmartViewLibrary else { return }
        perform {
            try await userSmartViewLibrary.delete(id: id)
            self.userSmartViews = await userSmartViewLibrary.snapshot()
            self.userSmartViewCounts[id] = nil
            if self.activeSmartViewID == .user(id) {
                self.clearOrdinarySearch()
            }
            self.statusMessage = "Smart View deleted."
        }
    }

    func clearOrdinarySearch() {
        searchText = ""
        updateSearch()
    }

    func removeSearchChip(_ chip: SearchQueryChip) {
        var tokens = searchText.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard tokens.indices.contains(chip.id) else { return }
        tokens.remove(at: chip.id)
        activeSmartViewID = nil
        searchText = tokens.joined(separator: " ")
        if !searchText.isEmpty { selectedSection = .searchResults }
        updateSearch()
    }

    func applySearchExample(_ query: String) {
        activeSmartViewID = nil
        searchText = query
        updateSearch()
    }

    func clipOriginContext(_ clip: PresentedClip) -> String {
        switch clip.origin {
        case .history:
            return "History"
        case let .saved(folderID):
            if let folderID,
               let folder = snapshot.folders.first(where: { $0.id == folderID })
            {
                return "Saved · \(folder.name)"
            }
            return "Saved · Unfiled"
        case .privateSession:
            return "Private Session"
        }
    }

    func clipSourceContext(_ clip: PresentedClip) -> String? {
        clip.captureContext?.sourceApplicationName
            ?? clip.sourceBundleIdentifier?.components(separatedBy: ".").last
    }

    func toggleCapture() {
        guard hasCompletedOnboarding else {
            statusMessage = "Finish setup before turning on clipboard capture."
            return
        }
        guard pasteboardAccessState != .denied else {
            statusMessage = "Clipboard access is blocked. Allow Clipboard Router in System Settings > Privacy & Security, then return to the app."
            return
        }
        guard let library else { return }
        perform {
            try await library.setCaptureEnabled(!self.isCaptureEnabled)
            try await self.refreshSnapshot()
            self.statusMessage = self.isCaptureEnabled ? "Clipboard capture resumed." : "Clipboard capture paused."
        }
    }

    func copy(_ clip: PresentedClip) {
        guard clip.sensitivity == nil,
              !secretDetector.scan(clip.content).containsSecret
        else {
            errorMessage = "Potential secret content stays hidden. Move it to Vault or remove it from ordinary history before copying."
            return
        }
        enqueueClipboardAction {
            try await self.typedPasteboardWriter.write(
                clip.content,
                mode: .original,
                sourceTypeIdentifiers: clip.pasteboardTypeIdentifiers
            )
            await self.recordMetric(ProductMetricEvent(
                anonymousInstallationID: self.metricsInstallationID,
                name: .recoveredAndReused,
                surface: .library,
                action: .copy,
                ageBucket: ProductMetricAgeBucket.classify(clip.date),
                resultCountBucket: self.isOrdinarySearchActive
                    ? ProductMetricCountBucket.classify(self.searchResults.count)
                    : nil,
                itemKind: clip.savedItemKind,
                contentType: clip.content.type
            ))
            self.statusMessage = "Copied original clip representations to the clipboard."
        }
    }

    /// Copies the canonical typed payload as an explicit Base64 transport value. Base64 is
    /// reversible encoding, not encryption; this action is intentionally separate from ordinary
    /// copy so the user can see that the value is portable plaintext and must not be treated as a
    /// secret-sharing primitive.
    func copyAsBase64(_ clip: PresentedClip) {
        guard clip.sensitivity == nil,
              !secretDetector.scan(clip.content).containsSecret
        else {
            errorMessage = "Base64 is not encryption. Potential secret content stays hidden; use Encrypted Share instead."
            return
        }
        do {
            let encoded = try ClipboardBase64Codec.encode(clip.content)
            let content = try ClipContent.detect(text: encoded)
            enqueueClipboardAction {
                try await self.typedPasteboardWriter.write(content, mode: .plainText)
                self.statusMessage = "Copied the clip as Base64. Base64 is not encrypted."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func presentEncryptedShare(_ clip: PresentedClip) {
        guard clip.origin != .privateSession else {
            errorMessage = "Private Session clips cannot be shared."
            return
        }
        encryptedShareEnvelope = nil
        pendingEncryptedShareRequest = EncryptedShareRequest(clip: clip)
    }

    /// Opens the share composer for a sensitive value that is still held only in quarantine.
    /// The value is never copied into ordinary History as a side effect of sharing.
    func presentEncryptedShareForQuarantine(id: UUID) {
        perform {
            guard let review = await self.quarantineStore.review(id: id) else {
                self.errorMessage = "That quarantined clip has expired."
                return
            }
            self.encryptedShareEnvelope = nil
            self.pendingEncryptedShareRequest = EncryptedShareRequest(
                quarantineID: id,
                content: review.content
            )
        }
    }

    func dismissEncryptedShare() {
        pendingEncryptedShareRequest = nil
        encryptedShareEnvelope = nil
    }

    func localSecureSharePublicKeyString() async -> String? {
        try? await secureShareService.localRecipientKeyString()
    }

    func generateEncryptedShare(
        for request: EncryptedShareRequest,
        recipientKeyString: String
    ) {
        let key = recipientKeyString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = "Paste an authenticated Clipboard Router recipient key first."
            return
        }
        perform {
            self.encryptedShareEnvelope = try await self.secureShareService.seal(
                request.content,
                for: key
            )
            self.statusMessage = "Encrypted share generated. Copy the opaque envelope and deliver it through your chosen channel."
        }
    }

    /// Moves a quarantined source into encrypted Vault after the user has explicitly reviewed
    /// the share flow. The quarantine entry is removed only after Vault has committed it.
    func moveEncryptedShareSourceToVault() {
        guard let quarantineID = pendingEncryptedShareRequest?.quarantineID else { return }
        moveQuarantinedClipToVault(id: quarantineID)
    }

    func copyEncryptedShareEnvelope() {
        guard let envelope = encryptedShareEnvelope else { return }
        enqueueClipboardAction {
            let content = try ClipContent.detect(text: envelope)
            try await self.typedPasteboardWriter.write(content, mode: .plainText)
            self.statusMessage = "Copied the authenticated encrypted share envelope."
        }
    }

    /// Explicitly decrypts a selected encrypted-share clip for an in-app preview. This returns
    /// ephemeral typed content only; it does not write plaintext to history or the pasteboard.
    func decryptEncryptedShare(_ clip: PresentedClip) async -> ClipContent? {
        guard clip.content.text.hasPrefix(SecureShareClipCodec.prefix) else {
            errorMessage = "This clip is not a Clipboard Router encrypted share."
            return nil
        }
        do {
            let content = try await secureShareService.decrypt(clip.content.text)
            decryptedSharePreview = content
            statusMessage = "Encrypted share authenticated. Plaintext remains in the in-app preview until you explicitly copy it."
            return content
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func isEncryptedShare(_ clip: PresentedClip) -> Bool {
        clip.content.text.hasPrefix(SecureShareClipCodec.prefix)
    }

    func clearDecryptedSharePreview() {
        decryptedSharePreview = nil
    }

    func copyDecryptedSharePreview() {
        guard let content = decryptedSharePreview else { return }
        enqueueClipboardAction {
            try await self.typedPasteboardWriter.write(content, mode: .original)
            self.statusMessage = "Copied the decrypted share after explicit confirmation."
        }
    }

    func copyAssistantResponse(_ text: String) {
        do {
            let content = try ClipContent.detect(text: text)
            enqueueClipboardAction {
                try await self.typedPasteboardWriter.write(content, mode: .plainText)
                self.statusMessage = "Copied the Assistant response to the clipboard."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyDebugBundleAssistantResponse(
        _ text: String,
        request: DeveloperDebugBundleReviewRequest
    ) {
        do {
            let content = try ClipContent.detect(text: text)
            guard !secretDetector.scan(content).containsSecret else {
                throw AppModelOperationError.generatedSensitiveContent
            }
            enqueueClipboardAction {
                _ = try await self.freshDebugBundleValidation(matching: request.pack)
                guard !self.secretDetector.scan(content).containsSecret else {
                    throw AppModelOperationError.generatedSensitiveContent
                }
                try await self.typedPasteboardWriter.write(content, mode: .plainText)
                self.statusMessage = "Copied the Assistant response to the clipboard."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Captures the app that was frontmost before the menu-bar surface receives a command.
    /// Synthesized input is always posted to this exact PID, never to whichever app happens to
    /// be active after an asynchronous clipboard write.
    func rememberPasteTarget() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier,
              !application.isTerminated
        else {
            pasteTargetProcessIdentifier = nil
            pasteTargetBundleIdentifier = nil
            pasteTargetLaunchDate = nil
            pasteTargetApplicationName = nil
            return
        }
        pasteTargetProcessIdentifier = application.processIdentifier
        pasteTargetBundleIdentifier = application.bundleIdentifier
        pasteTargetLaunchDate = application.launchDate
        pasteTargetApplicationName = application.localizedName
        pasteAutomationAccess = pasteAutomation.currentAccess()
    }

    func pasteIntoRememberedApplication(_ clip: PresentedClip, token: UUID? = nil) {
        if let token {
            guard pasteTargetProcessIdentifier != nil,
                  pasteTargetBundleIdentifier != nil,
                  pasteTargetLaunchDate != nil,
                  token == insertPalettePasteTargetToken
            else {
                errorMessage = "No fresh previous-app target is available. Open Quick Paste from the app you want to paste into."
                return
            }
            insertPalettePasteTargetToken = nil
        }
        let targetPID = pasteTargetProcessIdentifier
        let targetBundleIdentifier = pasteTargetBundleIdentifier
        let targetLaunchDate = pasteTargetLaunchDate
        let targetName = pasteTargetApplicationName
        enqueueClipboardAction {
            try await self.typedPasteboardWriter.write(
                clip.content,
                mode: .original,
                sourceTypeIdentifiers: clip.pasteboardTypeIdentifiers
            )
            guard let targetPID,
                  let application = NSRunningApplication(processIdentifier: targetPID),
                  !application.isTerminated,
                  application.bundleIdentifier == targetBundleIdentifier,
                  application.launchDate == targetLaunchDate
            else {
                self.statusMessage = "Copied the clip. The previous app or its focused session changed, so Clipboard Router did not inject a paste. Press Command-V where you want it."
                return
            }
            guard self.pasteAutomation.currentAccess() == .trusted else {
                self.pasteAutomationAccess = .permissionRequired
                self.statusMessage = "Copied the clip. Allow Accessibility for one-click paste, or press Command-V manually."
                return
            }
            // The palette necessarily made Clipboard Router frontmost. Its dismissal is queued
            // by SwiftUI after this action returns, so yield before restoring the captured app.
            await Task.yield()
            guard application.activate(options: []) else {
                self.statusMessage = "Copied the clip, but macOS could not return to \(targetName ?? "the previous app"). Press Command-V manually."
                return
            }
            var restoredTarget = false
            for _ in 0..<8 {
                guard !application.isTerminated,
                      application.bundleIdentifier == targetBundleIdentifier,
                      application.launchDate == targetLaunchDate
                else { break }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
                    restoredTarget = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard restoredTarget else {
                self.statusMessage = "Copied the clip. The previous app or its focused session changed, so Clipboard Router did not inject a paste. Press Command-V where you want it."
                return
            }
            switch self.pasteAutomation.pasteIfAuthorized(to: targetPID) {
            case .shortcutPosted:
                await self.recordPasteMetadata(for: clip)
                self.statusMessage = "Sent Command-V to \(targetName ?? application.localizedName ?? "the previous app")."
            case .permissionRequired:
                self.pasteAutomationAccess = .permissionRequired
                self.statusMessage = "Copied the clip. Allow Accessibility for one-click paste, or press Command-V manually."
            case .eventCreationFailed:
                self.statusMessage = "Copied the clip, but macOS could not create the paste event. Press Command-V manually."
            }
        }
    }

    private func recordPasteMetadata(for clip: PresentedClip) async {
        guard clip.origin != .privateSession, let library else { return }
        do {
            try await library.recordPaste(id: clip.id)
            try await refreshSnapshot()
        } catch ClipboardLibraryError.historyItemNotFound {
            // A saved clip may outlive the history row that carried device-local usage metadata.
            // The paste still succeeded; do not misreport it as a clipboard failure.
        } catch {
            errorMessage = "The paste succeeded, but its local usage count could not be updated: \(error.localizedDescription)"
        }
    }

    func requestPasteAutomationAccess() {
        pasteAutomationAccess = pasteAutomation.requestAccess()
        if pasteAutomationAccess == .trusted {
            statusMessage = "One-click paste is enabled."
        } else {
            statusMessage = "Enable Clipboard Router in System Settings > Privacy & Security > Accessibility, then return here."
        }
    }

    func detectedEntities(for clip: PresentedClip) -> [DetectedClipEntity] {
        guard canUseActionableClips(clip) else { return [] }
        let fingerprint = clip.content.deduplicationFingerprint
        if let cached = clipActionDetectionCache[fingerprint] { return cached }
        let detected = clipActionDetector.detect(in: clip.content.text)
        if clipActionDetectionCache.count >= 128,
           let oldestKey = clipActionDetectionCache.keys.first
        {
            clipActionDetectionCache.removeValue(forKey: oldestKey)
        }
        clipActionDetectionCache[fingerprint] = detected
        return detected
    }

    func suggestedActions(for clip: PresentedClip) -> [SuggestedClipAction] {
        var actions: [SuggestedClipAction] = []
        if canUseActionableClips(clip) {
            let entities = detectedEntities(for: clip)
            for entity in entities {
                switch entity.kind {
                case .webURL:
                    actions.append(SuggestedClipAction(kind: .openLink, entity: entity))
                case .emailAddress:
                    actions.append(SuggestedClipAction(kind: .composeEmail, entity: entity))
                    actions.append(SuggestedClipAction(kind: .saveContact, entity: entity))
                case .phoneNumber:
                    actions.append(SuggestedClipAction(kind: .openCallingApp, entity: entity))
                    actions.append(SuggestedClipAction(kind: .saveContact, entity: entity))
                case .date:
                    actions.append(SuggestedClipAction(kind: .createCalendarEvent, entity: entity))
                }
            }
            if let first = entities.first {
                actions.append(SuggestedClipAction(kind: .findRelated, entity: first))
            }
        }
        if canPresentAssistant(for: clip) {
            return Array(actions.prefix(7)) + [SuggestedClipAction(kind: .askAI, entity: nil)]
        }
        return Array(actions.prefix(8))
    }

    func applicableAutomations(for clip: PresentedClip) -> [ClipAutomation] {
        guard canUseActionableClips(clip) else { return [] }
        let entities = detectedEntities(for: clip)
        let folderID: UUID? = if case let .saved(folderID) = clip.origin { folderID } else { nil }
        return clipAutomations
            .filter {
                $0.applies(to: entities, clipText: clip.content.text, folderID: folderID)
                    && automationSupportsContent($0, content: clip.content)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Returns a Calendar draft when the chosen action requires review. Every other action is
    /// completed or queued immediately because the button label describes the exact effect.
    @discardableResult
    func performSuggestedAction(
        _ action: SuggestedClipAction,
        for clip: PresentedClip,
        presentationSurface: RequestPresentationSurface = .library
    ) -> CalendarEventDraftRequest? {
        guard suggestedActions(for: clip).contains(action) else {
            errorMessage = "This action is no longer available for the selected clip."
            return nil
        }

        switch action.kind {
        case .findRelated:
            guard let entity = action.entity else { return nil }
            findRelatedClips(to: entity)
            return nil
        case .askAI:
            presentAssistant(for: clip, presentationSurface: presentationSurface)
            return nil
        case .saveContact:
            guard let entity = action.entity,
                  entity.kind == .phoneNumber || entity.kind == .emailAddress
            else {
                errorMessage = "The detected contact value is no longer available."
                return nil
            }
            let draft = ContactDraft(
                phoneNumbers: entity.kind == .phoneNumber ? [entity.normalizedValue] : [],
                emailAddresses: entity.kind == .emailAddress ? [entity.normalizedValue] : []
            )
            let request = ContactDraftRequest(sourceClip: clip, draft: draft)
            if presentationSurface == .menuBar {
                presentMenuBarContinuation(.contact(request))
            } else {
                contactDraftPresentationSurface = presentationSurface
                pendingContactDraft = request
            }
            return nil
        case .createCalendarEvent:
            guard let startDate = action.entity?.date else {
                errorMessage = "The detected date is no longer available."
                return nil
            }
            let duration = max(action.entity?.duration ?? 3_600, 60)
            let rawTitle = clip.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty ? "Clipboard follow-up" : String(rawTitle.prefix(120))
            return CalendarEventDraftRequest(
                sourceClip: clip,
                draft: CalendarEventDraft(
                    title: title,
                    startDate: startDate,
                    endDate: startDate.addingTimeInterval(duration),
                    notes: "Created from a Clipboard Router clip.\n\n\(String(clip.content.text.prefix(4_000)))"
                )
            )
        case .openLink, .composeEmail, .openCallingApp:
            guard let entity = action.entity else { return nil }
            enqueueClipboardAction {
                guard self.suggestedActions(for: clip).contains(action) else {
                    throw ClipActionExecutionError.unsupportedEntity
                }
                let receipt = try await self.clipActionExecutor.perform(entity)
                self.statusMessage = receipt.userMessage
            }
            return nil
        }
    }

    func createCalendarEvent(
        _ draft: CalendarEventDraft,
        sourceClip: PresentedClip
    ) async -> Bool {
        guard canUseActionableClips(sourceClip) else {
            errorMessage = "The source clip changed or is no longer available. Review it again before adding an event."
            return false
        }
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let receipt = try await calendarEventCreator.create(draft)
            statusMessage = receipt.userMessage
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func contactDuplicates(for draft: ContactDraft) async -> [ContactDuplicate] {
        await contactCreator.possibleDuplicates(for: draft)
    }

    func createContact(
        _ draft: ContactDraft,
        sourceClip: PresentedClip,
        allowingPossibleDuplicate: Bool = false
    ) async -> Bool {
        guard canUseActionableClips(sourceClip), !isBusy else {
            errorMessage = "The source clip changed or is no longer eligible. Review it again before saving a contact."
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let name = try await contactCreator.create(
                draft,
                allowingPossibleDuplicate: allowingPossibleDuplicate
            )
            statusMessage = "Saved \(name) to Contacts."
            pendingContactDraft = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func dismissContactDraft() { pendingContactDraft = nil }
    func dismissAIAssistant() { pendingAIAssistant = nil }
    func dismissApplicationBrowser() { pendingApplicationBrowser = nil }

    func registerMenuBarContinuationPresenter(
        _ presenter: any MenuBarContinuationPresenting
    ) {
        menuBarContinuationPresenter = presenter
    }

    func presentMenuBarContinuation(_ action: MenuBarContinuationRequest.Action) {
        guard let menuBarContinuationPresenter else {
            errorMessage = "This panel could not be opened. Clipboard capture is still available."
            return
        }
        guard menuBarContinuationPresenter.present(action) else {
            statusMessage = "Finish or close the open panel before starting another menu-bar action."
            return
        }
    }

    func dismissMenuBarContinuation() {
        menuBarContinuationPresenter?.dismiss()
    }

    func presentAssistant(
        for clip: PresentedClip,
        presentationSurface: RequestPresentationSurface = .library
    ) {
        guard requireDirectLicense(.ai) else { return }
        guard canPresentAssistant(for: clip) else {
            errorMessage = assistantPresentationUnavailableReason(for: clip)
            return
        }
        let request = AIClipAssistantRequest(sourceClip: clip)
        if presentationSurface == .menuBar {
            presentMenuBarContinuation(.assistant(request))
        } else {
            assistantPresentationSurface = presentationSurface
            pendingAIAssistant = request
        }
    }

    func presentApplicationBrowser(
        for clip: PresentedClip,
        presentationSurface: RequestPresentationSurface = .library
    ) {
        guard canUseActionableClips(clip) else {
            errorMessage = "Only current, ordinary text and link clips can be opened in another app."
            return
        }
        refreshApplicationExclusionOptions()
        applicationBrowserPresentationSurface = presentationSurface
        pendingApplicationBrowser = ApplicationBrowserRequest(sourceClip: clip)
    }

    var onDeviceAIAvailability: OnDeviceAIAvailability { aiProcessor.availability }

    func canPresentAssistant(for clip: PresentedClip) -> Bool {
        canUseLocalAssistant(clip)
    }

    private func assistantPresentationUnavailableReason(for clip: PresentedClip) -> String {
        guard canUseLocalAssistant(clip) else { return assistantUnavailableReason(for: clip) }
        guard aiProcessor.availability != .available,
              !canUseCloudAssistant(for: clip)
        else { return assistantUnavailableReason(for: clip) }
        return "On-device Assistant is unavailable on this Mac. \(cloudAssistantUnavailableReason(for: clip))"
    }

    func canUseCloudAssistant(for clip: PresentedClip) -> Bool {
        guard canUseAssistantTextClip(clip, allowsLocationMetadata: false) else { return false }
        if case let .saved(folderID?) = clip.origin, !canEditSharedFolder(folderID) {
            return false
        }
        return true
    }

    func cloudAssistantUnavailableReason(for clip: PresentedClip) -> String {
        if clip.captureContext?.coarseLocation != nil {
            return "Cloud is blocked because this item includes location metadata."
        }
        if case let .saved(folderID?) = clip.origin, !canEditSharedFolder(folderID) {
            return "Cloud is blocked for view-only shared items."
        }
        return assistantUnavailableReason(for: clip)
    }

    func assistantUnavailableReason(for clip: PresentedClip) -> String {
        if clip.origin == .privateSession {
            return "Assistant is unavailable during a Private Session."
        }
        if clip.sensitivity != nil || secretDetector.scan(clip.content).containsSecret {
            return "Assistant is unavailable for a sensitive item. Move it to Vault or create a reviewed redacted note."
        }
        if !Self.isAssistantTextEligible(clip.content) {
            return "Assistant currently supports plain text, links, and the text from rich clips."
        }
        return "The item changed or is no longer available. Select it again and retry."
    }

    var isHostedAssistantModelValid: Bool {
        Self.isValidHostedAssistantModel(
            hostedAssistantModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func restoreDefaultHostedAssistantModel() {
        hostedAssistantModel = "gpt-5-nano"
    }

    func askOnDeviceAI(_ prompt: String, sourceClip: PresentedClip) async -> String? {
        guard requireDirectLicense(.ai) else { return nil }
        guard canUseLocalAssistant(sourceClip) else {
            errorMessage = assistantUnavailableReason(for: sourceClip)
            return nil
        }
        do {
            return try await aiProcessor.respond(context: sourceClip.content.text, prompt: prompt)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func askAssistant(
        prompt: String,
        messages: [AssistantMessage],
        purpose: AssistantPurpose,
        engine: AssistantEngine,
        sourceClip: PresentedClip
    ) async -> HostedAssistantResponse? {
        guard requireDirectLicense(.ai) else { return nil }
        guard canUseLocalAssistant(sourceClip) else {
            errorMessage = assistantUnavailableReason(for: sourceClip)
            return nil
        }
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else { return nil }
        guard let promptContent = try? ClipContent.detect(
            text: ([normalizedPrompt] + messages.map(\.text)).joined(separator: "\n")
        ), !secretDetector.scan(promptContent).containsSecret else {
            errorMessage = "A secret-like value was detected in this request. It was not sent."
            return nil
        }

        switch engine {
        case .onDevice:
            let transcript = messages.suffix(12).map {
                "\($0.role == .user ? "User" : "Assistant"): \($0.text)"
            }.joined(separator: "\n\n")
            let combined = transcript.isEmpty ? normalizedPrompt : "\(transcript)\n\nUser: \(normalizedPrompt)"
            guard let answer = await askOnDeviceAI(combined, sourceClip: sourceClip) else {
                return nil
            }
            return HostedAssistantResponse(model: "Apple on-device", text: answer)
        case .fastCloud:
            guard canUseCloudAssistant(for: sourceClip) else {
                errorMessage = "\(cloudAssistantUnavailableReason(for: sourceClip)) On this Mac remains available. Nothing was sent."
                return nil
            }
            guard isHostedAssistantConsentGranted else {
                errorMessage = "Review and enable Cloud Assistant in Settings > Assistant before sending clip content."
                return nil
            }
            let normalizedModel = hostedAssistantModel.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard Self.isValidHostedAssistantModel(normalizedModel) else {
                errorMessage = "Choose a valid model in Settings > Assistant before sending. Nothing was sent."
                return nil
            }
            do {
                guard let apiKey = try hostedAssistantCredentialStore.loadAPIKey() else {
                    throw HostedAssistantError.invalidConfiguration
                }
                let request = HostedAssistantRequest(
                    context: sourceClip.content.text,
                    messages: messages,
                    prompt: normalizedPrompt,
                    purpose: purpose,
                    model: normalizedModel,
                    enablesWebSearch: purpose == .research
                )
                return try await hostedAssistant.respond(to: request, apiKey: apiKey)
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
        }
    }

    func canUseCloudAssistant(for request: CombinedClipsReviewRequest) -> Bool {
        do {
            let pack = try currentCombinedClipsPack(matching: request.pack)
            return try pack.items.allSatisfy {
                canUseCloudAssistant(for: try currentCombinedClip(for: $0))
            }
        } catch {
            return false
        }
    }

    func cloudAssistantUnavailableReason(for request: CombinedClipsReviewRequest) -> String {
        do {
            let pack = try currentCombinedClipsPack(matching: request.pack)
            for item in pack.items {
                let clip = try currentCombinedClip(for: item)
                if !canUseCloudAssistant(for: clip) {
                    return cloudAssistantUnavailableReason(for: clip)
                }
            }
            return "Cloud Assistant is not available for this combined collection."
        } catch {
            return AppModelOperationError.combinedClipsChanged.localizedDescription
        }
    }

    func askCombinedClipsAssistant(
        prompt: String,
        messages: [AssistantMessage],
        purpose: AssistantPurpose,
        engine: AssistantEngine,
        request: CombinedClipsReviewRequest
    ) async -> HostedAssistantResponse? {
        guard requireDirectLicense(.ai) else { return nil }
        let validation: (
            pack: ContextPack,
            clips: [PresentedClip],
            expectations: [ContextPackSourceExpectation]
        )
        let rendered: String
        do {
            validation = try await freshCombinedClipsValidation(matching: request.pack)
            guard validation.clips.allSatisfy(canUseLocalAssistant) else {
                throw AppModelOperationError.combinedClipsChanged
            }
            rendered = try validation.pack.renderMarkdown()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else { return nil }
        guard let promptContent = try? ClipContent.detect(
            text: ([normalizedPrompt] + messages.map(\.text)).joined(separator: "\n")
        ), !secretDetector.scan(promptContent).containsSecret else {
            errorMessage = "A secret-like value was detected in this request. It was not sent."
            return nil
        }

        let transcript = messages.suffix(12).map {
            "\($0.role == .user ? "User" : "Assistant"): \($0.text)"
        }.joined(separator: "\n\n")
        let combinedPrompt = transcript.isEmpty
            ? normalizedPrompt
            : "\(transcript)\n\nUser: \(normalizedPrompt)"

        switch engine {
        case .onDevice:
            do {
                let answer = try await aiProcessor.respond(
                    context: rendered,
                    prompt: combinedPrompt
                )
                return HostedAssistantResponse(model: "Apple on-device", text: answer)
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
        case .fastCloud:
            guard validation.clips.allSatisfy(canUseCloudAssistant) else {
                errorMessage = "\(cloudAssistantUnavailableReason(for: request)) Nothing was sent."
                return nil
            }
            guard isHostedAssistantConsentGranted else {
                errorMessage = "Review and enable Cloud Assistant in Settings > Assistant before sending clip content."
                return nil
            }
            let normalizedModel = hostedAssistantModel.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard Self.isValidHostedAssistantModel(normalizedModel) else {
                errorMessage = "Choose a valid model in Settings > Assistant before sending. Nothing was sent."
                return nil
            }
            do {
                guard let apiKey = try hostedAssistantCredentialStore.loadAPIKey() else {
                    throw HostedAssistantError.invalidConfiguration
                }
                let hostedRequest = HostedAssistantRequest(
                    context: rendered,
                    messages: messages,
                    prompt: normalizedPrompt,
                    purpose: purpose,
                    model: normalizedModel,
                    enablesWebSearch: purpose == .research
                )
                return try await hostedAssistant.respond(to: hostedRequest, apiKey: apiKey)
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
        }
    }

    func canUseCloudAssistant(forDebugBundle request: DeveloperDebugBundleReviewRequest) -> Bool {
        do {
            let pack = try debugBundlePack(matching: request.pack, in: snapshot)
            return try pack.items.allSatisfy {
                canUseCloudAssistant(for: try currentCombinedClip(for: $0))
            }
        } catch {
            return false
        }
    }

    func canPresentAssistant(forDebugBundle request: DeveloperDebugBundleReviewRequest) -> Bool {
        do {
            let pack = try debugBundlePack(matching: request.pack, in: snapshot)
            return try pack.items.allSatisfy {
                canPresentAssistant(for: try currentCombinedClip(for: $0))
            }
        } catch {
            return false
        }
    }

    func cloudAssistantUnavailableReason(
        forDebugBundle request: DeveloperDebugBundleReviewRequest
    ) -> String {
        do {
            let pack = try debugBundlePack(matching: request.pack, in: snapshot)
            for item in pack.items {
                let clip = try currentCombinedClip(for: item)
                if !canUseCloudAssistant(for: clip) {
                    return cloudAssistantUnavailableReason(for: clip)
                }
            }
            return "Cloud Assistant is not available for this Debug Bundle."
        } catch {
            return AppModelOperationError.debugBundleChanged.localizedDescription
        }
    }

    func askDebugBundleAssistant(
        prompt: String,
        messages: [AssistantMessage],
        purpose: AssistantPurpose,
        engine: AssistantEngine,
        request: DeveloperDebugBundleReviewRequest,
        projectDisplayName: String,
        problemStatement: String
    ) async -> HostedAssistantResponse? {
        guard requireDirectLicense(.ai) else { return nil }
        let validation: (
            pack: ContextPack,
            clips: [PresentedClip],
            expectations: [ContextPackSourceExpectation]
        )
        let reviewed: DeveloperDebugBundleReview
        do {
            validation = try await freshDebugBundleValidation(matching: request.pack)
            guard validation.clips.allSatisfy(canUseLocalAssistant) else {
                throw AppModelOperationError.debugBundleChanged
            }
            reviewed = try reviewedDebugBundle(
                request: request,
                pack: validation.pack,
                projectDisplayName: projectDisplayName,
                problemStatement: problemStatement
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else { return nil }
        guard let promptContent = try? ClipContent.detect(
            text: ([normalizedPrompt] + messages.map(\.text)).joined(separator: "\n")
        ), !secretDetector.scan(promptContent).containsSecret else {
            errorMessage = "A secret-like value was detected in this request. It was not sent."
            return nil
        }

        let transcript = messages.suffix(12).map {
            "\($0.role == .user ? "User" : "Assistant"): \($0.text)"
        }.joined(separator: "\n\n")
        let combinedPrompt = transcript.isEmpty
            ? normalizedPrompt
            : "\(transcript)\n\nUser: \(normalizedPrompt)"

        switch engine {
        case .onDevice:
            do {
                let answer = try await aiProcessor.respond(
                    context: reviewed.markdown,
                    prompt: combinedPrompt
                )
                return HostedAssistantResponse(model: "Apple on-device", text: answer)
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
        case .fastCloud:
            guard validation.clips.allSatisfy(canUseCloudAssistant) else {
                errorMessage = "\(cloudAssistantUnavailableReason(forDebugBundle: request)) Nothing was sent."
                return nil
            }
            guard isHostedAssistantConsentGranted else {
                errorMessage = "Review and enable Cloud Assistant in Settings > Assistant before sending clip content."
                return nil
            }
            let normalizedModel = hostedAssistantModel.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard Self.isValidHostedAssistantModel(normalizedModel) else {
                errorMessage = "Choose a valid model in Settings > Assistant before sending. Nothing was sent."
                return nil
            }
            do {
                guard let apiKey = try hostedAssistantCredentialStore.loadAPIKey() else {
                    throw HostedAssistantError.invalidConfiguration
                }
                return try await hostedAssistant.respond(
                    to: HostedAssistantRequest(
                        context: reviewed.markdown,
                        messages: messages,
                        prompt: normalizedPrompt,
                        purpose: purpose,
                        model: normalizedModel,
                        enablesWebSearch: purpose == .research
                    ),
                    apiKey: apiKey
                )
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
        }
    }

    func saveHostedAssistantCredential(_ apiKey: String) -> Bool {
        do {
            try hostedAssistantCredentialStore.saveAPIKey(apiKey)
            isHostedAssistantConfigured = true
            statusMessage = "Cloud Assistant credential saved to this Mac's Keychain."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removeHostedAssistantCredential() {
        do {
            try hostedAssistantCredentialStore.deleteAPIKey()
            isHostedAssistantConfigured = false
            isHostedAssistantConsentGranted = false
            statusMessage = "Cloud Assistant was disconnected and its Keychain credential removed."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func testHostedAssistantConnection() async -> String? {
        guard requireDirectLicense(.ai) else { return nil }
        let normalizedModel = hostedAssistantModel.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard isHostedAssistantConfigured,
              Self.isValidHostedAssistantModel(normalizedModel)
        else {
            errorMessage = "Save an API key and choose a valid model before testing the connection."
            return nil
        }
        do {
            guard let apiKey = try hostedAssistantCredentialStore.loadAPIKey() else {
                throw HostedAssistantError.invalidConfiguration
            }
            let response = try await hostedAssistant.respond(
                to: HostedAssistantRequest(
                    context: "Clipboard Router connection test",
                    messages: [],
                    prompt: "Reply with OK.",
                    purpose: .quickAnswer,
                    model: normalizedModel,
                    enablesWebSearch: false
                ),
                apiKey: apiKey
            )
            return "Connected · \(response.model)"
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func copyAndOpen(_ clip: PresentedClip, in application: ApplicationExclusionOption) {
        guard canUseActionableClips(clip) else {
            errorMessage = "The clip changed or is no longer eligible for an external app."
            return
        }
        enqueueClipboardAction {
            guard self.canUseActionableClips(clip) else {
                throw ClipActionExecutionError.unsupportedEntity
            }
            let receipt = try await self.clipActionExecutor.copyAndOpen(
                clipText: clip.content.text,
                applicationURL: application.applicationURL,
                expectedBundleIdentifier: application.bundleIdentifier,
                expectedTeamIdentifier: application.teamIdentifier
            )
            self.pendingApplicationBrowser = nil
            self.statusMessage = receipt.userMessage
        }
    }

    func saveAIDraft(
        _ result: String,
        sourceClip: PresentedClip,
        modelProvenance: String = "Unknown assistant"
    ) async -> Bool {
        guard let library, canUseActionableClips(sourceClip), !result.isEmpty else { return false }
        do {
            let body = try reviewedAIDraftBody(
                result: result,
                modelProvenance: modelProvenance
            )
            let note = try await library.createNote(
                title: "AI draft — \(String(sourceClip.title.prefix(80)))",
                body: body,
                // Never inherit a source folder here: it may be a team-shared workspace.
                // The user can review and move the note explicitly after it is created.
                folderID: nil
            )
            try await refreshSnapshot()
            let organized = try await applyAlwaysRulesAfterLocalSave(note.id) ?? note
            await recordSavedClipForSync(organized)
            scheduleBackgroundSavedLibrarySync()
            statusMessage = "Saved the AI result to My Notes as an unverified draft. The source folder was not inherited."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func saveCombinedClipsAIDraft(
        _ result: String,
        request: CombinedClipsReviewRequest,
        modelProvenance: String = "Unknown assistant"
    ) async -> Bool {
        guard let library, !result.isEmpty, !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let validation = try await freshCombinedClipsValidation(matching: request.pack)
            let body = try reviewedAIDraftBody(
                result: result,
                modelProvenance: modelProvenance
            )
            let note = try await library.createNote(
                title: "AI draft — Combined Clips",
                body: body,
                folderID: nil,
                expectingCombinedClips: validation.expectations
            )
            try await refreshSnapshot()
            let organized = try await applyAlwaysRulesAfterLocalSave(note.id) ?? note
            await recordSavedClipForSync(organized)
            scheduleBackgroundSavedLibrarySync()
            statusMessage = "Saved the AI result to My Notes as an unverified draft."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func saveDebugBundleAIDraft(
        _ result: String,
        request: DeveloperDebugBundleReviewRequest,
        modelProvenance: String = "Unknown assistant"
    ) async -> Bool {
        guard let library, !result.isEmpty, !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let validation = try await freshDebugBundleValidation(matching: request.pack)
            let body = try reviewedAIDraftBody(
                result: result,
                modelProvenance: modelProvenance
            )
            let note = try await library.createNote(
                title: "AI draft — Debug Bundle",
                body: body,
                folderID: nil,
                expectingCombinedClips: validation.expectations
            )
            try await refreshSnapshot()
            let organized = try await applyAlwaysRulesAfterLocalSave(note.id) ?? note
            await recordSavedClipForSync(organized)
            scheduleBackgroundSavedLibrarySync()
            statusMessage = "Saved the AI result to My Notes as an unverified draft."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func runAutomation(_ automation: ClipAutomation, for clip: PresentedClip) {
        guard requireDirectLicense(.automation) else { return }
        guard applicableAutomations(for: clip).contains(automation) else {
            errorMessage = "This automation is disabled or does not match the selected clip."
            return
        }
        let entities = detectedEntities(for: clip)
        enqueueClipboardAction {
            guard self.applicableAutomations(for: clip).contains(automation) else {
                throw ClipActionExecutionError.unsupportedEntity
            }
            let receipt = try await self.clipActionExecutor.run(
                automation,
                clipText: clip.content.text,
                entities: entities
            )
            self.statusMessage = receipt.userMessage
        }
    }

    @discardableResult
    func addWebAutomation(
        name: String,
        filter: ClipAutomationEntityFilter,
        customMatcher: CustomClipTextMatcher? = nil,
        folderID: UUID?,
        template: String
    ) -> Bool {
        guard requireDirectLicense(.automation) else { return false }
        do {
            let automation = try ClipAutomation(
                name: name,
                entityFilter: filter,
                customMatcher: customMatcher,
                requiredFolderID: folderID,
                target: .webURLTemplate(template)
            )
            clipAutomations.append(automation)
            persistClipAutomations()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addApplicationAutomation(
        name: String,
        filter: ClipAutomationEntityFilter,
        customMatcher: CustomClipTextMatcher? = nil,
        folderID: UUID?,
        applicationURL: URL
    ) -> Bool {
        guard requireDirectLicense(.automation) else { return false }
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let metadata = actionMetadataInspector.metadata(forApplicationAt: applicationURL),
              case .valid = metadata.signature
        else {
            errorMessage = ClipActionExecutionError.untrustedApplication.localizedDescription
            return false
        }
        do {
            let bookmark = try actionBookmarks.bookmarkData(forApplicationAt: applicationURL)
            let displayName = metadata.displayName ?? metadata.bundleName
                ?? applicationURL.deletingPathExtension().lastPathComponent
            let automation = try ClipAutomation(
                name: name,
                entityFilter: filter,
                customMatcher: customMatcher,
                requiredFolderID: folderID,
                target: .application(bookmarkData: bookmark, displayName: displayName)
            )
            clipAutomations.append(automation)
            persistClipAutomations()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func updateWebAutomation(
        id: UUID,
        name: String,
        filter: ClipAutomationEntityFilter,
        customMatcher: CustomClipTextMatcher? = nil,
        folderID: UUID?,
        template: String
    ) -> Bool {
        guard let index = clipAutomations.firstIndex(where: { $0.id == id }) else {
            errorMessage = "That one-click destination no longer exists."
            return false
        }
        do {
            let current = clipAutomations[index]
            clipAutomations[index] = try ClipAutomation(
                id: current.id,
                name: name,
                isEnabled: current.isEnabled,
                entityFilter: filter,
                customMatcher: customMatcher,
                requiredFolderID: folderID,
                target: .webURLTemplate(template)
            )
            persistClipAutomations()
            statusMessage = "One-click destination updated."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func updateAutomationMetadata(
        id: UUID,
        name: String,
        filter: ClipAutomationEntityFilter,
        customMatcher: CustomClipTextMatcher? = nil,
        folderID: UUID?
    ) -> Bool {
        guard let index = clipAutomations.firstIndex(where: { $0.id == id }) else {
            errorMessage = "That one-click destination no longer exists."
            return false
        }
        do {
            let current = clipAutomations[index]
            clipAutomations[index] = try ClipAutomation(
                id: current.id,
                name: name,
                isEnabled: current.isEnabled,
                entityFilter: filter,
                customMatcher: customMatcher,
                requiredFolderID: folderID,
                target: current.target
            )
            persistClipAutomations()
            statusMessage = "One-click destination updated."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func makeApplicationFlowStep(id: UUID, applicationURL: URL) -> ClipFlowStep? {
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let metadata = actionMetadataInspector.metadata(forApplicationAt: applicationURL),
              case .valid = metadata.signature
        else {
            errorMessage = ClipActionExecutionError.untrustedApplication.localizedDescription
            return nil
        }
        do {
            let bookmark = try actionBookmarks.bookmarkData(forApplicationAt: applicationURL)
            let displayName = metadata.displayName ?? metadata.bundleName
                ?? applicationURL.deletingPathExtension().lastPathComponent
            return .openApplication(
                id: id,
                bookmarkData: bookmark,
                displayName: displayName
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func setAutomationEnabled(_ id: UUID, enabled: Bool) {
        guard let index = clipAutomations.firstIndex(where: { $0.id == id }) else { return }
        clipAutomations[index].isEnabled = enabled
        persistClipAutomations()
    }

    func deleteAutomation(_ id: UUID) {
        clipAutomations.removeAll { $0.id == id }
        persistClipAutomations()
    }

    private func persistClipAutomations() {
        do {
            defaults.set(try JSONEncoder().encode(clipAutomations), forKey: Self.clipAutomationsKey)
        } catch {
            errorMessage = "Clipboard Router could not save your automations: \(error.localizedDescription)"
        }
    }

    func applicableFlows(for clip: PresentedClip) -> [ClipFlow] {
        guard canUseActionableClips(clip), case let .saved(folderID) = clip.origin else { return [] }
        let entities = detectedEntities(for: clip)
        return clipFlows.filter { flow in
            guard flow.isEnabled,
                  flow.matches(entities: entities, clipText: clip.content.text)
            else { return false }
            if let workspaceID = flow.sharedFolderID {
                guard folderID.flatMap(sharedRootID(containing:)) == workspaceID else { return false }
            }
            if flow.mutatesLibrary, let folderID, !canEditSharedFolder(folderID) { return false }
            if case .manual = flow.trigger { return true }
            return false
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func addFlow(
        name: String,
        trigger: ClipFlowTrigger,
        filter: ClipAutomationEntityFilter,
        customMatcher: CustomClipTextMatcher? = nil,
        steps: [ClipFlowStep]
    ) -> Bool {
        guard requireDirectLicense(.automation) else { return false }
        do {
            let flow = try ClipFlow(
                name: name,
                trigger: trigger,
                entityFilter: filter,
                customMatcher: customMatcher,
                steps: steps
            )
            clipFlows.append(flow)
            persistClipFlows()
            statusMessage = "Custom action created. It now appears in eligible clips."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setFlowEnabled(_ id: UUID, enabled: Bool) {
        guard let index = clipFlows.firstIndex(where: { $0.id == id }) else { return }
        clipFlows[index].isEnabled = enabled
        persistClipFlows()
    }

    func deleteFlow(_ id: UUID) {
        if clipFlows.first(where: { $0.id == id })?.sharedFolderID != nil {
            suppressedTeamFlowIDs.insert(id)
            persistSuppressedTeamFlowIDs()
        }
        clipFlows.removeAll { $0.id == id }
        persistClipFlows()
    }

    @discardableResult
    func updateFlow(
        id: UUID,
        name: String,
        trigger: ClipFlowTrigger,
        filter: ClipAutomationEntityFilter,
        customMatcher: CustomClipTextMatcher? = nil,
        steps: [ClipFlowStep]
    ) -> Bool {
        guard let index = clipFlows.firstIndex(where: { $0.id == id }),
              clipFlows[index].sharedFolderID == nil
        else {
            errorMessage = "Team templates must be unpublished before editing."
            return false
        }
        do {
            let current = clipFlows[index]
            clipFlows[index] = try ClipFlow(
                id: current.id,
                name: name,
                isEnabled: current.isEnabled,
                trigger: trigger,
                entityFilter: filter,
                customMatcher: customMatcher,
                steps: steps
            )
            persistClipFlows()
            statusMessage = "Custom action updated."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func canUnpublishFlow(_ flow: ClipFlow) -> Bool {
        guard let workspaceID = flow.sharedFolderID else { return false }
        return sharedFolderSnapshots[workspaceID]?.currentRole.canManageFolder == true
    }

    func unpublishFlowFromTeam(_ flowID: UUID) {
        guard let flow = clipFlows.first(where: { $0.id == flowID }),
              let workspaceID = flow.sharedFolderID,
              let session = sharedFolderSessions[workspaceID],
              canUnpublishFlow(flow)
        else {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return
        }
        perform {
            let remaining = try self.clipFlows
                .filter { $0.sharedFolderID == workspaceID && $0.id != flowID }
                .map { definition in
                    try ClipFlow(
                        id: definition.id,
                        name: definition.name,
                        isEnabled: false,
                        trigger: definition.trigger,
                        entityFilter: definition.entityFilter,
                        customMatcher: definition.customMatcher,
                        steps: definition.steps,
                        sharedFolderID: workspaceID
                    )
                }
            let refreshed = try await session.synchronizeAutomationDefinitions(remaining)
            guard !refreshed.automationDefinitions.contains(where: { $0.id == flowID }) else {
                throw SharedFolderError.cloudFailure("The team template changed concurrently and was not removed.")
            }
            self.sharedFolderSnapshots[workspaceID] = refreshed
            let localCopy = try ClipFlow(
                id: flow.id,
                name: flow.name,
                isEnabled: flow.isEnabled,
                trigger: flow.trigger,
                entityFilter: flow.entityFilter,
                customMatcher: flow.customMatcher,
                steps: flow.steps
            )
            self.clipFlows.removeAll { $0.id == flowID }
            self.clipFlows.append(localCopy)
            self.suppressedTeamFlowIDs.remove(flowID)
            self.persistSuppressedTeamFlowIDs()
            self.persistClipFlows()
            self.statusMessage = "Unpublished \(flow.name) from the team workspace."
        }
    }

    var teamAutomationDestinations: [FolderDestination] {
        sharedFolderSnapshots.values.compactMap { shared in
            guard shared.currentRole.canManageFolder,
                  let folder = shared.folder
            else { return nil }
            return FolderDestination(
                id: folder.id,
                path: folderPath(for: folder.id),
                depth: 0,
                canAcceptItems: true
            )
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func publishFlowToTeam(_ flowID: UUID, workspaceID: UUID) {
        guard requireDirectLicense(.cloud) else { return }
        guard let session = sharedFolderSessions[workspaceID],
              sharedFolderSnapshots[workspaceID]?.currentRole.canManageFolder == true,
              let index = clipFlows.firstIndex(where: { $0.id == flowID })
        else {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return
        }
        perform {
            let source = self.clipFlows[index]
            let portable = try ClipFlow(
                id: source.id,
                name: source.name,
                isEnabled: false,
                trigger: source.trigger,
                entityFilter: source.entityFilter,
                customMatcher: source.customMatcher,
                steps: source.steps,
                sharedFolderID: workspaceID
            )
            for step in portable.steps {
                if case let .moveToFolder(_, destinationFolderID) = step {
                    guard let destinationFolderID,
                          self.sharedRootID(containing: destinationFolderID) == workspaceID,
                          self.canEditSharedFolder(destinationFolderID)
                    else { throw ClipFlowError.invalidSharedScope }
                }
            }
            var teamDefinitions = try self.clipFlows
                .filter { $0.sharedFolderID == workspaceID }
                .map { definition in
                    try ClipFlow(
                        id: definition.id,
                        name: definition.name,
                        isEnabled: false,
                        trigger: definition.trigger,
                        entityFilter: definition.entityFilter,
                        customMatcher: definition.customMatcher,
                        steps: definition.steps,
                        sharedFolderID: workspaceID
                    )
                }
            teamDefinitions.removeAll { $0.id == portable.id }
            teamDefinitions.append(portable)
            let refreshed = try await session.synchronizeAutomationDefinitions(teamDefinitions)
            guard refreshed.automationDefinitions.contains(portable) else {
                throw SharedFolderError.cloudFailure("The published template did not converge to the reviewed version.")
            }
            self.sharedFolderSnapshots[workspaceID] = refreshed
            self.clipFlows[index] = try ClipFlow(
                id: source.id,
                name: source.name,
                isEnabled: source.isEnabled,
                trigger: source.trigger,
                entityFilter: source.entityFilter,
                customMatcher: source.customMatcher,
                steps: source.steps,
                sharedFolderID: workspaceID
            )
            self.suppressedTeamFlowIDs.remove(source.id)
            self.persistSuppressedTeamFlowIDs()
            self.persistClipFlows()
            self.statusMessage = "Published \(source.name) as a team template. Each teammate must enable it on their own Mac."
        }
    }

    func requestFlowRun(
        _ flow: ClipFlow,
        for clip: PresentedClip,
        triggeredAutomatically: Bool = false,
        presentationSurface: RequestPresentationSurface = .library
    ) {
        do {
            try validateFlow(flow, for: clip, automatically: triggeredAutomatically)
            let request = try ClipFlowRunReviewRequest(
                sourceClip: clip,
                flow: flow,
                triggeredAutomatically: triggeredAutomatically
            )
            Task { @MainActor in
                await registerAutomationRun(
                    request,
                    presentationSurface: presentationSurface,
                    executeWithoutReview: false
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissFlowReview() {
        guard let runID = pendingFlowReview?.id else { return }
        advanceFlowReviewQueue()
        Task { @MainActor in
            try? await automationRunLedger.cancel(runID)
            await publishAutomationRunSnapshot()
        }
    }

    func executeFlow(_ request: ClipFlowRunReviewRequest) async -> Bool {
        guard !isBusy, let library else { return false }
        var activeClaim: AutomationRunClaim?
        do {
            let before = await automationRunLedger.snapshot()
            guard let durableRun = before.runs.first(where: { $0.id == request.id }),
                  durableRun.flowID == request.plan.flowID,
                  durableRun.flowVersionFingerprint == request.plan.flowVersionFingerprint,
                  durableRun.clipID == request.plan.clipID,
                  durableRun.clipFingerprint == request.plan.clipFingerprint
            else { throw ClipFlowError.staleRun }
            if durableRun.status == .needsReview {
                try await automationRunLedger.approve(request.id)
            }

            isBusy = true
            defer { isBusy = false }
            while true {
                let ledgerSnapshot = await automationRunLedger.snapshot()
                guard let run = ledgerSnapshot.runs.first(where: { $0.id == request.id }) else {
                    throw ClipFlowError.staleRun
                }
                if run.status == .succeeded { break }
                guard let currentFlow = clipFlows.first(where: { $0.id == request.flow.id }),
                      currentFlow == request.flow,
                      let current = currentSavedPresentedClip(id: request.sourceClip.id),
                      current.content.deduplicationFingerprint == run.clipFingerprint
                else {
                    try await automationRunLedger.markRunFailed(request.id, code: .staleFlow)
                    throw ClipFlowError.staleRun
                }
                try validateFlow(
                    currentFlow,
                    for: current,
                    automatically: request.triggeredAutomatically
                )
                let currentPlan = try ClipFlowRunPlan(
                    id: run.id,
                    flow: currentFlow,
                    clipID: current.id,
                    clipFingerprint: current.content.deduplicationFingerprint,
                    createdAt: run.createdAt
                )
                guard currentPlan.flowVersionFingerprint == run.flowVersionFingerprint else {
                    try await automationRunLedger.markRunFailed(request.id, code: .staleFlow)
                    throw ClipFlowError.staleRun
                }

                let claim = try await automationRunLedger.claimNextStep(
                    runID: request.id,
                    workerID: automationWorkerID
                )
                activeClaim = claim
                for sourceStepID in claim.receipt.sourceStepIDs {
                    guard currentFlow.steps.contains(where: { $0.id == sourceStepID }),
                          let latest = currentSavedPresentedClip(id: request.sourceClip.id)
                    else { throw ClipFlowError.staleRun }
                    try validateFlow(
                        currentFlow,
                        for: latest,
                        automatically: request.triggeredAutomatically
                    )
                }
                try await executeAutomationUnit(
                    claim.receipt,
                    flow: currentFlow,
                    sourceClipID: request.sourceClip.id,
                    expectedFingerprint: run.clipFingerprint,
                    library: library
                )
                try await automationRunLedger.markStepSucceeded(claim)
                activeClaim = nil
                await publishAutomationRunSnapshot()
            }
            try await refreshSnapshot()
            scheduleBackgroundSavedLibrarySync()
            await publishAutomationRunSnapshot()
            finishFlowReview(request.id)
            statusMessage = "Completed \(request.flow.name). Review any opened app or generated draft before sending."
            return true
        } catch {
            if let activeClaim {
                try? await automationRunLedger.markStepFailed(
                    activeClaim,
                    code: .executionFailed,
                    outcomeIsKnown: activeClaim.receipt.retrySafety == .retrySafe
                )
            } else if (error as? AutomationRunLedgerError) != .paused {
                let snapshot = await automationRunLedger.snapshot()
                if let run = snapshot.runs.first(where: { $0.id == request.id }),
                   [.planned, .running, .needsReview].contains(run.status)
                {
                    try? await automationRunLedger.markRunFailed(request.id, code: .ineligible)
                }
            }
            await publishAutomationRunSnapshot()
            isBusy = false
            finishFlowReview(request.id)
            let recovery = activeClaim?.receipt.retrySafety == .requiresReconciliation
                ? " Its outcome is marked uncertain; reconcile it before continuing."
                : " Retry is available only for the failed retry-safe step."
            errorMessage = "The flow stopped: \(error.localizedDescription) Completed steps were not rolled back.\(recovery)"
            return false
        }
    }

    private func executeAutomationUnit(
        _ receipt: AutomationRunStepReceipt,
        flow: ClipFlow,
        sourceClipID: UUID,
        expectedFingerprint: String,
        library: ClipboardLibrary
    ) async throws {
        guard let current = currentSavedPresentedClip(id: sourceClipID),
              current.content.deduplicationFingerprint == expectedFingerprint
        else { throw ClipFlowError.staleRun }
        let sourceSteps = receipt.sourceStepIDs.compactMap { id in
            flow.steps.first(where: { $0.id == id })
        }
        guard sourceSteps.count == receipt.sourceStepIDs.count else { throw ClipFlowError.staleRun }
        switch receipt.kind {
        case .organizeLibrary:
            let tags = sourceSteps.flatMap { step -> [String] in
                if case let .addTags(_, values) = step { return values }
                return []
            }
            let moves = sourceSteps.compactMap { step -> UUID?? in
                if case let .moveToFolder(_, folderID) = step { return .some(folderID) }
                return nil
            }
            guard moves.count <= 1 else { throw ClipFlowError.invalidSteps }
            let updated = try await library.applyAutomationOrganization(
                to: sourceClipID,
                addingTags: tags,
                movingTo: moves.first ?? nil,
                shouldMove: !moves.isEmpty,
                expectingFingerprint: expectedFingerprint
            )
            await recordSavedClipForSync(updated)
            try await refreshSnapshot()
        case .openWeb, .openApplication, .createTaskDraft, .enrichWithOnDeviceAI:
            guard sourceSteps.count == 1, let step = sourceSteps.first else {
                throw ClipFlowError.invalidSteps
            }
            switch step {
            case let .openWeb(_, template, label):
                _ = try await clipActionExecutor.run(
                    try ClipAutomation(name: label, target: .webURLTemplate(template)),
                    clipText: current.content.text,
                    entities: detectedEntities(for: current)
                )
            case let .openApplication(_, bookmarkData, displayName):
                _ = try await clipActionExecutor.run(
                    try ClipAutomation(
                        name: displayName,
                        target: .application(bookmarkData: bookmarkData, displayName: displayName)
                    ),
                    clipText: current.content.text,
                    entities: detectedEntities(for: current)
                )
            case let .createTaskDraft(_, titleTemplate, dueInDays):
                let due = Calendar.current.date(byAdding: .day, value: dueInDays, to: Date()) ?? Date()
                let renderedTitle = renderFlowText(titleTemplate, clip: current)
                let note = try await library.createNote(
                    title: renderedTitle,
                    // Do not embed the source UUID in user-facing note content. UUID-shaped
                    // strings are intentionally treated as secret-like by the detector; putting
                    // this internal identifier into an ordinary follow-up note would therefore
                    // make the newly-created note render as "Potential secret" and disappear
                    // from normal Notes/Saved surfaces. The durable automation receipt already
                    // retains the exact source clip ID for provenance.
                    body: "Due: \(due.formatted(date: .abbreviated, time: .omitted))\n\nCreated from the reviewed clip.",
                    folderID: current.origin.savedFolderID
                )
                await recordSavedClipForSync(note)
                try await refreshSnapshot()
                _ = try await applyAlwaysRulesAfterLocalSave(note.id)
            case let .enrichWithOnDeviceAI(_, instruction):
                let result = try await aiProcessor.respond(
                    context: current.content.text,
                    prompt: instruction
                )
                let output = try ClipContent.detect(text: result)
                guard !secretDetector.scan(output).containsSecret else {
                    throw AppModelOperationError.generatedSensitiveContent
                }
                let note = try await library.createNote(
                    title: "AI draft — \(String(current.title.prefix(80)))",
                    body: "Unverified on-device AI draft\n\n\(result)",
                    folderID: current.origin.savedFolderID
                )
                await recordSavedClipForSync(note)
                try await refreshSnapshot()
                _ = try await applyAlwaysRulesAfterLocalSave(note.id)
            case .addTags, .moveToFolder:
                throw ClipFlowError.invalidSteps
            }
        }
    }

    private func registerAutomationRun(
        _ request: ClipFlowRunReviewRequest,
        presentationSurface: RequestPresentationSurface,
        executeWithoutReview: Bool
    ) async {
        do {
            let creation = try await automationRunLedger.createRun(
                plan: request.plan,
                triggerKind: request.triggeredAutomatically ? .localFolderEntry : .manual,
                idempotencyKey: request.idempotencyKey,
                requiresReview: !executeWithoutReview
            )
            await publishAutomationRunSnapshot()
            guard creation.wasCreated else {
                statusMessage = "This trigger was already recorded. No automation steps were replayed."
                return
            }
            if executeWithoutReview {
                _ = await executeFlow(request)
            } else {
                enqueueFlowReview(request, presentationSurface: presentationSurface)
            }
        } catch {
            errorMessage = "The automation was not started because its durable run record could not be saved: \(error.localizedDescription)"
        }
    }

    private func restoreAutomationRunState() async {
        do {
            automationRunSnapshot = try await automationRunLedger.restoreForRelaunch(
                currentWorkerID: automationWorkerID
            )
            for run in automationRunSnapshot.runs where run.status == .needsReview {
                guard let request = restoredFlowReview(for: run) else {
                    try? await automationRunLedger.markRunFailed(run.id, code: .staleFlow)
                    continue
                }
                enqueueFlowReview(request)
            }
            await publishAutomationRunSnapshot()
        } catch {
            automationRunSnapshot = .empty
            errorMessage = "Automation recovery is unavailable: \(error.localizedDescription) No pending automation was executed."
        }
    }

    private func restoredFlowReview(for run: AutomationRunRecord) -> ClipFlowRunReviewRequest? {
        guard let flow = clipFlows.first(where: { $0.id == run.flowID }),
              let clip = currentSavedPresentedClip(id: run.clipID),
              clip.content.deduplicationFingerprint == run.clipFingerprint,
              let plan = try? ClipFlowRunPlan(
                  id: run.id,
                  flow: flow,
                  clipID: clip.id,
                  clipFingerprint: clip.content.deduplicationFingerprint,
                  createdAt: run.createdAt
              ),
              plan.flowVersionFingerprint == run.flowVersionFingerprint
        else { return nil }
        return try? ClipFlowRunReviewRequest(
            id: run.id,
            sourceClip: clip,
            flow: flow,
            triggeredAutomatically: run.triggerKind == .localFolderEntry,
            idempotencyKey: "restored:\(run.id.uuidString.lowercased())",
            createdAt: run.createdAt
        )
    }

    private func publishAutomationRunSnapshot() async {
        automationRunSnapshot = await automationRunLedger.snapshot()
    }

    func setAllAutomationRunsPaused(_ paused: Bool) {
        Task { @MainActor in
            do {
                try await automationRunLedger.setPaused(paused)
                await publishAutomationRunSnapshot()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func setFlowExecutionPaused(_ flowID: UUID, paused: Bool) {
        Task { @MainActor in
            do {
                try await automationRunLedger.setFlowPaused(flowID, paused: paused)
                await publishAutomationRunSnapshot()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func reviewAutomationRun(_ runID: UUID) {
        guard let run = automationRunSnapshot.runs.first(where: { $0.id == runID }),
              let request = restoredFlowReview(for: run)
        else {
            errorMessage = "The clip or automation changed. This run cannot continue."
            return
        }
        enqueueFlowReview(request)
    }

    func reconcileAutomationRun(_ runID: UUID, markSucceeded: Bool) {
        Task { @MainActor in
            do {
                try await automationRunLedger.reconcile(
                    runID: runID,
                    decision: markSucceeded ? .markSucceeded : .cancelRemaining
                )
                await publishAutomationRunSnapshot()
                if markSucceeded,
                   let run = automationRunSnapshot.runs.first(where: { $0.id == runID }),
                   run.status == .needsReview
                {
                    reviewAutomationRun(runID)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func cancelAutomationRun(_ runID: UUID) {
        Task { @MainActor in
            do {
                try await automationRunLedger.cancel(runID)
                await publishAutomationRunSnapshot()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func validateFlow(_ flow: ClipFlow, for clip: PresentedClip, automatically: Bool) throws {
        guard directLicenseAccessPolicy.allows(.automation) else {
            throw DirectLicenseError.premiumLicenseRequired
        }
        guard flow.isEnabled, canUseActionableClips(clip), case let .saved(sourceFolderID) = clip.origin,
              flow.matches(
                  entities: detectedEntities(for: clip),
                  clipText: clip.content.text
              )
        else { throw ClipFlowError.ineligibleClip }
        let sourceSharedRoot = sourceFolderID.flatMap(sharedRootID(containing:))
        if let workspaceID = flow.sharedFolderID {
            guard sourceSharedRoot == workspaceID else { throw ClipFlowError.invalidSharedScope }
        }
        if flow.mutatesLibrary, let sourceFolderID, !canEditSharedFolder(sourceFolderID) {
            throw SharedFolderError.permissionDenied
        }
        if automatically {
            guard flow.trigger.isAutomatic else { throw ClipFlowError.ineligibleClip }
        } else if case .folderEntry = flow.trigger {
            throw ClipFlowError.ineligibleClip
        }
        let folderIDs = Set(snapshot.folders.map(\.id))
        for step in flow.steps {
            if case let .moveToFolder(_, destinationFolderID) = step {
                if let destinationFolderID {
                    guard folderIDs.contains(destinationFolderID) else {
                        throw ClipboardLibraryError.folderNotFound(destinationFolderID)
                    }
                    guard canEditSharedFolder(destinationFolderID) else {
                        throw SharedFolderError.permissionDenied
                    }
                }
                let destinationSharedRoot = destinationFolderID.flatMap(sharedRootID(containing:))
                guard sourceSharedRoot == destinationSharedRoot else {
                    throw ClipFlowError.invalidSharedScope
                }
                if let workspaceID = flow.sharedFolderID,
                   destinationSharedRoot != workspaceID
                {
                    throw ClipFlowError.invalidSharedScope
                }
            }
        }
    }

    private func enqueueFlowReview(
        _ request: ClipFlowRunReviewRequest,
        presentationSurface: RequestPresentationSurface = .library
    ) {
        flowReviewPresentationSurfaces[request.id] = presentationSurface
        if pendingFlowReview == nil {
            pendingFlowReview = request
            flowReviewPresentationSurface = presentationSurface
        } else if pendingFlowReview?.id != request.id,
                  !queuedFlowReviews.contains(where: { $0.id == request.id })
        {
            queuedFlowReviews.append(request)
        }
    }

    private func advanceFlowReviewQueue() {
        if let currentID = pendingFlowReview?.id {
            flowReviewPresentationSurfaces.removeValue(forKey: currentID)
        }
        guard !queuedFlowReviews.isEmpty else {
            pendingFlowReview = nil
            return
        }
        let next = queuedFlowReviews.removeFirst()
        pendingFlowReview = next
        flowReviewPresentationSurface = flowReviewPresentationSurfaces[next.id] ?? .library
    }

    private func finishFlowReview(_ requestID: UUID) {
        if pendingFlowReview?.id == requestID {
            advanceFlowReviewQueue()
        } else {
            queuedFlowReviews.removeAll { $0.id == requestID }
            flowReviewPresentationSurfaces.removeValue(forKey: requestID)
        }
    }

    private func currentSavedPresentedClip(id: UUID) -> PresentedClip? {
        guard let item = snapshot.savedClips.first(where: { $0.id == id }) else { return nil }
        return PresentedClip(
            id: item.id,
            title: item.name,
            content: item.content,
            date: item.modifiedAt,
            sourceBundleIdentifier: item.sourceApplicationBundleIdentifier,
            origin: .saved(folderID: item.folderID),
            savedItemKind: item.kind,
            captureContext: item.captureContext,
            sensitivity: item.sensitivity,
            isPinned: item.pinnedAt != nil,
            tags: item.tags ?? [],
            pasteboardTypeIdentifiers: item.pasteboardTypeIdentifiers ?? []
        )
    }

    private func currentCombinedClip(for item: ContextPackItem) throws -> PresentedClip {
        try combinedClip(for: item, in: snapshot)
    }

    private func combinedClip(
        for item: ContextPackItem,
        in sourceSnapshot: ClipboardLibrarySnapshot
    ) throws -> PresentedClip {
        let current: PresentedClip
        if let saved = sourceSnapshot.savedClips.first(where: { $0.id == item.id }) {
            current = PresentedClip(
                id: saved.id,
                title: saved.name,
                content: saved.content,
                date: saved.modifiedAt,
                sourceBundleIdentifier: saved.sourceApplicationBundleIdentifier,
                origin: .saved(folderID: saved.folderID),
                savedItemKind: saved.kind,
                captureContext: saved.captureContext,
                sensitivity: saved.sensitivity,
                isPinned: saved.pinnedAt != nil,
                tags: saved.tags ?? [],
                pasteboardTypeIdentifiers: saved.pasteboardTypeIdentifiers ?? []
            )
        } else if let history = sourceSnapshot.history.first(where: { $0.id == item.id }) {
            current = PresentedClip(
                id: history.id,
                title: Self.previewTitle(for: history.content),
                content: history.content,
                date: history.lastCapturedAt,
                sourceBundleIdentifier: history.sourceApplicationBundleIdentifier,
                origin: .history,
                captureContext: history.captureContext,
                sensitivity: history.sensitivity,
                pasteboardTypeIdentifiers: history.pasteboardTypeIdentifiers ?? [],
                captureCount: history.captureCount,
                pasteCount: history.pasteCount,
                lastPastedAt: history.lastPastedAt
            )
        } else {
            throw AppModelOperationError.combinedClipsChanged
        }

        guard current.sensitivity == nil,
              !secretDetector.scan(current.content).containsSecret
        else {
            throw AppModelOperationError.combinedClipsChanged
        }
        return current
    }

    private func currentCombinedClipsPack(matching pack: ContextPack) throws -> ContextPack {
        try combinedClipsPack(matching: pack, in: snapshot)
    }

    private func combinedClipsPack(
        matching pack: ContextPack,
        in sourceSnapshot: ClipboardLibrarySnapshot
    ) throws -> ContextPack {
        guard let active = combinedClips,
              active.id == pack.id,
              active.items == pack.items
        else {
            throw AppModelOperationError.combinedClipsChanged
        }

        var currentItems: [ContextPackItem] = []
        currentItems.reserveCapacity(pack.items.count)
        for item in pack.items {
            let current = try combinedClip(for: item, in: sourceSnapshot)
            let refreshed = try ContextPackItem(
                id: current.id,
                title: current.title,
                textRepresentation: current.content.searchableText,
                capturedAt: current.date,
                sourceApplication: current.captureContext?.sourceApplicationName
                    ?? current.sourceBundleIdentifier,
                sourceURL: current.captureContext?.sourceURL.flatMap(URL.init(string:)),
                metadata: [
                    "Content type": current.content.type.rawValue,
                    "Approximate size": "\(current.content.estimatedStorageByteCount) bytes",
                ]
            )
            guard refreshed == item else {
                throw AppModelOperationError.combinedClipsChanged
            }
            currentItems.append(refreshed)
        }

        let validated = try ContextPack(
            id: pack.id,
            name: pack.name,
            items: currentItems,
            limits: pack.limits
        )
        let rendered = try validated.renderMarkdown()
        guard !secretDetector.scan(text: rendered).containsSecret else {
            throw AppModelOperationError.combinedClipsChanged
        }
        return validated
    }

    private func freshCombinedClipsValidation(
        matching pack: ContextPack
    ) async throws -> (
        pack: ContextPack,
        clips: [PresentedClip],
        expectations: [ContextPackSourceExpectation]
    ) {
        guard let library else { throw AppModelOperationError.libraryUnavailable }
        let sourceSnapshot = await library.snapshot()
        let validated = try combinedClipsPack(matching: pack, in: sourceSnapshot)
        let clips = try validated.items.map { try combinedClip(for: $0, in: sourceSnapshot) }
        let expectations = try validated.items.map { item in
            if let saved = sourceSnapshot.savedClips.first(where: { $0.id == item.id }) {
                return ContextPackSourceExpectation(
                    item: item,
                    source: .saved(folderID: saved.folderID, kind: saved.kind)
                )
            }
            guard sourceSnapshot.history.contains(where: { $0.id == item.id }) else {
                throw AppModelOperationError.combinedClipsChanged
            }
            return ContextPackSourceExpectation(item: item, source: .history)
        }
        return (validated, clips, expectations)
    }

    private func debugBundlePack(
        matching pack: ContextPack,
        in sourceSnapshot: ClipboardLibrarySnapshot
    ) throws -> ContextPack {
        guard let active = debugBundlePack,
              active.id == pack.id,
              active.items == pack.items
        else {
            throw AppModelOperationError.debugBundleChanged
        }

        do {
            var currentItems: [ContextPackItem] = []
            currentItems.reserveCapacity(pack.items.count)
            for item in pack.items {
                let current = try combinedClip(for: item, in: sourceSnapshot)
                let refreshed = try ContextPackItem(
                    id: current.id,
                    title: current.title,
                    textRepresentation: current.content.searchableText,
                    capturedAt: current.date,
                    sourceApplication: current.captureContext?.sourceApplicationName
                        ?? current.sourceBundleIdentifier,
                    sourceURL: current.captureContext?.sourceURL.flatMap(URL.init(string:)),
                    metadata: [
                        "Content type": current.content.type.rawValue,
                        "Approximate size": "\(current.content.estimatedStorageByteCount) bytes",
                    ]
                )
                guard refreshed == item else {
                    throw AppModelOperationError.debugBundleChanged
                }
                currentItems.append(refreshed)
            }
            return try ContextPack(
                id: pack.id,
                name: pack.name,
                items: currentItems,
                limits: pack.limits
            )
        } catch {
            throw AppModelOperationError.debugBundleChanged
        }
    }

    private func freshDebugBundleValidation(
        matching pack: ContextPack
    ) async throws -> (
        pack: ContextPack,
        clips: [PresentedClip],
        expectations: [ContextPackSourceExpectation]
    ) {
        guard let library else { throw AppModelOperationError.libraryUnavailable }
        let sourceSnapshot = await library.snapshot()
        let validated = try debugBundlePack(matching: pack, in: sourceSnapshot)
        let clips = try validated.items.map { try combinedClip(for: $0, in: sourceSnapshot) }
        let expectations = try validated.items.map { item in
            if let saved = sourceSnapshot.savedClips.first(where: { $0.id == item.id }) {
                return ContextPackSourceExpectation(
                    item: item,
                    source: .saved(folderID: saved.folderID, kind: saved.kind)
                )
            }
            guard sourceSnapshot.history.contains(where: { $0.id == item.id }) else {
                throw AppModelOperationError.debugBundleChanged
            }
            return ContextPackSourceExpectation(item: item, source: .history)
        }
        return (validated, clips, expectations)
    }

    private func reviewedAIDraftBody(
        result: String,
        modelProvenance: String
    ) throws -> String {
        let safeProvenance = modelProvenance
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let provenance = String(
            (safeProvenance.isEmpty ? "Unknown assistant" : safeProvenance).prefix(80)
        )
        let body = "Unverified AI draft · \(provenance)\n\n\(result)"
        let output = try ClipContent.detect(text: body)
        guard !secretDetector.scan(output).containsSecret else {
            throw AppModelOperationError.generatedSensitiveContent
        }
        return body
    }

    private func reviewedDebugBundle(
        request: DeveloperDebugBundleReviewRequest,
        pack: ContextPack,
        projectDisplayName: String,
        problemStatement: String
    ) throws -> DeveloperDebugBundleReview {
        let validatedRequest = DeveloperDebugBundleReviewRequest(
            id: request.id,
            pack: pack,
            generatedAt: request.generatedAt
        )
        let review = try DeveloperFeatureModel.review(
            request: validatedRequest,
            projectDisplayName: projectDisplayName,
            problemStatement: problemStatement
        )
        guard !secretDetector.scan(text: review.markdown).containsSecret else {
            throw AppModelOperationError.debugBundleChanged
        }
        return review
    }

    private func renderFlowText(_ template: String, clip: PresentedClip) -> String {
        template
            .replacingOccurrences(of: "{clip}", with: String(clip.content.text.prefix(300)))
            .replacingOccurrences(of: "{title}", with: clip.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persistClipFlows() {
        do {
            defaults.set(try JSONEncoder().encode(clipFlows), forKey: Self.clipFlowsKey)
            // Acceptance and crash-recovery relaunches can terminate the process
            // immediately after a reviewed flow edit. Force the UserDefaults
            // domain to commit before the caller reports the mutation complete.
            _ = defaults.synchronize()
        } catch {
            errorMessage = "Clipboard Router could not save your custom actions: \(error.localizedDescription)"
        }
    }

    private func persistSuppressedTeamFlowIDs() {
        do {
            let ordered = suppressedTeamFlowIDs.sorted { $0.uuidString < $1.uuidString }
            defaults.set(try JSONEncoder().encode(ordered), forKey: Self.suppressedTeamFlowIDsKey)
        } catch {
            errorMessage = "Clipboard Router could not remember a removed team action: \(error.localizedDescription)"
        }
    }

    private func handleLocalFolderEntry(_ item: SavedClip, from sourceFolderID: UUID?) {
        guard let destinationFolderID = item.folderID,
              sourceFolderID != destinationFolderID,
              item.sensitivity == nil,
              !secretDetector.scan(item.content).containsSecret
        else { return }
        let presented = PresentedClip(
            id: item.id,
            title: item.name,
            content: item.content,
            date: item.modifiedAt,
            sourceBundleIdentifier: item.sourceApplicationBundleIdentifier,
            origin: .saved(folderID: item.folderID),
            savedItemKind: item.kind,
            captureContext: item.captureContext,
            isPinned: item.pinnedAt != nil,
            tags: item.tags ?? [],
            pasteboardTypeIdentifiers: item.pasteboardTypeIdentifiers ?? []
        )
        let matching = clipFlows.filter { flow in
            guard flow.isEnabled,
                  flow.matches(
                      entities: detectedEntities(for: presented),
                      clipText: presented.content.text
                  ),
                  case let .folderEntry(folderID, includeDescendants) = flow.trigger
            else { return false }
            return folderID == destinationFolderID
                || (includeDescendants && isFolder(destinationFolderID, inside: folderID))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let requests = matching.compactMap { flow -> ClipFlowRunReviewRequest? in
            try? ClipFlowRunReviewRequest(
                sourceClip: presented,
                flow: flow,
                triggeredAutomatically: true,
                idempotencyKey: [
                    "folder-entry",
                    flow.id.uuidString.lowercased(),
                    item.id.uuidString.lowercased(),
                    item.content.deduplicationFingerprint,
                    sourceFolderID?.uuidString.lowercased() ?? "saved",
                    destinationFolderID.uuidString.lowercased(),
                    String(item.modifiedAt.timeIntervalSince1970.bitPattern),
                ].joined(separator: ":")
            )
        }
        guard !requests.isEmpty else { return }
        if !requests.filter({ $0.flow.requiresReviewWhenTriggered }).isEmpty {
            statusMessage = "Custom actions are ready for review because this clip entered \(folderPath(for: destinationFolderID))."
        }
        Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            for request in requests {
                await self.registerAutomationRun(
                    request,
                    presentationSurface: .library,
                    executeWithoutReview: !request.flow.requiresReviewWhenTriggered
                )
            }
        }
    }

    private func isFolder(_ folderID: UUID, inside ancestorID: UUID) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
        var cursor: UUID? = folderID
        var seen: Set<UUID> = []
        while let current = cursor, seen.insert(current).inserted {
            if current == ancestorID { return true }
            cursor = byID[current]?.parentFolderID
        }
        return false
    }

    private func canUseActionableClips(_ clip: PresentedClip) -> Bool {
        canUseCurrentOrdinaryTextClip(clip, allowsLocationMetadata: false)
    }

    private func canUseLocalAssistant(_ clip: PresentedClip) -> Bool {
        canUseAssistantTextClip(clip, allowsLocationMetadata: true)
    }

    private static func isAssistantTextEligible(_ content: ClipContent) -> Bool {
        switch content.type {
        case .plainText, .url, .richText:
            !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image, .fileURLs:
            false
        }
    }

    private func canUseAssistantTextClip(
        _ clip: PresentedClip,
        allowsLocationMetadata: Bool
    ) -> Bool {
        guard clip.origin != .privateSession,
              clipContextMenuPolicy(for: clip).canUseWorkflows,
              Self.isAssistantTextEligible(clip.content),
              allowsLocationMetadata || clip.captureContext?.coarseLocation == nil,
              clip.sensitivity == nil,
              !secretDetector.scan(clip.content).containsSecret
        else { return false }
        switch clip.origin {
        case .history:
            guard let item = snapshot.history.first(where: { $0.id == clip.id }) else {
                return false
            }
            return item.sensitivity == nil
                && item.content.deduplicationFingerprint == clip.content.deduplicationFingerprint
        case .saved:
            guard let item = snapshot.savedClips.first(where: { $0.id == clip.id }) else {
                return false
            }
            return item.sensitivity == nil
                && item.content.deduplicationFingerprint == clip.content.deduplicationFingerprint
                && clip.origin == .saved(folderID: item.folderID)
        case .privateSession:
            return false
        }
    }

    private func canUseCurrentOrdinaryTextClip(
        _ clip: PresentedClip,
        allowsLocationMetadata: Bool
    ) -> Bool {
        guard clip.origin != .privateSession,
              clipContextMenuPolicy(for: clip).canUseWorkflows,
              clip.content.isSafelyConvertibleToNote,
              allowsLocationMetadata || clip.captureContext?.coarseLocation == nil,
              clip.sensitivity == nil,
              !secretDetector.scan(clip.content).containsSecret
        else { return false }
        switch clip.origin {
        case .history:
            guard let item = snapshot.history.first(where: { $0.id == clip.id }) else {
                return false
            }
            return item.sensitivity == nil
                && item.content.deduplicationFingerprint == clip.content.deduplicationFingerprint
        case .saved:
            guard let item = snapshot.savedClips.first(where: { $0.id == clip.id }) else {
                return false
            }
            return item.sensitivity == nil
                && item.content.deduplicationFingerprint == clip.content.deduplicationFingerprint
                && clip.origin == .saved(folderID: item.folderID)
        case .privateSession:
            return false
        }
    }

    private func automationSupportsContent(
        _ automation: ClipAutomation,
        content: ClipContent
    ) -> Bool {
        switch automation.target {
        case .webURLTemplate:
            return true
        case .application:
            return content.type == .plainText || content.type == .url
        }
    }

    private func findRelatedClips(to entity: DetectedClipEntity) {
        let query: String
        switch entity.kind {
        case .webURL:
            query = URL(string: entity.normalizedValue)?.host().map { "domain:\($0)" }
                ?? entity.normalizedValue
        case .emailAddress, .phoneNumber:
            query = entity.normalizedValue
        case .date:
            query = entity.date.map { "date:\(Self.searchDateToken($0))" }
                ?? entity.displayValue
        }
        searchText = query
        selectedSection = .searchResults
        updateSearch()
        focusLibrarySearch()
    }

    func route(_ clip: PresentedClip, to destination: ExternalDestination) {
        if clip.origin == .privateSession {
            errorMessage = "Private Session clips cannot be opened in external AI apps. Copy explicitly if you intend to move this content outside the session."
            return
        }
        guard canUseActionableClips(clip) else {
            errorMessage = "Private, sensitive, secret, location-bearing, file, and rich-media clips cannot be routed to an external AI app. Create and review a redacted text copy first."
            return
        }
        enqueueClipboardAction {
            guard self.canUseActionableClips(clip) else {
                throw ClipActionExecutionError.unsupportedEntity
            }
            let receipt = try await self.router.route(clip.content, to: destination)
            self.statusMessage = receipt.userMessage
        }
    }

    func routeSelectedToPreferredDestination() {
        guard let selectedClip else { return }
        route(selectedClip, to: DestinationRegistry.destination(id: preferredDestinationID))
    }

    func installedApplicationURLs(for destination: ExternalDestination) -> [URL] {
        destinationApplicationOptions.compactMap { option in
            Self.matches(option, destination: destination) ? option.applicationURL : nil
        }
    }

    func selectedApplicationURL(for destination: ExternalDestination) -> URL? {
        destinationCatalog.selectedApplicationURL(for: destination)
    }

    func selectApplicationURL(_ url: URL?, for destination: ExternalDestination) {
        guard destinationCatalog.setSelectedApplicationURL(url, for: destination) else {
            errorMessage = "Clipboard Router could not verify or remember that application. Choose it again or select another signed copy."
            objectWillChange.send()
            return
        }
        objectWillChange.send()
    }

    func chooseApplication(for destination: ExternalDestination) {
        let panel = NSOpenPanel()
        panel.title = "Choose \(destination.displayName)"
        panel.prompt = "Choose Application"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let application = try destinationCatalog.chooseApplication(at: url, for: destination)
            statusMessage = "Using \(application.displayName) for \(destination.displayName)."
            objectWillChange.send()
            refreshApplicationExclusionOptions(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateMenuSearch(_ query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        menuSearchTask?.cancel()
        menuSearchQuery = normalized
        guard !normalized.isEmpty, let library else {
            menuSearchResults = []
            return
        }
        menuSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            guard !Task.isCancelled else { return }
            let resultCandidateLimit = max(self.menuBarClipLimit * 3, 50)
            let results = await library.search(query: normalized, limit: resultCandidateLimit)
            guard !Task.isCancelled, self.menuSearchQuery == normalized else { return }
            self.menuSearchResults = Array(results
                .map(self.presentedClip(for:))
                .filter { !self.isSensitiveForPresentation($0) }
                .prefix(self.menuBarClipLimit))
        }
    }

    func setMenuBarClipLimit(_ limit: Int) {
        let normalized = min(max(limit, Self.menuBarClipLimitRange.lowerBound), Self.menuBarClipLimitRange.upperBound)
        menuBarClipLimit = normalized
        defaults.set(normalized, forKey: Self.menuBarClipLimitKey)
        menuSearchResults = Array(menuSearchResults.prefix(normalized))
        if !menuSearchQuery.isEmpty {
            updateMenuSearch(menuSearchQuery)
        }
    }

    func insertAliasResults(matching rawQuery: String) -> [InsertAliasResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAlias = InsertAlias.normalize(query)
        let savedByID = Dictionary(uniqueKeysWithValues: snapshot.savedClips.map { ($0.id, $0) })

        var results: [InsertAliasResult] = insertAliases.compactMap { alias in
            guard let saved = savedByID[alias.savedClipID]
            else { return nil }
            let presented = presentedSavedClip(saved)
            guard canUseActionableClips(presented),
                  query.isEmpty
                    || alias.abbreviation.localizedCaseInsensitiveContains(normalizedAlias)
                    || alias.name.localizedCaseInsensitiveContains(query)
                    || saved.name.localizedCaseInsensitiveContains(query)
            else { return nil }
            return InsertAliasResult(alias: alias, clip: presented)
        }.sorted { lhs, rhs in
            (lhs.trigger ?? "").localizedStandardCompare(rhs.trigger ?? "") == .orderedAscending
        }

        let aliasedIDs = Set(results.map(\.clip.id))
        let matchingSaved = snapshot.savedClips.filter { saved in
            let presented = presentedSavedClip(saved)
            return !aliasedIDs.contains(saved.id)
                && canUseActionableClips(presented)
                && (query.isEmpty
                    || saved.name.localizedCaseInsensitiveContains(query)
                    || saved.content.text.localizedCaseInsensitiveContains(query))
        }.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.modifiedAt > rhs.modifiedAt
        }
        results.append(contentsOf: matchingSaved.prefix(max(0, 30 - results.count)).map {
            InsertAliasResult(alias: nil, clip: presentedSavedClip($0))
        })
        return Array(results.prefix(30))
    }

    @discardableResult
    func saveInsertAlias(
        for clip: PresentedClip,
        abbreviation: String,
        delivery: InsertAliasDelivery
    ) -> Bool {
        guard let current = currentOrdinaryPresentedClip(matching: clip),
              case .saved = current.origin,
              canUseActionableClips(current)
        else {
            errorMessage = "This saved item changed while the shortcut editor was open. Reopen it and try again."
            return false
        }
        do {
            let candidate = try InsertAlias(
                name: current.title,
                abbreviation: abbreviation,
                savedClipID: current.id,
                delivery: delivery
            )
            guard !insertAliases.contains(where: {
                $0.id != candidate.id
                    && $0.abbreviation == candidate.abbreviation
                    && $0.savedClipID != candidate.savedClipID
            }) else {
                errorMessage = "That abbreviation is already assigned to another saved item."
                return false
            }
            insertAliases.removeAll {
                $0.savedClipID == clip.id || $0.savedClipID == current.id
            }
            insertAliases.append(candidate)
            try persistInsertAliases()
            statusMessage = "Saved \(candidate.trigger). Use Quick Paste to copy or paste it."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removeInsertAlias(_ alias: InsertAlias) {
        insertAliases.removeAll { $0.id == alias.id }
        do {
            try persistInsertAliases()
            statusMessage = "Removed \(alias.trigger)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setTextExpansionEnabled(_ enabled: Bool) {
        isTextExpansionEnabled = enabled
        defaults.set(enabled, forKey: Self.textExpansionEnabledKey)
        refreshTextExpansionState(promptIfNeeded: enabled)
    }

    func saveCRMConnection(_ definition: CRMConnectionDefinition) {
        let clientID = definition.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = definition.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let redirectScheme = definition.redirectURI.scheme?.lowercased()
        guard !clientID.isEmpty, !name.isEmpty,
              redirectScheme == "clipboardrouter"
                || redirectScheme == "https"
                || definition.redirectURI.host?.lowercased() == "localhost"
        else {
            errorMessage = "Enter a connection name, OAuth client ID, and an approved HTTPS, localhost, or Clipboard Router callback URL."
            return
        }
        var normalized = definition
        normalized.displayName = name
        normalized.clientID = clientID
        if let index = crmConnectionDefinitions.firstIndex(where: { $0.id == definition.id }) {
            crmConnectionDefinitions[index] = normalized
        } else {
            crmConnectionDefinitions.append(normalized)
        }
        persistCRMConnectionDefinitions()
        refreshCRMConnectionStates()
        statusMessage = normalized.externalSetupBlocker == nil
            ? "Saved \(normalized.displayName). Connect when the provider app is configured."
            : "Saved \(normalized.displayName). Complete the required external token-broker setup before connecting."
    }

    func removeCRMConnectionDefinition(_ id: UUID) {
        guard let definition = crmConnectionDefinitions.first(where: { $0.id == id }) else {
            return
        }
        do {
            try crmCredentialStore.delete(connectionID: id)
            crmConnectionDefinitions.removeAll { $0.id == id }
            crmConnectionStates[id] = nil
            persistCRMConnectionDefinitions()
            if pendingCRMOAuthRequest?.connectionID == id { pendingCRMOAuthRequest = nil }
            statusMessage = "Removed \(definition.displayName) and its local OAuth credentials."
        } catch {
            errorMessage = "The connection definition was kept because its credentials could not be removed: \(error.localizedDescription)"
        }
    }

    func refreshCRMConnectionStates() {
        crmConnectionStates = Dictionary(uniqueKeysWithValues: crmConnectionDefinitions.map { definition in
            let state: CRMConnectionState
            if let blocker = definition.externalSetupBlocker {
                state = .setupRequired(blocker)
            } else if let tokens = try? crmCredentialStore.load(connectionID: definition.id) {
                state = .connected(accountID: tokens.accountID, scopes: tokens.scopes)
            } else {
                state = .disconnected
            }
            return (definition.id, state)
        })
    }

    func beginCRMConnection(_ id: UUID) {
        guard let definition = crmConnectionDefinitions.first(where: { $0.id == id }) else {
            errorMessage = "Save the CRM connection before connecting."
            return
        }
        guard definition.externalSetupBlocker == nil else {
            errorMessage = definition.externalSetupBlocker
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let request = try await self.crmOAuthCoordinator.begin(definition)
                self.pendingCRMOAuthRequest = request
                guard NSWorkspace.shared.open(request.authorizationURL) else {
                    self.pendingCRMOAuthRequest = nil
                    self.errorMessage = "The provider authorization page could not be opened."
                    return
                }
                self.statusMessage = "Finish authorization in your browser. Clipboard Router will accept only the matching callback and state."
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func handleCRMOAuthCallback(_ url: URL) {
        guard let request = pendingCRMOAuthRequest else {
            errorMessage = "No matching CRM connection attempt is active. Start again from Settings > CRM."
            return
        }
        let definition = request.definition
        guard crmConnectionDefinitions.first(where: { $0.id == request.connectionID }) == definition else {
            pendingCRMOAuthRequest = nil
            errorMessage = "The CRM connection changed during authorization. Start again from Settings > CRM."
            return
        }
        pendingCRMOAuthRequest = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let tokens = try await self.crmOAuthCoordinator.complete(
                    callbackURL: url,
                    request: request,
                    definition: definition
                )
                self.crmConnectionStates[definition.id] = .connected(
                    accountID: tokens.accountID,
                    scopes: tokens.scopes
                )
                self.statusMessage = "Connected \(definition.displayName)."
                if let clipID = self.pendingCRMSetupClipID,
                   let clip = self.currentOrdinaryPresentedClip(id: clipID)
                {
                    self.pendingCRMSetupClipID = nil
                    self.presentCRMReview(for: clip)
                }
            } catch {
                self.refreshCRMConnectionStates()
                self.errorMessage = "CRM authorization was not completed: \(error.localizedDescription)"
            }
        }
    }

    func disconnectCRMConnection(_ id: UUID) {
        guard let definition = crmConnectionDefinitions.first(where: { $0.id == id }) else {
            return
        }
        do {
            try crmCredentialStore.delete(connectionID: id)
            crmConnectionStates[id] = definition.externalSetupBlocker.map(CRMConnectionState.setupRequired)
                ?? .disconnected
            if pendingCRMOAuthRequest?.connectionID == id { pendingCRMOAuthRequest = nil }
            statusMessage = "Disconnected \(definition.displayName). Its reusable definition was kept."
        } catch {
            errorMessage = "The OAuth credentials could not be removed: \(error.localizedDescription)"
        }
    }

    func canSendToCRM(_ clip: PresentedClip) -> Bool {
        guard [.plainText, .url].contains(clip.content.type) else { return false }
        return canUseActionableClips(clip)
    }

    func presentCRMReview(for clip: PresentedClip) {
        guard canSendToCRM(clip),
              let current = currentOrdinaryPresentedClip(matching: clip)
        else {
            errorMessage = "CRM writes block Vault, sensitive, secret, location-bearing, file, image, rich-text, and Private Session items."
            return
        }
        refreshCRMConnectionStates()
        guard let definition = crmConnectionDefinitions.first(where: {
            if case .connected = crmConnectionStates[$0.id] { return true }
            return false
        }) else {
            pendingCRMSetupClipID = current.id
            UserDefaults.standard.set(SettingsTab.crm.rawValue, forKey: "settings.selectedTab")
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            statusMessage = "Connect Salesforce or HubSpot. This clip will reopen for review after authorization."
            return
        }
        pendingCRMSetupClipID = nil
        let object = defaultCRMObject(for: current)
        pendingCRMReview = CRMReviewDraft(
            id: UUID(),
            sourceClipID: current.id,
            sourceFingerprint: current.content.deduplicationFingerprint,
            connectionID: definition.id,
            provider: definition.provider,
            object: object,
            mode: .create,
            existingProviderID: "",
            fields: defaultCRMFields(for: object, clipID: current.id)
        )
        crmWriteOutcome = nil
    }

    func dismissCRMReview() {
        guard !isCRMWriteInFlight else { return }
        pendingCRMReview = nil
        crmWriteOutcome = nil
    }

    func defaultCRMFields(for object: CRMObjectType, clipID: UUID) -> [String: String] {
        guard let clip = currentOrdinaryPresentedClip(id: clipID), canSendToCRM(clip) else {
            return [:]
        }
        let text = clip.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let entities = detectedEntities(for: clip)
        switch object {
        case .contact:
            var result: [String: String] = [:]
            if let email = entities.first(where: { $0.kind == .emailAddress })?.normalizedValue {
                result["email"] = email
            }
            if let phone = entities.first(where: { $0.kind == .phoneNumber })?.normalizedValue {
                result["phone"] = phone
            }
            return result
        case .company:
            guard let link = entities.first(where: { $0.kind == .webURL }),
                  let host = URL(string: link.normalizedValue)?.host()
            else { return [:] }
            return ["domain": host]
        case .task:
            return [
                "subject": String(clip.title.prefix(255)),
                "body": String(text.prefix(16_384)),
            ]
        }
    }

    func confirmCRMWrite(_ draft: CRMReviewDraft) {
        guard !isCRMWriteInFlight,
              pendingCRMReview?.id == draft.id,
              let definition = crmConnectionDefinitions.first(where: { $0.id == draft.connectionID }),
              definition.provider == draft.provider,
              let source = currentOrdinaryPresentedClip(id: draft.sourceClipID),
              source.content.deduplicationFingerprint == draft.sourceFingerprint,
              canSendToCRM(source)
        else {
            errorMessage = "The source clip or CRM connection changed. Reopen the review before writing."
            return
        }
        let review: CRMWriteReview
        do { review = try draft.makeReview() }
        catch {
            errorMessage = error.localizedDescription
            return
        }
        isCRMWriteInFlight = true
        crmWriteOutcome = nil
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.crmWriteExecutor.execute(review, definition: definition)
            self.isCRMWriteInFlight = false
            self.crmWriteOutcome = outcome
            self.refreshCRMConnectionStates()
        }
    }

    func reconcileCRMWrite(_ draft: CRMReviewDraft) {
        guard !isCRMWriteInFlight,
              pendingCRMReview?.id == draft.id,
              let definition = crmConnectionDefinitions.first(where: { $0.id == draft.connectionID }),
              definition.provider == draft.provider,
              let source = currentOrdinaryPresentedClip(id: draft.sourceClipID),
              source.content.deduplicationFingerprint == draft.sourceFingerprint,
              canSendToCRM(source),
              let review = try? draft.makeReview()
        else {
            errorMessage = "The source clip or CRM connection changed. Reopen the review before reconciling."
            return
        }
        isCRMWriteInFlight = true
        Task { [weak self] in
            guard let self else { return }
            self.crmWriteOutcome = await self.crmWriteExecutor.reconcile(review, definition: definition)
            self.isCRMWriteInFlight = false
        }
    }

    private func persistCRMConnectionDefinitions() {
        do {
            defaults.set(try JSONEncoder().encode(crmConnectionDefinitions), forKey: Self.crmConnectionDefinitionsKey)
        } catch {
            errorMessage = "CRM definitions could not be saved. OAuth credentials were not changed."
        }
    }

    private func defaultCRMObject(for clip: PresentedClip) -> CRMObjectType {
        let entities = detectedEntities(for: clip)
        if entities.contains(where: { $0.kind == .emailAddress || $0.kind == .phoneNumber }) {
            return .contact
        }
        if entities.contains(where: { $0.kind == .webURL }) { return .company }
        return .task
    }

    private func currentOrdinaryPresentedClip(id: UUID) -> PresentedClip? {
        if let saved = currentSavedPresentedClip(id: id) { return saved }
        guard let history = snapshot.history.first(where: { $0.id == id }) else { return nil }
        return PresentedClip(
            id: history.id,
            title: Self.previewTitle(for: history.content),
            content: history.content,
            date: history.lastCapturedAt,
            sourceBundleIdentifier: history.sourceApplicationBundleIdentifier,
            origin: .history,
            captureContext: history.captureContext,
            sensitivity: history.sensitivity,
            pasteboardTypeIdentifiers: history.pasteboardTypeIdentifiers ?? [],
            captureCount: history.captureCount,
            pasteCount: history.pasteCount,
            lastPastedAt: history.lastPastedAt
        )
    }

    func refreshTextExpansionState(promptIfNeeded: Bool = false) {
        guard isTextExpansionEnabled else {
            textExpansionController.stop()
            textExpansionStatus = .off
            return
        }
        guard !isPrivateSessionActive else {
            textExpansionController.stop(status: .blocked("Unavailable during Private Session."))
            textExpansionStatus = textExpansionController.status
            return
        }
        textExpansionController.start(promptIfNeeded: promptIfNeeded)
        textExpansionStatus = textExpansionController.status
    }

    private var eligibleTextExpansionDefinitions: [TextExpansionDefinition] {
        let savedByID = Dictionary(uniqueKeysWithValues: snapshot.savedClips.map { ($0.id, $0) })
        return insertAliases.compactMap { alias in
            guard let saved = savedByID[alias.savedClipID],
                  saved.content.isSafelyConvertibleToNote,
                  saved.content.type == .plainText || saved.content.type == .url,
                  saved.sensitivity == nil,
                  saved.captureContext?.coarseLocation == nil,
                  !secretDetector.scan(saved.content).containsSecret
            else { return nil }
            return TextExpansionDefinition(
                aliasID: alias.id,
                trigger: alias.trigger,
                replacement: saved.content.text
            )
        }.sorted {
            if $0.trigger.count != $1.trigger.count { return $0.trigger.count > $1.trigger.count }
            return $0.aliasID.uuidString < $1.aliasID.uuidString
        }
    }

    private func isTextExpansionAllowed(in focus: TextExpansionFocus) -> Bool {
        guard isTextExpansionEnabled, !isPrivateSessionActive else { return false }
        let bundle = focus.bundleIdentifier.lowercased()
        return bundle != Bundle.main.bundleIdentifier?.lowercased()
            && !snapshot.settings.capturePolicy.excludedApplicationBundleIdentifiers.contains(bundle)
    }

    func performInsert(
        _ result: InsertAliasResult,
        delivery override: InsertAliasDelivery? = nil,
        pasteTargetToken: UUID? = nil
    ) {
        guard case .saved = result.clip.origin,
              canUseActionableClips(result.clip),
              snapshot.savedClips.contains(where: {
                  $0.id == result.clip.id
                    && $0.content.deduplicationFingerprint
                        == result.clip.content.deduplicationFingerprint
              })
        else {
            errorMessage = "This saved item changed or is no longer eligible. Review it again."
            return
        }
        let delivery = override ?? result.alias?.delivery ?? .copy
        switch delivery {
        case .copy:
            copy(result.clip)
        case .pasteIntoFrontmostApplication:
            guard let pasteTargetToken else {
                errorMessage = "No fresh previous-app target is available. Open Quick Paste from the app you want to paste into."
                return
            }
            pasteIntoRememberedApplication(result.clip, token: pasteTargetToken)
        }
    }

    func canPasteFromInsertPalette(token: UUID?) -> Bool {
        token != nil
            && token == insertPalettePasteTargetToken
            && pasteTargetProcessIdentifier != nil
            && pasteTargetBundleIdentifier != nil
            && pasteTargetLaunchDate != nil
    }

    private func persistInsertAliases() throws {
        defaults.set(try JSONEncoder().encode(insertAliases), forKey: Self.insertAliasesKey)
    }

    var menuBarPinnedClips: [PresentedClip] {
        Array(snapshot.savedClips
            .filter {
                $0.isPinned
                    && self.presentationSensitivityCategory(
                        content: $0.content,
                        stored: $0.sensitivity
                    ) == nil
            }
            .sorted { ($0.pinnedAt ?? $0.modifiedAt) > ($1.pinnedAt ?? $1.modifiedAt) }
            .prefix(menuBarClipLimit)
            .map {
                let history = $0.sourceHistoryItemID.flatMap { historyID in
                    snapshot.history.first(where: { $0.id == historyID })
                }
                return PresentedClip(
                    id: $0.id,
                    title: $0.name,
                    content: $0.content,
                    date: $0.modifiedAt,
                    sourceBundleIdentifier: $0.sourceApplicationBundleIdentifier,
                    origin: .saved(folderID: $0.folderID),
                    savedItemKind: $0.kind,
                    captureContext: $0.captureContext,
                    sensitivity: $0.sensitivity,
                    isPinned: true,
                    tags: $0.tags ?? [],
                    pasteboardTypeIdentifiers: $0.pasteboardTypeIdentifiers ?? [],
                    captureCount: history?.captureCount,
                    pasteCount: history?.pasteCount,
                    lastPastedAt: history?.lastPastedAt
                )
            })
    }

    var menuBarRecentClips: [PresentedClip] {
        let remainingSlots = max(0, menuBarClipLimit - menuBarPinnedClips.count)
        return Array(snapshot.history.lazy.filter {
            self.presentationSensitivityCategory(content: $0.content, stored: $0.sensitivity) == nil
        }.prefix(remainingSlots).map {
            PresentedClip(
                id: $0.id,
                title: Self.previewTitle(for: $0.content),
                content: $0.content,
                date: $0.lastCapturedAt,
                sourceBundleIdentifier: $0.sourceApplicationBundleIdentifier,
                origin: .history,
                captureContext: $0.captureContext,
                sensitivity: $0.sensitivity,
                pasteboardTypeIdentifiers: $0.pasteboardTypeIdentifiers ?? [],
                captureCount: $0.captureCount,
                pasteCount: $0.pasteCount,
                lastPastedAt: $0.lastPastedAt
            )
        })
    }

    func clipContextMenuPolicy(for clip: PresentedClip) -> ClipContextMenuPolicy {
        let isOrdinary = !isSensitiveForPresentation(clip)
        switch clip.origin {
        case .history:
            return ClipContextMenuPolicy(
                organization: .saveToFolder,
                canShareClip: isOrdinary,
                canExportClip: true,
                canUseWorkflows: isOrdinary,
                canRouteToAI: isOrdinary,
                showsSavedClipControls: false,
                canMutateSavedClip: false,
                folderID: nil,
                canManageFolderSharing: false,
                showsDelete: true,
                canDelete: true
            )
        case let .saved(folderID):
            let canEdit = folderID.map(canEditSharedFolder) ?? true
            return ClipContextMenuPolicy(
                organization: .moveToFolder,
                canShareClip: isOrdinary,
                canExportClip: true,
                canUseWorkflows: isOrdinary,
                canRouteToAI: isOrdinary,
                showsSavedClipControls: true,
                canMutateSavedClip: canEdit,
                folderID: folderID,
                canManageFolderSharing: folderID.map(canManageFolderSharing) ?? false,
                showsDelete: true,
                canDelete: canEdit
            )
        case .privateSession:
            return ClipContextMenuPolicy(
                organization: .none,
                canShareClip: false,
                canExportClip: false,
                canUseWorkflows: false,
                canRouteToAI: false,
                showsSavedClipControls: false,
                canMutateSavedClip: false,
                folderID: nil,
                canManageFolderSharing: false,
                showsDelete: false,
                canDelete: false
            )
        }
    }

    func isSensitiveForPresentation(_ clip: PresentedClip) -> Bool {
        sensitivityCategoryForPresentation(clip) != nil
    }

    func sensitivityCategoryForPresentation(_ clip: PresentedClip) -> String? {
        presentationSensitivityCategory(content: clip.content, stored: clip.sensitivity)
    }

    private func presentationSensitivityCategory(
        content: ClipContent,
        stored: ClipSensitivityMetadata?
    ) -> String? {
        stored?.category ?? secretDetector.scan(content).detections.first?.category.rawValue
    }

    func canMoveSavedClipToVault(_ clip: PresentedClip) -> Bool {
        guard case .saved = clip.origin else { return false }
        return canMoveClipToVault(clip)
    }

    /// Origin-aware Vault eligibility used by both the History and Saved context menus. Private
    /// Session never crosses into persistent storage. Typed payloads must satisfy Vault's bounded
    /// manifest policy, and a linked collaborative copy blocks the whole move.
    func canMoveClipToVault(_ clip: PresentedClip) -> Bool {
        guard vaultLibrary != nil, VaultItem.supports(clip.content) else { return false }
        let linked: [SavedClip]
        switch clip.origin {
        case .privateSession:
            return false
        case .history:
            guard snapshot.history.contains(where: { $0.id == clip.id }) else { return false }
            linked = snapshot.savedClips.filter { $0.sourceHistoryItemID == clip.id }
        case .saved:
            guard let selected = snapshot.savedClips.first(where: { $0.id == clip.id }) else {
                return false
            }
            if let historyID = selected.sourceHistoryItemID {
                linked = snapshot.savedClips.filter { $0.sourceHistoryItemID == historyID }
            } else {
                linked = [selected]
            }
        }
        return !linked.contains { saved in
            saved.folderID.map(isKnownSharedFolder) == true
        }
    }

    func vaultMoveUnavailableReason(for clip: PresentedClip) -> String? {
        if canMoveClipToVault(clip) { return nil }
        if case .privateSession = clip.origin {
            return "Private Session items are memory-only and cannot enter Vault."
        }
        if vaultLibrary == nil {
            return vaultAvailabilityMessage ?? "Vault is unavailable in this build."
        }
        if !VaultItem.supports(clip.content) {
            return "This item's typed payload is malformed or exceeds Vault's encrypted asset limits."
        }
        let linked: [SavedClip]
        switch clip.origin {
        case .history:
            linked = snapshot.savedClips.filter { $0.sourceHistoryItemID == clip.id }
        case .saved:
            let sourceID = snapshot.savedClips.first(where: { $0.id == clip.id })?.sourceHistoryItemID
            linked = snapshot.savedClips.filter {
                $0.id == clip.id || (sourceID != nil && $0.sourceHistoryItemID == sourceID)
            }
        case .privateSession:
            linked = []
        }
        if linked.contains(where: { $0.folderID.map(isKnownSharedFolder) == true }) {
            return AppModelOperationError.collaborativeVaultMoveUnsupported.localizedDescription
        }
        return "This item is no longer available in the ordinary library."
    }

    func vaultMoveSummary(for clip: PresentedClip) -> VaultMoveSummary? {
        guard canMoveClipToVault(clip) else { return nil }
        switch clip.origin {
        case .privateSession:
            return nil
        case .history:
            guard let history = snapshot.history.first(where: { $0.id == clip.id }) else {
                return nil
            }
            return VaultMoveSummary(
                historyItem: history,
                savedClips: snapshot.savedClips.filter {
                    $0.sourceHistoryItemID == clip.id
                },
                linkedHistoryItemID: history.id
            )
        case .saved:
            guard let saved = snapshot.savedClips.first(where: { $0.id == clip.id }) else {
                return nil
            }
            let linked = saved.sourceHistoryItemID.map { historyID in
                snapshot.savedClips.filter { $0.sourceHistoryItemID == historyID }
            } ?? [saved]
            let history = saved.sourceHistoryItemID.flatMap { historyID in
                snapshot.history.first(where: { $0.id == historyID })
            }
            return VaultMoveSummary(
                historyItem: history,
                savedClips: linked,
                linkedHistoryItemID: saved.sourceHistoryItemID
            )
        }
    }

    /// Pin means "keep this in Saved for quick access." For a History row, Core creates the
    /// pinned SavedClip with full provenance in one commit; Saved rows retain their toggle.
    func togglePinOrSave(_ clip: PresentedClip) {
        switch clip.origin {
        case .privateSession:
            errorMessage = AppModelOperationError.ordinaryClipRequired.localizedDescription
        case .saved:
            setPinned(clip, pinned: !clip.isPinned)
        case .history:
            guard let library else { return }
            let reusableClips = snapshot.savedClips.filter { saved in
                guard saved.sourceHistoryItemID == clip.id else { return false }
                return saved.folderID.map(canEditSharedFolder) != false
            }
            let readOnlyFolderIDs = Set(snapshot.folders.compactMap { folder -> UUID? in
                isKnownSharedFolder(folder.id) && !canEditSharedFolder(folder.id)
                    ? folder.id : nil
            })
            perform {
                let saved = try await library.pinHistoryItem(
                    id: clip.id,
                    reusableSavedClips: reusableClips,
                    forbiddenFolderIDs: readOnlyFolderIDs
                )
                try await self.refreshSnapshot()
                let organized = try await self.applyAlwaysRulesAfterLocalSave(saved.id) ?? saved
                await self.recordSavedClipForSync(organized)
                self.scheduleBackgroundSavedLibrarySync()
                self.statusMessage = "Clip saved and pinned for quick access."
            }
        }
    }

    func setPinned(_ clip: PresentedClip, pinned: Bool) {
        guard case .saved = clip.origin, let library else { return }
        if case let .saved(folderID?) = clip.origin,
           !canEditSharedFolder(folderID)
        {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return
        }
        perform {
            try await library.setSavedClipPinned(id: clip.id, pinned: pinned)
            if let updated = await library.snapshot().savedClips.first(where: { $0.id == clip.id }) {
                await self.recordSavedClipForSync(updated)
            }
            try await self.refreshSnapshot()
            self.scheduleBackgroundSavedLibrarySync()
            self.statusMessage = pinned ? "Clip pinned for quick access." : "Clip unpinned."
        }
    }

    func saveHistoryClip(_ clip: PresentedClip, folderID: UUID?) {
        guard requireDirectLicense(.premiumCreation) else { return }
        guard case .history = clip.origin, let library else { return }
        if let folderID, !canEditSharedFolder(folderID) {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return
        }
        perform {
            let saved = try await library.saveHistoryItem(id: clip.id, folderID: folderID)
            try await self.refreshSnapshot()
            let organized = try await self.applyAlwaysRulesAfterLocalSave(saved.id) ?? saved
            await self.recordSavedClipForSync(organized)
            self.scheduleBackgroundSavedLibrarySync()
            self.statusMessage = "Saved to your clip library."
            if folderID != nil { self.handleLocalFolderEntry(saved, from: nil) }
        }
    }

    /// Used by the Save Clip picker to keep folder creation and the pending save in one operation.
    func saveHistoryClipInNewFolder(_ clip: PresentedClip, named folderName: String) async throws {
        guard directLicenseAccessPolicy.allows(.premiumCreation) else {
            throw DirectLicenseError.premiumLicenseRequired
        }
        guard case .history = clip.origin else {
            throw AppModelOperationError.historyClipRequired
        }
        guard let library else {
            throw AppModelOperationError.libraryUnavailable
        }
        guard !isBusy else {
            throw AppModelOperationError.operationInProgress
        }

        isBusy = true
        defer { isBusy = false }

        let result = try await library.saveHistoryItemInNewFolder(id: clip.id, folderName: folderName)
        // The Core transaction journals both mutations, so one drain publishes them together.
        await recordFolderForSync(result.folder)
        try await refreshSnapshot()
        let organized = try await applyAlwaysRulesAfterLocalSave(result.savedClip.id)
            ?? result.savedClip
        await recordSavedClipForSync(organized)
        scheduleBackgroundSavedLibrarySync()
        selectedSection = .folder(result.folder.id)
        selectedClipID = result.savedClip.id
        statusMessage = "Created \(result.folder.name) and saved this clip."
    }

    func createFolder(named name: String) {
        createFolder(named: name, parentFolderID: nil)
    }

    func createFolder(named name: String, parentFolderID: UUID?) {
        guard requireDirectLicense(.premiumCreation) else { return }
        guard let library else { return }
        if let parentFolderID, !canManageSharedFolder(parentFolderID) {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return
        }
        perform {
            let folder = try await library.createFolder(
                name: name,
                parentFolderID: parentFolderID
            )
            await self.recordFolderForSync(folder)
            try await self.refreshSnapshot()
            self.scheduleBackgroundSavedLibrarySync()
            self.selectedSection = .folder(folder.id)
            self.statusMessage = "Folder created."
        }
    }

    func createSalesWorkspace(named name: String, parentFolderID: UUID? = nil) {
        guard requireDirectLicense(.premiumCreation) else { return }
        guard let library else { return }
        if let parentFolderID, !canManageSharedFolder(parentFolderID) {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return
        }
        perform {
            let created = try await library.createFolderRecipe(
                .salesWorkspace(named: name),
                parentFolderID: parentFolderID
            )
            for folder in [created.root] + created.children {
                await self.recordFolderForSync(folder)
            }
            try await self.refreshSnapshot()
            self.scheduleBackgroundSavedLibrarySync()
            self.selectedSection = .folder(created.root.id)
            await self.recordMetric(ProductMetricEvent(
                anonymousInstallationID: self.metricsInstallationID,
                name: .salesWorkspaceCreated
            ))
            self.statusMessage = "Sales workspace created with Accounts, Messaging, Competitors, and Unsorted."
        }
    }

    var folderDestinations: [FolderDestination] {
        snapshot.folders.map { folder in
            FolderDestination(
                id: folder.id,
                path: folderPath(for: folder.id),
                depth: folderDepth(for: folder.id),
                canAcceptItems: canEditSharedFolder(folder.id)
            )
        }
        .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    func folderPath(for id: UUID) -> String {
        let byID = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
        var names: [String] = []
        var cursor: UUID? = id
        var visited: Set<UUID> = []
        while let currentID = cursor,
              let folder = byID[currentID],
              visited.insert(currentID).inserted
        {
            names.append(folder.name)
            cursor = folder.parentFolderID
        }
        return names.reversed().joined(separator: " / ")
    }

    func folderDepth(for id: UUID) -> Int {
        max(0, folderPath(for: id).components(separatedBy: " / ").count - 1)
    }

    func canMoveFolder(id: UUID, to parentFolderID: UUID?) -> Bool {
        guard id != parentFolderID, canManageSharedFolder(id) else { return false }
        if let parentFolderID, !canManageSharedFolder(parentFolderID) { return false }
        let sourceSharedRoot = sharedRootID(containing: id)
        let destinationSharedRoot = parentFolderID.flatMap(sharedRootID(containing:))
        guard sourceSharedRoot == destinationSharedRoot else { return false }
        let byID = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
        var cursor = parentFolderID
        var visited: Set<UUID> = []
        while let current = cursor, visited.insert(current).inserted {
            if current == id { return false }
            cursor = byID[current]?.parentFolderID
        }
        return true
    }

    func moveFolder(id: UUID, to parentFolderID: UUID?) {
        guard let library, canMoveFolder(id: id, to: parentFolderID) else {
            let sourceRoot = sharedRootID(containing: id)
            let destinationRoot = parentFolderID.flatMap(sharedRootID(containing:))
            errorMessage = sourceRoot != destinationRoot
                ? "Shared and private folders use separate sync spaces. Move their contents explicitly instead of moving a folder across that boundary."
                : "That folder cannot be moved there. Check sharing permissions and folder nesting."
            return
        }
        perform {
            try await library.moveFolder(id: id, to: parentFolderID)
            if let folder = await library.snapshot().folders.first(where: { $0.id == id }) {
                await self.recordFolderForSync(folder)
            }
            try await self.refreshSnapshot()
            self.scheduleBackgroundSavedLibrarySync()
            self.statusMessage = parentFolderID == nil
                ? "Folder moved to the top level."
                : "Folder moved."
        }
    }

    func renameFolder(id: UUID, name: String) {
        guard let library else { return }
        guard canManageSharedFolder(id) else {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return
        }
        perform {
            try await library.renameFolder(id: id, to: name)
            if let folder = await library.snapshot().folders.first(where: { $0.id == id }) {
                await self.recordFolderForSync(folder)
            }
            try await self.refreshSnapshot()
            self.scheduleBackgroundSavedLibrarySync()
        }
    }

    func reorderFolders(idsInOrder: [UUID]) {
        guard let library else { return }
        perform {
            let existingIDs = Set((await library.snapshot()).folders.map(\.id))
            guard idsInOrder.count == existingIDs.count,
                  Set(idsInOrder) == existingIDs
            else { return }

            // Core normalizes sortOrder after each move and journals every affected folder.
            // Replaying the desired order makes multi-row drag operations deterministic.
            for (index, id) in idsInOrder.enumerated() {
                try await library.reorderFolder(id: id, to: index)
            }
            await self.drainSharedFolderMutations()
            await self.drainPendingSavedLibraryMutations()
            try await self.refreshSnapshot()
            self.scheduleBackgroundSavedLibrarySync()
            self.statusMessage = "Folders reordered."
        }
    }

    func deleteFolder(id: UUID) {
        guard let library else { return }
        guard canManageSharedFolder(id) else {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return
        }
        perform {
            let before = await library.snapshot()
            let affectedClipIDs = before.savedClips
                .filter { $0.folderID == id }
                .map(\.id)
            try await library.deleteFolder(id: id)
            await self.recordDeletionForSync(id: id, kind: .folder)
            let after = await library.snapshot()
            for clip in after.savedClips where affectedClipIDs.contains(clip.id) {
                await self.recordSavedClipForSync(clip)
            }
            try await self.refreshSnapshot()
            self.scheduleBackgroundSavedLibrarySync()
            if self.selectedSection == .folder(id) {
                self.selectedSection = .allSaved
            }
            self.statusMessage = "Folder deleted. Its clips are still in Saved."
        }
    }

    func renameSavedClip(id: UUID, name: String) {
        guard let library else { return }
        if let folderID = snapshot.savedClips.first(where: { $0.id == id })?.folderID,
           !canEditSharedFolder(folderID)
        {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return
        }
        perform {
            try await library.renameSavedClip(id: id, to: name)
            if let clip = await library.snapshot().savedClips.first(where: { $0.id == id }) {
                await self.recordSavedClipForSync(clip)
            }
            try await self.refreshSnapshot()
            self.scheduleBackgroundSavedLibrarySync()
            self.statusMessage = "Clip renamed."
        }
    }

    func moveSavedClip(id: UUID, to folderID: UUID?) {
        guard let library else { return }
        let sourceFolderID = snapshot.savedClips.first(where: { $0.id == id })?.folderID
        if let sourceFolderID, !canEditSharedFolder(sourceFolderID) {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return
        }
        if let folderID, !canEditSharedFolder(folderID) {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return
        }
        let sourceSharedRoot = sourceFolderID.flatMap(sharedRootID(containing:))
        let destinationSharedRoot = folderID.flatMap(sharedRootID(containing:))
        guard sourceSharedRoot == destinationSharedRoot else {
            errorMessage = "Shared and private items use separate sync spaces. Copy the item explicitly if you want it in both places."
            return
        }
        perform {
            try await library.moveSavedClip(id: id, to: folderID)
            let movedClip = await library.snapshot().savedClips.first(where: { $0.id == id })
            if let movedClip { await self.recordSavedClipForSync(movedClip) }
            try await self.refreshSnapshot()
            self.scheduleBackgroundSavedLibrarySync()
            if let movedClip, folderID != nil, folderID != sourceFolderID {
                self.handleLocalFolderEntry(movedClip, from: sourceFolderID)
            }
            if case let .folder(selectedFolderID) = self.selectedSection,
               selectedFolderID != folderID
            {
                self.selectedClipID = nil
            }
            self.statusMessage = folderID == nil ? "Moved to Saved." : "Clip moved."
        }
    }

    func updateTagsFromEditor(_ clip: PresentedClip, tags: [String]) async -> Bool {
        guard case let .saved(folderID) = clip.origin, let library else {
            errorMessage = "Save this item before adding tags."
            return false
        }
        if let folderID, !canEditSharedFolder(folderID) {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return false
        }
        guard !isBusy else {
            errorMessage = AppModelOperationError.operationInProgress.localizedDescription
            return false
        }
        guard let saved = snapshot.savedClips.first(where: { $0.id == clip.id }) else {
            errorMessage = ClipboardLibraryError.savedClipNotFound(clip.id).localizedDescription
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let expectation = SavedClipEditExpectation(
                name: saved.name,
                modifiedAt: saved.modifiedAt,
                folderID: saved.folderID,
                contentFingerprint: saved.content.deduplicationFingerprint
            )
            let updated = try await library.replaceTags(
                for: saved.id,
                with: tags,
                expecting: expectation
            )
            await recordSavedClipForSync(updated)
            try await refreshSnapshot()
            scheduleBackgroundSavedLibrarySync()
            statusMessage = updated.tags?.isEmpty == false ? "Tags updated." : "Tags removed."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func performBulkLibraryMutation(_ operation: BulkLibraryOperation) {
        guard let library else { return }
        let selected = selectedClipsForBulkAction
        guard !selected.isEmpty else {
            errorMessage = BulkLibraryMutationError.emptySelection.localizedDescription
            return
        }
        if case .saveHistory = operation,
           !directLicenseAccessPolicy.allows(.premiumCreation)
        {
            errorMessage = DirectLicenseError.premiumLicenseRequired.localizedDescription
            return
        }

        let destinationFolderID: UUID? = if case let .moveSaved(folderID) = operation {
            folderID
        } else if case let .saveHistory(folderID) = operation {
            folderID
        } else {
            nil
        }
        if let destinationFolderID, !canEditSharedFolder(destinationFolderID) {
            pendingBulkLibraryResult = BulkLibraryActionResult(
                action: bulkActionTitle(operation),
                successCount: 0,
                failures: selected.map {
                    .init(id: $0.id, title: bulkResultTitle($0), reason: "You have view-only access to the destination folder.")
                }
            )
            return
        }

        let selections = selected.map { clip in
            BulkLibrarySelection(id: clip.id, origin: bulkOrigin(clip.origin))
        }
        let titles = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, bulkResultTitle($0)) })

        perform {
            if let destinationFolderID, !self.canEditSharedFolder(destinationFolderID) {
                self.pendingBulkLibraryResult = BulkLibraryActionResult(
                    action: self.bulkActionTitle(operation),
                    successCount: 0,
                    failures: selected.map {
                        .init(id: $0.id, title: self.bulkResultTitle($0), reason: "You now have view-only access to the destination folder.")
                    }
                )
                return
            }
            let currentSavedByID = Dictionary(
                uniqueKeysWithValues: self.snapshot.savedClips.map { ($0.id, $0) }
            )
            let forbiddenSavedIDs = Set(selections.compactMap { selection -> UUID? in
                guard selection.origin == .saved,
                      let folderID = currentSavedByID[selection.id]?.folderID,
                      !self.canEditSharedFolder(folderID)
                else { return nil }
                return selection.id
            })
            let destinationRoot = destinationFolderID.flatMap(self.sharedRootID(containing:))
            let crossSpaceSavedIDs = Set(selections.compactMap { selection -> UUID? in
                guard selection.origin == .saved,
                      case .moveSaved = operation,
                      let current = currentSavedByID[selection.id]
                else { return nil }
                let sourceRoot = current.folderID.flatMap(self.sharedRootID(containing:))
                return sourceRoot == destinationRoot ? nil : selection.id
            })
            let currentHistoryByID = Dictionary(
                uniqueKeysWithValues: self.snapshot.history.map { ($0.id, $0) }
            )
            let sensitiveIDs = Set(selections.compactMap { selection -> UUID? in
                let content: ClipContent?
                let stored: ClipSensitivityMetadata?
                switch selection.origin {
                case .saved:
                    content = currentSavedByID[selection.id]?.content
                    stored = currentSavedByID[selection.id]?.sensitivity
                case .history:
                    content = currentHistoryByID[selection.id]?.content
                    stored = currentHistoryByID[selection.id]?.sensitivity
                case .privateSession, .vault:
                    return nil
                }
                guard let content else { return nil }
                return self.presentationSensitivityCategory(content: content, stored: stored) != nil
                    || self.secretDetector.scan(content).containsSecret ? selection.id : nil
            })
            let plan = try BulkLibraryMutationPlanner.plan(
                selections: selections,
                snapshot: self.snapshot,
                operation: operation,
                forbiddenSavedIDs: forbiddenSavedIDs,
                crossSpaceSavedIDs: crossSpaceSavedIDs,
                detectedSensitiveIDs: sensitiveIDs
            )
            let updated = plan.eligibleCount > 0
                ? try await library.applyBulkMutation(
                    plan,
                    authorize: { [weak self] in
                        await MainActor.run {
                            self?.isBulkMutationCurrentlyAuthorized(plan) == true
                        }
                    }
                )
                : []
            for clip in updated { await self.recordSavedClipForSync(clip) }
            try await self.refreshSnapshot()
            self.scheduleBackgroundSavedLibrarySync()
            self.setSelectedClipIDs(self.selectedClipIDs)
            self.pendingBulkLibraryResult = BulkLibraryActionResult(
                action: self.bulkActionTitle(operation),
                successCount: updated.count,
                failures: plan.failures.map { failure in
                    BulkLibraryActionResult.Failure(
                        id: failure.id,
                        title: titles[failure.id] ?? "Unavailable item",
                        reason: self.bulkFailureDescription(failure.reason)
                    )
                }
            )
            self.statusMessage = "\(updated.count) item\(updated.count == 1 ? "" : "s") updated."
        }
    }

    func exportBulkLibrarySelection() {
        let selected = selectedClipsForBulkAction
        guard !selected.isEmpty else {
            errorMessage = BulkLibraryMutationError.emptySelection.localizedDescription
            return
        }
        var selections: [OrdinaryClipArchiveSelection] = []
        var failures: [BulkLibraryActionResult.Failure] = []
        for clip in selected {
            if clip.origin == .privateSession {
                failures.append(.init(id: clip.id, title: bulkResultTitle(clip), reason: "Private Session items are memory-only."))
                continue
            }
            if case let .saved(folderID?) = clip.origin, !canEditSharedFolder(folderID) {
                failures.append(.init(id: clip.id, title: bulkResultTitle(clip), reason: "This shared item is view-only."))
                continue
            }
            if presentationSensitivityCategory(content: clip.content, stored: clip.sensitivity) != nil
                || secretDetector.scan(clip.content).containsSecret
            {
                failures.append(.init(id: clip.id, title: "Sensitive item", reason: "Sensitive items require individual export confirmation."))
                continue
            }
            if Self.containsNonPortableLocalReference(clip.content) {
                failures.append(.init(id: clip.id, title: bulkResultTitle(clip), reason: "Local file references are not portable."))
                continue
            }
            do { selections.append(try archiveSelection(for: clip)) }
            catch { failures.append(.init(id: clip.id, title: bulkResultTitle(clip), reason: error.localizedDescription)) }
        }
        guard !selections.isEmpty else {
            pendingBulkLibraryResult = BulkLibraryActionResult(
                action: "Export Selection",
                successCount: 0,
                failures: failures
            )
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Selected Clips"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "Selected Clips.clipboardrouterarchive"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let clips = selections.map(\.clip)
        let folders = Dictionary(
            grouping: selections.flatMap(\.folders),
            by: \.id
        ).values.compactMap(\.first)
        perform {
            let manifest = try await self.archiveService.export(
                savedClips: clips,
                folders: folders,
                to: destination
            )
            let omitted = manifest.omissions.map { omission in
                BulkLibraryActionResult.Failure(
                    id: omission.id,
                    title: clips.first(where: { $0.id == omission.id })?.name ?? "Unavailable item",
                    reason: omission.reason
                )
            }
            self.pendingBulkLibraryResult = BulkLibraryActionResult(
                action: "Export Selection",
                successCount: manifest.entries.count,
                failures: failures + omitted
            )
            self.statusMessage = "Exported \(manifest.entries.count) selected item\(manifest.entries.count == 1 ? "" : "s")."
        }
    }

    func dismissBulkLibraryResult() { pendingBulkLibraryResult = nil }

    private func bulkOrigin(_ origin: PresentedClip.Origin) -> BulkLibraryItemOrigin {
        switch origin {
        case .history: .history
        case .saved: .saved
        case .privateSession: .privateSession
        }
    }

    private func bulkResultTitle(_ clip: PresentedClip) -> String {
        isSensitiveForPresentation(clip) ? "Sensitive item" : clip.title
    }

    private func bulkActionTitle(_ operation: BulkLibraryOperation) -> String {
        switch operation {
        case .saveHistory: "Save Selection"
        case .moveSaved: "Move Selection"
        case .addTags: "Tag Selection"
        case let .setPinned(value): value ? "Pin Selection" : "Unpin Selection"
        }
    }

    /// Re-evaluated from inside ClipboardLibrary's serialized mutation permit so a role
    /// revocation received while a bulk review is open cannot authorize the commit.
    private func isBulkMutationCurrentlyAuthorized(_ plan: BulkLibraryMutationPlan) -> Bool {
        let destinationFolderID: UUID? = switch plan.operation {
        case let .saveHistory(folderID), let .moveSaved(folderID): folderID
        case .addTags, .setPinned: nil
        }
        if let destinationFolderID, !canEditSharedFolder(destinationFolderID) {
            return false
        }
        let savedByID = Dictionary(uniqueKeysWithValues: snapshot.savedClips.map { ($0.id, $0) })
        for expectation in plan.saved {
            guard let current = savedByID[expectation.id] else { return false }
            if let folderID = current.folderID, !canEditSharedFolder(folderID) { return false }
            if case .moveSaved = plan.operation {
                let sourceRoot = current.folderID.flatMap(sharedRootID(containing:))
                let destinationRoot = destinationFolderID.flatMap(sharedRootID(containing:))
                if sourceRoot != destinationRoot { return false }
            }
        }
        return true
    }

    private func bulkFailureDescription(_ reason: BulkLibraryFailureReason) -> String {
        switch reason {
        case .notFound: "The item no longer exists."
        case .immutableHistory: "History is immutable. Save it before organizing it."
        case .alreadySaved: "This item is already in Saved."
        case .privateSession: "Private Session items are memory-only."
        case .vault: "Vault items cannot enter ordinary bulk actions."
        case .sensitive: "Sensitive items require individual review."
        case .permissionDenied: "This shared item is view-only."
        case .crossSpaceMove: "Private and shared folder spaces cannot be crossed by a bulk move."
        }
    }

    /// This check intentionally runs again from the Core mutation permit immediately before
    /// persistence. Suggestions, Always Apply, and Undo therefore share one authorization rule.
    private func isAutomaticOrganizationCurrentlyAuthorized(
        sourceFolderID: UUID?,
        destinationFolderID: UUID?
    ) -> Bool {
        if let sourceFolderID, !canEditSharedFolder(sourceFolderID) { return false }
        if let destinationFolderID, !canEditSharedFolder(destinationFolderID) { return false }
        return sourceFolderID.flatMap(sharedRootID(containing:))
            == destinationFolderID.flatMap(sharedRootID(containing:))
    }

    func automaticOrganizationSuggestions(
        for clip: PresentedClip
    ) -> [AutomaticOrganizationSuggestion] {
        guard case .saved = clip.origin,
              let saved = snapshot.savedClips.first(where: { $0.id == clip.id }),
              saved.sensitivity == nil,
              !secretDetector.scan(saved.content).containsSecret
        else { return [] }
        return automaticOrganizationEngine.suggestions(
            for: saved,
            snapshot: automaticOrganizationSnapshot,
            context: .committedLocalOrdinary
        )
    }

    var automaticOrganizationPreviewClips: [PresentedClip] {
        snapshot.savedClips
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .compactMap { currentSavedPresentedClip(id: $0.id) }
    }

    func setAutomaticOrganizationRuleBehavior(
        _ ruleID: UUID,
        behavior: AutomaticOrganizationRuleBehavior
    ) {
        perform {
            var next = self.automaticOrganizationSnapshot
            guard let index = next.rules.firstIndex(where: { $0.id == ruleID }) else {
                throw AutomaticOrganizationError.ruleNotFound
            }
            next.rules[index].behavior = behavior
            next.suppressedRuleIDs.remove(ruleID)
            try await self.automaticOrganizationStore.save(next)
            self.automaticOrganizationSnapshot = next
            self.statusMessage = behavior == .alwaysApply
                ? "Future matches will organize automatically."
                : "Future matches will ask before organizing."
        }
    }

    func moveAutomaticOrganizationRule(_ ruleID: UUID, offset: Int) {
        guard offset == -1 || offset == 1 else { return }
        perform {
            var next = self.automaticOrganizationSnapshot
            let ordered = next.rules.sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.id.uuidString < $1.id.uuidString
            }
            guard let currentIndex = ordered.firstIndex(where: { $0.id == ruleID }) else {
                throw AutomaticOrganizationError.ruleNotFound
            }
            let destinationIndex = currentIndex + offset
            guard ordered.indices.contains(destinationIndex),
                  let first = next.rules.firstIndex(where: { $0.id == ruleID }),
                  let second = next.rules.firstIndex(where: {
                      $0.id == ordered[destinationIndex].id
                  })
            else { return }
            let priority = next.rules[first].priority
            next.rules[first].priority = next.rules[second].priority
            next.rules[second].priority = priority
            try await self.automaticOrganizationStore.save(next)
            self.automaticOrganizationSnapshot = next
        }
    }

    func latestAutomaticOrganizationReceipt(
        for savedClipID: UUID
    ) -> AutomaticOrganizationReceipt? {
        automaticOrganizationSnapshot.receipts
            .filter { $0.savedClipID == savedClipID }
            .max { $0.appliedAt < $1.appliedAt }
    }

    func addAutomaticOrganizationRule(_ rule: AutomaticOrganizationRule) async -> Bool {
        guard requireDirectLicense(.automation) else { return false }
        guard !isBusy else {
            errorMessage = AppModelOperationError.operationInProgress.localizedDescription
            return false
        }
        isBusy = true
        defer { isBusy = false }
        guard automaticOrganizationSnapshot.rules.count
                < AutomaticOrganizationSnapshot.maximumRules,
              !automaticOrganizationSnapshot.rules.contains(where: { $0.id == rule.id })
        else {
            errorMessage = AutomaticOrganizationError.invalidSnapshot.localizedDescription
            return false
        }
        do {
            try validateAutomaticOrganizationDestination(for: rule)
            var next = automaticOrganizationSnapshot
            next.rules.append(rule)
            next = try AutomaticOrganizationSnapshot(
                schemaVersion: next.schemaVersion,
                rules: next.rules,
                suppressedRuleIDs: next.suppressedRuleIDs,
                receipts: next.receipts,
                locallyCreatedSavedItemIDs: next.locallyCreatedSavedItemIDs
            )
            try await automaticOrganizationStore.save(next)
            automaticOrganizationSnapshot = next
            errorMessage = nil
            statusMessage = "Organization rule created."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateAutomaticOrganizationRule(
        _ replacement: AutomaticOrganizationRule,
        expecting expected: AutomaticOrganizationRule
    ) async -> Bool {
        guard requireDirectLicense(.automation) else { return false }
        guard !isBusy else {
            errorMessage = AppModelOperationError.operationInProgress.localizedDescription
            return false
        }
        isBusy = true
        defer { isBusy = false }

        do {
            try validateAutomaticOrganizationDestination(for: replacement)
            let next = try automaticOrganizationSnapshot.replacingRule(
                replacement,
                expecting: expected
            )
            try await automaticOrganizationStore.save(next)
            automaticOrganizationSnapshot = next
            errorMessage = nil
            statusMessage = "Organization rule updated."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func validateAutomaticOrganizationDestination(
        for rule: AutomaticOrganizationRule
    ) throws {
        guard rule.action.movesToFolder,
              let destinationID = rule.action.destinationFolderID
        else { return }
        guard folderDestinations.contains(where: {
            $0.id == destinationID && $0.canAcceptItems
        }) else {
            throw AutomaticOrganizationError.ineligibleDestination
        }
    }

    func setAutomaticOrganizationRuleEnabled(_ ruleID: UUID, enabled: Bool) {
        perform {
            var next = self.automaticOrganizationSnapshot
            guard let index = next.rules.firstIndex(where: { $0.id == ruleID }) else {
                throw AutomaticOrganizationError.ruleNotFound
            }
            next.rules[index].isEnabled = enabled
            if enabled { next.suppressedRuleIDs.remove(ruleID) }
            try await self.automaticOrganizationStore.save(next)
            self.automaticOrganizationSnapshot = next
            self.statusMessage = enabled ? "Organization rule enabled." : "Organization rule paused."
        }
    }

    func deleteAutomaticOrganizationRule(_ ruleID: UUID) {
        perform {
            var next = self.automaticOrganizationSnapshot
            guard next.rules.contains(where: { $0.id == ruleID }) else {
                throw AutomaticOrganizationError.ruleNotFound
            }
            next.rules.removeAll { $0.id == ruleID }
            next.suppressedRuleIDs.remove(ruleID)
            try await self.automaticOrganizationStore.save(next)
            self.automaticOrganizationSnapshot = next
            self.statusMessage = "Organization rule deleted."
        }
    }

    func applyAutomaticOrganizationOnce(
        _ suggestion: AutomaticOrganizationSuggestion,
        to clip: PresentedClip
    ) {
        guard requireDirectLicense(.automation) else { return }
        applyAutomaticOrganization(suggestion, to: clip, alwaysApply: false)
    }

    func alwaysApplyAutomaticOrganization(
        _ suggestion: AutomaticOrganizationSuggestion,
        to clip: PresentedClip
    ) {
        guard requireDirectLicense(.automation) else { return }
        applyAutomaticOrganization(suggestion, to: clip, alwaysApply: true)
    }

    func neverSuggestAutomaticOrganization(_ suggestion: AutomaticOrganizationSuggestion) {
        perform {
            var next = self.automaticOrganizationSnapshot
            guard let current = next.rules.first(where: { $0.id == suggestion.rule.id }) else {
                throw AutomaticOrganizationError.ruleNotFound
            }
            guard current == suggestion.rule else {
                throw AutomaticOrganizationError.staleRule
            }
            next.suppressedRuleIDs.insert(suggestion.rule.id)
            try await self.automaticOrganizationStore.save(next)
            self.automaticOrganizationSnapshot = next
            self.statusMessage = "This rule will no longer suggest changes."
        }
    }

    func undoAutomaticOrganization(_ receipt: AutomaticOrganizationReceipt) {
        guard let library else { return }
        perform {
            guard let current = self.snapshot.savedClips.first(where: {
                $0.id == receipt.savedClipID
            }), AutomaticOrganizationItemState(savedClip: current) == receipt.after else {
                throw AutomaticOrganizationError.staleReceipt
            }
            let restored = try await library.applyAutomaticOrganization(
                to: current.id,
                folderID: receipt.before.folderID,
                tags: receipt.before.tags,
                expecting: receipt.after.expectation,
                authorize: { [weak self] in
                    await MainActor.run {
                        self?.isAutomaticOrganizationCurrentlyAuthorized(
                            sourceFolderID: receipt.after.folderID,
                            destinationFolderID: receipt.before.folderID
                        ) == true
                    }
                }
            )
            var next = self.automaticOrganizationSnapshot
            next.receipts.removeAll { $0.id == receipt.id }
            self.automaticOrganizationSnapshot = next
            do {
                try await self.automaticOrganizationStore.save(next)
            } catch {
                self.errorMessage = "The item was restored, but receipt cleanup could not be saved: \(error.localizedDescription)"
            }
            await self.recordSavedClipForSync(restored)
            try await self.refreshSnapshot()
            self.scheduleBackgroundSavedLibrarySync()
            self.statusMessage = "Automatic organization undone."
        }
    }

    private func applyAutomaticOrganization(
        _ suggestion: AutomaticOrganizationSuggestion,
        to clip: PresentedClip,
        alwaysApply: Bool
    ) {
        guard case .saved = clip.origin else {
            errorMessage = AutomaticOrganizationError.protectedItem.localizedDescription
            return
        }
        perform {
            guard self.automaticOrganizationSnapshot.rules.contains(where: {
                $0 == suggestion.rule
            }) else { throw AutomaticOrganizationError.invalidRule }
            guard let current = self.snapshot.savedClips.first(where: { $0.id == clip.id }),
                  current.modifiedAt == clip.date,
                  current.folderID == clip.origin.savedFolderID,
                  (current.tags ?? []) == clip.tags,
                  current.content.deduplicationFingerprint
                    == clip.content.deduplicationFingerprint,
                  self.automaticOrganizationEngine.suggestions(
                    for: current,
                    snapshot: self.automaticOrganizationSnapshot,
                    context: .committedLocalOrdinary
                  ).contains(where: { $0.rule.id == suggestion.rule.id })
            else { throw ClipboardLibraryError.savedItemChangedDuringEdit(clip.id) }
            _ = try await self.applyAutomaticOrganizationRule(
                suggestion.rule,
                to: clip.id,
                context: .committedLocalOrdinary
            )
            if alwaysApply {
                var next = self.automaticOrganizationSnapshot
                guard let index = next.rules.firstIndex(where: { $0.id == suggestion.rule.id })
                else { throw AutomaticOrganizationError.invalidRule }
                next.rules[index].behavior = .alwaysApply
                next.suppressedRuleIDs.remove(suggestion.rule.id)
                try await self.automaticOrganizationStore.save(next)
                self.automaticOrganizationSnapshot = next
                self.statusMessage = "Applied. Future matching saved items will organize automatically."
            } else {
                self.statusMessage = "Organization applied."
            }
        }
    }

    @discardableResult
    private func applyAutomaticOrganizationRule(
        _ rule: AutomaticOrganizationRule,
        to savedClipID: UUID,
        context: AutomaticOrganizationEvaluationContext
    ) async throws -> SavedClip {
        guard context.permitsOrganization, let library else {
            throw AutomaticOrganizationError.protectedItem
        }
        guard let current = snapshot.savedClips.first(where: { $0.id == savedClipID }),
              current.sensitivity == nil,
              !secretDetector.scan(current.content).containsSecret
        else { throw AutomaticOrganizationError.protectedItem }

        let sourceSharedRoot = current.folderID.flatMap(sharedRootID(containing:))
        let destinationFolderID = rule.action.movesToFolder
            ? rule.action.destinationFolderID : current.folderID
        let destinationSharedRoot = destinationFolderID.flatMap(sharedRootID(containing:))
        if let currentFolderID = current.folderID, !canEditSharedFolder(currentFolderID) {
            throw SharedFolderError.permissionDenied
        }
        if let destinationFolderID, !canEditSharedFolder(destinationFolderID) {
            throw SharedFolderError.permissionDenied
        }
        guard sourceSharedRoot == destinationSharedRoot else {
            throw AppModelOperationError.automaticOrganizationCrossSpace
        }

        let nextTags = try ClipTag.normalize((current.tags ?? []) + rule.action.addedTags)
        guard current.folderID != destinationFolderID || (current.tags ?? []) != nextTags else {
            return current
        }
        let before = AutomaticOrganizationItemState(savedClip: current)
        let updated = try await library.applyAutomaticOrganization(
            to: current.id,
            folderID: destinationFolderID,
            tags: nextTags,
            expecting: SavedClipOrganizationExpectation(savedClip: current),
            authorize: { [weak self] in
                await MainActor.run {
                    self?.isAutomaticOrganizationCurrentlyAuthorized(
                        sourceFolderID: current.folderID,
                        destinationFolderID: destinationFolderID
                    ) == true
                }
            }
        )
        let receipt = AutomaticOrganizationReceipt(
            savedClipID: current.id,
            ruleID: rule.id,
            appliedAt: updated.modifiedAt,
            before: before,
            after: AutomaticOrganizationItemState(savedClip: updated)
        )
        var next = automaticOrganizationSnapshot
        next.receipts.insert(receipt, at: 0)
        if next.receipts.count > AutomaticOrganizationSnapshot.maximumReceipts {
            next.receipts = Array(next.receipts.prefix(AutomaticOrganizationSnapshot.maximumReceipts))
        }
        // The library commit has already succeeded. Keep the in-memory receipt available for Undo
        // even if durable receipt persistence becomes unavailable, and surface that failure.
        automaticOrganizationSnapshot = next
        do {
            try await automaticOrganizationStore.save(next)
        } catch {
            errorMessage = "The item was organized, but its Undo receipt could not be saved: \(error.localizedDescription)"
        }
        await recordSavedClipForSync(updated)
        try await refreshSnapshot()
        scheduleBackgroundSavedLibrarySync()
        return updated
    }

    private func applyAlwaysRulesAfterLocalSave(_ savedClipID: UUID) async throws -> SavedClip? {
        guard directLicenseAccessPolicy.allows(.automation) else { return nil }
        guard var current = snapshot.savedClips.first(where: { $0.id == savedClipID }),
              current.sensitivity == nil,
              !secretDetector.scan(current.content).containsSecret
        else { return nil }
        if !automaticOrganizationSnapshot.locallyCreatedSavedItemIDs.contains(savedClipID) {
            var next = automaticOrganizationSnapshot
            if next.locallyCreatedSavedItemIDs.count
                >= AutomaticOrganizationSnapshot.maximumTrackedLocalItems
            {
                let liveIDs = Set(snapshot.savedClips.map(\.id))
                next.locallyCreatedSavedItemIDs.formIntersection(liveIDs)
            }
            guard next.locallyCreatedSavedItemIDs.count
                < AutomaticOrganizationSnapshot.maximumTrackedLocalItems
            else { return nil }
            next.locallyCreatedSavedItemIDs.insert(savedClipID)
            try await automaticOrganizationStore.save(next)
            automaticOrganizationSnapshot = next
        }
        let matches = automaticOrganizationEngine.automaticRules(
            for: current,
            snapshot: automaticOrganizationSnapshot,
            context: .committedLocalOrdinary
        )
        for match in matches.prefix(AutomaticOrganizationEngine.maximumAutomaticApplications) {
            current = try await applyAutomaticOrganizationRule(
                match.rule,
                to: current.id,
                context: .committedLocalOrdinary
            )
        }
        return current
    }

    func organizeTransferredItem(_ transfer: LibraryItemTransfer, to folderID: UUID?) -> Bool {
        if let folderID, !canEditSharedFolder(folderID) {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return false
        }
        switch transfer.origin {
        case .history:
            guard let history = snapshot.history.first(where: { $0.id == transfer.id }) else {
                return false
            }
            saveHistoryClip(
                PresentedClip(
                    id: history.id,
                    title: Self.previewTitle(for: history.content),
                    content: history.content,
                    date: history.lastCapturedAt,
                    sourceBundleIdentifier: history.sourceApplicationBundleIdentifier,
                    origin: .history,
                    captureContext: history.captureContext,
                    pasteboardTypeIdentifiers: history.pasteboardTypeIdentifiers ?? []
                ),
                folderID: folderID
            )
        case .saved:
            guard snapshot.savedClips.contains(where: { $0.id == transfer.id }) else { return false }
            moveSavedClip(id: transfer.id, to: folderID)
        }
        return true
    }

    @discardableResult
    func createNote(
        title: String,
        body: String,
        folderID: UUID? = nil,
        pinned: Bool = false
    ) -> Bool {
        guard requireDirectLicense(.premiumCreation) else { return false }
        guard let library else { return false }
        guard validateManualNoteContent(title: title, body: body) else { return false }
        if let folderID, !canEditSharedFolder(folderID) {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return false
        }
        perform {
            let note = try await library.createNote(
                title: title,
                body: body,
                folderID: folderID,
                pinned: pinned
            )
            try await self.refreshSnapshot()
            let organized = try await self.applyAlwaysRulesAfterLocalSave(note.id) ?? note
            await self.recordSavedClipForSync(organized)
            self.scheduleBackgroundSavedLibrarySync()
            self.selectedSection = .smartView(.notes)
            self.selectedClipID = note.id
            self.statusMessage = "Note created."
        }
        return true
    }

    func canConvertToNote(_ clip: PresentedClip) -> Bool {
        guard clip.origin != .privateSession,
              clip.savedItemKind != .note,
              Self.isSafelyConvertibleToNote(clip.content),
              clip.captureContext?.coarseLocation == nil,
              !secretDetector.scan(clip.content).containsSecret
        else { return false }
        switch clip.origin {
        case .history:
            return snapshot.history.contains {
                $0.id == clip.id
                    && $0.sensitivity == nil
                    && $0.content.deduplicationFingerprint
                        == clip.content.deduplicationFingerprint
            }
        case let .saved(folderID):
            if let folderID, !canEditSharedFolder(folderID) { return false }
            return snapshot.savedClips.contains {
                $0.id == clip.id
                    && $0.sensitivity == nil
                    && $0.content.deduplicationFingerprint
                        == clip.content.deduplicationFingerprint
                    && $0.folderID == folderID
            }
        case .privateSession:
            return false
        }
    }

    func canEditClip(_ clip: PresentedClip) -> Bool {
        guard clip.origin != .privateSession,
              clip.savedItemKind == .clip,
              clip.sensitivity == nil,
              !secretDetector.scan(clip.content).containsSecret
        else { return false }
        if case let .saved(folderID?) = clip.origin, !canEditSharedFolder(folderID) {
            return false
        }
        return clip.content.isSafelyEditableAsPlainTextCopy
    }

    func canEditNote(_ clip: PresentedClip) -> Bool {
        guard clip.savedItemKind == .note,
              clip.sensitivity == nil,
              !secretDetector.scan(clip.content).containsSecret,
              case let .saved(folderID) = clip.origin
        else {
            return false
        }
        return folderID.map(canEditSharedFolder) ?? true
    }

    @discardableResult
    func saveEditedClip(
        _ clip: PresentedClip,
        title: String,
        body: String,
        folderID: UUID?
    ) -> Bool {
        guard canEditClip(clip), let library else {
            errorMessage = "Only text-bearing clips without images, files, OCR, or sensitive data can be edited."
            return false
        }
        guard validateManualClipEditContent(title: title, body: body) else { return false }
        if let folderID, !canEditSharedFolder(folderID) {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return false
        }

        switch clip.origin {
        case .history:
            perform {
                let edited = try await library.createEditedCopyFromHistory(
                    id: clip.id,
                    title: title,
                    body: body,
                    folderID: folderID
                )
                try await self.refreshSnapshot()
                let organized = try await self.applyAlwaysRulesAfterLocalSave(edited.id) ?? edited
                await self.recordSavedClipForSync(organized)
                self.scheduleBackgroundSavedLibrarySync()
                self.selectedSection = folderID.map(LibrarySection.folder) ?? .allSaved
                self.selectedClipID = edited.id
                self.statusMessage = "Edited copy saved. History was left unchanged."
            }
        case let .saved(existingFolderID):
            if let existingFolderID, !canEditSharedFolder(existingFolderID) {
                errorMessage = SharedFolderError.permissionDenied.localizedDescription
                return false
            }
            let sourceSharedRoot = existingFolderID.flatMap(sharedRootID(containing:))
            let destinationSharedRoot = folderID.flatMap(sharedRootID(containing:))
            guard sourceSharedRoot == destinationSharedRoot else {
                errorMessage = "Shared and private items use separate sync spaces. Copy the clip explicitly if you want it in both places."
                return false
            }
            perform {
                let edited: SavedClip
                let createdCopy: Bool
                if clip.content.type == .richText {
                    edited = try await library.createEditedCopyFromSavedClip(
                        id: clip.id,
                        title: title,
                        body: body,
                        folderID: folderID
                    )
                    createdCopy = true
                    self.selectedSection = folderID.map(LibrarySection.folder) ?? .allSaved
                    self.statusMessage = "Editable copy saved. The rich-text original was left unchanged."
                } else {
                    edited = try await library.updateSavedClipContent(
                        id: clip.id,
                        title: title,
                        body: body,
                        folderID: folderID
                    )
                    createdCopy = false
                    self.statusMessage = "Clip updated."
                }
                try await self.refreshSnapshot()
                let organized = createdCopy
                    ? try await self.applyAlwaysRulesAfterLocalSave(edited.id) ?? edited
                    : edited
                await self.recordSavedClipForSync(organized)
                self.scheduleBackgroundSavedLibrarySync()
                self.selectedClipID = edited.id
            }
        case .privateSession:
            return false
        }
        return true
    }

    /// Editor-specific save that reports durable completion. The sheet stays open on validation,
    /// permission, stale-version, busy, or persistence failures so the user's draft is not lost.
    func saveEditedClipFromEditor(
        _ clip: PresentedClip,
        title: String,
        body: String,
        folderID: UUID?
    ) async -> Bool {
        guard canEditClip(clip), let library else {
            errorMessage = "Only text-bearing clips without images, files, OCR, or sensitive data can be edited."
            return false
        }
        guard validateManualClipEditContent(title: title, body: body) else { return false }
        guard !isBusy else {
            errorMessage = AppModelOperationError.operationInProgress.localizedDescription
            return false
        }
        if let folderID, !canEditSharedFolder(folderID) {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return false
        }

        isBusy = true
        defer { isBusy = false }
        do {
            let edited: SavedClip
            let createdCopy: Bool
            switch clip.origin {
            case .history:
                edited = try await library.createEditedCopyFromHistory(
                    id: clip.id,
                    title: title,
                    body: body,
                    folderID: folderID
                )
                createdCopy = true
                selectedSection = folderID.map(LibrarySection.folder) ?? .allSaved
                statusMessage = "Edited copy saved. History was left unchanged."
            case .saved:
                guard let current = snapshot.savedClips.first(where: { $0.id == clip.id }) else {
                    throw ClipboardLibraryError.savedClipNotFound(clip.id)
                }
                if let currentFolderID = current.folderID,
                   !canEditSharedFolder(currentFolderID)
                {
                    throw SharedFolderError.permissionDenied
                }
                let sourceSharedRoot = current.folderID.flatMap(sharedRootID(containing:))
                let destinationSharedRoot = folderID.flatMap(sharedRootID(containing:))
                guard sourceSharedRoot == destinationSharedRoot else {
                    errorMessage = "Shared and private items use separate sync spaces. Copy the clip explicitly if you want it in both places."
                    return false
                }
                let expectation = SavedClipEditExpectation(
                    name: clip.title,
                    modifiedAt: clip.date,
                    folderID: clip.origin.savedFolderID,
                    contentFingerprint: clip.content.deduplicationFingerprint
                )
                if current.content.type == .richText {
                    edited = try await library.createEditedCopyFromSavedClip(
                        id: clip.id,
                        title: title,
                        body: body,
                        folderID: folderID,
                        expecting: expectation
                    )
                    createdCopy = true
                    selectedSection = folderID.map(LibrarySection.folder) ?? .allSaved
                    statusMessage = "Editable copy saved. The rich-text original was left unchanged."
                } else {
                    edited = try await library.updateSavedClipContent(
                        id: clip.id,
                        title: title,
                        body: body,
                        folderID: folderID,
                        expecting: expectation
                    )
                    createdCopy = false
                    statusMessage = "Clip updated."
                }
            case .privateSession:
                throw AppModelOperationError.ordinaryClipRequired
            }
            try await refreshSnapshot()
            let organized = createdCopy
                ? try await applyAlwaysRulesAfterLocalSave(edited.id) ?? edited
                : edited
            await recordSavedClipForSync(organized)
            scheduleBackgroundSavedLibrarySync()
            selectedClipID = edited.id
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    static func isSafelyConvertibleToNote(_ content: ClipContent) -> Bool {
        content.isSafelyConvertibleToNote
    }

    func convertToNote(_ clip: PresentedClip, title: String? = nil) {
        guard canConvertToNote(clip) else {
            errorMessage = "Only plain text and web links without attached files or rich media can be converted to notes."
            return
        }
        guard let library else { return }
        perform {
            let note: SavedClip
            switch clip.origin {
            case .history:
                note = try await library.convertHistoryItemToNote(id: clip.id, title: title)
            case .saved:
                if let folderID = self.snapshot.savedClips.first(where: { $0.id == clip.id })?.folderID,
                   !self.canEditSharedFolder(folderID)
                {
                    throw SharedFolderError.permissionDenied
                }
                note = try await library.convertSavedClipToNote(id: clip.id, title: title)
            case .privateSession:
                throw AppModelOperationError.ordinaryClipRequired
            }
            try await self.refreshSnapshot()
            let organized = try await self.applyAlwaysRulesAfterLocalSave(note.id) ?? note
            await self.recordSavedClipForSync(organized)
            self.scheduleBackgroundSavedLibrarySync()
            self.selectedSection = .smartView(.notes)
            self.selectedClipID = note.id
            self.statusMessage = "Converted to an editable note."
        }
    }

    @discardableResult
    func updateNote(id: UUID, title: String, body: String, folderID: UUID?) -> Bool {
        guard let library else { return false }
        guard validateManualNoteContent(title: title, body: body) else { return false }
        let existingFolderID = snapshot.savedClips.first(where: { $0.id == id })?.folderID
        if let existingFolderID, !canEditSharedFolder(existingFolderID)
        {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return false
        }
        if let folderID, !canEditSharedFolder(folderID) {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return false
        }
        let sourceSharedRoot = existingFolderID.flatMap(sharedRootID(containing:))
        let destinationSharedRoot = folderID.flatMap(sharedRootID(containing:))
        guard sourceSharedRoot == destinationSharedRoot else {
            errorMessage = "Shared and private items use separate sync spaces. Copy the note explicitly if you want it in both places."
            return false
        }
        perform {
            let note = try await library.updateNote(
                id: id,
                title: title,
                body: body,
                folderID: folderID
            )
            await self.recordSavedClipForSync(note)
            try await self.refreshSnapshot()
            self.scheduleBackgroundSavedLibrarySync()
            self.statusMessage = "Note updated."
        }
        return true
    }

    func createNoteFromEditor(
        title: String,
        body: String,
        folderID: UUID?
    ) async -> Bool {
        guard requireDirectLicense(.premiumCreation) else { return false }
        guard let library else { return false }
        guard validateManualNoteContent(title: title, body: body) else { return false }
        if let folderID, !canEditSharedFolder(folderID) {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return false
        }
        guard !isBusy else {
            errorMessage = AppModelOperationError.operationInProgress.localizedDescription
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let note = try await library.createNote(
                title: title,
                body: body,
                folderID: folderID
            )
            try await refreshSnapshot()
            let organized = try await applyAlwaysRulesAfterLocalSave(note.id) ?? note
            await recordSavedClipForSync(organized)
            scheduleBackgroundSavedLibrarySync()
            requestPostEditorNotePresentation(note.id, status: "Note created.")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateNoteFromEditor(
        _ clip: PresentedClip,
        title: String,
        body: String,
        folderID: UUID?
    ) async -> Bool {
        guard canEditNote(clip), let library else { return false }
        guard validateManualNoteContent(title: title, body: body) else { return false }
        guard !isBusy else {
            errorMessage = AppModelOperationError.operationInProgress.localizedDescription
            return false
        }
        guard let current = snapshot.savedClips.first(where: { $0.id == clip.id }) else {
            errorMessage = ClipboardLibraryError.savedClipNotFound(clip.id).localizedDescription
            return false
        }
        if let currentFolderID = current.folderID, !canEditSharedFolder(currentFolderID) {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return false
        }
        if let folderID, !canEditSharedFolder(folderID) {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return false
        }
        let sourceSharedRoot = current.folderID.flatMap(sharedRootID(containing:))
        let destinationSharedRoot = folderID.flatMap(sharedRootID(containing:))
        guard sourceSharedRoot == destinationSharedRoot else {
            errorMessage = "Shared and private items use separate sync spaces. Copy the note explicitly if you want it in both places."
            return false
        }

        isBusy = true
        defer { isBusy = false }
        do {
            let expectation = SavedClipEditExpectation(
                name: clip.title,
                modifiedAt: clip.date,
                folderID: clip.origin.savedFolderID,
                contentFingerprint: clip.content.deduplicationFingerprint
            )
            let note = try await library.updateNote(
                id: clip.id,
                title: title,
                body: body,
                folderID: folderID,
                expecting: expectation
            )
            await recordSavedClipForSync(note)
            try await refreshSnapshot()
            scheduleBackgroundSavedLibrarySync()
            selectedClipID = note.id
            statusMessage = "Note updated."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func validateManualNoteContent(title: String, body: String) -> Bool {
        let scan = secretDetector.scan(text: title + "\n" + body)
        guard let strongest = scan.detections.max(by: {
            Self.sensitivityConfidence($0.confidence)
                < Self.sensitivityConfidence($1.confidence)
        }) else { return true }
        errorMessage = AppModelOperationError.sensitiveNoteRequiresVault(
            category: strongest.category.rawValue
        ).localizedDescription
        return false
    }

    private func validateManualClipEditContent(title: String, body: String) -> Bool {
        let scan = secretDetector.scan(text: title + "\n" + body)
        guard let strongest = scan.detections.max(by: {
            Self.sensitivityConfidence($0.confidence)
                < Self.sensitivityConfidence($1.confidence)
        }) else { return true }
        errorMessage = AppModelOperationError.sensitiveClipEditRequiresVault(
            category: strongest.category.rawValue
        ).localizedDescription
        return false
    }

    func requestCreateNote(presentationSurface: RequestPresentationSurface = .library) {
        noteCreationPresentationSurface = presentationSurface
        noteCreationRequestID &+= 1
    }

    func requestInsertPalette(
        capturingCurrentApplication: Bool = false,
        preservingRememberedApplication: Bool = false,
        notifyPresentationHosts: Bool = true,
        presentationSurface: RequestPresentationSurface = .library
    ) {
        if capturingCurrentApplication {
            rememberPasteTarget()
        } else if !preservingRememberedApplication {
            pasteTargetProcessIdentifier = nil
            pasteTargetBundleIdentifier = nil
            pasteTargetLaunchDate = nil
            pasteTargetApplicationName = nil
        }
        insertPalettePasteTargetToken = pasteTargetProcessIdentifier == nil ? nil : UUID()
        if notifyPresentationHosts {
            insertPalettePresentationSurface = presentationSurface
            insertPaletteRequestID &+= 1
        }
    }

    func delete(_ clip: PresentedClip) {
        guard let library else { return }
        if case let .saved(folderID?) = clip.origin,
           !canEditSharedFolder(folderID)
        {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return
        }
        perform {
            switch clip.origin {
            case .history:
                try await library.deleteHistoryItem(id: clip.id)
            case .saved:
                try await library.deleteSavedClip(id: clip.id)
                await self.recordDeletionForSync(id: clip.id, kind: .savedClip)
            case .privateSession:
                return
            }
            try await self.refreshSnapshot()
            if case .saved = clip.origin {
                self.scheduleBackgroundSavedLibrarySync()
            }
            self.selectedClipID = nil
            self.statusMessage = "Clip deleted."
        }
    }

    func clearHistory() {
        guard let library else { return }
        perform {
            try await library.clearHistory()
            try await self.refreshSnapshot()
            self.selectedClipID = nil
            self.statusMessage = "Clipboard history cleared. Saved clips were not removed."
        }
    }

    func setRetention(_ policy: HistoryRetentionPolicy) {
        guard let library else { return }
        perform {
            try await library.setRetentionPolicy(policy)
            try await self.refreshSnapshot()
            self.statusMessage = "History retention updated."
        }
    }

    var captureDeviceContext: DeviceCaptureContext {
        captureContextProvider.deviceContext
    }

    var captureContextInstallationIDDescription: String {
        "Installation …\(captureContextInstallationID.suffix(8))"
    }

    func refreshCaptureContextStatus() {
        captureLocationAuthorization = captureContextProvider.locationAuthorization
        currentCoarseLocation = captureContextProvider.currentCoarseLocation(at: Date())
        coarseLocationObservedAt = currentCoarseLocation == nil
            ? nil : captureContextProvider.cachedLocationDate
    }

    func setDeviceContextEnabled(_ enabled: Bool) {
        guard let library else { return }
        perform {
            try await library.setDeviceContextEnabled(enabled)
            try await self.refreshSnapshot()
            self.statusMessage = enabled
                ? "New ordinary clips will include this Mac's device context."
                : "Device context disabled for new clips."
        }
    }

    func setLocationContextEnabled(_ enabled: Bool) {
        guard let library else { return }
        perform {
            try await library.setLocationContextEnabled(enabled)
            if !enabled {
                self.captureContextProvider.clearLocation()
                self.currentCoarseLocation = nil
                self.coarseLocationObservedAt = nil
            }
            try await self.refreshSnapshot()
            self.statusMessage = enabled
                ? "Approximate location is enabled. Choose Allow Location to request macOS permission."
                : "Approximate location disabled for new clips."
        }
    }

    func requestCaptureLocationPermissionAndRefresh() {
        guard snapshot.settings.effectiveLocationContextEnabled else {
            statusMessage = "Turn on approximate location before asking macOS for permission."
            return
        }
        guard !isRefreshingCaptureLocation else { return }
        isRefreshingCaptureLocation = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRefreshingCaptureLocation = false }
            do {
                let coarse = try await self.captureContextProvider
                    .requestLocationPermissionAndRefresh(at: Date())
                self.captureLocationAuthorization = self.captureContextProvider.locationAuthorization
                self.currentCoarseLocation = coarse
                self.coarseLocationObservedAt = self.captureContextProvider.cachedLocationDate
                self.statusMessage = "Approximate location refreshed. Exact coordinates were discarded."
            } catch {
                self.captureLocationAuthorization = self.captureContextProvider.locationAuthorization
                self.currentCoarseLocation = nil
                self.coarseLocationObservedAt = nil
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func refreshCaptureLocation() {
        guard snapshot.settings.effectiveLocationContextEnabled else { return }
        guard !isRefreshingCaptureLocation else { return }
        isRefreshingCaptureLocation = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRefreshingCaptureLocation = false }
            do {
                let coarse = try await self.captureContextProvider.refreshLocation(at: Date())
                self.captureLocationAuthorization = self.captureContextProvider.locationAuthorization
                self.currentCoarseLocation = coarse
                self.coarseLocationObservedAt = self.captureContextProvider.cachedLocationDate
                self.statusMessage = "Approximate location refreshed. Exact coordinates were discarded."
            } catch {
                self.captureLocationAuthorization = self.captureContextProvider.locationAuthorization
                self.currentCoarseLocation = nil
                self.coarseLocationObservedAt = nil
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func deleteCapturedContext(device: Bool, location: Bool) {
        guard let library else { return }
        perform {
            let result = try await library.deleteCapturedContext(
                device: device,
                location: location
            )
            if location {
                self.captureContextProvider.clearLocation()
                self.currentCoarseLocation = nil
                self.coarseLocationObservedAt = nil
            }
            try await self.refreshSnapshot()
            if result.savedClipCount > 0 { self.scheduleBackgroundSavedLibrarySync() }
            self.statusMessage = result.totalItemCount == 0
                ? "No matching context was stored in existing clips."
                : "Removed context from \(result.totalItemCount) existing item\(result.totalItemCount == 1 ? "" : "s")."
        }
    }

    func excludeApplication(bundleIdentifier: String, excluded: Bool) {
        guard let library else { return }
        perform {
            try await library.setApplication(bundleIdentifier, excluded: excluded)
            try await self.refreshSnapshot()
        }
    }

    func refreshApplicationExclusionOptions(force: Bool = false) {
        let request = applicationDiscoveryCoordinator.request(at: Date(), force: force)
        guard case let .start(generation) = request else { return }

        isDiscoveringApplications = true
        isDiscoveringDestinationApplications = true
        let runningIdentifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        applicationDiscoveryTask = Task.detached(priority: .utility) { [weak self] in
            let options = Self.discoverApplications(runningBundleIdentifiers: runningIdentifiers)
            let destinationBundleIdentifiers = Set(
                DestinationRegistry.all.flatMap(\.applicationBundleIdentifierCandidates)
            )
            let destinationOptions = options.filter {
                destinationBundleIdentifiers.contains($0.bundleIdentifier)
            }
            let otherOptions = options.filter {
                !destinationBundleIdentifiers.contains($0.bundleIdentifier)
            }
            let verifiedDestinations = await Self.verifyApplications(destinationOptions)
            await MainActor.run {
                guard let self,
                      !Task.isCancelled,
                      self.applicationDiscoveryCoordinator.isCurrent(generation: generation)
                else { return }
                self.destinationApplicationOptions = verifiedDestinations
                self.isDiscoveringDestinationApplications = false
            }
            let verifiedOthers = await Self.verifyApplications(otherOptions)
            let verifiedByPath = Dictionary(
                uniqueKeysWithValues: (verifiedDestinations + verifiedOthers).map {
                    ($0.applicationURL.standardizedFileURL.path, $0)
                }
            )
            let verifiedOptions = options.compactMap {
                verifiedByPath[$0.applicationURL.standardizedFileURL.path]
            }
            let wasCancelled = Task.isCancelled
            let completedAt = Date()
            await MainActor.run {
                guard let self else { return }
                if wasCancelled {
                    guard self.applicationDiscoveryCoordinator.cancel(generation: generation) else {
                        return
                    }
                } else {
                    guard self.applicationDiscoveryCoordinator.complete(
                        generation: generation,
                        at: completedAt
                    ) else { return }
                    self.applicationExclusionOptions = verifiedOptions
                    self.destinationApplicationOptions = verifiedOptions.filter {
                        destinationBundleIdentifiers.contains($0.bundleIdentifier)
                    }
                }
                self.isDiscoveringApplications = false
                self.isDiscoveringDestinationApplications = false
                self.applicationDiscoveryTask = nil
            }
        }
    }

    func cancelApplicationDiscovery() {
        guard let generation = applicationDiscoveryCoordinator.inFlightGeneration else {
            applicationDiscoveryTask = nil
            isDiscoveringApplications = false
            isDiscoveringDestinationApplications = false
            return
        }
        applicationDiscoveryTask?.cancel()
        _ = applicationDiscoveryCoordinator.cancel(generation: generation)
        applicationDiscoveryTask = nil
        isDiscoveringApplications = false
        isDiscoveringDestinationApplications = false
    }

    func chooseExcludedApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an application to exclude"
        panel.prompt = "Exclude Application"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleIdentifier = Bundle(url: url)?.bundleIdentifier
        else { return }

        excludeApplication(bundleIdentifier: bundleIdentifier, excluded: true)
        refreshApplicationExclusionOptions(force: true)
    }

    // MARK: - Clipboard Health and quarantine

    func keepQuarantinedClip(id: UUID) {
        guard let library else { return }
        perform {
            guard let review = await self.quarantineStore.review(id: id) else { return }
            let metadata = self.quarantineMetadata[id]
            let candidate: CaptureCandidate
            if let draft = metadata?.draft {
                let materialized = try await self.captureMaterializer.materialize(
                    draft,
                    ocrText: metadata?.ocrText
                )
                candidate = CaptureCandidate(
                    content: materialized.content,
                    sourceApplicationBundleIdentifier:
                        metadata?.sourceApplicationBundleIdentifier,
                    originatingDeviceIdentifier: metadata?.originatingDeviceIdentifier,
                    captureContext: metadata?.captureContext,
                    pasteboardTypeIdentifiers: metadata?.pasteboardTypeIdentifiers ?? [],
                    capturedAt: metadata?.capturedAt ?? Date()
                )
            } else {
                candidate = CaptureCandidate(
                    content: review.content,
                    sourceApplicationBundleIdentifier: metadata?.sourceApplicationBundleIdentifier,
                    originatingDeviceIdentifier: metadata?.originatingDeviceIdentifier,
                    captureContext: metadata?.captureContext,
                    pasteboardTypeIdentifiers: metadata?.pasteboardTypeIdentifiers ?? [],
                    capturedAt: metadata?.capturedAt ?? Date()
                )
            }
            let detection = review.receipt.detections.max { lhs, rhs in
                Self.sensitivityConfidence(lhs.confidence)
                    < Self.sensitivityConfidence(rhs.confidence)
            }
            let classifiedCandidate = CaptureCandidate(
                content: candidate.content,
                sourceApplicationBundleIdentifier: candidate.sourceApplicationBundleIdentifier,
                originatingDeviceIdentifier: candidate.originatingDeviceIdentifier,
                captureContext: candidate.captureContext,
                sensitivity: try detection.map {
                    try ClipSensitivityMetadata(
                        category: $0.category.rawValue,
                        confidence: Self.sensitivityConfidence($0.confidence),
                        detectorVersion: 1
                    )
                },
                pasteboardTypeIdentifiers: candidate.pasteboardTypeIdentifiers,
                capturedAt: candidate.capturedAt
            )
            _ = try await library.capture(classifiedCandidate)
            _ = await self.quarantineStore.delete(id: id)
            self.quarantineMetadata.removeValue(forKey: id)
            try await self.refreshSnapshot()
            await self.refreshClipboardHealth()
            self.statusMessage = "Kept in ordinary history by explicit choice."
        }
    }

    func deleteQuarantinedClip(id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.quarantineStore.delete(id: id)
            self.quarantineMetadata.removeValue(forKey: id)
            await self.refreshClipboardHealth()
            self.statusMessage = "Sensitive clip deleted from memory."
        }
    }

    func deleteAllQuarantinedClips() {
        let ids = quarantineReceipts.map(\.id)
        deleteQuarantinedClips(ids: ids)
    }

    func deleteQuarantinedClips(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let confirmedIDs = Set(ids)
        perform {
            for id in confirmedIDs {
                _ = await self.quarantineStore.delete(id: id)
                self.quarantineMetadata.removeValue(forKey: id)
            }
            await self.refreshClipboardHealth()
            self.statusMessage = "Deleted \(confirmedIDs.count) sensitive clip\(confirmedIDs.count == 1 ? "" : "s") from memory."
        }
    }

    func moveAllEligibleQuarantinedClipsToVault() {
        guard let vaultLibrary else {
            errorMessage = vaultAvailabilityMessage ?? "Vault is unavailable in this build."
            return
        }
        let ids = quarantineReceipts.map(\.id)
        guard !ids.isEmpty else { return }
        perform {
            if !(await self.vaultSession.isUnlocked) {
                try await self.unlockVaultNow()
            }
            var moved = 0
            var skipped = 0
            var failed = 0
            for id in ids {
                guard let review = await self.quarantineStore.review(id: id) else { continue }
                if let draft = self.quarantineMetadata[id]?.draft,
                   draft.richTextData != nil || draft.htmlData != nil || draft.image != nil
                       || !draft.fileURLs.isEmpty
                {
                    skipped += 1
                    continue
                }
                do {
                    let category = review.receipt.detections.first?.category.rawValue
                        ?? "Sensitive"
                    let item = try VaultItem(
                        id: review.id,
                        name: "Quarantined \(category)",
                        content: review.content,
                        createdAt: review.receipt.detectedAt,
                        modifiedAt: review.receipt.detectedAt
                    )
                    try await self.commitQuarantinedVaultItem(item, to: vaultLibrary)
                    _ = await self.quarantineStore.delete(id: id)
                    self.quarantineMetadata.removeValue(forKey: id)
                    moved += 1
                } catch {
                    failed += 1
                }
            }
            await self.refreshClipboardHealth()
            try await self.refreshVaultSummaries()
            let remaining = skipped + failed
            self.statusMessage = remaining == 0
                ? "Moved \(moved) sensitive clip\(moved == 1 ? "" : "s") to encrypted Vault."
                : "Moved \(moved) to Vault; left \(remaining) clip\(remaining == 1 ? "" : "s") for individual review (\(skipped) unsupported, \(failed) failed)."
        }
    }

    func moveQuarantinedClipToVault(id: UUID) {
        guard let vaultLibrary else {
            errorMessage = vaultAvailabilityMessage ?? "Vault is unavailable in this build."
            return
        }
        perform {
            guard let review = await self.quarantineStore.review(id: id) else { return }
            if let draft = self.quarantineMetadata[id]?.draft,
               draft.richTextData != nil || draft.htmlData != nil || draft.image != nil
                    || !draft.fileURLs.isEmpty
            {
                throw VaultError.unsupportedExternalRepresentations
            }
            if !(await self.vaultSession.isUnlocked) {
                try await self.unlockVaultNow()
            }
            let category = review.receipt.detections.first?.category.rawValue ?? "Sensitive"
            let item = try VaultItem(
                id: review.id,
                name: "Quarantined \(category)",
                content: review.content,
                createdAt: review.receipt.detectedAt,
                modifiedAt: review.receipt.detectedAt
            )
            try await self.commitQuarantinedVaultItem(item, to: vaultLibrary)
            _ = await self.quarantineStore.delete(id: id)
            self.quarantineMetadata.removeValue(forKey: id)
            await self.refreshClipboardHealth()
            try await self.refreshVaultSummaries()
            if self.pendingEncryptedShareRequest?.quarantineID == id {
                self.pendingEncryptedShareRequest = nil
                self.encryptedShareEnvelope = nil
            }
            self.statusMessage = "Sensitive clip moved from memory to encrypted Vault."
        }
    }

    /// Crash-safe retry boundary for quarantine moves. If the encrypted item was durably added
    /// before the process stopped, an exact authenticated match completes the pending deletion;
    /// an ID collision with different content still fails closed.
    private func commitQuarantinedVaultItem(
        _ item: VaultItem,
        to vaultLibrary: VaultLibrary
    ) async throws {
        do {
            _ = try await vaultLibrary.add(item)
        } catch let error as VaultError {
            guard case .duplicateItem = error,
                  let existing = try await vaultLibrary.existingItem(id: item.id),
                  existing == item
            else { throw error }
        }
    }

    // MARK: - Private Session

    func startPrivateSession() {
        guard !isPrivateSessionActive, !isStartingPrivateSession else { return }
        isStartingPrivateSession = true
        statusMessage = "Starting Private Session…"
        Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            if self.isTextExpansionEnabled {
                self.textExpansionController.stop(status: .blocked("Unavailable during Private Session."))
                self.textExpansionStatus = self.textExpansionController.status
            }
            await self.privateSession.begin()
            self.privateSessionGeneration &+= 1
            self.privateSessionClips = []
            self.isPrivateSessionActive = true
            self.isStartingPrivateSession = false
            self.refreshTextExpansionState()
            self.selectLibrarySection(.privateSession)
            self.statusMessage = "Private Session started. New clips stay only in memory."
        }
    }

    func endPrivateSession() {
        guard isPrivateSessionActive else { return }
        let endedGeneration = privateSessionGeneration
        let quarantinedIDs = Set(
            quarantineMetadata.compactMap { id, metadata in
                metadata.privateSessionGeneration == endedGeneration ? id : nil
            }
        )
        isPrivateSessionActive = false
        refreshTextExpansionState()
        privateSessionGeneration &+= 1
        privateSessionClips = []
        quarantineMetadata = quarantineMetadata.filter { !quarantinedIDs.contains($0.key) }
        quarantineReceipts.removeAll { quarantinedIDs.contains($0.id) }
        clipboardHealth = ClipboardHealth.summarize(quarantineReceipts)
        if selectedSection == .privateSession { selectedSection = .history }
        Task { [weak self] in
            guard let self else { return }
            await self.privateSession.end()
            for id in quarantinedIDs {
                _ = await self.quarantineStore.delete(id: id)
            }
            await self.refreshClipboardHealth()
        }
        statusMessage = "Private Session ended and its in-memory clips were cleared."
    }

    // MARK: - Combine Clips, Paste Stack, and safe transforms

    func addToCombinedClips(_ clip: PresentedClip) {
        guard !isBusy else {
            errorMessage = AppModelOperationError.operationInProgress.localizedDescription
            return
        }
        guard let current = currentOrdinaryPresentedClip(matching: clip),
              current.sensitivity == nil,
              !secretDetector.scan(current.content).containsSecret
        else {
            errorMessage = "Private, sensitive, or changed items cannot be combined."
            return
        }
        do {
            var pack: ContextPack
            if let combinedClips {
                pack = combinedClips
            } else {
                pack = try ContextPack(name: "Combined Clips")
            }
            let item = try ContextPackItem(
                id: current.id,
                title: current.title,
                textRepresentation: current.content.searchableText,
                capturedAt: current.date,
                sourceApplication: current.captureContext?.sourceApplicationName
                    ?? current.sourceBundleIdentifier,
                sourceURL: current.captureContext?.sourceURL.flatMap(URL.init(string:)),
                metadata: [
                    "Content type": current.content.type.rawValue,
                    "Approximate size": "\(current.content.estimatedStorageByteCount) bytes",
                ]
            )
            try pack.append(item)
            combinedClips = pack
            statusMessage = "Added to Combine Clips."
        } catch ContextPackError.duplicateItem {
            statusMessage = "That clip is already in Combine Clips."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeFromCombinedClips(itemID: UUID) {
        guard !isBusy else {
            errorMessage = AppModelOperationError.operationInProgress.localizedDescription
            return
        }
        guard var pack = combinedClips else { return }
        _ = pack.remove(itemID: itemID)
        combinedClips = pack.items.isEmpty ? nil : pack
        if pendingCombinedClipsReview?.pack.id == pack.id {
            pendingCombinedClipsReview = nil
        }
    }

    func clearCombinedClips() {
        guard !isBusy else {
            errorMessage = AppModelOperationError.operationInProgress.localizedDescription
            return
        }
        combinedClips = nil
        pendingCombinedClipsReview = nil
    }

    func prepareCombinedClipsReview() {
        do {
            guard let pack = combinedClips else {
                throw AppModelOperationError.combinedClipsUnavailable
            }
            _ = try currentCombinedClipsPack(matching: pack)
            pendingCombinedClipsReview = CombinedClipsReviewRequest(pack: pack)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissCombinedClipsReview() {
        pendingCombinedClipsReview = nil
    }

    func combinedClipsMarkdown(for request: CombinedClipsReviewRequest) -> String? {
        do {
            return try currentCombinedClipsPack(matching: request.pack).renderMarkdown()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func copyCombinedClips(_ request: CombinedClipsReviewRequest) {
        do {
            let rendered = try currentCombinedClipsPack(matching: request.pack).renderMarkdown()
            let content = try ClipContent(type: .plainText, text: rendered)
            enqueueClipboardAction {
                guard let validation = try? await self.freshCombinedClipsValidation(
                    matching: request.pack
                ), try validation.pack.renderMarkdown() == rendered
                else {
                    throw AppModelOperationError.combinedClipsChanged
                }
                try await self.typedPasteboardWriter.write(content, mode: .plainText)
                self.statusMessage = "Combined clips copied as Markdown."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveCombinedClipsAsNote(_ request: CombinedClipsReviewRequest) async -> Bool {
        guard let library, !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let validation = try await freshCombinedClipsValidation(matching: request.pack)
            let body = try validation.pack.renderMarkdown()
            let note = try await library.createNote(
                title: "Combined Clips",
                body: body,
                folderID: nil,
                expectingCombinedClips: validation.expectations
            )
            try await refreshSnapshot()
            let organized = try await applyAlwaysRulesAfterLocalSave(note.id) ?? note
            await recordSavedClipForSync(organized)
            scheduleBackgroundSavedLibrarySync()
            selectedSection = .smartView(.notes)
            selectedClipID = note.id
            pendingCombinedClipsReview = nil
            statusMessage = "Combined clips saved to My Notes."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func shareCombinedClips(_ request: CombinedClipsReviewRequest) {
        Task { @MainActor in
            do {
                let validation = try await freshCombinedClipsValidation(matching: request.pack)
                let rendered = try validation.pack.renderMarkdown()
                guard let view = NSApp.keyWindow?.contentView else {
                    throw AppModelOperationError.libraryUnavailable
                }
                let picker = NSSharingServicePicker(items: [rendered])
                picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    var activeDeveloperProject: DeveloperProject? {
        developerWorkspaceSnapshot.activeProjectID.flatMap { id in
            developerWorkspaceSnapshot.projects.first { $0.id == id && !$0.isArchived }
        }
    }

    var selectedDeveloperProject: DeveloperProject? {
        let id = selectedDeveloperProjectID ?? developerWorkspaceSnapshot.activeProjectID
        return id.flatMap { projectID in
            developerWorkspaceSnapshot.projects.first { $0.id == projectID && !$0.isArchived }
        }
    }

    var developerProjects: [DeveloperProject] {
        developerWorkspaceSnapshot.projects
            .filter { !$0.isArchived }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    var developerTeamDestinations: [FolderDestination] {
        folderDestinations.filter { destination in
            guard destination.canAcceptItems,
                  let rootID = sharedRootID(containing: destination.id)
            else { return false }
            return sharedFolderSnapshots[rootID]?.currentRole.canEditClips == true
        }
    }

    var bundledCommandLineToolVersion: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/cr.version")
        guard let data = try? Data(contentsOf: url), data.count <= 128,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    func exportBundledCommandLineTool() {
        guard canExportBundledCommandLineTool else {
            errorMessage = "The cr command is available only in the direct-download edition."
            return
        }
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cr")
        guard let values = try? source.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey,
        ]), values.isRegularFile == true, values.isSymbolicLink != true,
              values.isExecutable == true
        else {
            errorMessage = "The signed cr command is available in the packaged desktop app. Build and verify the app before exporting it."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export the cr Command"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "cr"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            guard let existing = try? destination.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ]), existing.isRegularFile == true, existing.isSymbolicLink != true else {
                errorMessage = "The selected destination is not a replaceable regular file."
                return
            }
            let confirmation = NSAlert()
            confirmation.messageText = "Replace the existing cr command?"
            confirmation.informativeText = destination.path
            confirmation.alertStyle = .warning
            confirmation.addButton(withTitle: "Replace")
            confirmation.addButton(withTitle: "Cancel")
            guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        }

        let staging = destination.deletingLastPathComponent().appendingPathComponent(
            ".cr-export-\(UUID().uuidString)"
        )
        do {
            try fileManager.copyItem(at: source, to: staging)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
            statusMessage = "Exported cr to \(destination.path). Clipboard Router did not modify PATH."
        } catch {
            try? fileManager.removeItem(at: staging)
            errorMessage = "The cr command could not be exported: \(error.localizedDescription)"
        }
    }

    func createDeveloperProject(name: String, repositoryRootURL: URL) async -> Bool {
        guard let developerWorkspace, !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let grant = try projectRootAccess.grant(forExplicitlySelectedURL: repositoryRootURL)
            let session = try projectRootAccess.open(grant)
            defer { session.close() }
            let inspection = try repositoryInspector.inspect(session)
            let canonicalPath = session.url.standardizedFileURL.path(percentEncoded: false)
            let fingerprint = SHA256.hash(data: Data(canonicalPath.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let repository = try DeveloperRepositoryReference(
                displayName: inspection.projectName,
                securityScopedBookmark: grant.bookmarkData,
                canonicalPathFingerprint: fingerprint,
                branch: inspection.branchLabel
            )
            let project = try await developerWorkspace.createProject(
                name: name,
                repository: repository,
                activate: false
            )
            developerWorkspaceSnapshot = await developerWorkspace.snapshot()
            selectedDeveloperProjectID = project.id
            try await refreshDeveloperTimeline()
            selectedSection = .developerProjects
            statusMessage = "Created \(project.name). Choose Make Active when you are ready."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func selectDeveloperProject(_ id: UUID?) {
        selectedDeveloperProjectID = id
        Task { [weak self] in try? await self?.refreshDeveloperTimeline() }
    }

    func setActiveDeveloperProject(_ id: UUID?) {
        guard let developerWorkspace else {
            errorMessage = "Developer Projects are not available."
            return
        }
        guard !isBusy else {
            statusMessage = "Please wait for the current project change to finish."
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isBusy = true
            defer { self.isBusy = false }
            do {
                try await developerWorkspace.setActiveProject(id)
                self.developerWorkspaceSnapshot = await developerWorkspace.snapshot()
                if let id { self.selectedDeveloperProjectID = id }
                try await self.refreshDeveloperTimeline()
                self.statusMessage = id == nil
                    ? "Developer capture is no longer assigned to a project."
                    : "Active Project changed."
            } catch { self.errorMessage = error.localizedDescription }
        }
    }

    func setDeveloperAutoCapture(_ enabled: Bool, for projectID: UUID) {
        guard let developerWorkspace, !isBusy else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isBusy = true
            defer { self.isBusy = false }
            do {
                _ = try await developerWorkspace.updateSettings(
                    projectID: projectID,
                    autoAddDeveloperClips: enabled
                )
                self.developerWorkspaceSnapshot = await developerWorkspace.snapshot()
                if !enabled {
                    self.statusMessage = "Automatic project capture is off."
                } else if self.developerWorkspaceSnapshot.activeProjectID == projectID {
                    self.statusMessage = "Developer clips from approved apps will be added to this Active Project."
                } else {
                    self.statusMessage = "Auto-add is configured and will start when this project is Active."
                }
            } catch { self.errorMessage = error.localizedDescription }
        }
    }

    func setDeveloperSourceApplication(
        _ bundleIdentifier: String,
        allowed: Bool,
        for projectID: UUID
    ) {
        guard let developerWorkspace else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await developerWorkspace.setSourceApplication(
                    projectID: projectID,
                    bundleIdentifier: bundleIdentifier,
                    allowed: allowed
                )
                self.developerWorkspaceSnapshot = await developerWorkspace.snapshot()
                self.statusMessage = allowed
                    ? "Added an approved capture source."
                    : "Removed an approved capture source."
            } catch { self.errorMessage = error.localizedDescription }
        }
    }

    func renameDeveloperProject(id: UUID, name: String) async -> Bool {
        guard let developerWorkspace, !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await developerWorkspace.renameProject(id: id, name: name)
            developerWorkspaceSnapshot = await developerWorkspace.snapshot()
            statusMessage = "Project renamed."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func archiveDeveloperProject(id: UUID) {
        guard let developerWorkspace, !isBusy else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isBusy = true
            defer { self.isBusy = false }
            do {
                _ = try await developerWorkspace.archiveProject(id: id)
                self.developerWorkspaceSnapshot = await developerWorkspace.snapshot()
                self.selectedDeveloperProjectID = self.developerWorkspaceSnapshot.activeProjectID
                    ?? self.developerProjects.first?.id
                try await self.refreshDeveloperTimeline()
                self.statusMessage = "Project archived."
            } catch { self.errorMessage = error.localizedDescription }
        }
    }

    func canAddToDeveloperProject(_ clip: PresentedClip) -> Bool {
        guard let current = currentOrdinaryPresentedClip(matching: clip),
              current.sensitivity == nil,
              !secretDetector.scan(current.content).containsSecret
        else { return false }
        return true
    }

    func addToDeveloperProject(_ clip: PresentedClip, projectID: UUID) {
        guard let project = developerProjects.first(where: { $0.id == projectID }),
              let developerWorkspace,
              let current = currentOrdinaryPresentedClip(matching: clip),
              current.sensitivity == nil,
              !secretDetector.scan(current.content).containsSecret
        else {
            errorMessage = developerProjects.contains(where: { $0.id == projectID })
                ? "Private, sensitive, or changed items cannot enter a Developer Project."
                : "That project is no longer available."
            return
        }
        let reference: DeveloperClipReference
        switch current.origin {
        case .history: reference = .history(current.id)
        case .saved: reference = .saved(current.id)
        case .privateSession: return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await developerWorkspace.addMembership(
                    projectID: project.id,
                    clip: reference
                )
                self.developerWorkspaceSnapshot = await developerWorkspace.snapshot()
                if self.selectedDeveloperProjectID == project.id {
                    try await self.refreshDeveloperTimeline()
                }
                self.statusMessage = "Added to \(project.name)."
            } catch { self.errorMessage = error.localizedDescription }
        }
    }

    func addToActiveDeveloperProject(_ clip: PresentedClip) {
        guard let project = activeDeveloperProject else {
            errorMessage = "Choose a project or create a new one."
            return
        }
        addToDeveloperProject(clip, projectID: project.id)
    }

    func developerClip(for reference: DeveloperClipReference) -> PresentedClip? {
        switch reference {
        case let .history(id):
            guard let item = snapshot.history.first(where: { $0.id == id }) else { return nil }
            return PresentedClip(
                id: item.id,
                title: Self.previewTitle(for: item.content),
                content: item.content,
                date: item.lastCapturedAt,
                sourceBundleIdentifier: item.sourceApplicationBundleIdentifier,
                origin: .history,
                captureContext: item.captureContext,
                sensitivity: item.sensitivity,
                pasteboardTypeIdentifiers: item.pasteboardTypeIdentifiers ?? [],
                captureCount: item.captureCount,
                pasteCount: item.pasteCount,
                lastPastedAt: item.lastPastedAt
            )
        case let .saved(id):
            return currentSavedPresentedClip(id: id)
        }
    }

    func persistDebugBundle(
        _ request: DeveloperDebugBundleReviewRequest,
        projectID: UUID,
        projectDisplayName: String,
        problemStatement: String
    ) async -> Bool {
        guard let developerWorkspace,
              let project = developerWorkspaceSnapshot.projects.first(where: {
                  $0.id == projectID && !$0.isArchived
              }),
              !isBusy
        else {
            errorMessage = "Choose an available destination project before saving this Debug Bundle."
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let validation = try await freshDebugBundleValidation(matching: request.pack)
            let review = try reviewedDebugBundle(
                request: request,
                pack: validation.pack,
                projectDisplayName: projectDisplayName,
                problemStatement: problemStatement
            )
            _ = try await developerWorkspace.saveDebugBundle(
                projectID: project.id,
                bundle: review.bundle
            )
            developerWorkspaceSnapshot = await developerWorkspace.snapshot()
            try await refreshDeveloperTimeline()
            statusMessage = "Debug Bundle saved to \(project.name)."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func publishDebugBundleToTeam(
        _ request: DeveloperDebugBundleReviewRequest,
        projectDisplayName: String,
        problemStatement: String,
        folderID: UUID
    ) async -> Bool {
        guard developerTeamDestinations.contains(where: { $0.id == folderID }),
              let rootID = sharedRootID(containing: folderID),
              sharedFolderSessions[rootID] != nil,
              let library,
              !isBusy
        else {
            errorMessage = "Choose an editable shared folder."
            return false
        }
        isBusy = true
        defer { isBusy = false }
        var isSavedLocally = false
        do {
            let validation = try await freshDebugBundleValidation(matching: request.pack)
            let review = try reviewedDebugBundle(
                request: request,
                pack: validation.pack,
                projectDisplayName: projectDisplayName,
                problemStatement: problemStatement
            )
            let publication = try SharedDebugBundlePublication(
                sanitizing: review.bundle,
                includeBranch: false,
                publishedAt: request.generatedAt
            )
            // Publish through the existing Saved Note record understood by every V2 client.
            // The dedicated Debug Bundle record remains reserved for a future versioned zone.
            let outgoingText = Self.sharedDebugBundleNoteBody(publication)
            let outgoingContent = try ClipContent(type: .plainText, text: outgoingText)
            guard !secretDetector.scan(outgoingContent).containsSecret else {
                throw AppModelOperationError.generatedSensitiveContent
            }
            let noteTitle = "Debug Bundle — \(publication.projectName)"
            let before = await library.snapshot()
            let untaggedNote = if let existing = before.savedClips.first(where: {
                $0.kind == .note
                    && $0.folderID == folderID
                    && $0.name == noteTitle
                    && $0.content.text == outgoingText
            }) {
                existing
            } else {
                try await library.createNote(
                    title: noteTitle,
                    body: outgoingText,
                    folderID: folderID,
                    expectingCombinedClips: validation.expectations,
                    at: publication.publishedAt
                )
            }
            let note = try await library.replaceTags(
                for: untaggedNote.id,
                with: (untaggedNote.tags ?? []) + [Self.sharedDebugBundleTag],
                expecting: SavedClipEditExpectation(
                    name: untaggedNote.name,
                    modifiedAt: untaggedNote.modifiedAt,
                    folderID: untaggedNote.folderID,
                    contentFingerprint: untaggedNote.content.deduplicationFingerprint
                ),
                at: publication.publishedAt
            )
            isSavedLocally = true
            let local = await library.snapshot()
            let rootFolder = local.folders.first(where: { $0.id == rootID })
            let subtree = Self.localSharedSubtree(rootID: rootID, in: local)
            guard let session = sharedFolderSessions[rootID] else {
                throw SharedFolderError.cloudFailure("The shared workspace is no longer open")
            }
            let refreshed = try await session.synchronizeLocal(
                folder: rootFolder,
                folders: subtree.folders,
                savedClips: subtree.savedItems
            )
            guard refreshed.managedSavedClipIDs.contains(note.id),
                  refreshed.savedClips.contains(note)
            else { throw SharedFolderError.invalidRecord(note.id) }
            sharedFolderSnapshots[rootID] = refreshed
            await acknowledgeSharedFolderMutations(
                from: local,
                controlledFolderIDs: refreshed.managedFolderIDs,
                controlledClipIDs: refreshed.managedSavedClipIDs
            )
            try await refreshSnapshot()
            try persistSharedFolderLocations()
            pendingDebugBundleReview = nil
            statusMessage = "Sanitized Debug Bundle published for team review."
            return true
        } catch {
            if isSavedLocally {
                try? await refreshSnapshot()
            }
            errorMessage = isSavedLocally
                ? "The Debug Bundle is saved locally, but team publishing is still pending. \(error.localizedDescription)"
                : error.localizedDescription
            return false
        }
    }

    func openDeveloperProjectInIDE(
        _ project: DeveloperProject,
        application: ApplicationExclusionOption
    ) {
        guard let repository = project.repository else {
            errorMessage = "This project has no selected repository folder."
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let grant = try ProjectRootAccessGrant(
                    bookmarkData: repository.securityScopedBookmark,
                    rootLabel: repository.displayName
                )
                let session = try self.projectRootAccess.open(grant)
                defer { session.close() }
                let selection = try IDEApplicationSelection(
                    displayName: application.displayName,
                    bundleIdentifier: application.bundleIdentifier,
                    teamIdentifier: application.teamIdentifier,
                    applicationURL: application.applicationURL
                )
                try await self.ideHandoff.open(project: session, in: selection)
                if let developerWorkspace = self.developerWorkspace {
                    _ = try await developerWorkspace.updateSettings(
                        projectID: project.id,
                        preferredIDEBundleIdentifier: application.bundleIdentifier
                    )
                    self.developerWorkspaceSnapshot = await developerWorkspace.snapshot()
                }
                self.statusMessage = "Opened \(project.name) in \(application.displayName)."
            } catch { self.errorMessage = error.localizedDescription }
        }
    }

    private func refreshDeveloperTimeline() async throws {
        guard let developerWorkspace, let projectID = selectedDeveloperProjectID else {
            developerTimeline = []
            return
        }
        let timeline = try await developerWorkspace.timeline(projectID: projectID, limit: 250)
        guard selectedDeveloperProjectID == projectID else { return }
        developerTimeline = timeline
    }

    private func autoAddDeveloperCapture(
        _ outcome: CaptureOutcome,
        candidate: CaptureCandidate,
        observedProjectID: UUID?
    ) async {
        guard let developerWorkspace,
              let observedProjectID,
              let project = developerWorkspaceSnapshot.projects.first(where: {
                  $0.id == observedProjectID && !$0.isArchived
              }),
              candidate.sensitivity == nil,
              !secretDetector.scan(candidate.content).containsSecret
        else { return }
        let analysis = DeveloperContentRecognizer().analyze(candidate.content.searchableText)
        guard analysis.kind != .plainText else { return }
        let item: HistoryItem
        switch outcome {
        case let .inserted(value), let .refreshedDuplicate(value): item = value
        case .ignored: return
        }
        do {
            _ = try await developerWorkspace.addMembership(
                projectID: project.id,
                clip: .history(item.id),
                at: candidate.capturedAt
            )
            developerWorkspaceSnapshot = await developerWorkspace.snapshot()
            if selectedDeveloperProjectID == project.id {
                try await refreshDeveloperTimeline()
            }
        } catch {
            // The ordinary capture has already succeeded; project attribution is secondary.
            statusMessage = "Clip captured, but it could not be added to \(project.name)."
        }
    }

    private static func sharedDebugBundleNoteBody(
        _ publication: SharedDebugBundlePublication
    ) -> String {
        var sections = [
            "Debug Bundle",
            "Project: \(publication.projectName)",
            "Published: \(publication.publishedAt.formatted(.iso8601))",
        ]
        if let problem = publication.problemStatement {
            sections.append("Problem:\n\(problem)")
        }
        for (index, item) in publication.items.enumerated() {
            var heading = "Item \(index + 1): \(item.title)\nType: \(item.kind.rawValue)"
            if let language = item.languageHint {
                heading += "\nLanguage: \(language)"
            }
            sections.append("\(heading)\n\n\(item.content)")
        }
        return sections.joined(separator: "\n\n")
    }

    private func automaticDeveloperProjectID(
        sourceBundleIdentifier: String?
    ) -> UUID? {
        guard let project = activeDeveloperProject,
              project.autoAddDeveloperClips,
              let sourceBundleIdentifier,
              project.allowedSourceBundleIdentifiers.contains(sourceBundleIdentifier)
        else { return nil }
        return project.id
    }

    func addToDebugBundle(_ clip: PresentedClip) {
        guard !isBusy else {
            errorMessage = AppModelOperationError.operationInProgress.localizedDescription
            return
        }
        guard let current = currentOrdinaryPresentedClip(matching: clip),
              current.sensitivity == nil,
              !secretDetector.scan(current.content).containsSecret
        else {
            errorMessage = "Private, sensitive, or changed items cannot enter a Debug Bundle."
            return
        }
        do {
            var pack = try debugBundlePack ?? ContextPack(name: "Untitled Project")
            let item = try ContextPackItem(
                id: current.id,
                title: current.title,
                textRepresentation: current.content.searchableText,
                capturedAt: current.date,
                sourceApplication: current.captureContext?.sourceApplicationName
                    ?? current.sourceBundleIdentifier,
                sourceURL: current.captureContext?.sourceURL.flatMap(URL.init(string:)),
                metadata: [
                    "Content type": current.content.type.rawValue,
                    "Approximate size": "\(current.content.estimatedStorageByteCount) bytes",
                ]
            )
            try pack.append(item)
            debugBundlePack = pack
            statusMessage = "Added to Debug Bundle."
        } catch ContextPackError.duplicateItem {
            statusMessage = "That clip is already in the Debug Bundle."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeFromDebugBundle(itemID: UUID) {
        guard var pack = debugBundlePack else { return }
        _ = pack.remove(itemID: itemID)
        debugBundlePack = pack.items.isEmpty ? nil : pack
        if pendingDebugBundleReview?.pack.id == pack.id {
            pendingDebugBundleReview = nil
        }
    }

    /// Reorders one draft item by a single position. Stale IDs, unsupported offsets, and
    /// boundary moves fail closed before the published pack or pending review is changed.
    @discardableResult
    func moveDebugBundleItem(itemID: UUID, offset: Int) -> Bool {
        guard !isBusy,
              offset == -1 || offset == 1,
              var pack = debugBundlePack,
              let sourceIndex = pack.items.firstIndex(where: { $0.id == itemID })
        else { return false }
        let destinationIndex = sourceIndex + offset
        guard pack.items.indices.contains(destinationIndex) else { return false }

        do {
            try pack.move(from: sourceIndex, to: destinationIndex)
            debugBundlePack = pack
            if pendingDebugBundleReview?.pack.id == pack.id {
                pendingDebugBundleReview = nil
            }
            statusMessage = offset < 0
                ? "Moved Debug Bundle item earlier."
                : "Moved Debug Bundle item later."
            return true
        } catch {
            // ContextPack validates indices before mutation. Preserve the last valid draft.
            return false
        }
    }

    func clearDebugBundle() {
        guard !isBusy else { return }
        debugBundlePack = nil
        pendingDebugBundleReview = nil
    }

    func prepareDebugBundleReview() {
        do {
            guard let pack = debugBundlePack else {
                throw AppModelOperationError.debugBundleUnavailable
            }
            _ = try debugBundlePack(matching: pack, in: snapshot)
            pendingDebugBundleReview = DeveloperDebugBundleReviewRequest(pack: pack)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissDebugBundleReview() {
        pendingDebugBundleReview = nil
    }

    func debugBundleReview(
        for request: DeveloperDebugBundleReviewRequest,
        projectDisplayName: String,
        problemStatement: String
    ) -> DeveloperDebugBundleReview? {
        do {
            let pack = try debugBundlePack(matching: request.pack, in: snapshot)
            return try reviewedDebugBundle(
                request: request,
                pack: pack,
                projectDisplayName: projectDisplayName,
                problemStatement: problemStatement
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func copyDebugBundle(
        _ request: DeveloperDebugBundleReviewRequest,
        projectDisplayName: String,
        problemStatement: String
    ) {
        do {
            let initial = try reviewedDebugBundle(
                request: request,
                pack: try debugBundlePack(matching: request.pack, in: snapshot),
                projectDisplayName: projectDisplayName,
                problemStatement: problemStatement
            )
            let content = try ClipContent(type: .plainText, text: initial.markdown)
            enqueueClipboardAction {
                let validation = try await self.freshDebugBundleValidation(matching: request.pack)
                let current = try self.reviewedDebugBundle(
                    request: request,
                    pack: validation.pack,
                    projectDisplayName: projectDisplayName,
                    problemStatement: problemStatement
                )
                guard current.markdown == initial.markdown else {
                    throw AppModelOperationError.debugBundleChanged
                }
                try await self.typedPasteboardWriter.write(content, mode: .plainText)
                self.statusMessage = "Debug Bundle copied as Markdown."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveDebugBundleAsNote(
        _ request: DeveloperDebugBundleReviewRequest,
        projectDisplayName: String,
        problemStatement: String
    ) async -> Bool {
        guard let library, !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let validation = try await freshDebugBundleValidation(matching: request.pack)
            let review = try reviewedDebugBundle(
                request: request,
                pack: validation.pack,
                projectDisplayName: projectDisplayName,
                problemStatement: problemStatement
            )
            let note = try await library.createNote(
                title: "Debug Bundle — \(review.bundle.project.name)",
                body: review.markdown,
                folderID: nil,
                expectingCombinedClips: validation.expectations
            )
            try await refreshSnapshot()
            let organized = try await applyAlwaysRulesAfterLocalSave(note.id) ?? note
            await recordSavedClipForSync(organized)
            scheduleBackgroundSavedLibrarySync()
            selectedSection = .smartView(.notes)
            selectedClipID = note.id
            pendingDebugBundleReview = nil
            statusMessage = "Debug Bundle saved to My Notes."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func shareDebugBundle(
        _ request: DeveloperDebugBundleReviewRequest,
        projectDisplayName: String,
        problemStatement: String
    ) {
        Task { @MainActor in
            do {
                let validation = try await freshDebugBundleValidation(matching: request.pack)
                let review = try reviewedDebugBundle(
                    request: request,
                    pack: validation.pack,
                    projectDisplayName: projectDisplayName,
                    problemStatement: problemStatement
                )
                guard let view = NSApp.keyWindow?.contentView else {
                    throw AppModelOperationError.libraryUnavailable
                }
                NSSharingServicePicker(items: [review.markdown])
                    .show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func addToPasteStack(_ clip: PresentedClip) {
        guard let current = currentOrdinaryPresentedClip(matching: clip),
              current.sensitivity == nil,
              !secretDetector.scan(current.content).containsSecret
        else {
            errorMessage = "Private, sensitive, or changed items cannot enter Paste Stack."
            return
        }
        do {
            try pasteStack.enqueue(PasteStackEntry(payload: current))
            publishPasteStackState()
            statusMessage = "Added to Paste Stack."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyNextPasteStackItem() {
        guard !isPasteStackWriteInFlight else {
            statusMessage = "A Paste Stack clipboard write is already in progress."
            return
        }
        guard let attempt = pasteStack.next(action: .copy) else {
            statusMessage = pasteStackItems.isEmpty ? "Paste Stack is empty." : "Paste Stack complete."
            return
        }
        isPasteStackWriteInFlight = true
        enqueueClipboardAction {
            defer { self.isPasteStackWriteInFlight = false }
            do {
                try await self.typedPasteboardWriter.write(
                    attempt.entry.payload.content,
                    mode: .original,
                    sourceTypeIdentifiers: attempt.entry.payload.pasteboardTypeIdentifiers
                )
                _ = try self.pasteStack.confirm(attemptID: attempt.id, outcome: .succeeded)
                self.publishPasteStackState()
                self.statusMessage = "Copied. Paste Stack advanced after confirmed clipboard write."
            } catch {
                _ = try? self.pasteStack.confirm(attemptID: attempt.id, outcome: .failed)
                self.publishPasteStackState()
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func previousPasteStackItem() {
        guard !isPasteStackWriteInFlight else {
            statusMessage = "Wait for the current Paste Stack clipboard write to finish."
            return
        }
        _ = pasteStack.previous()
        publishPasteStackState()
    }

    func skipPasteStackItem() {
        guard !isPasteStackWriteInFlight else {
            statusMessage = "Wait for the current Paste Stack clipboard write to finish."
            return
        }
        _ = pasteStack.skip()
        publishPasteStackState()
    }

    func restartPasteStack() {
        guard !isPasteStackWriteInFlight else {
            statusMessage = "Wait for the current Paste Stack clipboard write to finish."
            return
        }
        _ = pasteStack.restart()
        publishPasteStackState()
    }

    func clearPasteStack() {
        guard !isPasteStackWriteInFlight else {
            statusMessage = "Wait for the current Paste Stack clipboard write to finish."
            return
        }
        pasteStack.clear()
        publishPasteStackState()
    }

    func previewTransform(_ transform: SafeTextTransform, title: String, for clip: PresentedClip) {
        guard let current = currentOrdinaryPresentedClip(matching: clip),
              current.sensitivity == nil,
              !secretDetector.scan(current.content).containsSecret
        else {
            errorMessage = "Private, sensitive, or changed items cannot create transform previews."
            return
        }
        do {
            let transformedText = try SafeTextTransformer.apply(
                transform,
                to: current.content.text
            )
            guard !secretDetector.scan(text: transformedText).containsSecret else {
                errorMessage = "The transformed result contains a secret-like value and cannot be previewed or copied."
                return
            }
            transformPreview = TransformPreview(
                sourceClipID: current.id,
                title: title,
                transformedText: transformedText
            )
            selectLibrarySection(.workflows)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyTransformPreview() {
        guard let transformPreview else { return }
        guard !secretDetector.scan(text: transformPreview.transformedText).containsSecret else {
            errorMessage = "The transformed result contains a secret-like value and was not copied."
            return
        }
        let content: ClipContent
        do {
            content = try ClipContent(type: .plainText, text: transformPreview.transformedText)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        enqueueClipboardAction {
            guard !self.secretDetector.scan(text: content.text).containsSecret else {
                throw AppModelOperationError.generatedSensitiveContent
            }
            try await self.typedPasteboardWriter.write(content, mode: .plainText)
            self.statusMessage = "Transformed text copied. The original clip was not changed."
        }
    }

    func dismissTransformPreview() {
        transformPreview = nil
    }

    // MARK: - Export and system sharing

    func archiveSelection(for clip: PresentedClip) throws -> OrdinaryClipArchiveSelection {
        switch clip.origin {
        case .privateSession:
            throw AppModelOperationError.ordinaryClipRequired
        case .history:
            guard let history = snapshot.history.first(where: { $0.id == clip.id }) else {
                throw ClipboardLibraryError.historyItemNotFound(clip.id)
            }
            let exportClip = try SavedClip(
                id: history.id,
                name: clip.title,
                content: history.content,
                sourceHistoryItemID: history.id,
                createdAt: history.createdAt,
                modifiedAt: history.modifiedAt,
                sourceApplicationBundleIdentifier: history.sourceApplicationBundleIdentifier,
                originatingDeviceIdentifier: history.originatingDeviceIdentifier,
                captureContext: history.captureContext,
                originallyCapturedAt: history.createdAt,
                sensitivity: history.sensitivity,
                pasteboardTypeIdentifiers: history.pasteboardTypeIdentifiers ?? []
            )
            return OrdinaryClipArchiveSelection(clip: exportClip, folders: [])
        case .saved:
            guard let saved = snapshot.savedClips.first(where: { $0.id == clip.id }) else {
                throw ClipboardLibraryError.savedClipNotFound(clip.id)
            }
            let folders = saved.folderID
                .flatMap { folderID in snapshot.folders.first(where: { $0.id == folderID }) }
                .map { [$0] } ?? []
            return OrdinaryClipArchiveSelection(clip: saved, folders: folders)
        }
    }

    static func safeExportFilename(_ rawName: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
            .union(.controlCharacters)
        let sanitized = rawName.unicodeScalars.map { scalar in
            forbidden.contains(scalar) ? " " : String(scalar)
        }.joined()
        let collapsed = sanitized
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let bounded = String(collapsed.prefix(80))
        return bounded.isEmpty ? "Clip" : bounded
    }

    static func containsNonPortableLocalReference(_ content: ClipContent) -> Bool {
        let structuredURL = content.representations.url
            .flatMap { URL(string: $0.originalURL) }
        return content.type == .fileURLs
            || !content.representations.files.isEmpty
            || structuredURL?.isFileURL == true
    }

    func clipExportDecision(_ clip: PresentedClip) -> ClipExportDecision {
        guard clip.origin != .privateSession else {
            return .unavailable(
                reason: AppModelOperationError.ordinaryClipRequired.localizedDescription
            )
        }
        if Self.containsNonPortableLocalReference(clip.content) {
            return .unavailable(
                reason: AppModelOperationError.localFileArchiveUnsupported.localizedDescription
            )
        }
        let selection: OrdinaryClipArchiveSelection
        do {
            selection = try archiveSelection(for: clip)
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
        if let category = presentationSensitivityCategory(
            content: selection.clip.content,
            stored: selection.clip.sensitivity
        ) {
            return .requiresSensitiveConfirmation(category: category)
        }
        return .available
    }

    func exportOrdinaryClip(
        _ clip: PresentedClip,
        sensitiveContentConfirmed: Bool = false,
        confirmedSensitivityCategory: String? = nil
    ) {
        let selection: OrdinaryClipArchiveSelection
        do {
            if let confirmedSensitivityCategory {
                guard let current = currentOrdinaryPresentedClip(matching: clip),
                      sensitivityCategoryForPresentation(current) == confirmedSensitivityCategory
                else {
                    throw AppModelOperationError.sensitiveExportConfirmationRequired
                }
            }
            selection = try archiveSelection(for: clip)
            guard !Self.containsNonPortableLocalReference(selection.clip.content) else {
                throw AppModelOperationError.localFileArchiveUnsupported
            }
            if presentationSensitivityCategory(
                content: selection.clip.content,
                stored: selection.clip.sensitivity
            ) != nil, !sensitiveContentConfirmed {
                throw AppModelOperationError.sensitiveExportConfirmationRequired
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Clip"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "\(Self.safeExportFilename(selection.clip.name)).clipboardrouterarchive"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        perform {
            let manifest = try await self.archiveService.export(
                savedClips: [selection.clip],
                folders: selection.folders,
                to: destination,
                includeFlaggedSensitiveClipIDs: sensitiveContentConfirmed
                    ? [selection.clip.id]
                    : []
            )
            guard let exported = manifest.entries.first(where: { $0.id == selection.clip.id }) else {
                throw AppModelOperationError.clipArchiveOmitted
            }
            self.statusMessage = "Exported \(exported.name)."
        }
    }

    func exportSavedLibrary() {
        let panel = NSSavePanel()
        panel.title = "Export Saved Clips and Folders"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "Clipboard Library.clipboardrouterarchive"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let savedClips = snapshot.savedClips
        let folders = snapshot.folders
        perform {
            let manifest = try await self.archiveService.export(
                savedClips: savedClips,
                folders: folders,
                to: destination
            )
            let omissionSuffix = manifest.omissions.isEmpty
                ? ""
                : " \(manifest.omissions.count) portability note(s) are in the manifest."
            self.statusMessage = "Exported \(manifest.entries.count) saved clips.\(omissionSuffix)"
        }
    }

    func prepareFolderHandoff(folderID: UUID) {
        do {
            let projection = try FolderHandoffProjector().project(
                rootFolderID: folderID,
                snapshot: snapshot
            )
            pendingHandoffReview = HandoffReviewRequest(projection: projection)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissHandoffReview() {
        pendingHandoffReview = nil
    }

    func copyFolderBrief(_ projection: HandoffProjection) {
        do {
            let data = try MarkdownHandoffRenderer().render(projection)
            guard let markdown = String(data: data, encoding: .utf8) else {
                throw HandoffExportError.writeFailed("Markdown could not be decoded as UTF-8.")
            }
            let content = try ClipContent(type: .plainText, text: markdown)
            pendingHandoffReview = nil
            enqueueClipboardAction {
                try await self.typedPasteboardWriter.write(content, mode: .plainText)
                let suffix = projection.omissions.isEmpty
                    ? ""
                    : " \(projection.omissions.count) ineligible item(s) were disclosed in the brief."
                self.statusMessage = "Copied \(projection.records.count) research item(s) as Markdown.\(suffix)"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportFolderHandoff(_ projection: HandoffProjection, format: HandoffFormat) {
        let renderer: any HandoffRendering
        let pathExtension: String
        switch format {
        case .markdown:
            renderer = MarkdownHandoffRenderer()
            pathExtension = "md"
        case .csv:
            renderer = CSVHandoffRenderer()
            pathExtension = "csv"
        case .json:
            renderer = JSONHandoffRenderer()
            pathExtension = "json"
        }
        let data: Data
        do {
            data = try renderer.render(projection)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Research Handoff"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "\(Self.safeExportFilename(projection.rootFolderPath)).\(pathExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        pendingHandoffReview = nil
        perform {
            try HandoffFileWriter().write(data, to: destination)
            await self.recordMetric(ProductMetricEvent(
                anonymousInstallationID: self.metricsInstallationID,
                name: .researchHandoffExported,
                action: .export,
                eligibleItemCount: projection.records.count,
                omittedItemCount: projection.omissions.count
            ))
            let suffix = projection.omissions.isEmpty
                ? ""
                : " \(projection.omissions.count) item(s) were omitted and disclosed in the export."
            self.statusMessage = "Exported \(projection.records.count) research item(s).\(suffix)"
        }
    }

    func exportProductMetrics() {
        let panel = NSSavePanel()
        panel.title = "Export Content-Blind Pilot Metrics"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "Clipboard Router Pilot Metrics.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        perform {
            let data = try await self.metricsLedger.exportData()
            try data.write(to: destination, options: .atomic)
            self.statusMessage = "Exported content-blind pilot metrics."
        }
    }

    private func recordMetric(_ event: ProductMetricEvent) async {
        do {
            try await metricsLedger.record(event)
        } catch {
            // Product metrics never block clipboard work and are deliberately not sent anywhere.
        }
    }

    func liveLinkPreviewState(for clip: PresentedClip) -> LiveLinkPreviewState {
        if let state = liveLinkPreviewStates[clip.id] { return state }
        if case let .blocked(message) = liveLinkPreviewEligibility(for: clip) {
            return .blocked(message)
        }
        return .idle
    }

    func canLoadLiveLinkPreview(for clip: PresentedClip) -> Bool {
        if case .eligible = liveLinkPreviewEligibility(for: clip) { return true }
        return false
    }

    func liveLinkPreviewEligibility(for clip: PresentedClip) -> LiveLinkPreviewEligibility {
        guard clip.origin != .privateSession else {
            return .blocked("Live previews are disabled for Private Session items.")
        }
        guard let current = currentOrdinaryPresentedClip(matching: clip) else {
            return .blocked("This clip changed or is no longer available.")
        }
        guard current.sensitivity == nil,
              !secretDetector.scan(current.content).containsSecret
        else {
            return .blocked("Live previews are disabled for sensitive and Vault content.")
        }
        guard let descriptor = StoredLinkPreviewDescriptor(content: current.content) else {
            return .blocked("This clip does not contain a web address that can be previewed.")
        }
        do {
            return .eligible(try LiveLinkPreviewURLPolicy().validated(descriptor.url))
        } catch let error as LiveLinkPreviewError {
            return .blocked(error.localizedDescription)
        } catch {
            return .blocked("This link cannot be previewed safely.")
        }
    }

    func loadLiveLinkPreview(for clip: PresentedClip, refresh: Bool = false) async {
        if !refresh, case .loaded = liveLinkPreviewStates[clip.id] { return }
        guard case let .eligible(url) = liveLinkPreviewEligibility(for: clip) else {
            if case let .blocked(message) = liveLinkPreviewEligibility(for: clip) {
                liveLinkPreviewStates[clip.id] = .blocked(message)
            }
            return
        }

        let generation = (liveLinkPreviewGenerations[clip.id] ?? 0) &+ 1
        liveLinkPreviewGenerations[clip.id] = generation
        liveLinkPreviewStates[clip.id] = .loading
        do {
            let metadata = try await liveLinkPreviewClient.preview(for: url, refresh: refresh)
            try Task.checkCancellation()
            guard liveLinkPreviewGenerations[clip.id] == generation else { return }
            guard case let .eligible(currentURL) = liveLinkPreviewEligibility(for: clip),
                  currentURL == url
            else {
                liveLinkPreviewStates[clip.id] = .blocked(
                    "This clip changed or became sensitive while its preview was loading."
                )
                return
            }
            liveLinkPreviewStates[clip.id] = .loaded(metadata)
        } catch is CancellationError {
            guard liveLinkPreviewGenerations[clip.id] == generation else { return }
            liveLinkPreviewStates[clip.id] = .idle
        } catch let error as LiveLinkPreviewError {
            guard liveLinkPreviewGenerations[clip.id] == generation else { return }
            if error.isBlocked {
                liveLinkPreviewStates[clip.id] = .blocked(error.localizedDescription)
            } else if error == .offline || error == .timedOut {
                liveLinkPreviewStates[clip.id] = .offline(error.localizedDescription)
            } else {
                liveLinkPreviewStates[clip.id] = .failed(error.localizedDescription)
            }
        } catch {
            guard liveLinkPreviewGenerations[clip.id] == generation else { return }
            liveLinkPreviewStates[clip.id] = .failed(
                "The live preview could not be loaded. The stored link is still available."
            )
        }
    }

    func clearLiveLinkPreviewCache() async {
        liveLinkPreviewGenerations.removeAll(keepingCapacity: false)
        liveLinkPreviewStates.removeAll(keepingCapacity: false)
        await liveLinkPreviewClient.clearCache()
    }

    func clearLiveLinkPreview(for clip: PresentedClip) async {
        liveLinkPreviewGenerations[clip.id] = (liveLinkPreviewGenerations[clip.id] ?? 0) &+ 1
        liveLinkPreviewStates.removeValue(forKey: clip.id)
        guard case let .eligible(url) = liveLinkPreviewEligibility(for: clip) else { return }
        await liveLinkPreviewClient.removeCachedPreview(for: url)
    }

    func shareOrdinaryClip(_ clip: PresentedClip) {
        guard let current = currentOrdinaryPresentedClip(matching: clip),
              current.sensitivity == nil,
              !secretDetector.scan(current.content).containsSecret
        else {
            errorMessage = "This item is private, sensitive, or changed after it was selected. Review it again before sharing."
            return
        }
        perform {
            let representations = current.content.representations
            let item = NSPasteboardItem()
            guard item.setString(current.content.text, forType: .string) else {
                throw TypedPasteboardWriteError.pasteboardWriteFailed
            }
            if let reference = representations.richText {
                let data = try await self.assetStore.read(reference)
                guard item.setData(data, forType: .rtf) else {
                    throw TypedPasteboardWriteError.pasteboardWriteFailed
                }
            }
            if let reference = representations.html {
                let data = try await self.assetStore.read(reference)
                guard item.setData(data, forType: .html) else {
                    throw TypedPasteboardWriteError.pasteboardWriteFailed
                }
            }
            if let reference = representations.image {
                let data = try await self.assetStore.read(reference)
                let type = NSPasteboard.PasteboardType(reference.uniformTypeIdentifier)
                guard item.setData(data, forType: type) else {
                    throw TypedPasteboardWriteError.pasteboardWriteFailed
                }
            }
            if let urlText = representations.url?.originalURL {
                guard item.setString(urlText, forType: .URL) else {
                    throw TypedPasteboardWriteError.pasteboardWriteFailed
                }
            }

            // A file-list clip is inherently a collection of separate file objects. Other clip
            // types are represented by exactly one multi-representation pasteboard item.
            var items: [Any] = current.content.type == .fileURLs
                ? representations.files.map(\.url)
                : [item]
            if items.isEmpty { items = [item] }

            guard let latest = self.currentOrdinaryPresentedClip(matching: current),
                  latest.sensitivity == nil,
                  !self.secretDetector.scan(latest.content).containsSecret
            else {
                self.errorMessage = "This item changed while preparing the share sheet. Nothing was shared."
                return
            }

            guard let view = NSApp.keyWindow?.contentView else {
                self.errorMessage = "Open the Clipboard Router window before sharing."
                return
            }
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    private func currentOrdinaryPresentedClip(matching clip: PresentedClip) -> PresentedClip? {
        let current: PresentedClip?
        switch clip.origin {
        case .privateSession:
            return nil
        case .history:
            guard let item = snapshot.history.first(where: { $0.id == clip.id }) else { return nil }
            current = PresentedClip(
                id: item.id,
                title: Self.previewTitle(for: item.content),
                content: item.content,
                date: item.lastCapturedAt,
                sourceBundleIdentifier: item.sourceApplicationBundleIdentifier,
                origin: .history,
                captureContext: item.captureContext,
                sensitivity: item.sensitivity,
                pasteboardTypeIdentifiers: item.pasteboardTypeIdentifiers ?? [],
                captureCount: item.captureCount,
                pasteCount: item.pasteCount,
                lastPastedAt: item.lastPastedAt
            )
        case .saved:
            current = currentSavedPresentedClip(id: clip.id)
        }
        guard let current,
              current.origin == clip.origin,
              current.content.deduplicationFingerprint == clip.content.deduplicationFingerprint
        else { return nil }
        return current
    }

    func dismissStatus() {
        statusMessage = nil
    }

    func refreshPasteboardAccessState() {
        pasteboardAccessState = pasteboardAccessStateProvider()

        if pasteboardAccessState == .denied {
            clipboardMonitor.stop()
        } else if hasCompletedOnboarding,
                  isCaptureEnabled,
                  isReady,
                  !clipboardMonitor.isRunning
        {
            // A newly granted permission starts from the current generation; previously denied
            // clipboard contents are never imported retroactively.
            clipboardMonitor.start()
        }
    }

    // MARK: - Vault

    func unlockVault() {
        perform {
            try await self.unlockVaultNow()
            self.statusMessage = "Vault unlocked. It locks automatically after five minutes."
        }
    }

    func lockVault() {
        // Manual lock is a safety action and must never be dropped behind the general UI busy
        // gate. Hide plaintext synchronously, then revoke the actor-isolated key.
        publishVaultLockedState()
        statusMessage = "Vault locked."
        Task { [weak self] in
            await self?.vaultSession.lock()
        }
    }

    func selectVaultItem(id: UUID?) {
        vaultSelectionTask?.cancel()
        vaultSelectionTask = nil
        selectedVaultItemID = id
        // Never show plaintext from the previous row while a new selection decrypts.
        selectedVaultItem = nil
        guard let id else {
            return
        }
        vaultSelectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard await self.vaultSession.isUnlocked else {
                    self.publishVaultLockedState()
                    throw VaultError.locked
                }
                guard let item = try await self.vaultLibrary?.items().first(
                    where: { $0.id == id }
                ) else {
                    throw VaultError.itemNotFound(id)
                }
                guard !Task.isCancelled, self.selectedVaultItemID == id else { return }
                // Only the currently selected item's content is retained by the UI model.
                self.selectedVaultItem = item
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Compatibility wrapper retained for existing Saved-only call sites.
    func moveSavedClipToVault(id: UUID) {
        guard let saved = snapshot.savedClips.first(where: { $0.id == id }) else {
            errorMessage = ClipboardLibraryError.savedClipNotFound(id).localizedDescription
            return
        }
        moveClipToVault(PresentedClip(
            id: saved.id,
            title: saved.name,
            content: saved.content,
            date: saved.modifiedAt,
            sourceBundleIdentifier: saved.sourceApplicationBundleIdentifier,
            origin: .saved(folderID: saved.folderID),
            savedItemKind: saved.kind,
            captureContext: saved.captureContext,
            isPinned: saved.isPinned,
            tags: saved.tags ?? [],
            pasteboardTypeIdentifiers: saved.pasteboardTypeIdentifiers ?? []
        ))
    }

    /// Commits encrypted Vault state first, then atomically removes every linked ordinary copy.
    /// Authentication, validation, or Vault-store failure therefore cannot delete History/Saved.
    func moveClipToVault(_ clip: PresentedClip) {
        guard let summary = vaultMoveSummary(for: clip) else {
            errorMessage = vaultAvailabilityMessage ?? "This clip cannot be moved to Vault."
            return
        }
        moveClipToVault(clip, confirmedSummary: summary)
    }

    func moveClipToVault(_ clip: PresentedClip, confirmedSummary: VaultMoveSummary) {
        guard case .privateSession = clip.origin else {
            guard let library else { return }
            guard let vaultLibrary else {
                errorMessage = vaultAvailabilityMessage ?? "Vault is unavailable in this session."
                return
            }
            perform {
                if !(await self.vaultSession.isUnlocked) {
                    try await self.unlockVaultNow()
                }
                // Unlock can suspend for user authentication. Rebuild and revalidate the complete
                // move set afterwards so stale UI state cannot authorize a destructive cleanup.
                let ordinary = await library.snapshot()
                let plan = try self.vaultMovePlan(for: clip, in: ordinary)
                guard plan.summary == confirmedSummary else {
                    self.statusMessage = "Vault move paused because its History or Saved copy scope changed. Review and confirm again."
                    throw AppModelOperationError.vaultMoveReconfirmationRequired
                }
                do {
                    _ = try await vaultLibrary.add(plan.item, sourceAssets: self.assetStore)
                } catch let VaultError.duplicateItem(existingID) where existingID == plan.item.id {
                    // A prior attempt may have committed encrypted storage and then failed its
                    // ordinary transaction. Resume only after authenticated decryption proves the
                    // existing ciphertext is the exact same move manifest.
                    guard let existing = try await vaultLibrary.existingItem(id: plan.item.id),
                          existing.exactlyMatchesMoveManifest(plan.item)
                    else { throw VaultError.migrationConflict }
                    try await vaultLibrary.verifyAssets(for: existing)
                }
                _ = try await library.deleteOrdinaryCopiesForVaultMove(
                    expectedHistoryItem: plan.historyItem,
                    expectedSavedClips: plan.savedClips,
                    forbiddenFolderIDs: self.privateSyncSharedFolderIDs,
                    completeLinkedHistoryItemID: plan.linkedHistoryItemID,
                    expectedCompleteLinkedSavedClipIDs: plan.linkedHistoryItemID == nil
                        ? nil : Set(plan.savedClips.map(\.id))
                )
                await self.recordDeletionForSync(id: plan.item.id, kind: .savedClip)
                try await self.refreshSnapshot()
                try await self.removeMovedOrdinaryAssetsIfUnreferenced(plan.item.content)
                try await self.refreshVaultSummaries()
                self.selectedClipID = nil
                self.selectedSection = .vault
                self.selectedVaultItemID = plan.item.id
                self.selectedVaultItem = plan.item
                self.scheduleBackgroundSavedLibrarySync()
                self.statusMessage = "Moved to Vault. All linked ordinary copies were removed."
            }
            return
        }
        errorMessage = AppModelOperationError.ordinaryClipRequired.localizedDescription
    }

    private func vaultMovePlan(
        for clip: PresentedClip,
        in ordinary: ClipboardLibrarySnapshot
    ) throws -> VaultMovePlan {
        switch clip.origin {
        case .privateSession:
            throw AppModelOperationError.ordinaryClipRequired
        case .history:
            guard let history = ordinary.history.first(where: { $0.id == clip.id }) else {
                throw ClipboardLibraryError.historyItemNotFound(clip.id)
            }
            guard VaultItem.supports(history.content) else {
                throw VaultError.unsupportedExternalRepresentations
            }
            let linked = ordinary.savedClips.filter { $0.sourceHistoryItemID == history.id }
            try validateNoCollaborativeVaultSources(linked)
            let provenance = VaultItemProvenance(
                ordinaryOrigin: .history,
                sourceHistoryItemID: history.id,
                linkedSavedClipIDs: linked.map(\.id),
                sourceHistoryFingerprint: VaultHistoryItemFingerprint(history),
                linkedSavedClipFingerprints: linked.map(VaultSavedClipFingerprint.init),
                sourceApplicationBundleIdentifier: history.sourceApplicationBundleIdentifier,
                originatingDeviceIdentifier: history.originatingDeviceIdentifier,
                captureContext: history.captureContext,
                originallyCapturedAt: history.createdAt,
                sensitivity: history.sensitivity,
                pasteboardTypeIdentifiers: history.pasteboardTypeIdentifiers ?? []
            )
            return VaultMovePlan(
                item: try VaultItem(
                    id: history.id,
                    name: Self.previewTitle(for: history.content),
                    content: history.content,
                    createdAt: history.createdAt,
                    modifiedAt: history.modifiedAt,
                    provenance: provenance
                ),
                historyItem: history,
                savedClips: linked,
                linkedHistoryItemID: history.id
            )
        case .saved:
            guard let saved = ordinary.savedClips.first(where: { $0.id == clip.id }) else {
                throw ClipboardLibraryError.savedClipNotFound(clip.id)
            }
            guard VaultItem.supports(saved.content) else {
                throw VaultError.unsupportedExternalRepresentations
            }
            let linked = saved.sourceHistoryItemID.map { historyID in
                ordinary.savedClips.filter { $0.sourceHistoryItemID == historyID }
            } ?? [saved]
            try validateNoCollaborativeVaultSources(linked)
            let provenance = VaultItemProvenance(
                ordinaryOrigin: .saved,
                sourceHistoryItemID: saved.sourceHistoryItemID,
                sourceSavedClipID: saved.id,
                linkedSavedClipIDs: linked.map(\.id),
                sourceHistoryFingerprint: saved.sourceHistoryItemID.flatMap { historyID in
                    ordinary.history.first(where: { $0.id == historyID })
                        .map(VaultHistoryItemFingerprint.init)
                },
                linkedSavedClipFingerprints: linked.map(VaultSavedClipFingerprint.init),
                sourceFolderID: saved.folderID,
                sourcePinnedAt: saved.pinnedAt,
                sourceApplicationBundleIdentifier: saved.sourceApplicationBundleIdentifier,
                originatingDeviceIdentifier: saved.originatingDeviceIdentifier,
                captureContext: saved.captureContext,
                originallyCapturedAt: saved.originallyCapturedAt,
                sensitivity: saved.sensitivity,
                pasteboardTypeIdentifiers: saved.pasteboardTypeIdentifiers ?? []
            )
            return VaultMovePlan(
                item: try VaultItem(
                    id: saved.id,
                    kind: saved.kind,
                    name: saved.name,
                    content: saved.content,
                    createdAt: saved.createdAt,
                    modifiedAt: saved.modifiedAt,
                    provenance: provenance
                ),
                historyItem: saved.sourceHistoryItemID.flatMap { historyID in
                    ordinary.history.first(where: { $0.id == historyID })
                },
                savedClips: linked,
                linkedHistoryItemID: saved.sourceHistoryItemID
            )
        }
    }

    private func validateNoCollaborativeVaultSources(_ clips: [SavedClip]) throws {
        if clips.contains(where: { $0.folderID.map(isKnownSharedFolder) == true }) {
            throw AppModelOperationError.collaborativeVaultMoveUnsupported
        }
    }

    func securePasteVaultItem(_ item: VaultItem) {
        enqueueClipboardAction {
            // Authorization must happen before any plaintext touches the pasteboard. This closes
            // the gap between the deadline and the one-second auto-lock observer.
            try await self.vaultSession.authorizeActivity()
            guard let vaultLibrary = self.vaultLibrary else {
                throw VaultError.unreadableStore("Vault is unavailable")
            }
            let payload = try await vaultLibrary.restoredPayload(id: item.id)
            let timeout = self.securePasteTimeoutSeconds
            self.lastSecurePasteReceipt = try await self.securePaste.copy(
                payload,
                clearDelay: TimeInterval(timeout)
            )
            self.statusMessage = "Secure Paste copied for \(timeout) seconds. It clears only if you do not replace the clipboard."
        }
    }

    /// The view must obtain explicit confirmation immediately before calling this method.
    func routeVaultItem(_ item: VaultItem, to destination: ExternalDestination) {
        enqueueClipboardAction {
            // Resolve ambiguity and retain any security-scoped access before decrypted content
            // touches the clipboard. A failed preflight therefore exposes no Vault plaintext.
            let preparedTarget = try self.router.prepareDestination(destination)
            defer { preparedTarget.cancel() }
            // Refresh the timeout before opening another app. Opening the destination makes this
            // app resign active, which deliberately auto-locks Vault before the route returns.
            try await self.vaultSession.authorizeActivity()
            guard let vaultLibrary = self.vaultLibrary else {
                throw VaultError.unreadableStore("Vault is unavailable")
            }
            let payload = try await vaultLibrary.restoredPayload(id: item.id)
            let timeout = self.securePasteTimeoutSeconds
            self.lastSecurePasteReceipt = try await self.securePaste.copy(
                payload,
                clearDelay: TimeInterval(timeout)
            )
            let receipt = try await self.router.openPreparedTarget(preparedTarget)
            self.statusMessage = receipt.userMessage
        }
    }

    func deleteVaultItem(id: UUID) {
        guard let vaultLibrary else { return }
        perform {
            guard await self.vaultSession.isUnlocked else { throw VaultError.locked }
            try await vaultLibrary.delete(id: id)
            self.selectedVaultItemID = nil
            self.selectedVaultItem = nil
            try await self.refreshVaultSummaries()
            self.statusMessage = "Vault item permanently deleted."
        }
    }

    private func unlockVaultNow() async throws {
        guard vaultLibrary != nil else {
            throw VaultError.unreadableStore(vaultAvailabilityMessage ?? "Vault is unavailable")
        }
        try await vaultSession.unlock()
        if let vaultLibrary {
            // Crash recovery may remove an ordinary source only after authenticated decryption
            // proves that the Vault contains the exact item that was being moved.
            let authenticatedItems = try await vaultLibrary.items()
            do {
                try await reconcileCompletedVaultMoves(vaultItems: authenticatedItems)
                try await refreshSnapshot()
            } catch {
                statusMessage = "Vault unlocked. Interrupted move cleanup was postponed to protect the ordinary source: \(error.localizedDescription)"
            }
        }
        isVaultUnlocked = true
        vaultAvailabilityMessage = nil
        try await refreshVaultSummaries()
    }

    private func refreshVaultSummaries() async throws {
        guard let vaultLibrary, await vaultSession.isUnlocked else {
            publishVaultLockedState()
            return
        }
        // `VaultLibrary` verifies every authenticated envelope. Content is immediately discarded
        // here; only non-content summaries remain until the user selects one item.
        let items = try await vaultLibrary.items()
        vaultSummaries = items.map {
            VaultItemSummary(
                id: $0.id,
                name: $0.name,
                modifiedAt: $0.modifiedAt,
                contentType: $0.content.type
            )
        }
        vaultEncryptedItemCount = items.count
        isVaultUnlocked = true
        if let selectedVaultItemID,
           !vaultSummaries.contains(where: { $0.id == selectedVaultItemID })
        {
            self.selectedVaultItemID = nil
            selectedVaultItem = nil
        }
    }

    private func publishVaultLockedState() {
        vaultSelectionTask?.cancel()
        vaultSelectionTask = nil
        isVaultUnlocked = false
        vaultSummaries = []
        selectedVaultItemID = nil
        selectedVaultItem = nil
    }

    private func beginVaultStateObservation() {
        vaultStateTask?.cancel()
        vaultStateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let unlocked = await self.vaultSession.isUnlocked
                if self.isVaultUnlocked && !unlocked {
                    self.publishVaultLockedState()
                }
            }
        }
    }

    private func installLifecycleObservers() {
        guard lifecycleObservers.isEmpty else { return }
        lifecycleObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication else { return }
                MainActor.assumeIsolated {
                    self?.clipboardMonitor.applicationDidActivate(
                        bundleIdentifier: application.bundleIdentifier
                    )
                }
            }
        )
        lifecycleObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didDeactivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication else { return }
                MainActor.assumeIsolated {
                    self?.clipboardMonitor.applicationDidDeactivate(
                        bundleIdentifier: application.bundleIdentifier
                    )
                }
            }
        )
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshPasteboardAccessState()
                    self?.refreshLaunchAtLoginState()
                    self?.refreshTextExpansionState()
                    guard self?.directLicenseAccessPolicy.allows(.cloud) == true else {
                        return
                    }
                    if self?.isSavedLibrarySyncEnabled == true,
                       self?.syncContainerIdentifier != nil
                    {
                        await self?.synchronizeAndApplyRemote()
                    }
                    await self?.refreshAllSharedFolders(trigger: "activation")
                    await self?.installCloudPushSubscriptions(forceVerification: false)
                }
            }
        )
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.handleVaultLifecycle(.appDidEnterBackground) }
            }
        )
        lifecycleObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.handleVaultLifecycle(.systemWillSleep) }
            }
        )
        lifecycleObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.handleVaultLifecycle(.screenDidLock) }
            }
        )
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.handleVaultLifecycle(.appWillTerminate) }
            }
        )
    }

    private func handleVaultLifecycle(_ event: VaultLifecycleEvent) async {
        await vaultAutoLock.handleLifecycleEvent(event)
        publishVaultLockedState()
        if case .appWillTerminate = event, let receipt = lastSecurePasteReceipt {
            // Termination notifications offer only a best-effort async cleanup window. The
            // ownership-checked timer is the primary Secure Paste clearing mechanism.
            _ = await securePaste.clearIfStillOwned(receipt)
        }
        if case .appWillTerminate = event {
            stopSyncRefreshLoop()
            directLicenseRefreshTask?.cancel()
            directLicenseRefreshTask = nil
            retentionPruneTask?.cancel()
            retentionPruneTask = nil
            quarantineExpirationTask?.cancel()
            quarantineExpirationTask = nil
        }
    }

    private func startRetentionPruneLoopIfNeeded() {
        guard retentionPruneTask == nil else { return }
        retentionPruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, let library = self.library else { return }
                do {
                    let removed = try await library.pruneHistory(referenceDate: Date())
                    if removed > 0 { try await self.refreshSnapshot() }
                    await self.refreshClipboardHealth()
                    try? await self.collectUnreferencedAssets()
                } catch {
                    self.errorMessage = "History retention could not be applied: \(error.localizedDescription)"
                }
            }
        }
    }

    private func startDirectLicenseRefreshLoopIfNeeded() {
        guard isDirectLicenseCommerceConfigured, directLicenseRefreshTask == nil else { return }
        directLicenseRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshDirectLicenseFromRepositoryIfAvailable()
                let serverInterval: TimeInterval = 6 * 60 * 60
                let currentWallClock = self.directLicenseClock.observation().wallClock
                let boundaryInterval = self.directLicenseNextBoundary.map {
                    max(1, $0.timeIntervalSince(currentWallClock))
                } ?? serverInterval
                try? await Task.sleep(
                    for: .seconds(min(serverInterval, boundaryInterval))
                )
                if self.directLicenseNextBoundary.map({
                    self.directLicenseClock.observation().wallClock >= $0
                }) == true {
                    await self.refreshDirectLicenseState()
                }
            }
        }
    }

    private func refreshDirectLicenseFromRepositoryIfAvailable() async {
        guard isDirectLicenseCommerceConfigured,
              !isDirectLicenseOperationInProgress,
              let token = try? await directLicenseCredentialStore.loadToken()
        else { return }
        do {
            let refreshed = try await directLicenseRepository.refresh(
                token: token,
                deviceID: directLicenseDeviceID
            )
            try await acceptDirectLicenseToken(refreshed)
        } catch DirectLicenseError.repositoryUnavailable {
            await refreshDirectLicenseState(serviceUnavailable: true)
        } catch {
            // A configured licensing service rejected or corrupted the refresh. Fail closed
            // instead of allowing an old lifetime token to authorize automation indefinitely.
            directLicenseStatus = .tampered
            directLicenseAccountID = nil
            directLicenseID = nil
            directLicenseNextBoundary = nil
            stopSyncRefreshLoop()
            stopSharedFolderRefreshLoop()
        }
    }

    private func reconcileCompletedVaultMoves(vaultItems: [VaultItem]) async throws {
        guard let library, let vaultLibrary, !vaultItems.isEmpty else { return }
        for vaultItem in vaultItems {
            // A relaunch may observe the item envelope after a crash but before every asset was
            // durably verified. Never use that envelope as deletion authority until all typed
            // representations authenticate and match their encrypted manifest.
            try await vaultLibrary.verifyAssets(for: vaultItem)
            let ordinary = await library.snapshot()
            var expectedHistory: HistoryItem?
            var expectedSaved: [SavedClip] = []

            if let provenance = vaultItem.provenance {
                if let fingerprint = provenance.sourceHistoryFingerprint,
                   let current = ordinary.history.first(where: {
                       $0.id == fingerprint.item.id
                   }),
                   fingerprint.exactlyMatches(current)
                {
                    expectedHistory = current
                } else if provenance.sourceHistoryFingerprint == nil,
                          provenance.ordinaryOrigin == .history,
                          let historyID = provenance.sourceHistoryItemID,
                          let current = ordinary.history.first(where: { $0.id == historyID }),
                          Self.vaultItem(vaultItem, exactlyMatches: current)
                {
                    // Backward compatibility for first-generation provenance: only its primary
                    // History row can be proven. Legacy linked IDs are never deletion authority.
                    expectedHistory = current
                }

                if let fingerprints = provenance.linkedSavedClipFingerprints {
                    expectedSaved = fingerprints.compactMap { fingerprint in
                        ordinary.savedClips.first(where: { $0.id == fingerprint.clip.id })
                            .flatMap { fingerprint.exactlyMatches($0) ? $0 : nil }
                    }
                } else if provenance.ordinaryOrigin == .saved,
                          let savedID = provenance.sourceSavedClipID,
                          let current = ordinary.savedClips.first(where: { $0.id == savedID }),
                          Self.vaultItem(vaultItem, exactlyMatches: current)
                {
                    // First-generation provenance can prove only its primary Saved source.
                    expectedSaved = [current]
                }
            } else if let current = ordinary.savedClips.first(where: { $0.id == vaultItem.id }),
                      Self.vaultItem(vaultItem, exactlyMatches: current)
            {
                // Pre-provenance ciphertext proves only the Saved row whose complete payload is
                // identical to the decrypted Vault item. Linked IDs/history are not inferred.
                expectedSaved = [current]
            }

            guard expectedHistory != nil || !expectedSaved.isEmpty else { continue }
            try validateNoCollaborativeVaultSources(expectedSaved)
            _ = try await library.deleteOrdinaryCopiesForVaultMove(
                expectedHistoryItem: expectedHistory,
                expectedSavedClips: expectedSaved,
                forbiddenFolderIDs: privateSyncSharedFolderIDs
            )
            await recordDeletionForSync(id: vaultItem.id, kind: .savedClip)
        }
        scheduleBackgroundSavedLibrarySync()
    }

    static func vaultItem(_ vaultItem: VaultItem, exactlyMatches saved: SavedClip) -> Bool {
        guard vaultItem.id == saved.id
            && vaultItem.name == saved.name
            && vaultItem.content == saved.content
            && vaultItem.createdAt == saved.createdAt
            && vaultItem.modifiedAt == saved.modifiedAt
        else { return false }
        guard let provenance = vaultItem.provenance else { return true }
        return provenance.ordinaryOrigin == .saved
            && provenance.sourceSavedClipID == saved.id
            && provenance.sourceHistoryItemID == saved.sourceHistoryItemID
            && provenance.sourceFolderID == saved.folderID
            && provenance.sourcePinnedAt == saved.pinnedAt
            && provenance.sourceApplicationBundleIdentifier
                == saved.sourceApplicationBundleIdentifier
            && provenance.originatingDeviceIdentifier == saved.originatingDeviceIdentifier
            && provenance.captureContext == saved.captureContext
            && provenance.originallyCapturedAt == saved.originallyCapturedAt
            && provenance.sensitivity == saved.sensitivity
            && provenance.pasteboardTypeIdentifiers
                == (saved.pasteboardTypeIdentifiers ?? [])
    }

    static func vaultItem(_ vaultItem: VaultItem, exactlyMatches history: HistoryItem) -> Bool {
        guard let provenance = vaultItem.provenance else { return false }
        return vaultItem.id == history.id
            && vaultItem.name == previewTitle(for: history.content)
            && vaultItem.content == history.content
            && vaultItem.createdAt == history.createdAt
            && vaultItem.modifiedAt == history.modifiedAt
            && provenance.ordinaryOrigin == .history
            && provenance.sourceHistoryItemID == history.id
            && provenance.sourceSavedClipID == nil
            && provenance.sourceApplicationBundleIdentifier
                == history.sourceApplicationBundleIdentifier
            && provenance.originatingDeviceIdentifier == history.originatingDeviceIdentifier
            && provenance.captureContext == history.captureContext
            && provenance.originallyCapturedAt == history.createdAt
            && provenance.sensitivity == history.sensitivity
            && provenance.pasteboardTypeIdentifiers
                == (history.pasteboardTypeIdentifiers ?? [])
    }

    // MARK: - Collaborative folders

    func sharedFolderSnapshot(for folderID: UUID) -> SharedFolderSessionSnapshot? {
        sharedRootID(containing: folderID).flatMap { sharedFolderSnapshots[$0] }
    }

    func canManageSharedFolder(_ folderID: UUID) -> Bool {
        if let rootID = sharedRootID(containing: folderID),
           let shared = sharedFolderSnapshots[rootID]
        {
            return folderID == rootID
                ? shared.currentRole.canManageFolder
                : shared.currentRole.canEditClips
        }
        return !isKnownSharedFolder(folderID)
    }

    func canEditSharedFolder(_ folderID: UUID) -> Bool {
        if let rootID = sharedRootID(containing: folderID),
           let shared = sharedFolderSnapshots[rootID]
        {
            return shared.currentRole.canEditClips
        }
        return !isKnownSharedFolder(folderID)
    }

    func canManageFolderSharing(_ folderID: UUID) -> Bool {
        guard let rootID = sharedRootID(containing: folderID) else {
            return true // An ordinary folder may start a new share.
        }
        return sharedFolderSnapshots[rootID]?.currentRole.canManageFolder == true
    }

    var canStartFolderSharing: Bool {
        if case .available = sharedFolderCapability { return true }
        return false
    }

    private func isKnownSharedFolder(_ folderID: UUID) -> Bool {
        sharedRootID(containing: folderID) != nil
    }

    private func sharedRootID(containing folderID: UUID) -> UUID? {
        for (rootID, shared) in sharedFolderSnapshots where
            rootID == folderID || shared.managedFolderIDs.contains(folderID)
        {
            return rootID
        }
        let roots = Set(sharedFolderSessions.keys)
            .union(loadSharedFolderLocations().map(\.folderID))
        if roots.contains(folderID) { return folderID }
        let byID = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
        var cursor: UUID? = folderID
        var seen: Set<UUID> = []
        while let id = cursor, seen.insert(id).inserted {
            if roots.contains(id) { return id }
            cursor = byID[id]?.parentFolderID
        }
        return nil
    }

    func shareFolder(id folderID: UUID) {
        guard requireDirectLicense(.cloud) else { return }
        guard let library else { return }
        guard canManageFolderSharing(folderID) else {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return
        }
        if let rootID = sharedRootID(containing: folderID),
           sharedFolderSessions[rootID] != nil
        {
            presentSharedFolderInvitationSurface(folderID: rootID)
            return
        }
        perform {
            guard self.sharedFolderSessions[folderID] == nil else {
                self.presentSharedFolderInvitationSurface(folderID: folderID)
                return
            }
            guard let transport = self.sharedFolderTransport else {
                throw SharedFolderError.cloudCapabilityUnavailable(.configurationMissing)
            }
            guard case .available = await transport.capability() else {
                let capability = await transport.capability()
                if case let .unavailable(issue) = capability {
                    throw SharedFolderError.cloudCapabilityUnavailable(issue)
                }
                throw SharedFolderError.cloudCapabilityUnavailable(.couldNotDetermine)
            }
            let local = await library.snapshot()
            guard let folder = local.folders.first(where: { $0.id == folderID }) else {
                throw ClipboardLibraryError.folderNotFound(folderID)
            }
            let subtree = Self.localSharedSubtree(rootID: folderID, in: local)
            let session = try await SharedFolderSession.create(
                folder: folder,
                folders: subtree.folders,
                savedClips: subtree.savedItems,
                deviceID: self.syncDeviceID,
                transport: transport
            )
            self.sharedFolderSessions[folderID] = session
            let sharedSnapshot = await session.snapshot()
            self.sharedFolderSnapshots[folderID] = sharedSnapshot
            await self.acknowledgeSharedFolderMutations(
                from: local,
                controlledFolderIDs: Set(subtree.folders.map(\.id)).union([folderID]),
                controlledClipIDs: Set(subtree.savedItems.map(\.id))
            )
            try await self.refreshSnapshot()
            try self.persistSharedFolderLocations()
            self.startSharedFolderRefreshLoopIfNeeded()
            await self.enqueuePrivateSyncTombstonesForSharedEntities()
            self.statusMessage = "Shared-folder zone created. Choose people and permissions in the macOS invitation window."
            self.presentSharedFolderInvitationSurface(folderID: folderID)
        }
    }

    func refreshSharedFolder(id folderID: UUID) {
        guard requireDirectLicense(.cloud) else { return }
        guard canManageFolderSharing(folderID) else {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return
        }
        let rootID = sharedRootID(containing: folderID) ?? folderID
        guard let session = sharedFolderSessions[rootID] else {
            sharedFolderMessage = "This folder has no active CloudKit share in this installation."
            return
        }
        perform {
            do {
                let refreshed = try await session.refresh()
                self.sharedFolderSnapshots[rootID] = refreshed
                try await self.applySharedFolderSnapshot(refreshed)
                self.sharedFolderMessage = nil
                self.statusMessage = "Shared folder refreshed."
            } catch {
                self.sharedFolderSnapshots[rootID] = await session.snapshot()
                self.sharedFolderMessage = error.localizedDescription
                throw error
            }
        }
    }

    func presentSharedFolderInvitationSurface(folderID: UUID) {
        guard canManageFolderSharing(folderID) else {
            errorMessage = SharedFolderError.permissionDenied.localizedDescription
            return
        }
        let rootID = sharedRootID(containing: folderID) ?? folderID
        guard let location = sharedFolderSnapshots[rootID]?.location,
              let provider = sharedFolderTransport as? any SharedFolderSharePresentationProviding
        else {
            sharedFolderMessage = "The system invitation surface is available only in a signed CloudKit build. The folder remains local."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let presentation = try await provider.sharePresentation(for: location)
                try self.cloudSharingPresenter.present(presentation)
            } catch {
                self.sharedFolderMessage = error.localizedDescription
            }
        }
    }

    /// Called only from the macOS app-delegate CKSharingSupported handoff.
    func acceptCloudKitShare(_ metadata: CKShare.Metadata) {
        pendingCloudKitShareMetadata.append(metadata)
        guard shareAcceptanceTask == nil else { return }
        shareAcceptanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.shareAcceptanceTask = nil }
            while !self.pendingCloudKitShareMetadata.isEmpty {
                let next = self.pendingCloudKitShareMetadata.removeFirst()
                do {
                    try await self.acceptCloudKitShareNow(next)
                } catch {
                    self.sharedFolderMessage = error.localizedDescription
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func acceptCloudKitShareNow(_ metadata: CKShare.Metadata) async throws {
        guard let adapter = cloudKitSharedFolderAdapter,
              let transport = sharedFolderTransport
        else {
            throw SharedFolderError.cloudCapabilityUnavailable(.configurationMissing)
        }
        let remote = try await adapter.acceptShare(metadata)
        let session = try await SharedFolderSession.open(
            remote: remote,
            deviceID: syncDeviceID,
            transport: transport
        )
        sharedFolderSessions[remote.location.folderID] = session
        let sharedSnapshot = await session.snapshot()
        sharedFolderSnapshots[remote.location.folderID] = sharedSnapshot
        try await applySharedFolderSnapshot(sharedSnapshot)
        try persistSharedFolderLocations()
        startSharedFolderRefreshLoopIfNeeded()
        selectedSection = .folder(remote.location.folderID)
        sharedFolderMessage = nil
        statusMessage = "Shared folder accepted. Its CloudKit records were validated before opening."
    }

    private func prepareSharedFolderState() async {
        let transport: any SharedFolderTransport
        if let injectedSharedFolderTransport {
            transport = injectedSharedFolderTransport
        } else if let containerIdentifier = syncContainerIdentifier,
                  Self.hasCloudKitContainerEntitlement(containerIdentifier)
        {
            let adapter = CloudKitSharedFolderAdapter(
                configuration: CloudKitSharingConfiguration(
                    isFeatureEnabled: true,
                    hasCloudKitEntitlement: true,
                    containerIdentifier: containerIdentifier
                )
            )
            cloudKitSharedFolderAdapter = adapter
            transport = adapter
        } else {
            sharedFolderCapability = .unavailable(.configurationMissing)
            sharedFolderMessage = Self.sharedFolderCapabilityMessage(.configurationMissing)
            return
        }
        sharedFolderTransport = transport
        let capability = await transport.capability()
        sharedFolderCapability = capability
        guard case .available = capability else {
            if case let .unavailable(issue) = capability {
                sharedFolderMessage = Self.sharedFolderCapabilityMessage(issue)
            }
            return
        }

        let participantID: String
        let accountFingerprint: String
        do {
            participantID = try await transport.currentParticipantID()
            accountFingerprint = try SharedAccountFingerprint.derive(
                accountIdentifier: participantID,
                installationSecret: syncDeviceID
            )
        } catch {
            sharedFolderMessage = error.localizedDescription
            return
        }
        sharedAccountFingerprint = accountFingerprint

        let registrations: [SharedWorkspaceRegistration]
        do {
            if let registry = try sharedWorkspaceRegistryStore.load() {
                guard registry.accountFingerprint == accountFingerprint else {
                    try await hideRegisteredSharedWorkspaces(registry.workspaces)
                    sharedFolderMessage = SharedWorkspacePersistenceError.accountMismatch.localizedDescription
                    return
                }
                registrations = registry.workspaces
            } else {
                registrations = loadSharedFolderLocations().map { location in
                    registration(
                        for: location,
                        managedFolderIDs: [location.folderID],
                        managedSavedClipIDs: [],
                        accountFingerprint: accountFingerprint,
                        at: nil
                    )
                }
            }
        } catch {
            await purgeUntrustedSharedWorkspaceState()
            sharedFolderMessage = "Shared workspaces stayed hidden because their local registry could not be validated: \(error.localizedDescription)"
            return
        }

        for registration in registrations {
            do {
                let location = registration.location
                let remote = try await transport.synchronize([], at: location)
                let session = try await SharedFolderSession.open(
                    remote: remote,
                    deviceID: syncDeviceID,
                    transport: transport
                )
                sharedFolderSessions[location.folderID] = session
                let sharedSnapshot = await session.snapshot()
                sharedFolderSnapshots[location.folderID] = sharedSnapshot
                try await applySharedFolderSnapshot(sharedSnapshot)
            } catch {
                sharedFolderMessage = "Could not reopen \(registration.location.title): \(error.localizedDescription)"
            }
        }
        if !sharedFolderSessions.isEmpty {
            try? persistSharedFolderLocations()
            startSharedFolderRefreshLoopIfNeeded()
        }
    }

    private func startSharedFolderRefreshLoopIfNeeded() {
        guard directLicenseAccessPolicy.allows(.cloud),
              sharedFolderRefreshTask == nil,
              !sharedFolderSessions.isEmpty
        else { return }
        sharedFolderRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                guard NSApp.isActive else { continue }
                await self.refreshAllSharedFolders(trigger: "timer")
            }
        }
    }

    private func refreshAllSharedFolders(trigger: String) async {
        guard directLicenseAccessPolicy.allows(.cloud),
              let transport = sharedFolderTransport,
              !sharedFolderSessions.isEmpty
        else { return }
        if isSharedFolderRefreshInProgress {
            sharedFolderRefreshNeedsAnotherPass = true
            return
        }
        isSharedFolderRefreshInProgress = true
        defer {
            isSharedFolderRefreshInProgress = false
            if sharedFolderRefreshNeedsAnotherPass {
                sharedFolderRefreshNeedsAnotherPass = false
                Task { @MainActor [weak self] in
                    await self?.refreshAllSharedFolders(trigger: "coalesced")
                }
            }
        }
        do {
            let participantID = try await transport.currentParticipantID()
            let fingerprint = try SharedAccountFingerprint.derive(
                accountIdentifier: participantID,
                installationSecret: syncDeviceID
            )
            guard fingerprint == sharedAccountFingerprint else {
                do {
                    if let registry = try sharedWorkspaceRegistryStore.load() {
                        try await hideRegisteredSharedWorkspaces(registry.workspaces)
                    } else {
                        await purgeUntrustedSharedWorkspaceState()
                    }
                } catch {
                    await purgeUntrustedSharedWorkspaceState()
                }
                sharedFolderSessions.removeAll()
                sharedFolderSnapshots.removeAll()
                sharedFolderRefreshTask?.cancel()
                sharedFolderRefreshTask = nil
                sharedFolderMessage = SharedWorkspacePersistenceError.accountMismatch.localizedDescription
                return
            }
        } catch {
            sharedFolderMessage = "Shared-folder account validation failed during \(trigger): \(error.localizedDescription)"
            return
        }

        for (rootID, session) in sharedFolderSessions.sorted(by: {
            $0.key.uuidString < $1.key.uuidString
        }) {
            do {
                let refreshed = try await session.refresh()
                sharedFolderSnapshots[rootID] = refreshed
                try await applySharedFolderSnapshot(refreshed)
            } catch {
                sharedFolderSnapshots[rootID] = await session.snapshot()
                sharedFolderMessage = "\((await session.snapshot()).location.title): \(error.localizedDescription)"
            }
        }
        try? persistSharedFolderLocations()
    }

    private func stopSharedFolderRefreshLoop() {
        sharedFolderRefreshTask?.cancel()
        sharedFolderRefreshTask = nil
    }

    private func drainSharedFolderMutations() async {
        guard let library, !sharedFolderSessions.isEmpty else { return }
        let local = await library.snapshot()
        for (folderID, session) in sharedFolderSessions {
            let folder = local.folders.first(where: { $0.id == folderID })
            let subtree = Self.localSharedSubtree(rootID: folderID, in: local)
            let before = await session.snapshot()
            do {
                let refreshed = try await session.synchronizeLocal(
                    folder: folder,
                    folders: subtree.folders,
                    savedClips: subtree.savedItems
                )
                sharedFolderSnapshots[folderID] = refreshed
                let controlledFolderIDs = before.managedFolderIDs
                    .union(subtree.folders.map(\.id))
                    .union([folderID])
                let controlledClipIDs = before.managedSavedClipIDs
                    .union(subtree.savedItems.map(\.id))
                await acknowledgeSharedFolderMutations(
                    from: local,
                    controlledFolderIDs: controlledFolderIDs,
                    controlledClipIDs: controlledClipIDs
                )
            } catch {
                sharedFolderSnapshots[folderID] = await session.snapshot()
                sharedFolderMessage = "\(before.location.title): \(error.localizedDescription)"
            }
        }
        await enqueuePrivateSyncTombstonesForSharedEntities()
    }

    private func acknowledgeSharedFolderMutations(
        from uploadedSnapshot: ClipboardLibrarySnapshot,
        controlledFolderIDs: Set<UUID>,
        controlledClipIDs: Set<UUID>
    ) async {
        guard let library else { return }
        // The snapshot supplied to the successful transport operation contains exact journal
        // tokens. Core's acknowledgement is equality-based, so a concurrent newer edit remains
        // pending instead of being erased by this confirmation.
        for mutation in uploadedSnapshot.pendingSavedLibraryMutations where
            (mutation.kind == .folder && controlledFolderIDs.contains(mutation.id))
                || (mutation.kind == .savedClip && controlledClipIDs.contains(mutation.id))
        {
            try? await library.acknowledgePendingSavedLibraryMutation(mutation)
        }
    }

    func applySharedFolderSnapshot(
        _ shared: SharedFolderSessionSnapshot
    ) async throws {
        guard let library else { return }
        let local = await library.snapshot()
        let localByID = Dictionary(uniqueKeysWithValues: local.folders.map { ($0.id, $0) })
        let remoteFolders = (shared.folder.map { [$0] } ?? []) + shared.folders
        var nextSortOrder = local.folders.count
        var locallyOrderedFolders: [ClipFolder] = []
        for folder in remoteFolders {
            let sortOrder: Int
            if let localFolder = localByID[folder.id] {
                sortOrder = localFolder.sortOrder
            } else {
                sortOrder = nextSortOrder
                nextSortOrder += 1
            }
            locallyOrderedFolders.append(try ClipFolder(
                id: folder.id,
                name: folder.name,
                parentFolderID: folder.parentFolderID,
                sortOrder: sortOrder,
                createdAt: folder.createdAt,
                modifiedAt: folder.modifiedAt
            ))
        }
        try await library.applySyncedSavedLibrary(
            savedClips: shared.savedClips,
            folders: locallyOrderedFolders,
            managedSavedClipIDs: shared.managedSavedClipIDs,
            managedFolderIDs: shared.managedFolderIDs
        )
        let priorTeamFlows = Dictionary(uniqueKeysWithValues: clipFlows
            .filter { $0.sharedFolderID == shared.location.folderID }
            .map { ($0.id, $0) })
        clipFlows.removeAll { $0.sharedFolderID == shared.location.folderID }
        for incoming in shared.automationDefinitions where !suppressedTeamFlowIDs.contains(incoming.id) {
            let preservedEnabled: Bool
            if let prior = priorTeamFlows[incoming.id],
               prior.name == incoming.name,
               prior.trigger == incoming.trigger,
               prior.entityFilter == incoming.entityFilter,
               prior.customMatcher == incoming.customMatcher,
               prior.steps == incoming.steps
            {
                preservedEnabled = prior.isEnabled
            } else {
                preservedEnabled = false
            }
            if let installed = try? ClipFlow(
                id: incoming.id,
                name: incoming.name,
                isEnabled: preservedEnabled,
                trigger: incoming.trigger,
                entityFilter: incoming.entityFilter,
                customMatcher: incoming.customMatcher,
                steps: incoming.steps,
                sharedFolderID: shared.location.folderID
            ) {
                clipFlows.append(installed)
            }
        }
        persistClipFlows()
        sharedFolderSnapshots[shared.location.folderID] = shared
        try await refreshSnapshot()
        await enqueuePrivateSyncTombstonesForSharedEntities()
    }

    private static func localSharedSubtree(
        rootID: UUID,
        in local: ClipboardLibrarySnapshot
    ) -> (folders: [ClipFolder], savedItems: [SavedClip]) {
        let byParent = Dictionary(grouping: local.folders.compactMap { folder -> ClipFolder? in
            folder.id == rootID ? nil : folder
        }, by: \.parentFolderID)
        var folderIDs: Set<UUID> = [rootID]
        var queue: [UUID] = [rootID]
        var descendants: [ClipFolder] = []
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for child in (byParent[parent] ?? []).sorted(by: { $0.id.uuidString < $1.id.uuidString })
                where folderIDs.insert(child.id).inserted
            {
                descendants.append(child)
                queue.append(child.id)
            }
        }
        return (
            descendants,
            local.savedClips.filter { $0.folderID.map(folderIDs.contains) == true }
        )
    }

    private var sharedFolderLocationsURL: URL {
        supportDirectory.appendingPathComponent("shared-folder-locations.json")
    }

    private var sharedWorkspaceRegistryStore: SharedWorkspaceRegistryStore {
        SharedWorkspaceRegistryStore(
            fileURL: supportDirectory.appendingPathComponent("shared-workspace-registry.json")
        )
    }

    private func persistSharedFolderLocations() throws {
        let locations = sharedFolderSnapshots.values.map(\.location).sorted {
            $0.folderID.uuidString < $1.folderID.uuidString
        }
        let data = try JSONEncoder().encode(locations)
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        try data.write(to: sharedFolderLocationsURL, options: .atomic)

        guard let accountFingerprint = sharedAccountFingerprint else { return }
        let registrations = sharedFolderSnapshots.values.map { snapshot in
            registration(
                for: snapshot.location,
                managedFolderIDs: snapshot.managedFolderIDs,
                managedSavedClipIDs: snapshot.managedSavedClipIDs,
                accountFingerprint: accountFingerprint,
                at: snapshot.status.successDate
            )
        }
        try sharedWorkspaceRegistryStore.save(SharedWorkspaceRegistry(
            accountFingerprint: accountFingerprint,
            workspaces: registrations
        ))
    }

    private func registration(
        for location: SharedFolderRemoteLocation,
        managedFolderIDs: Set<UUID>,
        managedSavedClipIDs: Set<UUID>,
        accountFingerprint: String,
        at lastSuccessfulFetchAt: Date?
    ) -> SharedWorkspaceRegistration {
        SharedWorkspaceRegistration(
            accountFingerprint: accountFingerprint,
            location: location,
            managedFolderIDs: managedFolderIDs,
            managedSavedClipIDs: managedSavedClipIDs,
            cursor: SharedZoneCursor(
                accountFingerprint: accountFingerprint,
                folderID: location.folderID,
                ownerParticipantID: location.ownerParticipantID,
                zoneName: location.zoneName,
                databaseScope: location.databaseScope,
                lastSuccessfulFetchAt: lastSuccessfulFetchAt
            ),
            recoveryCopies: sharedFolderSnapshots[location.folderID]?.recoveryCopies ?? []
        )
    }

    private func hideRegisteredSharedWorkspaces(
        _ registrations: [SharedWorkspaceRegistration]
    ) async throws {
        guard let library else { return }
        let workspaceIDs = Set(registrations.map { $0.location.folderID })
        clipFlows.removeAll { flow in
            flow.sharedFolderID.map(workspaceIDs.contains) ?? false
        }
        queuedFlowReviews.removeAll { request in
            request.flow.sharedFolderID.map(workspaceIDs.contains) ?? false
        }
        if let pendingFlowReview,
           pendingFlowReview.flow.sharedFolderID.map(workspaceIDs.contains) == true
        {
            advanceFlowReviewQueue()
        }
        persistClipFlows()
        try await library.removeAccountScopedSavedLibrary(
            savedClipIDs: registrations.reduce(into: Set<UUID>()) {
                $0.formUnion($1.managedSavedClipIDs)
            },
            folderIDs: registrations.reduce(into: Set<UUID>()) {
                $0.formUnion($1.managedFolderIDs)
            }
        )
        try await refreshSnapshot()
    }

    private func purgeUntrustedSharedWorkspaceState() async {
        let rootIDs = Set(loadSharedFolderLocations().map(\.folderID))
            .union(clipFlows.compactMap(\.sharedFolderID))
        clipFlows.removeAll { $0.sharedFolderID != nil }
        queuedFlowReviews.removeAll { $0.flow.sharedFolderID != nil }
        if pendingFlowReview?.flow.sharedFolderID != nil { advanceFlowReviewQueue() }
        suppressedTeamFlowIDs.removeAll()
        persistClipFlows()
        persistSuppressedTeamFlowIDs()

        if let library, !rootIDs.isEmpty {
            let local = await library.snapshot()
            let byID = Dictionary(uniqueKeysWithValues: local.folders.map { ($0.id, $0) })
            let folderIDs = Set(local.folders.compactMap { folder -> UUID? in
                var cursor: UUID? = folder.id
                var seen: Set<UUID> = []
                while let id = cursor, seen.insert(id).inserted {
                    if rootIDs.contains(id) { return folder.id }
                    cursor = byID[id]?.parentFolderID
                }
                return nil
            }).union(rootIDs)
            let clipIDs = Set(local.savedClips.compactMap { clip in
                clip.folderID.map(folderIDs.contains) == true ? clip.id : nil
            })
            try? await library.removeAccountScopedSavedLibrary(
                savedClipIDs: clipIDs,
                folderIDs: folderIDs
            )
            try? await refreshSnapshot()
        }
        sharedFolderSessions.removeAll()
        sharedFolderSnapshots.removeAll()
    }

    private func loadSharedFolderLocations() -> [SharedFolderRemoteLocation] {
        guard let data = try? Data(contentsOf: sharedFolderLocationsURL),
              let locations = try? JSONDecoder().decode(
                  [SharedFolderRemoteLocation].self,
                  from: data
              )
        else { return [] }
        return locations
    }

    private static func hasCloudKitContainerEntitlement(_ containerIdentifier: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let containers = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.icloud-container-identifiers" as CFString,
                  nil
              ) as? [String]
        else { return false }
        return containers.contains(containerIdentifier)
    }

    static func sharedFolderCapabilityMessage(_ issue: SharedCloudCapabilityIssue) -> String {
        switch issue {
        case .featureDisabled:
            "Collaborative folders are disabled in this build. Local folders continue to work."
        case .configurationMissing:
            "Collaborative folders require an Apple Developer-signed build whose CloudKit container appears in both Info.plist and signed entitlements. No share or upload was attempted."
        case .noICloudAccount:
            "Sign in to iCloud in System Settings before creating or opening a shared folder."
        case .restrictedAccount:
            "This iCloud account is restricted from CloudKit sharing. Check Screen Time or managed-account policy."
        case .temporarilyUnavailable:
            "CloudKit sharing is temporarily unavailable. The folder remains local; try Refresh later."
        case .couldNotDetermine:
            "Clipboard Router could not verify CloudKit sharing capability. No share or upload was attempted."
        }
    }

    // MARK: - Saved-library sync

    var isSavedLibrarySyncEnabled: Bool { syncSnapshot.isEnabled }
    var hasPendingSyncAccountChange: Bool {
        syncSnapshot.pendingAccountFingerprint != nil
    }

    var approvedSyncAccountLabel: String {
        Self.shortAccountLabel(syncSnapshot.confirmedAccountFingerprint)
    }

    var pendingSyncAccountLabel: String {
        Self.shortAccountLabel(syncSnapshot.pendingAccountFingerprint)
    }

    func setSavedLibrarySyncEnabled(_ enabled: Bool) {
        if !enabled {
            isSyncOptOutRequested = true
            syncProjectionGeneration &+= 1
            syncApplyNeedsAnotherPass = false
            stopSyncRefreshLoop()
            syncAvailabilityMessage = "Turning saved-library sync off…"
            // Opt-out is not dropped merely because another UI operation currently owns `isBusy`.
            Task { [weak self] in
                guard let self else { return }
                do {
                    let coordinator = try await self.ensureSyncCoordinator(useCloudKit: false)
                    try await coordinator.setEnabled(false)
                    self.syncSnapshot = await coordinator.snapshot()
                    self.syncAvailabilityMessage = nil
                } catch {
                    self.syncAvailabilityMessage = "Could not persist sync opt-out: \(error.localizedDescription)"
                }
            }
            return
        }

        guard requireDirectLicense(.cloud) else { return }

        isSyncOptOutRequested = false
        syncProjectionGeneration &+= 1
        perform {
            guard self.syncContainerIdentifier != nil else {
                self.syncAvailabilityMessage = Self.cloudKitUnavailableMessage
                return
            }
            let coordinator = try await self.ensureSyncCoordinator(useCloudKit: true)
            try await coordinator.setEnabled(true)
            self.syncSnapshot = await coordinator.snapshot()

            // Pull first, then seed the resulting union of remote-managed and local-only data.
            await self.synchronizeAndApplyRemote()
            let local = await self.library?.snapshot() ?? .empty
            let sharedFolderIDs = self.privateSyncSharedFolderIDs
            for folder in local.folders where !sharedFolderIDs.contains(folder.id) {
                do { _ = try await coordinator.recordFolder(folder) }
                catch { self.syncAvailabilityMessage = error.localizedDescription }
            }
            for clip in local.savedClips where
                clip.folderID.map({ !sharedFolderIDs.contains($0) }) ?? true
            {
                do { _ = try await coordinator.recordSavedClip(clip) }
                catch { self.syncAvailabilityMessage = error.localizedDescription }
            }
            await self.enqueuePrivateSyncTombstonesForSharedEntities()
            await self.synchronizeAndApplyRemote()
            await self.installCloudPushSubscriptions(forceVerification: true)
            self.startSyncRefreshLoopIfNeeded()
        }
    }

    func synchronizeSavedLibrary() {
        guard requireDirectLicense(.cloud) else { return }
        perform {
            guard self.syncSnapshot.isEnabled else { throw SavedLibrarySyncError.disabled }
            guard self.syncContainerIdentifier != nil else {
                self.syncAvailabilityMessage = Self.cloudKitUnavailableMessage
                return
            }
            await self.synchronizeAndApplyRemote()
        }
    }

    func confirmPendingSyncAccountChange() {
        guard requireDirectLicense(.cloud) else { return }
        perform {
            guard let syncCoordinator = self.syncCoordinator else {
                throw SavedLibrarySyncError.accountConfirmationNotPending
            }
            try await syncCoordinator.confirmPendingAccountChange()
            self.syncSnapshot = await syncCoordinator.snapshot()
            self.syncAvailabilityMessage = nil
            await self.synchronizeAndApplyRemote()
            await self.installCloudPushSubscriptions(forceVerification: true)
        }
    }

    func keepSyncAccountChangePaused() {
        syncAvailabilityMessage = "Sync remains paused. Local saved-library changes stay queued and nothing uploads to the newly detected iCloud account."
    }

    private func preparePersistedSyncState() async {
        syncContainerIdentifier = Self.configuredCloudKitContainerIdentifier()
        do {
            let persisted = try await syncStore.load()
            syncSnapshot = persisted
            if case let .idle(lastSuccessfulSync) = persisted.status,
               let lastSuccessfulSync
            {
                syncLastSuccessfulDate = lastSuccessfulSync
                defaults.set(lastSuccessfulSync, forKey: Self.syncLastSuccessKey)
            }
            guard persisted.isEnabled else { return }
            if syncContainerIdentifier == nil {
                syncAvailabilityMessage = Self.cloudKitUnavailableMessage
                // Keep accepting local mutations into the durable outbox without constructing
                // CKContainer. A later signed build can flush them.
                syncCoordinator = try await SavedLibrarySyncCoordinator.open(
                    deviceID: syncDeviceID,
                    transport: InMemorySavedLibrarySyncTransport(),
                    store: syncStore,
                    assetStore: assetStore,
                    assetStager: syncAssetStager
                )
            } else {
                syncCoordinator = try await SavedLibrarySyncCoordinator.open(
                    deviceID: syncDeviceID,
                    transport: CloudKitSavedLibraryTransport(
                        containerIdentifier: syncContainerIdentifier
                    ),
                    store: syncStore,
                    assetStore: assetStore,
                    assetStager: syncAssetStager
                )
            }
        } catch {
            syncAvailabilityMessage = error.localizedDescription
        }
    }

    private func ensureSyncCoordinator(
        useCloudKit: Bool
    ) async throws -> SavedLibrarySyncCoordinator {
        if let syncCoordinator { return syncCoordinator }
        let transport: any SavedLibrarySyncTransport
        if useCloudKit {
            guard let syncContainerIdentifier else {
                throw SavedLibrarySyncError.cloudKitConfigurationRequired
            }
            transport = CloudKitSavedLibraryTransport(
                containerIdentifier: syncContainerIdentifier
            )
        } else {
            transport = InMemorySavedLibrarySyncTransport()
        }
        let coordinator = try await SavedLibrarySyncCoordinator.open(
            deviceID: syncDeviceID,
            transport: transport,
            store: syncStore,
            assetStore: assetStore,
            assetStager: syncAssetStager
        )
        syncCoordinator = coordinator
        return coordinator
    }

    private func recordSavedClipForSync(_: SavedClip) async {
        await drainPendingSavedLibraryMutations()
        await drainSharedFolderMutations()
    }

    private func recordFolderForSync(_: ClipFolder) async {
        await drainPendingSavedLibraryMutations()
        await drainSharedFolderMutations()
    }

    private func recordDeletionForSync(id _: UUID, kind _: SyncEntityKind) async {
        await drainPendingSavedLibraryMutations()
        await drainSharedFolderMutations()
    }

    /// Transfers Core's exact, atomically-journaled mutations into the sync outbox. Core removes
    /// an entry only after that exact value is durable in the coordinator; a concurrent newer edit
    /// therefore survives for the next drain.
    private func drainPendingSavedLibraryMutations() async {
        guard syncSnapshot.isEnabled,
              !isSyncOptOutRequested,
              let syncCoordinator,
              let library
        else { return }

        let localSnapshot = await library.snapshot()
        let sharedFolderIDs = privateSyncSharedFolderIDs
        let sharedManagedClipIDs = Set(
            sharedFolderSnapshots.values.flatMap(\.managedSavedClipIDs)
        )
        let currentClipsByID = Dictionary(
            uniqueKeysWithValues: localSnapshot.savedClips.map { ($0.id, $0) }
        )
        for mutation in localSnapshot.pendingSavedLibraryMutations.sorted(by: {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.id.uuidString < $1.id.uuidString
        }) where !Self.isPrivateSyncExcludedMutation(
            mutation,
            sharedFolderIDs: sharedFolderIDs,
            sharedManagedClipIDs: sharedManagedClipIDs,
            currentClipsByID: currentClipsByID
        ) {
            do {
                if mutation.isDeletion {
                    _ = try await syncCoordinator.recordDeletion(
                        id: mutation.id,
                        kind: mutation.kind == .savedClip ? .savedClip : .folder
                    )
                } else {
                    switch mutation.kind {
                    case .savedClip:
                        guard let clip = localSnapshot.savedClips.first(
                            where: { $0.id == mutation.id }
                        ) else { continue }
                        _ = try await syncCoordinator.recordSavedClip(clip)
                    case .folder:
                        guard let folder = localSnapshot.folders.first(
                            where: { $0.id == mutation.id }
                        ) else { continue }
                        _ = try await syncCoordinator.recordFolder(folder)
                    }
                }
                try await library.acknowledgePendingSavedLibraryMutation(mutation)
            } catch let error as SavedLibrarySyncError {
                if case .ineligible = error {
                    // The coordinator already persisted a payload-free local-only reason. Treat
                    // this exact journal entry as handled instead of retrying it forever.
                    try? await library.acknowledgePendingSavedLibraryMutation(mutation)
                    syncSnapshot = await syncCoordinator.snapshot()
                    continue
                } else if case let .recordTooLarge(_, size) = error {
                    syncAvailabilityMessage = "A local saved clip is \(size) bytes, above the 256 KiB sync limit. It remains local-only and protected from remote replacement."
                } else {
                    syncAvailabilityMessage = error.localizedDescription
                }
                // Transient/size failures retain the exact Core mutation for a later retry.
            } catch {
                syncAvailabilityMessage = error.localizedDescription
            }
        }
        syncSnapshot = await syncCoordinator.snapshot()
    }

    private var privateSyncSharedFolderIDs: Set<UUID> {
        let roots = Set(sharedFolderSessions.keys)
            .union(sharedFolderSnapshots.keys)
            .union(loadSharedFolderLocations().map(\.folderID))
        var result = roots.union(sharedFolderSnapshots.values.flatMap(\.managedFolderIDs))
        let byParent = Dictionary(grouping: snapshot.folders, by: \.parentFolderID)
        var queue = Array(roots)
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for child in byParent[parent] ?? [] where result.insert(child.id).inserted {
                queue.append(child.id)
            }
        }
        return result
    }

    struct PrivateSyncSharedExclusion: Equatable {
        let folderIDs: Set<UUID>
        let savedClipIDs: Set<UUID>
    }

    static func privateSyncSharedExclusion(
        sharedFolderIDs: Set<UUID>,
        sharedManagedClipIDs: Set<UUID>,
        local: ClipboardLibrarySnapshot,
        privateSavedClips: [SavedClip]
    ) -> PrivateSyncSharedExclusion {
        let clipsInSharedFolders = local.savedClips + privateSavedClips
        let relatedClipIDs = Set(clipsInSharedFolders.compactMap { clip -> UUID? in
            guard let folderID = clip.folderID, sharedFolderIDs.contains(folderID) else {
                return nil
            }
            return clip.id
        })
        return PrivateSyncSharedExclusion(
            folderIDs: sharedFolderIDs,
            savedClipIDs: sharedManagedClipIDs.union(relatedClipIDs)
        )
    }

    static func isPrivateSyncExcludedMutation(
        _ mutation: PendingSavedLibraryMutation,
        sharedFolderIDs: Set<UUID>,
        sharedManagedClipIDs: Set<UUID>,
        currentClipsByID: [UUID: SavedClip]
    ) -> Bool {
        switch mutation.kind {
        case .folder:
            return sharedFolderIDs.contains(mutation.id)
        case .savedClip:
            if let current = currentClipsByID[mutation.id] {
                return current.folderID.map(sharedFolderIDs.contains) ?? false
            }
            return sharedManagedClipIDs.contains(mutation.id)
        }
    }

    @discardableResult
    private func enqueuePrivateSyncTombstonesForSharedEntities() async -> Bool {
        guard syncSnapshot.isEnabled,
              !isSyncOptOutRequested,
              let syncCoordinator,
              let library
        else { return false }

        let coordinatorSnapshot = await syncCoordinator.snapshot()
        let materialized = await syncCoordinator.materializedLibrary()
        let local = await library.snapshot()
        let exclusion = Self.privateSyncSharedExclusion(
            sharedFolderIDs: privateSyncSharedFolderIDs,
            sharedManagedClipIDs: Set(
                sharedFolderSnapshots.values.flatMap(\.managedSavedClipIDs)
            ),
            local: local,
            privateSavedClips: materialized.savedClips
        )
        var didEnqueue = false

        // Tombstone clips before folders. The private coordinator intentionally unfiles children
        // of deleted folders, which would otherwise erase the evidence that they belong to the
        // collaborative data plane before those stale private records can be removed.
        for id in exclusion.savedClipIDs.sorted(by: { $0.uuidString < $1.uuidString }) where
            coordinatorSnapshot.records[id]?.isTombstone != true
                || coordinatorSnapshot.records[id]?.kind != .savedClip
        {
            do {
                _ = try await syncCoordinator.recordDeletion(id: id, kind: .savedClip)
                didEnqueue = true
            } catch {
                syncAvailabilityMessage = "Could not isolate a collaborative clip from private sync: \(error.localizedDescription)"
            }
        }
        for id in exclusion.folderIDs.sorted(by: { $0.uuidString < $1.uuidString }) where
            coordinatorSnapshot.records[id]?.isTombstone != true
                || coordinatorSnapshot.records[id]?.kind != .folder
        {
            do {
                _ = try await syncCoordinator.recordDeletion(id: id, kind: .folder)
                didEnqueue = true
            } catch {
                syncAvailabilityMessage = "Could not isolate a collaborative folder from private sync: \(error.localizedDescription)"
            }
        }
        syncSnapshot = await syncCoordinator.snapshot()
        return didEnqueue
    }

    private func scheduleBackgroundSavedLibrarySync() {
        guard directLicenseAccessPolicy.allows(.cloud),
              syncSnapshot.isEnabled,
              !isSyncOptOutRequested,
              syncContainerIdentifier != nil
        else { return }
        Task { [weak self] in
            await self?.synchronizeAndApplyRemote()
        }
    }

    private func startSyncRefreshLoopIfNeeded() {
        guard directLicenseAccessPolicy.allows(.cloud),
              syncRefreshTask == nil,
              syncSnapshot.isEnabled,
              !isSyncOptOutRequested,
              syncContainerIdentifier != nil
        else { return }
        syncRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                guard self.syncSnapshot.isEnabled,
                      !self.isSyncOptOutRequested,
                      self.syncContainerIdentifier != nil
                else { return }
                await self.synchronizeAndApplyRemote()
            }
        }
    }

    private func stopSyncRefreshLoop() {
        syncRefreshTask?.cancel()
        syncRefreshTask = nil
    }

    private func synchronizeAndApplyRemote() async {
        guard directLicenseAccessPolicy.allows(.cloud) else { return }
        if isSyncApplyInProgress {
            syncApplyNeedsAnotherPass = true
            return
        }
        isSyncApplyInProgress = true
        let projectionGeneration = syncProjectionGeneration
        defer {
            isSyncApplyInProgress = false
            if syncApplyNeedsAnotherPass {
                syncApplyNeedsAnotherPass = false
                if syncSnapshot.isEnabled && !isSyncOptOutRequested {
                    Task { @MainActor [weak self] in
                        await self?.synchronizeAndApplyRemote()
                    }
                }
            }
        }
        guard syncSnapshot.isEnabled,
              !isSyncOptOutRequested,
              let syncCoordinator,
              let library
        else { return }
        // The durable local journal always reaches the outbox before remote fetch/projection.
        await drainPendingSavedLibraryMutations()
        await enqueuePrivateSyncTombstonesForSharedEntities()
        guard projectionGeneration == syncProjectionGeneration,
              syncSnapshot.isEnabled,
              !isSyncOptOutRequested
        else { return }
        await syncCoordinator.synchronize()
        if await enqueuePrivateSyncTombstonesForSharedEntities() {
            // A just-fetched stale private record may have a newer stamp than the preflight
            // tombstone. Issue one newer tombstone and flush it before projection.
            await syncCoordinator.synchronize()
        }
        let coordinatorSnapshot = await syncCoordinator.snapshot()
        guard projectionGeneration == syncProjectionGeneration,
              !isSyncOptOutRequested
        else { return }
        syncSnapshot = coordinatorSnapshot
        // A concurrent opt-out invalidates projection as well as network work. Stale coordinator
        // records must never overwrite local edits after the user disables sync.
        guard coordinatorSnapshot.isEnabled else { return }
        switch coordinatorSnapshot.status {
        case .failed(let message): syncAvailabilityMessage = message
        case .accountUnavailable(let account):
            syncAvailabilityMessage = "Sign in to iCloud in System Settings (account: \(account.rawValue))."
        case .offline: syncAvailabilityMessage = "Offline. Local changes are queued and will retry."
        case .disabled: break
        case let .idle(lastSuccessfulSync):
            syncAvailabilityMessage = nil
            if let lastSuccessfulSync {
                syncLastSuccessfulDate = lastSuccessfulSync
                defaults.set(lastSuccessfulSync, forKey: Self.syncLastSuccessKey)
            }
        case .syncing: syncAvailabilityMessage = nil
        }

        let materialized = await syncCoordinator.materializedLibrary()
        guard projectionGeneration == syncProjectionGeneration,
              syncSnapshot.isEnabled,
              !isSyncOptOutRequested
        else { return }
        let currentLocalSnapshot = await library.snapshot()
        let sharedExclusion = Self.privateSyncSharedExclusion(
            sharedFolderIDs: privateSyncSharedFolderIDs,
            sharedManagedClipIDs: Set(
                sharedFolderSnapshots.values.flatMap(\.managedSavedClipIDs)
            ),
            local: currentLocalSnapshot,
            privateSavedClips: materialized.savedClips
        )
        let pendingSavedClipIDs = Set(
            currentLocalSnapshot.pendingSavedLibraryMutations
                .filter { $0.kind == .savedClip }
                .map(\.id)
        )
        let pendingFolderIDs = Set(
            currentLocalSnapshot.pendingSavedLibraryMutations
                .filter { $0.kind == .folder }
                .map(\.id)
        )
        let protectedSavedClipIDs = pendingSavedClipIDs.union(sharedExclusion.savedClipIDs)
        let protectedFolderIDs = pendingFolderIDs.union(sharedExclusion.folderIDs)
        if !pendingSavedClipIDs.isEmpty || !pendingFolderIDs.isEmpty {
            syncAvailabilityMessage = "Some local saved-library changes could not enter the sync outbox. They remain local-only, pending, and protected from remote replacement."
        }
        let managedSavedClipIDs = Self.managedProjectionIDs(
            in: coordinatorSnapshot,
            kind: .savedClip,
            protecting: protectedSavedClipIDs
        )
        let managedFolderIDs = Self.managedProjectionIDs(
            in: coordinatorSnapshot,
            kind: .folder,
            protecting: protectedFolderIDs
        )
        guard projectionGeneration == syncProjectionGeneration,
              syncSnapshot.isEnabled,
              !isSyncOptOutRequested
        else { return }
        do {
            try await library.applySyncedSavedLibrary(
                savedClips: materialized.savedClips.filter {
                    !protectedSavedClipIDs.contains($0.id)
                },
                folders: materialized.folders.filter {
                    !protectedFolderIDs.contains($0.id)
                },
                managedSavedClipIDs: managedSavedClipIDs,
                managedFolderIDs: managedFolderIDs
            )
            try await refreshSnapshot()
        } catch {
            syncAvailabilityMessage = "Remote changes are safe in the sync log, but could not be applied locally: \(error.localizedDescription)"
        }
    }

    private static var cloudKitUnavailableMessage: String {
        "iCloud sync is unavailable in this build. Install an Apple Developer-signed build whose Info.plist and entitlements contain the same CloudKit container. Local clips continue to work."
    }

    func noteCloudPushRegistrationSucceeded() {
        cloudPushRegistrationMessage = nil
    }

    func noteCloudPushRegistrationFailure(_ error: any Error) {
        cloudPushRegistrationMessage =
            "macOS could not register this app for silent CloudKit notifications: \(error.localizedDescription). Recovery polling remains active."
    }

    @discardableResult
    func receiveCloudKitRemoteNotification(_ userInfo: [String: Any]) async -> Bool {
        guard let expectedContainer = cloudPushExpectedContainerIdentifier else { return false }
        let payload = Dictionary(uniqueKeysWithValues: userInfo.map { (AnyHashable($0.key), $0.value) })
        guard let notification = cloudPushNotificationDecoder.decode(payload) else { return false }
        let scopes = CloudPushNotificationRouter.refreshScopes(
            for: notification,
            expectedContainerIdentifier: expectedContainer
        )
        guard !scopes.isEmpty else { return false }
        await cloudPushRefreshCoalescer.requestRefresh(for: scopes)
        return true
    }

    private var cloudPushExpectedContainerIdentifier: String? {
        syncContainerIdentifier ?? injectedCloudPushSubscriptionCoordinator?.containerIdentifier
    }

    private func installCloudPushSubscriptions(forceVerification: Bool) async {
        guard directLicenseAccessPolicy.allows(.cloud),
              syncSnapshot.isEnabled || !sharedFolderSessions.isEmpty
        else { return }
        if Self.isCloudKitPushEnabled() {
            NSApp.registerForRemoteNotifications()
        }
        let coordinator: CloudPushSubscriptionCoordinator
        if let existing = cloudPushSubscriptionCoordinator
            ?? injectedCloudPushSubscriptionCoordinator
        {
            coordinator = existing
            cloudPushSubscriptionCoordinator = existing
        } else {
            guard Self.isCloudKitPushEnabled(),
                  let containerIdentifier = syncContainerIdentifier,
                  let environment = Self.configuredCloudKitEnvironment()
            else {
                cloudPushInstallationStatus = .notConfigured
                return
            }
            let created = CloudPushSubscriptionCoordinator(
                containerIdentifier: containerIdentifier,
                environment: environment,
                client: CloudKitPushSubscriptionClient(
                    containerIdentifier: containerIdentifier
                ),
                store: JSONFileCloudPushInstallationStateStore(
                    fileURL: supportDirectory.appendingPathComponent(
                        "cloud-push-subscriptions.json"
                    )
                )
            )
            cloudPushSubscriptionCoordinator = created
            coordinator = created
        }

        if !forceVerification,
           case let .ready(lastVerifiedAt, _) = cloudPushInstallationStatus,
           Date().timeIntervalSince(lastVerifiedAt) < 24 * 60 * 60
        {
            return
        }
        cloudPushInstallationStatus = .installing
        cloudPushInstallationStatus = await coordinator.install().status
    }

    private func performCloudPushRefresh(for scopes: Set<CloudPushDatabaseScope>) async {
        guard directLicenseAccessPolicy.allows(.cloud) else { return }
        // A private-database signal may represent either personal saved-library records or zones
        // owned and shared by this account. Shared-database signals apply only to accepted zones.
        if scopes.contains(.private), syncSnapshot.isEnabled, syncContainerIdentifier != nil {
            await synchronizeAndApplyRemote()
        }
        if !sharedFolderSessions.isEmpty,
           (scopes.contains(.private) || scopes.contains(.shared))
        {
            await refreshAllSharedFolders(trigger: "push")
        }
    }

    private static func configuredCloudKitContainerIdentifier() -> String? {
        guard let raw = Bundle.main.object(
            forInfoDictionaryKey: cloudKitContainerInfoKey
        ) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("iCloud."), !value.contains("PLACEHOLDER") else { return nil }
        return value
    }

    private static func configuredCloudKitEnvironment() -> CloudPushEnvironment? {
        guard let raw = Bundle.main.object(
            forInfoDictionaryKey: cloudKitEnvironmentInfoKey
        ) as? String else { return nil }
        return CloudPushEnvironment(rawValue: raw.lowercased())
    }

    private static func isCloudKitPushEnabled() -> Bool {
        Bundle.main.object(forInfoDictionaryKey: cloudKitPushEnabledInfoKey) as? Bool == true
    }

    private static func shortAccountLabel(_ fingerprint: String?) -> String {
        guard let fingerprint, !fingerprint.isEmpty else { return "Unknown" }
        return "Account …\(fingerprint.suffix(8))"
    }

    private static func sensitivityConfidence(_ confidence: SecretConfidence) -> Int {
        switch confidence {
        case .medium: 70
        case .high: 100
        }
    }

    private static func matches(
        _ option: ApplicationExclusionOption,
        destination: ExternalDestination
    ) -> Bool {
        guard let teamIdentifier = option.teamIdentifier else { return false }
        let observedName = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return destination.applicationIdentities.contains { identity in
            guard identity.product == destination.productIdentity,
                  identity.bundleIdentifiers.contains(option.bundleIdentifier),
                  identity.teamIdentifiers.contains(teamIdentifier)
            else { return false }
            return identity.productNames.contains { acceptedName in
                acceptedName.trimmingCharacters(in: .whitespacesAndNewlines)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) == observedName
            }
        }
    }

    private static func isValidHostedAssistantModel(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 120
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    func capture(_ draft: PasteboardCaptureDraft) {
        guard let library, !isStartingPrivateSession else { return }
        let observedPrivateSessionGeneration = isPrivateSessionActive
            ? privateSessionGeneration : nil
        let observedDeveloperProjectID = automaticDeveloperProjectID(
            sourceBundleIdentifier: draft.source.applicationBundleIdentifier
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                let ocrText: String?
                if let imageData = draft.image?.data {
                    ocrText = try? await self.ocrService.recognizeText(in: imageData)
                } else {
                    ocrText = nil
                }
                // A session transition takes precedence over ordinary history. If capture
                // started just before the user activated Private Session, fail closed rather
                // than allowing this value to enter persistent history or quarantine metadata.
                guard (!self.isPrivateSessionActive && !self.isStartingPrivateSession)
                    || observedPrivateSessionGeneration != nil
                else { return }
                let ephemeralCandidate = try self.ephemeralCandidate(
                    for: draft,
                    ocrText: ocrText
                )

                // Recheck policy before OCR-derived text can enter quarantine or assets can be
                // materialized. The monitor already checks, but settings can race this task.
                guard case .accept = self.snapshot.settings.capturePolicy.decision(
                    for: ephemeralCandidate
                ) else { return }

                let containsSecret = self.snapshot.settings.effectiveSecretDetectionEnabled
                    && self.secretDetector.scan(ephemeralCandidate.content).containsSecret

                if let observedPrivateSessionGeneration {
                    guard self.isPrivateSessionActive,
                          self.privateSessionGeneration == observedPrivateSessionGeneration
                    else { return }
                    if containsSecret {
                        if case let .quarantined(receipt) = await self.quarantineStore.submit(
                            ephemeralCandidate.content
                        ) {
                            guard self.isPrivateSessionActive,
                                  self.privateSessionGeneration == observedPrivateSessionGeneration
                            else {
                                _ = await self.quarantineStore.delete(id: receipt.id)
                                return
                            }
                            self.quarantineMetadata[receipt.id] = QuarantineCaptureMetadata(
                                sourceApplicationBundleIdentifier:
                                    ephemeralCandidate.sourceApplicationBundleIdentifier,
                                originatingDeviceIdentifier:
                                    ephemeralCandidate.originatingDeviceIdentifier,
                                captureContext: ephemeralCandidate.captureContext,
                                pasteboardTypeIdentifiers:
                                    ephemeralCandidate.pasteboardTypeIdentifiers,
                                capturedAt: ephemeralCandidate.capturedAt,
                                draft: draft,
                                ocrText: ocrText,
                                privateSessionGeneration: observedPrivateSessionGeneration
                            )
                            await self.refreshClipboardHealth()
                            self.statusMessage = "Sensitive content copied during Private Session was held only in memory for review."
                        }
                        return
                    }
                    try await self.privateSession.append(
                        PrivateSessionClip(id: UUID(), candidate: ephemeralCandidate)
                    )
                    await self.publishPrivateSessionState(
                        expectedGeneration: observedPrivateSessionGeneration
                    )
                    return
                }

                guard !self.isPrivateSessionActive, !self.isStartingPrivateSession else { return }
                if containsSecret {
                    if case let .quarantined(receipt) = await self.quarantineStore.submit(
                        ephemeralCandidate.content
                    ) {
                        self.quarantineMetadata[receipt.id] = QuarantineCaptureMetadata(
                            sourceApplicationBundleIdentifier:
                                ephemeralCandidate.sourceApplicationBundleIdentifier,
                            originatingDeviceIdentifier:
                                ephemeralCandidate.originatingDeviceIdentifier,
                            captureContext: ephemeralCandidate.captureContext,
                            pasteboardTypeIdentifiers:
                                ephemeralCandidate.pasteboardTypeIdentifiers,
                            capturedAt: ephemeralCandidate.capturedAt,
                            draft: draft,
                            ocrText: ocrText,
                            privateSessionGeneration: nil
                        )
                        await self.refreshClipboardHealth()
                        self.statusMessage = "A potentially sensitive clip was held in memory for review and was not added to history."
                    }
                    return
                }

                let materialized = try await self.captureMaterializer.materialize(
                    draft,
                    ocrText: ocrText
                )
                let candidate = self.attachingOptionalCaptureContext(to: materialized)
                guard !self.isPrivateSessionActive, !self.isStartingPrivateSession else { return }
                let outcome = try await library.capture(candidate)
                try await self.refreshSnapshot()
                await self.autoAddDeveloperCapture(
                    outcome,
                    candidate: candidate,
                    observedProjectID: observedDeveloperProjectID
                )
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Compatibility path for unit adapters and any legacy text-only monitor.
    private func capture(_ candidate: CaptureCandidate) {
        guard let library, !isStartingPrivateSession else { return }
        let observedPrivateSessionGeneration = isPrivateSessionActive
            ? privateSessionGeneration : nil
        let observedDeveloperProjectID = automaticDeveloperProjectID(
            sourceBundleIdentifier: candidate.sourceApplicationBundleIdentifier
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                let protectedCandidate = self.strippingOptionalCaptureContext(from: candidate)
                guard (!self.isPrivateSessionActive && !self.isStartingPrivateSession)
                    || observedPrivateSessionGeneration != nil
                else { return }
                // Apply capture exclusions before even retaining a sensitive value in memory.
                guard case .accept = self.snapshot.settings.capturePolicy.decision(for: candidate)
                else { return }

                let containsSecret = self.snapshot.settings.effectiveSecretDetectionEnabled
                    && self.secretDetector.scan(candidate.content).containsSecret

                if let observedPrivateSessionGeneration {
                    guard self.isPrivateSessionActive,
                          self.privateSessionGeneration == observedPrivateSessionGeneration
                    else { return }
                    if containsSecret {
                        if case let .quarantined(receipt) = await self.quarantineStore.submit(
                            protectedCandidate.content
                        ) {
                            guard self.isPrivateSessionActive,
                                  self.privateSessionGeneration == observedPrivateSessionGeneration
                            else {
                                _ = await self.quarantineStore.delete(id: receipt.id)
                                return
                            }
                            self.quarantineMetadata[receipt.id] = QuarantineCaptureMetadata(
                                sourceApplicationBundleIdentifier:
                                    protectedCandidate.sourceApplicationBundleIdentifier,
                                originatingDeviceIdentifier:
                                    protectedCandidate.originatingDeviceIdentifier,
                                captureContext: protectedCandidate.captureContext,
                                pasteboardTypeIdentifiers:
                                    protectedCandidate.pasteboardTypeIdentifiers,
                                capturedAt: protectedCandidate.capturedAt,
                                draft: nil,
                                ocrText: protectedCandidate.content.representations.ocrText,
                                privateSessionGeneration: observedPrivateSessionGeneration
                            )
                            await self.refreshClipboardHealth()
                        }
                        return
                    }
                    try await self.privateSession.append(
                        PrivateSessionClip(id: UUID(), candidate: protectedCandidate)
                    )
                    await self.publishPrivateSessionState(
                        expectedGeneration: observedPrivateSessionGeneration
                    )
                    return
                }

                guard !self.isPrivateSessionActive, !self.isStartingPrivateSession else { return }
                if containsSecret {
                    switch await self.quarantineStore.submit(protectedCandidate.content) {
                    case .allowed:
                        break
                    case let .quarantined(receipt):
                        self.quarantineMetadata[receipt.id] = QuarantineCaptureMetadata(
                            sourceApplicationBundleIdentifier:
                                protectedCandidate.sourceApplicationBundleIdentifier,
                            originatingDeviceIdentifier:
                                protectedCandidate.originatingDeviceIdentifier,
                            captureContext: protectedCandidate.captureContext,
                            pasteboardTypeIdentifiers:
                                protectedCandidate.pasteboardTypeIdentifiers,
                            capturedAt: protectedCandidate.capturedAt,
                            draft: nil,
                            ocrText: protectedCandidate.content.representations.ocrText,
                            privateSessionGeneration: nil
                        )
                        await self.refreshClipboardHealth()
                        self.statusMessage = "A potentially sensitive clip was held in memory for review and was not added to history."
                        return
                    }
                }

                let ordinaryCandidate = self.attachingOptionalCaptureContext(to: candidate)
                guard !self.isPrivateSessionActive, !self.isStartingPrivateSession else { return }
                let outcome = try await library.capture(ordinaryCandidate)
                try await self.refreshSnapshot()
                await self.autoAddDeveloperCapture(
                    outcome,
                    candidate: ordinaryCandidate,
                    observedProjectID: observedDeveloperProjectID
                )
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func ephemeralCandidate(
        for draft: PasteboardCaptureDraft,
        ocrText: String?
    ) throws -> CaptureCandidate {
        let text = draft.textForSensitivityAnalysis(ocrText: ocrText)

        let type: SupportedContentType
        if draft.image != nil {
            type = .image
        } else if !draft.fileURLs.isEmpty {
            type = .fileURLs
        } else if draft.richTextData != nil || draft.htmlData != nil {
            type = .richText
        } else if draft.url != nil {
            type = .url
        } else {
            type = .plainText
        }
        let files = try draft.fileURLs.map { try ClipFileReference(url: $0) }
        let content = try ClipContent(
            type: type,
            text: text,
            representations: ClipRepresentations(
                files: files,
                url: draft.url.map {
                    URLClipMetadata(originalURL: $0.absoluteString, host: $0.host)
                },
                ocrText: ocrText
            )
        )
        return CaptureCandidate(
            content: content,
            sourceApplicationBundleIdentifier: draft.source.applicationBundleIdentifier,
            captureContext: draft.source.clipCaptureContext,
            pasteboardTypeIdentifiers: draft.typeIdentifiers,
            capturedAt: draft.capturedAt
        )
    }

    private func attachingOptionalCaptureContext(
        to candidate: CaptureCandidate
    ) -> CaptureCandidate {
        let includesDevice = snapshot.settings.effectiveDeviceContextEnabled
        let includesLocation = snapshot.settings.effectiveLocationContextEnabled
        let location = includesLocation
            ? captureContextProvider.currentCoarseLocation(at: Date()) : nil
        guard includesDevice || location != nil else { return candidate }
        var context = candidate.captureContext ?? ClipCaptureContext()
        if includesDevice {
            let device = captureContextProvider.deviceContext
            context.deviceLabel = device.label
            context.operatingSystem = device.operatingSystem
        }
        if let location { context.coarseLocation = location }
        return CaptureCandidate(
            content: candidate.content,
            sourceApplicationBundleIdentifier: candidate.sourceApplicationBundleIdentifier,
            originatingDeviceIdentifier: includesDevice
                ? captureContextInstallationID : candidate.originatingDeviceIdentifier,
            captureContext: context,
            sensitivity: candidate.sensitivity,
            pasteboardTypeIdentifiers: candidate.pasteboardTypeIdentifiers,
            capturedAt: candidate.capturedAt
        )
    }

    private func strippingOptionalCaptureContext(
        from candidate: CaptureCandidate
    ) -> CaptureCandidate {
        var context = candidate.captureContext
        context?.deviceLabel = nil
        context?.operatingSystem = nil
        context?.coarseLocation = nil
        if let remaining = context,
           remaining.sourceApplicationName == nil,
           remaining.sourceURL == nil,
           remaining.sourceDomain == nil
        {
            context = nil
        }
        return CaptureCandidate(
            content: candidate.content,
            sourceApplicationBundleIdentifier: candidate.sourceApplicationBundleIdentifier,
            originatingDeviceIdentifier: nil,
            captureContext: context,
            sensitivity: candidate.sensitivity,
            pasteboardTypeIdentifiers: candidate.pasteboardTypeIdentifiers,
            capturedAt: candidate.capturedAt
        )
    }

    private func refreshClipboardHealth() async {
        let expiration = await quarantineStore.expirationSnapshot()
        quarantineReceipts = expiration.pending
        clipboardHealth = expiration.health
        let activeIDs = Set(expiration.pending.map(\.id))
        quarantineMetadata = quarantineMetadata.filter { activeIDs.contains($0.key) }
        scheduleQuarantineExpiration(at: expiration.nextExpirationDate)
    }

    private func scheduleQuarantineExpiration(at date: Date?) {
        quarantineExpirationTask?.cancel()
        quarantineExpirationTask = nil
        guard let date else { return }
        let nanoseconds = UInt64(max(0, date.timeIntervalSinceNow) * 1_000_000_000)
        quarantineExpirationTask = Task { @MainActor [weak self] in
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled, let self else { return }
            self.quarantineExpirationTask = nil
            await self.refreshClipboardHealth()
        }
    }

    private func publishPrivateSessionState(expectedGeneration: UInt64) async {
        let clips = await privateSession.snapshot().map {
            let candidate = $0.candidate
            return PresentedClip(
                id: $0.id,
                title: Self.previewTitle(for: candidate.content),
                content: candidate.content,
                date: candidate.capturedAt,
                sourceBundleIdentifier: candidate.sourceApplicationBundleIdentifier,
                origin: .privateSession,
                captureContext: candidate.captureContext
            )
        }
        guard isPrivateSessionActive,
              privateSessionGeneration == expectedGeneration
        else { return }
        privateSessionClips = clips
    }

    static func managedProjectionIDs(
        in snapshot: SavedLibrarySyncSnapshot,
        kind: SyncEntityKind,
        protecting protectedIDs: Set<UUID>
    ) -> Set<UUID> {
        let localOnlyIDs = Set(snapshot.entityStates.compactMap { id, state in
            if case .localOnly = state { return id }
            return nil
        })
        return Set(
            snapshot.records.values
                .filter { $0.kind == kind && !localOnlyIDs.contains($0.id) }
                .map(\.id)
        ).subtracting(protectedIDs)
    }

    private func publishPasteStackState() {
        pasteStackItems = pasteStack.entries.map(\.payload)
        pasteStackCurrentIndex = pasteStack.currentIndex
    }

    private func presentedClip(for result: ClipSearchResult) -> PresentedClip {
        switch result.kind {
        case .historyItem:
            let history = snapshot.history.first(where: { $0.id == result.id })
            return PresentedClip(
                id: result.id,
                title: Self.previewTitle(for: result.content),
                content: result.content,
                date: result.recency,
                sourceBundleIdentifier: result.sourceApplicationBundleIdentifier,
                origin: .history,
                captureContext: result.captureContext,
                sensitivity: result.sensitivity,
                pasteboardTypeIdentifiers: result.pasteboardTypeIdentifiers,
                captureCount: result.captureCount,
                pasteCount: result.pasteCount,
                lastPastedAt: history?.lastPastedAt
            )
        case .savedClip:
            let saved = snapshot.savedClips.first(where: { $0.id == result.id })
            let history = saved?.sourceHistoryItemID.flatMap { historyID in
                snapshot.history.first(where: { $0.id == historyID })
            }
            return PresentedClip(
                id: result.id,
                title: result.name ?? Self.previewTitle(for: result.content),
                content: result.content,
                date: result.recency,
                sourceBundleIdentifier: result.sourceApplicationBundleIdentifier,
                origin: .saved(folderID: result.folderID),
                savedItemKind: result.savedItemKind ?? saved?.kind ?? .clip,
                captureContext: result.captureContext,
                sensitivity: result.sensitivity,
                isPinned: result.isPinned,
                tags: result.tags,
                pasteboardTypeIdentifiers: result.pasteboardTypeIdentifiers,
                captureCount: result.captureCount,
                pasteCount: result.pasteCount,
                lastPastedAt: history?.lastPastedAt
            )
        }
    }

    private func refreshSnapshot() async throws {
        guard let library else { return }
        let refreshedSnapshot = await library.snapshot()
        staticSmartViews = makeStaticSmartViews(for: refreshedSnapshot)
        snapshot = refreshedSnapshot
        await assetStore.setQuotaBytes(snapshot.settings.effectiveMaximumAssetStorageBytes)
        if !searchText.isEmpty {
            searchResults = await library.search(query: searchText, limit: 500)
        }
        scheduleUserSmartViewCountRefresh()
        try? await collectUnreferencedAssets()
    }

    private func refreshUserSmartViewCounts() async {
        guard let library, !userSmartViews.isEmpty else {
            userSmartViewCounts = [:]
            return
        }
        var counts: [UUID: Int] = [:]
        for view in userSmartViews {
            counts[view.id] = await library.search(query: view.query, limit: 10_000).count
        }
        userSmartViewCounts = counts
    }

    private func scheduleUserSmartViewCountRefresh() {
        smartViewCountTask?.cancel()
        smartViewCountTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.refreshUserSmartViewCounts()
        }
    }

    private func collectUnreferencedAssets(
        olderThan cutoff: Date = Date().addingTimeInterval(-5 * 60)
    ) async throws {
        let references = Set(
            (snapshot.history.map(\.content) + snapshot.savedClips.map(\.content))
                .flatMap(\.representations.referencedAssets)
        )
        // Leave a grace window for a representation that has been materialized but whose
        // corresponding library transaction is still in flight.
        _ = try await assetStore.collectGarbage(
            keeping: references,
            olderThan: cutoff
        )
    }

    private func removeMovedOrdinaryAssetsIfUnreferenced(_ content: ClipContent) async throws {
        let retained = Set(
            (snapshot.history.map(\.content) + snapshot.savedClips.map(\.content))
                .flatMap(\.representations.referencedAssets)
        )
        for reference in content.representations.referencedAssets where !retained.contains(reference) {
            try await assetStore.removeUnreferenced(reference)
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else {
            errorMessage = AppModelOperationError.operationInProgress.localizedDescription
            return
        }
        isBusy = true
        Task { [weak self] in
            defer { self?.isBusy = false }
            do {
                try await operation()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// Clipboard writes and routes are independent of library/cloud maintenance. They are queued
    /// in click order so an unrelated sync/export cannot silently drop a copy, while rapid user
    /// actions cannot race each other on the one system pasteboard.
    private func enqueueClipboardAction(
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        clipboardActionQueue.append(operation)
        guard !isClipboardActionInFlight else { return }
        isClipboardActionInFlight = true
        Task { [weak self] in
            guard let self else { return }
            while !self.clipboardActionQueue.isEmpty {
                let next = self.clipboardActionQueue.removeFirst()
                do {
                    try await next()
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
            self.isClipboardActionInFlight = false
        }
    }

    func setSecurePasteTimeout(seconds: Int) {
        guard [15, 30, 45, 60].contains(seconds) else { return }
        securePasteTimeoutSeconds = seconds
        defaults.set(seconds, forKey: Self.securePasteTimeoutKey)
    }

    func refreshLaunchAtLoginState() {
        launchAtLoginState = launchAtLoginService.state
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        refreshLaunchAtLoginState()
        let isRegistered = launchAtLoginState == .on || launchAtLoginState == .requiresApproval
        guard enabled != isRegistered else {
            refreshLaunchAtLoginState()
            return
        }
        do {
            if enabled {
                try launchAtLoginService.register()
            } else {
                try launchAtLoginService.unregister()
            }
            refreshLaunchAtLoginState()
            errorMessage = nil
            switch launchAtLoginState {
            case .on:
                statusMessage = "Clipboard Router will launch when you log in."
            case .off:
                statusMessage = "Clipboard Router will no longer launch at login."
            case .requiresApproval:
                statusMessage = "Approve Clipboard Router in System Settings > General > Login Items."
            case .unavailable:
                errorMessage = "Launch at login is unavailable in this build."
            }
        } catch {
            refreshLaunchAtLoginState()
            errorMessage = "Launch at login could not be updated: \(error.localizedDescription)"
        }
    }

    func openLoginItemsSettings() {
        launchAtLoginService.openSystemSettings()
    }

    func setGlobalHotKeyChoice(_ choice: GlobalHotKeyChoice) {
        guard choice != globalHotKeyChoice else { return }
        guard choice.descriptor != createNoteHotKeyChoice.descriptor,
              choice.descriptor != insertPaletteHotKeyChoice.descriptor
        else {
            errorMessage = "Choose different shortcuts for Clipboard Search, Create Note, and Quick Paste."
            return
        }
        let previous = globalHotKeyChoice
        do {
            try registerGlobalHotKey(choice)
            globalHotKeyChoice = choice
            defaults.set(choice.rawValue, forKey: Self.globalHotKeyChoiceKey)
            statusMessage = "Global shortcut changed to \(choice.displayName)."
        } catch {
            // Registering a new Carbon hotkey first unregisters the old one. Restore the known
            // working selection before reporting the conflict.
            try? registerGlobalHotKey(previous)
            errorMessage = "\(choice.displayName) could not be registered: \(error.localizedDescription)"
        }
    }

    func setCreateNoteHotKeyChoice(_ choice: GlobalHotKeyChoice) {
        guard choice != createNoteHotKeyChoice else { return }
        guard choice.descriptor != globalHotKeyChoice.descriptor,
              choice.descriptor != insertPaletteHotKeyChoice.descriptor
        else {
            errorMessage = "Choose different shortcuts for Clipboard Search, Create Note, and Quick Paste."
            return
        }
        let previous = createNoteHotKeyChoice
        do {
            try registerCreateNoteHotKey(choice)
            createNoteHotKeyChoice = choice
            defaults.set(choice.rawValue, forKey: Self.createNoteHotKeyChoiceKey)
            statusMessage = "Create Note shortcut changed to \(choice.displayName)."
        } catch {
            try? registerCreateNoteHotKey(previous)
            errorMessage = "\(choice.displayName) could not be registered: \(error.localizedDescription)"
        }
    }

    func setInsertPaletteHotKeyChoice(_ choice: GlobalHotKeyChoice) {
        guard choice != insertPaletteHotKeyChoice else { return }
        guard choice.descriptor != globalHotKeyChoice.descriptor,
              choice.descriptor != createNoteHotKeyChoice.descriptor
        else {
            errorMessage = "Choose different shortcuts for Clipboard Search, Create Note, and Quick Paste."
            return
        }
        let previous = insertPaletteHotKeyChoice
        do {
            try registerInsertPaletteHotKey(choice)
            insertPaletteHotKeyChoice = choice
            defaults.set(choice.rawValue, forKey: Self.insertPaletteHotKeyChoiceKey)
            statusMessage = "Quick Paste shortcut changed to \(choice.displayName)."
        } catch {
            try? registerInsertPaletteHotKey(previous)
            errorMessage = "\(choice.displayName) could not be registered: \(error.localizedDescription)"
        }
    }

    private func registerGlobalHotKey(_ choice: GlobalHotKeyChoice) throws {
        try hotKey.register(id: .showClipboardRouter, descriptor: choice.descriptor) {
            self.rememberPasteTarget()
            let pointerLocation = NSEvent.mouseLocation
            self.selectedSection = .history
            self.searchFocusRequestID &+= 1
            NSApp.activate(ignoringOtherApps: true)
            let window = NSApp.windows.first {
                $0.title == "Clipboard Router" && $0.canBecomeKey
            } ?? NSApp.windows.first(where: { $0.canBecomeKey })
            if let window {
                Self.center(window: window, onScreenContaining: pointerLocation)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func registerCreateNoteHotKey(_ choice: GlobalHotKeyChoice) throws {
        try hotKey.register(id: .createNote, descriptor: choice.descriptor) {
            self.requestCreateNote(presentationSurface: .library)
            self.selectedSection = .smartView(.notes)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
        }
    }

    private func registerInsertPaletteHotKey(_ choice: GlobalHotKeyChoice) throws {
        try hotKey.register(id: .insertPalette, descriptor: choice.descriptor) {
            self.requestInsertPalette(
                capturingCurrentApplication: true,
                presentationSurface: .library
            )
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
        }
    }

    private static func center(window: NSWindow, onScreenContaining point: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
            ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let x = min(
            max(visible.minX, point.x - window.frame.width / 2),
            max(visible.minX, visible.maxX - window.frame.width)
        )
        let y = min(
            max(visible.minY, point.y - window.frame.height / 2),
            max(visible.minY, visible.maxY - window.frame.height)
        )
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func defaultSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipboardRouter", isDirectory: true)
    }

    private nonisolated static func discoverApplications(
        runningBundleIdentifiers: Set<String>
    ) -> [ApplicationExclusionOption] {
        let currentUserName = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let realUserHomeDirectory = currentUserName.isEmpty
            ? nil
            : NSHomeDirectoryForUser(currentUserName).map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        let roots = applicationDiscoveryRoots(userHomeDirectory: realUserHomeDirectory)
        var optionsByPath: [String: ApplicationExclusionOption] = [:]

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard !Task.isCancelled else { return [] }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard !Task.isCancelled else { return [] }
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                    continue
                }
                enumerator.skipDescendants()
                guard let bundle = Bundle(url: url),
                      let identifier = bundle.bundleIdentifier,
                      !identifier.isEmpty
                else { continue }
                let displayName = (bundle.object(
                    forInfoDictionaryKey: "CFBundleDisplayName"
                ) as? String) ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let option = ApplicationExclusionOption(
                    bundleIdentifier: identifier,
                    displayName: displayName,
                    applicationURL: url,
                    teamIdentifier: nil,
                    isRunning: runningBundleIdentifiers.contains(identifier)
                )
                optionsByPath[url.standardizedFileURL.path] = option
            }
        }

        return optionsByPath.values.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            let nameOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.applicationURL.path.localizedStandardCompare(rhs.applicationURL.path)
                == .orderedAscending
        }
    }

    /// Produces discovery roots without consulting process-global sandbox state. A sandboxed
    /// process can report its container from `homeDirectoryForCurrentUser`; callers therefore
    /// resolve the login user's home with `NSHomeDirectoryForUser` and pass it through this seam.
    /// If macOS still denies that directory, the explicit application picker remains the
    /// user-consented route and no broad filesystem entitlement is required.
    nonisolated static func applicationDiscoveryRoots(
        userHomeDirectory: URL?
    ) -> [URL] {
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        ]
        if let userHomeDirectory {
            roots.append(
                userHomeDirectory.standardizedFileURL
                    .appendingPathComponent("Applications", isDirectory: true)
            )
        }

        var seenPaths = Set<String>()
        return roots.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
    }

    /// Signature checks are intentionally bounded and performed away from the main actor.
    /// Checking hundreds of installed applications serially can leave Settings in a loading
    /// state for close to a minute, while starting one task per app can exhaust the cooperative
    /// thread pool. This worker keeps a small, fixed number of checks in flight and publishes
    /// only the final verified snapshot.
    nonisolated static func verifyApplications(
        _ options: [ApplicationExclusionOption],
        maximumConcurrentChecks: Int = 16,
        inspector: @escaping @Sendable (URL) -> InstalledApplicationMetadata? = {
            SystemApplicationMetadataInspector.discoveryMetadataSnapshot(forApplicationAt: $0)
        }
    ) async -> [ApplicationExclusionOption] {
        guard !options.isEmpty, maximumConcurrentChecks > 0, !Task.isCancelled else {
            return []
        }

        return await withTaskGroup(
            of: (Int, ApplicationExclusionOption?).self,
            returning: [ApplicationExclusionOption].self
        ) { group in
            let initialCount = min(maximumConcurrentChecks, options.count)
            var nextIndex = initialCount
            var verifiedByIndex: [Int: ApplicationExclusionOption] = [:]

            func submit(_ index: Int) {
                let option = options[index]
                group.addTask {
                    guard !Task.isCancelled,
                          let metadata = inspector(option.applicationURL),
                          metadata.bundleIdentifier == option.bundleIdentifier,
                          case let .valid(teamIdentifier) = metadata.signature
                    else { return (index, nil) }
                    return (
                        index,
                        ApplicationExclusionOption(
                            bundleIdentifier: option.bundleIdentifier,
                            displayName: option.displayName,
                            applicationURL: metadata.url,
                            teamIdentifier: teamIdentifier,
                            isRunning: option.isRunning
                        )
                    )
                }
            }

            for index in 0..<initialCount {
                submit(index)
            }

            while let (index, verified) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    return []
                }
                if let verified {
                    verifiedByIndex[index] = verified
                }
                if nextIndex < options.count {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }

            return verifiedByIndex.keys.sorted().compactMap { verifiedByIndex[$0] }
        }
    }

    private static func previewTitle(for content: ClipContent) -> String {
        let trimmed = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Untitled clip"
        return String(firstLine.prefix(100))
    }

    private func presentedSavedClip(_ saved: SavedClip) -> PresentedClip {
        let history = saved.sourceHistoryItemID.flatMap { historyID in
            snapshot.history.first(where: { $0.id == historyID })
        }
        return PresentedClip(
            id: saved.id,
            title: saved.name,
            content: saved.content,
            date: saved.modifiedAt,
            sourceBundleIdentifier: saved.sourceApplicationBundleIdentifier,
            origin: .saved(folderID: saved.folderID),
            savedItemKind: saved.kind,
            captureContext: saved.captureContext,
            sensitivity: saved.sensitivity,
            isPinned: saved.isPinned,
            tags: saved.tags ?? [],
            pasteboardTypeIdentifiers: saved.pasteboardTypeIdentifiers ?? [],
            captureCount: history?.captureCount,
            pasteCount: history?.pasteCount,
            lastPastedAt: history?.lastPastedAt
        )
    }

    private static func searchDateToken(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
