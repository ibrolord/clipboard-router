import Foundation

/// Stable identifiers shared by every clip action surface. These values are deliberately not
/// user-facing; tests and telemetry can rely on them without coupling to localized titles.
enum ClipActionID: String, CaseIterable, Hashable, Sendable {
    case showInLibrary
    case useAI
    case saveToFolder
    case moveToFolder
    case pin
    case editNote
    case editClip
    case makeNote
    case setShortcut
    case rename
    case editTags
    case moveToVault
    case share
    case export
    case quickActions
    case actions
    case copyAndOpen
    case sendToCRM
    case clipTools
    case delete
}

enum ClipActionSurface: String, CaseIterable, Hashable, Sendable {
    case menuBar
    case libraryContext
    case libraryInspector
}

enum ClipActionGroup: Int, CaseIterable, Comparable, Sendable {
    case navigation
    case organization
    case editing
    case sharing
    case productivity
    case integration
    case destructive

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum ClipActionPresentation: Equatable, Sendable {
    case immediate
    case submenu
    case persistentContinuation
    case libraryRoute
    case systemPanel
    case destructive
}

struct ClipActionDescriptor: Equatable, Sendable {
    let id: ClipActionID
    let group: ClipActionGroup
    let order: Int
    let title: String
    let symbolName: String
    let isEnabled: Bool
    let disabledReason: String?
    let presentation: ClipActionPresentation
}

struct ClipActionInventory: Equatable, Sendable {
    let surface: ClipActionSurface
    let descriptors: [ClipActionDescriptor]

    subscript(_ id: ClipActionID) -> ClipActionDescriptor? {
        descriptors.first { $0.id == id }
    }

    func contains(_ id: ClipActionID) -> Bool { self[id] != nil }
}

/// A resolved, side-effect-free view of AppModel policy. Tests use this type to cover the complete
/// state matrix without recreating CloudKit, Vault, AI, or CRM transports.
struct ClipActionCapabilities: Equatable, Sendable {
    var organization: ClipContextMenuPolicy.Organization
    var isHistory: Bool
    var isSaved: Bool
    var isPrivate: Bool
    var isNote: Bool
    var isPinned: Bool
    var isSensitive: Bool
    var canMutateSaved: Bool
    var canEditNote: Bool
    var canEditClip: Bool
    var canMakeNote: Bool
    var canSetShortcut: Bool
    var canMoveToVault: Bool
    var vaultUnavailableReason: String?
    var canShare: Bool
    var canExport: Bool
    var exportUnavailableReason: String?
    var hasQuickActions: Bool
    var hasActionFlows: Bool
    var canRouteToAI: Bool
    var canUseAssistant: Bool
    var canSendToCRM: Bool
    var canUseWorkflows: Bool
    var showsDelete: Bool
    var canDelete: Bool
}

@MainActor
enum ClipActionCatalog {
    /// Metadata management is deliberately Library-only because those editors are owned by the
    /// persistent Library window. `showInLibrary` is deliberately Menu-Bar-only navigation.
    static let deliberateSurfaceDifferences: Set<ClipActionID> = [
        .showInLibrary, .rename, .editTags,
    ]

    static func inventory(
        for clip: PresentedClip,
        model: AppModel,
        surface: ClipActionSurface
    ) -> ClipActionInventory {
        let policy = model.clipContextMenuPolicy(for: clip)
        let suggestions = model.suggestedActions(for: clip)
        let exportDecision = model.clipExportDecision(clip)
        let isSaved = clip.origin.isSaved
        let capabilities = ClipActionCapabilities(
            organization: policy.organization,
            isHistory: clip.origin == .history,
            isSaved: isSaved,
            isPrivate: clip.origin == .privateSession,
            isNote: clip.savedItemKind == .note,
            isPinned: clip.isPinned,
            isSensitive: model.isSensitiveForPresentation(clip),
            canMutateSaved: policy.canMutateSavedClip,
            canEditNote: model.canEditNote(clip),
            canEditClip: model.canEditClip(clip),
            canMakeNote: model.canConvertToNote(clip),
            canSetShortcut: isSaved && model.insertAliasResults(matching: clip.title)
                .contains { $0.clip.id == clip.id },
            canMoveToVault: model.canMoveClipToVault(clip),
            vaultUnavailableReason: model.vaultMoveUnavailableReason(for: clip),
            canShare: policy.canShareClip,
            canExport: policy.canExportClip,
            exportUnavailableReason: exportDecision.unavailableReason,
            hasQuickActions: suggestions.contains { $0.kind != .askAI },
            hasActionFlows: !model.applicableAutomations(for: clip).isEmpty
                || !model.applicableFlows(for: clip).isEmpty || isSaved,
            canRouteToAI: policy.canRouteToAI,
            canUseAssistant: suggestions.contains { $0.kind == .askAI },
            canSendToCRM: model.canSendToCRM(clip),
            canUseWorkflows: policy.canUseWorkflows,
            showsDelete: policy.showsDelete,
            canDelete: policy.canDelete
        )
        return inventory(for: capabilities, surface: surface)
    }

    static func inventory(
        for capabilities: ClipActionCapabilities,
        surface: ClipActionSurface
    ) -> ClipActionInventory {
        var items: [ClipActionDescriptor] = []
        func add(
            _ id: ClipActionID,
            _ group: ClipActionGroup,
            _ order: Int,
            _ title: String,
            _ symbol: String,
            enabled: Bool = true,
            reason: String? = nil,
            presentation: ClipActionPresentation = .immediate
        ) {
            items.append(ClipActionDescriptor(
                id: id,
                group: group,
                order: order,
                title: title,
                symbolName: symbol,
                isEnabled: enabled,
                disabledReason: enabled ? nil : reason,
                presentation: presentation
            ))
        }

        if surface == .menuBar, !capabilities.isPrivate, !capabilities.isSensitive {
            add(.showInLibrary, .navigation, 0, "Show in Library…", "text.viewfinder", presentation: .libraryRoute)
        }
        if capabilities.canUseAssistant {
            add(.useAI, .navigation, 10, "Use AI…", "sparkles", presentation: .persistentContinuation)
        }
        switch capabilities.organization {
        case .saveToFolder:
            add(.saveToFolder, .organization, 100, "Save to Folder", "folder.badge.plus", presentation: .submenu)
        case .moveToFolder:
            add(.moveToFolder, .organization, 100, "Move to Folder", "folder", enabled: capabilities.canMutateSaved, reason: "You have view-only access to this shared folder.", presentation: .submenu)
        case .none:
            break
        }
        if !capabilities.isPrivate {
            add(
                .pin, .organization, 110,
                capabilities.isHistory ? "Pin & Save" : (capabilities.isPinned ? "Unpin" : "Pin"),
                capabilities.isPinned ? "pin.slash" : "pin",
                enabled: !capabilities.isSensitive && (!capabilities.isSaved || capabilities.canMutateSaved),
                reason: capabilities.isSensitive ? "Sensitive items cannot be pinned outside Vault." : "You have view-only access to this shared folder."
            )
        }
        if capabilities.isNote, capabilities.canEditNote {
            add(.editNote, .editing, 200, "Edit Note…", "square.and.pencil", presentation: .persistentContinuation)
        } else {
            if capabilities.canEditClip {
                add(.editClip, .editing, 200, capabilities.isHistory ? "Edit a Saved Copy…" : "Edit Clip…", "pencil", presentation: .persistentContinuation)
            }
            if capabilities.canMakeNote {
                add(.makeNote, .editing, 210, "Make Note…", "note.text.badge.plus", presentation: .persistentContinuation)
            }
        }
        if capabilities.canSetShortcut {
            add(.setShortcut, .editing, 220, "Set Shortcut…", "character.textbox", presentation: .persistentContinuation)
        }
        if capabilities.isSaved, surface == .libraryInspector {
            add(.rename, .editing, 230, "Rename…", "character.cursor.ibeam", enabled: capabilities.canMutateSaved && !capabilities.isSensitive, reason: "This item cannot be renamed.", presentation: .persistentContinuation)
            add(.editTags, .editing, 240, "Edit Tags…", "tag", enabled: capabilities.canMutateSaved, reason: "You have view-only access to this shared folder.", presentation: .persistentContinuation)
        }
        if !capabilities.isPrivate {
            add(.moveToVault, .organization, 120, "Move to Vault…", "lock", enabled: capabilities.canMoveToVault, reason: capabilities.vaultUnavailableReason, presentation: .persistentContinuation)
        }
        if capabilities.canShare {
            add(.share, .sharing, 300, "Share Clip…", "square.and.arrow.up", presentation: .systemPanel)
        }
        if capabilities.canExport {
            add(.export, .sharing, 310, "Export Clip…", "square.and.arrow.down", enabled: capabilities.exportUnavailableReason == nil, reason: capabilities.exportUnavailableReason, presentation: .systemPanel)
        }
        if capabilities.hasQuickActions {
            add(.quickActions, .productivity, 400, "Quick Actions", "bolt", presentation: .submenu)
        }
        if capabilities.hasActionFlows {
            add(.actions, .productivity, 410, "Actions", "play.square.stack", presentation: .submenu)
        }
        if capabilities.canRouteToAI {
            add(.copyAndOpen, .integration, 500, "Copy & Open…", "arrow.up.forward.app", presentation: .libraryRoute)
        }
        if capabilities.canSendToCRM {
            add(.sendToCRM, .integration, 510, "Send to CRM…", "building.2", presentation: .libraryRoute)
        }
        if capabilities.canUseWorkflows {
            add(.clipTools, .integration, 520, "Clip Tools", "square.stack.3d.up", presentation: .submenu)
        }
        if capabilities.showsDelete {
            add(.delete, .destructive, 900, "Delete", "trash", enabled: capabilities.canDelete, reason: capabilities.canDelete ? nil : "You have view-only access to this shared folder.", presentation: .destructive)
        }

        items.sort { ($0.group, $0.order, $0.id.rawValue) < ($1.group, $1.order, $1.id.rawValue) }
        return ClipActionInventory(surface: surface, descriptors: items)
    }
}
