import Foundation

/// Actor-isolated source of truth for ordinary history, saved clips, and folders.
/// Mutations are persisted before becoming visible in memory.
public actor ClipboardLibrary {
    private var state: ClipboardLibrarySnapshot
    private var searchIndex: ClipSearchIndex?
    private let persistence: any ClipboardLibraryPersisting
    private var isMutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    public static func open(
        persistence: any ClipboardLibraryPersisting
    ) async throws -> ClipboardLibrary {
        let loaded = try await persistence.load()
        let normalized = try normalizeAndValidate(loaded)
        if normalized != loaded {
            try await persistence.save(normalized)
        }
        let library = try ClipboardLibrary(snapshot: normalized, persistence: persistence)
        // Retention is a wall-clock policy, so reopening after time away must not briefly
        // expose or index expired history while waiting for the next clipboard event.
        _ = try await library.pruneHistory(referenceDate: Date())
        return library
    }

    public init(
        snapshot: ClipboardLibrarySnapshot = .empty,
        persistence: any ClipboardLibraryPersisting = InMemoryClipboardLibraryStore()
    ) throws {
        let normalized = try Self.normalizeAndValidate(snapshot)
        self.state = normalized
        self.searchIndex = persistence is any ClipboardLibrarySearchPersisting
            ? nil : ClipSearchIndex(snapshot: normalized)
        self.persistence = persistence
    }

    public func snapshot() -> ClipboardLibrarySnapshot {
        state
    }

    @discardableResult
    public func capture(_ candidate: CaptureCandidate) async throws -> CaptureOutcome {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        switch state.settings.capturePolicy.decision(for: candidate) {
        case let .reject(reason):
            return .ignored(reason)
        case .accept:
            break
        }

        var next = state
        let outcome: CaptureOutcome
        if let duplicateIndex = next.history.firstIndex(where: {
            $0.deduplicationFingerprint == candidate.content.deduplicationFingerprint
                && $0.content == candidate.content
        }) {
            var duplicate = next.history.remove(at: duplicateIndex)
            duplicate.captureCount += 1
            if candidate.capturedAt >= duplicate.lastCapturedAt {
                duplicate.modifiedAt = candidate.capturedAt
                duplicate.lastCapturedAt = candidate.capturedAt
                duplicate.sourceApplicationBundleIdentifier = candidate.sourceApplicationBundleIdentifier
                duplicate.originatingDeviceIdentifier = candidate.originatingDeviceIdentifier
                duplicate.captureContext = candidate.captureContext
                duplicate.sensitivity = candidate.sensitivity
                duplicate.pasteboardTypeIdentifiers = candidate.pasteboardTypeIdentifiers.sorted()
            }
            next.history.insert(duplicate, at: 0)
            outcome = .refreshedDuplicate(duplicate)
        } else {
            let item = HistoryItem(
                content: candidate.content,
                createdAt: candidate.capturedAt,
                sourceApplicationBundleIdentifier: candidate.sourceApplicationBundleIdentifier,
                originatingDeviceIdentifier: candidate.originatingDeviceIdentifier,
                captureContext: candidate.captureContext,
                sensitivity: candidate.sensitivity,
                pasteboardTypeIdentifiers: candidate.pasteboardTypeIdentifiers.sorted()
            )
            next.history.insert(item, at: 0)
            outcome = .inserted(item)
        }

        pruneHistory(in: &next, relativeTo: candidate.capturedAt)
        try await commit(next)
        return outcome
    }

    public func search(query: String, limit: Int = 50) async -> [ClipSearchResult] {
        if let searchable = persistence as? any ClipboardLibrarySearchPersisting {
            return await searchable.search(query: query, limit: limit)
        }
        return searchIndex?.search(query: query, limit: limit) ?? []
    }

    public func setCaptureEnabled(_ isEnabled: Bool) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        next.settings.capturePolicy.isCaptureEnabled = isEnabled
        try await commit(next)
    }

    public func setApplication(_ bundleIdentifier: String, excluded: Bool) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        next.settings.capturePolicy.setApplication(bundleIdentifier, excluded: excluded)
        try await commit(next)
    }

    public func setRetentionPolicy(
        _ policy: HistoryRetentionPolicy,
        referenceDate: Date = Date()
    ) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        next.settings.retentionPolicy = policy
        pruneHistory(in: &next, relativeTo: referenceDate)
        try await commit(next)
    }

    public func setLocationContextEnabled(_ isEnabled: Bool) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        next.settings.isLocationContextEnabled = isEnabled
        try await commit(next)
    }

    public func setDeviceContextEnabled(_ isEnabled: Bool) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        next.settings.isDeviceContextEnabled = isEnabled
        try await commit(next)
    }

    /// Removes only user-controlled device and approximate-location metadata. Source app, URL,
    /// and domain provenance remain intact. The entire change is one persisted transaction.
    @discardableResult
    public func deleteCapturedContext(
        device: Bool,
        location: Bool,
        at date: Date = Date()
    ) async throws -> CaptureContextDeletionResult {
        guard device || location else {
            return CaptureContextDeletionResult(historyItemCount: 0, savedClipCount: 0)
        }
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        var historyCount = 0
        var savedCount = 0

        for index in next.history.indices {
            let priorDevice = next.history[index].originatingDeviceIdentifier
            let priorContext = next.history[index].captureContext
            if device { next.history[index].originatingDeviceIdentifier = nil }
            next.history[index].captureContext = Self.removingCapturedContext(
                priorContext,
                device: device,
                location: location
            )
            if priorDevice != next.history[index].originatingDeviceIdentifier
                || priorContext != next.history[index].captureContext
            {
                next.history[index].modifiedAt = date
                historyCount += 1
            }
        }

        for index in next.savedClips.indices {
            let priorDevice = next.savedClips[index].originatingDeviceIdentifier
            let priorContext = next.savedClips[index].captureContext
            if device { next.savedClips[index].originatingDeviceIdentifier = nil }
            next.savedClips[index].captureContext = Self.removingCapturedContext(
                priorContext,
                device: device,
                location: location
            )
            if priorDevice != next.savedClips[index].originatingDeviceIdentifier
                || priorContext != next.savedClips[index].captureContext
            {
                next.savedClips[index].modifiedAt = date
                markPendingMutation(
                    in: &next,
                    id: next.savedClips[index].id,
                    kind: .savedClip,
                    isDeletion: false,
                    modifiedAt: date
                )
                savedCount += 1
            }
        }

        guard historyCount + savedCount > 0 else {
            return CaptureContextDeletionResult(historyItemCount: 0, savedClipCount: 0)
        }
        try await commit(next)
        return CaptureContextDeletionResult(
            historyItemCount: historyCount,
            savedClipCount: savedCount
        )
    }

    @discardableResult
    public func pruneHistory(referenceDate: Date = Date()) async throws -> Int {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        let priorCount = next.history.count
        pruneHistory(in: &next, relativeTo: referenceDate)
        let removedCount = priorCount - next.history.count
        if removedCount > 0 {
            try await commit(next)
        }
        return removedCount
    }

    public func deleteHistoryItem(id: UUID) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        guard let index = next.history.firstIndex(where: { $0.id == id }) else {
            throw ClipboardLibraryError.historyItemNotFound(id)
        }
        next.history.remove(at: index)
        try await commit(next)
    }

    public func clearHistory() async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard !state.history.isEmpty else { return }
        var next = state
        next.history.removeAll(keepingCapacity: false)
        try await commit(next)
    }

    public func recordPaste(id: UUID, at date: Date = Date()) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        if let index = next.history.firstIndex(where: { $0.id == id }) {
            next.history[index].pasteCount = (next.history[index].pasteCount ?? 0) + 1
            next.history[index].lastPastedAt = date
        } else if let saved = next.savedClips.first(where: { $0.id == id }),
                  let historyID = saved.sourceHistoryItemID,
                  let historyIndex = next.history.firstIndex(where: { $0.id == historyID })
        {
            next.history[historyIndex].pasteCount = (next.history[historyIndex].pasteCount ?? 0) + 1
            next.history[historyIndex].lastPastedAt = date
        } else {
            throw ClipboardLibraryError.historyItemNotFound(id)
        }
        try await commit(next)
    }

    @discardableResult
    public func saveHistoryItem(
        id: UUID,
        name: String? = nil,
        folderID: UUID? = nil,
        pinned: Bool = false,
        at date: Date = Date()
    ) async throws -> SavedClip {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard let historyItem = state.history.first(where: { $0.id == id }) else {
            throw ClipboardLibraryError.historyItemNotFound(id)
        }
        try validateFolder(folderID, in: state)

        let clip = try SavedClip(
            name: name ?? defaultSavedClipName(for: historyItem.content),
            content: historyItem.content,
            folderID: folderID,
            sourceHistoryItemID: historyItem.id,
            createdAt: date,
            pinnedAt: pinned ? date : nil,
            sourceApplicationBundleIdentifier: historyItem.sourceApplicationBundleIdentifier,
            originatingDeviceIdentifier: historyItem.originatingDeviceIdentifier,
            captureContext: historyItem.captureContext,
            originallyCapturedAt: historyItem.createdAt,
            sensitivity: historyItem.sensitivity,
            pasteboardTypeIdentifiers: historyItem.pasteboardTypeIdentifiers ?? []
        )
        var next = state
        next.savedClips.append(clip)
        markPendingMutation(
            in: &next,
            id: clip.id,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: clip.modifiedAt
        )
        try await commit(next)
        return clip
    }

    /// Creates an editable saved note without manufacturing a clipboard-history row.
    @discardableResult
    public func createNote(
        title: String,
        body: String,
        folderID: UUID? = nil,
        pinned: Bool = false,
        at date: Date = Date()
    ) async throws -> SavedClip {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        try validateFolder(folderID, in: state)
        let validatedTitle = try validatedName(title)
        let note = try SavedClip(
            kind: .note,
            name: validatedTitle,
            content: try noteContent(body: body, fallbackTitle: validatedTitle),
            folderID: folderID,
            createdAt: date,
            pinnedAt: pinned ? date : nil
        )
        var next = state
        next.savedClips.append(note)
        markPendingMutation(
            in: &next,
            id: note.id,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: note.modifiedAt
        )
        try await commit(next)
        return note
    }

    /// Creates a derived note only if every reviewed source still matches the actor-isolated
    /// library state. Validation and insertion share one mutation permit, closing the gap between
    /// an AppModel snapshot check and persistence.
    @discardableResult
    public func createNote(
        title: String,
        body: String,
        folderID: UUID? = nil,
        pinned: Bool = false,
        expectingCombinedClips expectations: [ContextPackSourceExpectation],
        at date: Date = Date()
    ) async throws -> SavedClip {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard !expectations.isEmpty else {
            throw ClipboardLibraryError.emptyContent
        }
        for expectation in expectations {
            try validateCombinedClipExpectation(expectation, in: state)
        }
        try validateFolder(folderID, in: state)
        let validatedTitle = try validatedName(title)
        let note = try SavedClip(
            kind: .note,
            name: validatedTitle,
            content: try noteContent(body: body, fallbackTitle: validatedTitle),
            folderID: folderID,
            createdAt: date,
            pinnedAt: pinned ? date : nil
        )
        var next = state
        next.savedClips.append(note)
        markPendingMutation(
            in: &next,
            id: note.id,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: note.modifiedAt
        )
        try await commit(next)
        return note
    }

    /// Creates a note derived from History while preserving the original History row unchanged.
    @discardableResult
    public func convertHistoryItemToNote(
        id: UUID,
        title: String? = nil,
        folderID: UUID? = nil,
        pinned: Bool = false,
        at date: Date = Date()
    ) async throws -> SavedClip {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard let historyItem = state.history.first(where: { $0.id == id }) else {
            throw ClipboardLibraryError.historyItemNotFound(id)
        }
        guard historyItem.content.isSafelyConvertibleToNote else {
            throw ClipboardLibraryError.unsupportedNoteConversion(id)
        }
        try validateFolder(folderID, in: state)
        let validatedTitle = try validatedName(
            title ?? defaultSavedClipName(for: historyItem.content)
        )
        let note = try SavedClip(
            kind: .note,
            name: validatedTitle,
            content: historyItem.content,
            folderID: folderID,
            derivedFromHistoryItemID: historyItem.id,
            createdAt: date,
            pinnedAt: pinned ? date : nil,
            sourceApplicationBundleIdentifier: historyItem.sourceApplicationBundleIdentifier,
            originatingDeviceIdentifier: historyItem.originatingDeviceIdentifier,
            captureContext: historyItem.captureContext,
            originallyCapturedAt: historyItem.createdAt,
            sensitivity: historyItem.sensitivity,
            pasteboardTypeIdentifiers: historyItem.pasteboardTypeIdentifiers ?? []
        )
        var next = state
        next.savedClips.append(note)
        markPendingMutation(
            in: &next,
            id: note.id,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: note.modifiedAt
        )
        try await commit(next)
        return note
    }

    /// Converts an existing saved clip in place, preserving its identity, pin, folder, tags,
    /// timestamps, and provenance. The current content becomes the first editable note body.
    @discardableResult
    public func convertSavedClipToNote(
        id: UUID,
        title: String? = nil,
        at date: Date = Date()
    ) async throws -> SavedClip {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        guard let index = next.savedClips.firstIndex(where: { $0.id == id }) else {
            throw ClipboardLibraryError.savedClipNotFound(id)
        }
        guard next.savedClips[index].content.isSafelyConvertibleToNote else {
            throw ClipboardLibraryError.unsupportedNoteConversion(id)
        }
        if let title {
            next.savedClips[index].name = try validatedName(title)
        }
        next.savedClips[index].kind = .note
        if next.savedClips[index].derivedFromHistoryItemID == nil {
            next.savedClips[index].derivedFromHistoryItemID =
                next.savedClips[index].sourceHistoryItemID
        }
        next.savedClips[index].modifiedAt = date
        markPendingMutation(
            in: &next,
            id: id,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: date
        )
        try await commit(next)
        return next.savedClips[index]
    }

    @discardableResult
    public func updateNote(
        id: UUID,
        title: String,
        body: String,
        at date: Date = Date()
    ) async throws -> SavedClip {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        guard let index = next.savedClips.firstIndex(where: { $0.id == id }) else {
            throw ClipboardLibraryError.savedClipNotFound(id)
        }
        guard next.savedClips[index].kind == .note else {
            throw ClipboardLibraryError.savedItemIsNotNote(id)
        }
        let validatedTitle = try validatedName(title)
        next.savedClips[index].name = validatedTitle
        next.savedClips[index].content = try noteContent(
            body: body,
            fallbackTitle: validatedTitle
        )
        next.savedClips[index].modifiedAt = date
        markPendingMutation(
            in: &next,
            id: id,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: date
        )
        try await commit(next)
        return next.savedClips[index]
    }

    /// Atomically edits a note and moves it to a validated destination folder. Callers never
    /// observe title/body changes without the corresponding folder move (or vice versa).
    @discardableResult
    public func updateNote(
        id: UUID,
        title: String,
        body: String,
        folderID: UUID?,
        expecting expectation: SavedClipEditExpectation? = nil,
        at date: Date = Date()
    ) async throws -> SavedClip {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        try validateFolder(folderID, in: state)
        var next = state
        guard let index = next.savedClips.firstIndex(where: { $0.id == id }) else {
            throw ClipboardLibraryError.savedClipNotFound(id)
        }
        guard next.savedClips[index].kind == .note else {
            throw ClipboardLibraryError.savedItemIsNotNote(id)
        }
        if let expectation {
            try validateEditExpectation(expectation, for: next.savedClips[index])
        }
        let validatedTitle = try validatedName(title)
        next.savedClips[index].name = validatedTitle
        next.savedClips[index].content = try noteContent(
            body: body,
            fallbackTitle: validatedTitle
        )
        next.savedClips[index].folderID = folderID
        next.savedClips[index].modifiedAt = date
        markPendingMutation(
            in: &next,
            id: id,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: date
        )
        try await commit(next)
        return next.savedClips[index]
    }

    /// Creates an edited Saved copy of a History item while leaving the captured History row
    /// immutable. Rich-text input is deliberately flattened only into this new reviewed copy;
    /// the original RTF/HTML representations remain attached to the immutable History item.
    @discardableResult
    public func createEditedCopyFromHistory(
        id: UUID,
        title: String,
        body: String,
        folderID: UUID? = nil,
        at date: Date = Date()
    ) async throws -> SavedClip {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard let historyItem = state.history.first(where: { $0.id == id }) else {
            throw ClipboardLibraryError.historyItemNotFound(id)
        }
        guard historyItem.content.isSafelyEditableAsPlainTextCopy else {
            throw ClipboardLibraryError.unsupportedClipEditing(id)
        }
        try validateFolder(folderID, in: state)
        let validatedTitle = try validatedName(title)
        let edited = try SavedClip(
            kind: .clip,
            name: validatedTitle,
            content: try ClipContent.detect(text: body),
            folderID: folderID,
            derivedFromHistoryItemID: historyItem.id,
            createdAt: date,
            sourceApplicationBundleIdentifier: historyItem.sourceApplicationBundleIdentifier,
            originatingDeviceIdentifier: historyItem.originatingDeviceIdentifier,
            captureContext: historyItem.captureContext,
            originallyCapturedAt: historyItem.createdAt,
            pasteboardTypeIdentifiers: historyItem.pasteboardTypeIdentifiers ?? []
        )
        var next = state
        next.savedClips.append(edited)
        markPendingMutation(
            in: &next,
            id: edited.id,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: edited.modifiedAt
        )
        try await commit(next)
        return edited
    }

    /// Creates a new editable plain-text copy of a Saved rich-text clip. This is intentionally
    /// separate from `updateSavedClipContent`: the representation-bearing source is never
    /// flattened or overwritten in place.
    @discardableResult
    public func createEditedCopyFromSavedClip(
        id: UUID,
        title: String,
        body: String,
        folderID: UUID?,
        expecting expectation: SavedClipEditExpectation? = nil,
        at date: Date = Date()
    ) async throws -> SavedClip {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        try validateFolder(folderID, in: state)
        guard let source = state.savedClips.first(where: { $0.id == id }) else {
            throw ClipboardLibraryError.savedClipNotFound(id)
        }
        guard source.kind == .clip else {
            throw ClipboardLibraryError.savedItemIsNotEditableClip(id)
        }
        guard source.content.type == .richText,
              source.content.isSafelyEditableAsPlainTextCopy
        else {
            throw ClipboardLibraryError.unsupportedClipEditing(id)
        }
        if let expectation {
            try validateEditExpectation(expectation, for: source)
        }

        let edited = try SavedClip(
            kind: .clip,
            name: try validatedName(title),
            content: try ClipContent.detect(text: body),
            folderID: folderID,
            derivedFromHistoryItemID: source.derivedFromHistoryItemID
                ?? source.sourceHistoryItemID,
            createdAt: date,
            tags: source.tags ?? [],
            sourceApplicationBundleIdentifier: source.sourceApplicationBundleIdentifier,
            originatingDeviceIdentifier: source.originatingDeviceIdentifier,
            captureContext: source.captureContext,
            originallyCapturedAt: source.originallyCapturedAt,
            pasteboardTypeIdentifiers: source.pasteboardTypeIdentifiers ?? []
        )
        var next = state
        next.savedClips.append(edited)
        markPendingMutation(
            in: &next,
            id: edited.id,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: edited.modifiedAt
        )
        try await commit(next)
        return edited
    }

    /// Atomically edits a safe text/URL Saved clip and optionally moves it. Images, files, rich
    /// text, OCR payloads, and asset-backed fallbacks are rejected so no representation is lost.
    @discardableResult
    public func updateSavedClipContent(
        id: UUID,
        title: String,
        body: String,
        folderID: UUID?,
        expecting expectation: SavedClipEditExpectation? = nil,
        at date: Date = Date()
    ) async throws -> SavedClip {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        try validateFolder(folderID, in: state)
        var next = state
        guard let index = next.savedClips.firstIndex(where: { $0.id == id }) else {
            throw ClipboardLibraryError.savedClipNotFound(id)
        }
        guard next.savedClips[index].kind == .clip else {
            throw ClipboardLibraryError.savedItemIsNotEditableClip(id)
        }
        guard next.savedClips[index].content.isSafelyConvertibleToNote else {
            throw ClipboardLibraryError.unsupportedClipEditing(id)
        }
        if let expectation {
            try validateEditExpectation(expectation, for: next.savedClips[index])
        }
        next.savedClips[index].name = try validatedName(title)
        next.savedClips[index].content = try ClipContent.detect(text: body)
        next.savedClips[index].folderID = folderID
        if next.savedClips[index].derivedFromHistoryItemID == nil {
            next.savedClips[index].derivedFromHistoryItemID =
                next.savedClips[index].sourceHistoryItemID
        }
        next.savedClips[index].modifiedAt = date
        markPendingMutation(
            in: &next,
            id: id,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: date
        )
        try await commit(next)
        return next.savedClips[index]
    }

    /// Saves and pins a History item in one persisted mutation. This is the menu-bar Pin
    /// primitive: callers never observe an unpinned intermediate SavedClip, and a failed store
    /// write leaves neither version in memory.
    @discardableResult
    public func pinHistoryItem(
        id: UUID,
        name: String? = nil,
        folderID: UUID? = nil,
        reusableSavedClips: [SavedClip]? = nil,
        forbiddenFolderIDs: Set<UUID> = [],
        at date: Date = Date()
    ) async throws -> SavedClip {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard let historyItem = state.history.first(where: { $0.id == id }) else {
            throw ClipboardLibraryError.historyItemNotFound(id)
        }
        try validateFolder(folderID, in: state)
        let reusableByID = reusableSavedClips.map { clips -> [UUID: SavedClip] in
            var result: [UUID: SavedClip] = [:]
            for clip in clips { result[clip.id] = clip }
            return result
        }

        // A History row may already have one or more intentionally organized Saved copies. Pin
        // the already-pinned copy when present, otherwise reuse the most recently edited linked
        // copy. Repeated menu clicks therefore never manufacture duplicates.
        if let existingIndex = state.savedClips.indices
            .filter({ index in
                let clip = state.savedClips[index]
                guard clip.sourceHistoryItemID == id else { return false }
                if let reusableByID, reusableByID[clip.id] != clip { return false }
                return clip.folderID.map(forbiddenFolderIDs.contains) != true
            })
            .sorted(by: { lhs, rhs in
                let left = state.savedClips[lhs]
                let right = state.savedClips[rhs]
                if left.isPinned != right.isPinned { return left.isPinned }
                if left.modifiedAt != right.modifiedAt { return left.modifiedAt > right.modifiedAt }
                return left.id.uuidString < right.id.uuidString
            })
            .first
        {
            let existing = state.savedClips[existingIndex]
            guard !existing.isPinned else { return existing }
            var next = state
            next.savedClips[existingIndex].pinnedAt = date
            next.savedClips[existingIndex].modifiedAt = date
            markPendingMutation(
                in: &next,
                id: existing.id,
                kind: .savedClip,
                isDeletion: false,
                modifiedAt: date
            )
            try await commit(next)
            return next.savedClips[existingIndex]
        }

        let clip = try SavedClip(
            name: name ?? defaultSavedClipName(for: historyItem.content),
            content: historyItem.content,
            folderID: folderID,
            sourceHistoryItemID: historyItem.id,
            createdAt: date,
            pinnedAt: date,
            sourceApplicationBundleIdentifier: historyItem.sourceApplicationBundleIdentifier,
            originatingDeviceIdentifier: historyItem.originatingDeviceIdentifier,
            captureContext: historyItem.captureContext,
            originallyCapturedAt: historyItem.createdAt,
            sensitivity: historyItem.sensitivity,
            pasteboardTypeIdentifiers: historyItem.pasteboardTypeIdentifiers ?? []
        )
        var next = state
        next.savedClips.append(clip)
        markPendingMutation(
            in: &next,
            id: clip.id,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: clip.modifiedAt
        )
        try await commit(next)
        return clip
    }

    /// Creates a folder and saves a history item into it as one persisted library mutation.
    /// This prevents an empty folder from being left behind if the pending save cannot complete.
    @discardableResult
    public func saveHistoryItemInNewFolder(
        id: UUID,
        folderName: String,
        at date: Date = Date()
    ) async throws -> (folder: ClipFolder, savedClip: SavedClip) {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard let historyItem = state.history.first(where: { $0.id == id }) else {
            throw ClipboardLibraryError.historyItemNotFound(id)
        }

        let folder = try makeNewFolder(
            named: folderName,
            parentFolderID: nil,
            in: state,
            at: date
        )
        let savedClip = try SavedClip(
            name: defaultSavedClipName(for: historyItem.content),
            content: historyItem.content,
            folderID: folder.id,
            sourceHistoryItemID: historyItem.id,
            createdAt: date,
            sourceApplicationBundleIdentifier: historyItem.sourceApplicationBundleIdentifier,
            originatingDeviceIdentifier: historyItem.originatingDeviceIdentifier,
            captureContext: historyItem.captureContext,
            originallyCapturedAt: historyItem.createdAt,
            sensitivity: historyItem.sensitivity,
            pasteboardTypeIdentifiers: historyItem.pasteboardTypeIdentifiers ?? []
        )

        var next = state
        next.folders.append(folder)
        next.savedClips.append(savedClip)
        markPendingMutation(
            in: &next,
            id: folder.id,
            kind: .folder,
            isDeletion: false,
            modifiedAt: folder.modifiedAt
        )
        markPendingMutation(
            in: &next,
            id: savedClip.id,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: savedClip.modifiedAt
        )
        try await commit(next)
        return (folder, savedClip)
    }

    public func renameSavedClip(id: UUID, to name: String, at date: Date = Date()) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        guard let index = next.savedClips.firstIndex(where: { $0.id == id }) else {
            throw ClipboardLibraryError.savedClipNotFound(id)
        }
        next.savedClips[index].name = try validatedName(name)
        next.savedClips[index].modifiedAt = date
        markPendingMutation(
            in: &next,
            id: id,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: date
        )
        try await commit(next)
    }

    public func setSavedClipPinned(
        id: UUID,
        pinned: Bool,
        at date: Date = Date()
    ) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        guard let index = next.savedClips.firstIndex(where: { $0.id == id }) else {
            throw ClipboardLibraryError.savedClipNotFound(id)
        }
        next.savedClips[index].pinnedAt = pinned ? date : nil
        next.savedClips[index].modifiedAt = date
        markPendingMutation(
            in: &next,
            id: id,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: date
        )
        try await commit(next)
    }

    public func moveSavedClip(
        id: UUID,
        to folderID: UUID?,
        at date: Date = Date()
    ) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        try validateFolder(folderID, in: state)
        var next = state
        guard let index = next.savedClips.firstIndex(where: { $0.id == id }) else {
            throw ClipboardLibraryError.savedClipNotFound(id)
        }
        next.savedClips[index].folderID = folderID
        next.savedClips[index].modifiedAt = date
        markPendingMutation(
            in: &next,
            id: id,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: date
        )
        try await commit(next)
    }

    public func deleteSavedClip(id: UUID, at date: Date = Date()) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        guard let index = next.savedClips.firstIndex(where: { $0.id == id }) else {
            throw ClipboardLibraryError.savedClipNotFound(id)
        }
        next.savedClips.remove(at: index)
        markPendingMutation(
            in: &next,
            id: id,
            kind: .savedClip,
            isDeletion: true,
            modifiedAt: date
        )
        try await commit(next)
    }

    /// Atomically verifies and removes ordinary sources after encrypted Vault persistence. The
    /// expected rows are authenticated inside the Vault ciphertext. Checking them only in the app
    /// before this actor mutation would leave a race where sync or another action could move a
    /// linked clip into collaboration before deletion.
    @discardableResult
    public func deleteOrdinaryCopiesForVaultMove(
        expectedHistoryItem: HistoryItem?,
        expectedSavedClips: [SavedClip],
        forbiddenFolderIDs: Set<UUID>,
        completeLinkedHistoryItemID: UUID? = nil,
        expectedCompleteLinkedSavedClipIDs: Set<UUID>? = nil,
        at date: Date = Date()
    ) async throws -> [UUID] {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        if let expectedHistoryItem {
            guard state.history.first(where: { $0.id == expectedHistoryItem.id })
                    == expectedHistoryItem
            else {
                throw ClipboardLibraryError.ordinaryVaultMoveSourceChanged(
                    expectedHistoryItem.id
                )
            }
        }
        var uniqueExpected: [UUID: SavedClip] = [:]
        for expected in expectedSavedClips { uniqueExpected[expected.id] = expected }
        for expected in uniqueExpected.values {
            guard let current = state.savedClips.first(where: { $0.id == expected.id }),
                  current == expected
            else {
                throw ClipboardLibraryError.ordinaryVaultMoveSourceChanged(expected.id)
            }
            if let folderID = current.folderID, forbiddenFolderIDs.contains(folderID) {
                throw ClipboardLibraryError.ordinaryVaultMoveForbiddenFolder(expected.id)
            }
        }
        if let completeLinkedHistoryItemID,
           let expectedCompleteLinkedSavedClipIDs
        {
            let currentCompleteSet = Set(state.savedClips.compactMap { clip in
                clip.sourceHistoryItemID == completeLinkedHistoryItemID ? clip.id : nil
            })
            guard currentCompleteSet == expectedCompleteLinkedSavedClipIDs else {
                throw ClipboardLibraryError.ordinaryVaultMoveScopeChanged(
                    completeLinkedHistoryItemID
                )
            }
        } else if completeLinkedHistoryItemID != nil
                    || expectedCompleteLinkedSavedClipIDs != nil
        {
            throw ClipboardLibraryError.ordinaryVaultMoveScopeChanged(
                completeLinkedHistoryItemID ?? expectedHistoryItem?.id ?? UUID()
            )
        }

        var next = state
        if let expectedHistoryItem {
            next.history.removeAll { $0.id == expectedHistoryItem.id }
        }

        let removedSavedClipIDs = uniqueExpected.keys
            .sorted { $0.uuidString < $1.uuidString }
        guard expectedHistoryItem != nil || !removedSavedClipIDs.isEmpty
        else { return [] }

        next.savedClips.removeAll { uniqueExpected[$0.id] != nil }
        for id in removedSavedClipIDs {
            markPendingMutation(
                in: &next,
                id: id,
                kind: .savedClip,
                isDeletion: true,
                modifiedAt: date
            )
        }
        try await commit(next)
        if let flusher = persistence as? any ClipboardLibrarySensitiveDeletionFlushing {
            try await flusher.flushSensitiveDeletions()
        }
        return removedSavedClipIDs
    }

    @discardableResult
    public func createFolder(
        name: String,
        parentFolderID: UUID? = nil,
        at date: Date = Date()
    ) async throws -> ClipFolder {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        try validateFolder(parentFolderID, in: state)
        let folder = try makeNewFolder(
            named: name,
            parentFolderID: parentFolderID,
            in: state,
            at: date
        )
        var next = state
        next.folders.append(folder)
        markPendingMutation(
            in: &next,
            id: folder.id,
            kind: .folder,
            isDeletion: false,
            modifiedAt: folder.modifiedAt
        )
        try await commit(next)
        return folder
    }

    /// Creates a root and all recipe children in one durable transaction. A validation or
    /// persistence failure publishes none of the folders.
    @discardableResult
    public func createFolderRecipe(
        _ recipe: FolderRecipe,
        parentFolderID: UUID? = nil,
        at date: Date = Date()
    ) async throws -> CreatedFolderRecipe {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        try validateFolder(parentFolderID, in: state)
        var next = state
        let root = try makeNewFolder(
            named: recipe.rootName,
            parentFolderID: parentFolderID,
            in: next,
            at: date
        )
        next.folders.append(root)
        var children: [ClipFolder] = []
        for childName in recipe.childNames {
            let child = try makeNewFolder(
                named: childName,
                parentFolderID: root.id,
                in: next,
                at: date
            )
            next.folders.append(child)
            children.append(child)
        }
        for folder in [root] + children {
            markPendingMutation(
                in: &next,
                id: folder.id,
                kind: .folder,
                isDeletion: false,
                modifiedAt: folder.modifiedAt
            )
        }
        try await commit(next)
        return CreatedFolderRecipe(root: root, children: children)
    }

    /// Replaces an item's complete tag set atomically with its SQLite/FTS state and sync journal.
    @discardableResult
    public func replaceTags(
        for savedClipID: UUID,
        with candidates: [String],
        expecting expectation: SavedClipEditExpectation? = nil,
        at date: Date = Date()
    ) async throws -> SavedClip {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let tags = try ClipTag.normalize(candidates)
        var next = state
        guard let index = next.savedClips.firstIndex(where: { $0.id == savedClipID }) else {
            throw ClipboardLibraryError.savedClipNotFound(savedClipID)
        }
        if let expectation {
            try validateEditExpectation(expectation, for: next.savedClips[index])
        }
        if next.savedClips[index].tags == tags { return next.savedClips[index] }
        next.savedClips[index].tags = tags
        next.savedClips[index].modifiedAt = date
        markPendingMutation(
            in: &next,
            id: savedClipID,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: date
        )
        try await commit(next)
        return next.savedClips[index]
    }

    /// Applies all reversible organization steps from one automation in one durable mutation.
    /// Validation happens before the snapshot changes, so callers never observe tags without the
    /// corresponding move (or the reverse) after a store failure.
    @discardableResult
    public func applyAutomationOrganization(
        to savedClipID: UUID,
        addingTags candidates: [String],
        movingTo destinationFolderID: UUID?,
        shouldMove: Bool,
        expectingFingerprint: String,
        at date: Date = Date()
    ) async throws -> SavedClip {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let addedTags = try ClipTag.normalize(candidates)
        if shouldMove { try validateFolder(destinationFolderID, in: state) }
        var next = state
        guard let index = next.savedClips.firstIndex(where: { $0.id == savedClipID }) else {
            throw ClipboardLibraryError.savedClipNotFound(savedClipID)
        }
        guard next.savedClips[index].content.deduplicationFingerprint == expectingFingerprint else {
            throw ClipboardLibraryError.savedItemChangedDuringEdit(savedClipID)
        }

        let mergedTags = try ClipTag.normalize((next.savedClips[index].tags ?? []) + addedTags)
        let currentFolderID = next.savedClips[index].folderID
        let nextFolderID = shouldMove ? destinationFolderID : currentFolderID
        guard next.savedClips[index].tags != mergedTags || currentFolderID != nextFolderID else {
            return next.savedClips[index]
        }
        next.savedClips[index].tags = mergedTags
        next.savedClips[index].folderID = nextFolderID
        next.savedClips[index].modifiedAt = date
        markPendingMutation(
            in: &next,
            id: savedClipID,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: date
        )
        try await commit(next)
        return next.savedClips[index]
    }

    /// Replaces folder and tags in one commit after verifying the complete organization state.
    /// This is intentionally stricter than automation's add-tags primitive: suggestions and Undo
    /// must never overwrite a manual move or tag edit that happened after the preview was shown.
    @discardableResult
    public func applyAutomaticOrganization(
        to savedClipID: UUID,
        folderID: UUID?,
        tags candidates: [String],
        expecting expectation: SavedClipOrganizationExpectation,
        authorize: (@Sendable () async -> Bool)? = nil,
        at date: Date = Date()
    ) async throws -> SavedClip {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        try validateFolder(folderID, in: state)
        let tags = try ClipTag.normalize(candidates)
        var next = state
        guard let index = next.savedClips.firstIndex(where: { $0.id == savedClipID }) else {
            throw ClipboardLibraryError.savedClipNotFound(savedClipID)
        }
        let current = next.savedClips[index]
        guard current.modifiedAt == expectation.modifiedAt,
              current.folderID == expectation.folderID,
              (current.tags ?? []) == expectation.tags,
              current.content.deduplicationFingerprint == expectation.contentFingerprint
        else { throw ClipboardLibraryError.savedItemChangedDuringEdit(savedClipID) }
        guard current.folderID != folderID || (current.tags ?? []) != tags else { return current }
        if let authorize, !(await authorize()) {
            throw AutomaticOrganizationError.authorizationChanged
        }

        next.savedClips[index].folderID = folderID
        next.savedClips[index].tags = tags
        next.savedClips[index].modifiedAt = date
        markPendingMutation(
            in: &next,
            id: savedClipID,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: date
        )
        try await commit(next)
        return next.savedClips[index]
    }

    public func renameFolder(id: UUID, to name: String, at date: Date = Date()) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        guard let index = next.folders.firstIndex(where: { $0.id == id }) else {
            throw ClipboardLibraryError.folderNotFound(id)
        }
        next.folders[index].name = try validatedUniqueFolderName(
            name,
            excluding: id,
            parentFolderID: next.folders[index].parentFolderID,
            in: state
        )
        next.folders[index].modifiedAt = date
        markPendingMutation(
            in: &next,
            id: id,
            kind: .folder,
            isDeletion: false,
            modifiedAt: date
        )
        try await commit(next)
    }

    public func reorderFolder(id: UUID, to newIndex: Int, at date: Date = Date()) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        guard let oldIndex = next.folders.firstIndex(where: { $0.id == id }) else {
            throw ClipboardLibraryError.folderNotFound(id)
        }
        let parentFolderID = next.folders[oldIndex].parentFolderID
        var siblings = next.folders.filter { $0.parentFolderID == parentFolderID }
        guard siblings.indices.contains(newIndex) else {
            throw ClipboardLibraryError.invalidFolderIndex(newIndex)
        }
        guard let siblingOldIndex = siblings.firstIndex(where: { $0.id == id }) else {
            throw ClipboardLibraryError.folderNotFound(id)
        }
        var folder = siblings.remove(at: siblingOldIndex)
        folder.modifiedAt = date
        siblings.insert(folder, at: newIndex)
        for (index, sibling) in siblings.enumerated() {
            guard let folderIndex = next.folders.firstIndex(where: { $0.id == sibling.id }) else {
                continue
            }
            next.folders[folderIndex].sortOrder = index
            next.folders[folderIndex].modifiedAt = date
            let changedFolderID = next.folders[folderIndex].id
            markPendingMutation(
                in: &next,
                id: changedFolderID,
                kind: .folder,
                isDeletion: false,
                modifiedAt: date
            )
        }
        try await commit(next)
    }

    /// Moves a folder to a new parent and appends it after that parent's existing children.
    /// Self/descendant moves are rejected before persistence.
    public func moveFolder(
        id: UUID,
        to parentFolderID: UUID?,
        at date: Date = Date()
    ) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        guard let movingIndex = next.folders.firstIndex(where: { $0.id == id }) else {
            throw ClipboardLibraryError.folderNotFound(id)
        }
        if parentFolderID == id { throw ClipboardLibraryError.folderCycle(id) }
        try validateFolder(parentFolderID, in: state)
        if let parentFolderID,
           Self.descendantFolderIDs(of: id, in: state).contains(parentFolderID)
        {
            throw ClipboardLibraryError.folderCycle(id)
        }
        _ = try validatedUniqueFolderName(
            next.folders[movingIndex].name,
            excluding: id,
            parentFolderID: parentFolderID,
            in: state
        )
        let oldParentID = next.folders[movingIndex].parentFolderID
        guard oldParentID != parentFolderID else { return }
        next.folders[movingIndex].parentFolderID = parentFolderID
        next.folders[movingIndex].sortOrder = next.folders.filter {
            $0.id != id && $0.parentFolderID == parentFolderID
        }.count
        next.folders[movingIndex].modifiedAt = date
        normalizeSiblingOrder(parentFolderID: oldParentID, in: &next, modifiedAt: date)
        markPendingMutation(
            in: &next,
            id: id,
            kind: .folder,
            isDeletion: false,
            modifiedAt: date
        )
        try await commit(next)
    }

    /// Deletes only the folder. Direct clips become Unfiled and direct children are promoted to
    /// the deleted folder's parent. Deeper descendants remain attached to their immediate parent.
    public func deleteFolder(id: UUID, at date: Date = Date()) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        guard let index = next.folders.firstIndex(where: { $0.id == id }) else {
            throw ClipboardLibraryError.folderNotFound(id)
        }
        let deleted = next.folders[index]
        let promotedChildren = next.folders.filter { $0.parentFolderID == id }
        for child in promotedChildren {
            _ = try validatedUniqueFolderName(
                child.name,
                excluding: child.id,
                parentFolderID: deleted.parentFolderID,
                in: ClipboardLibrarySnapshot(
                    folders: next.folders.filter { $0.id != id && $0.parentFolderID != id }
                )
            )
        }
        next.folders.remove(at: index)
        markPendingMutation(
            in: &next,
            id: id,
            kind: .folder,
            isDeletion: true,
            modifiedAt: date
        )
        for clipIndex in next.savedClips.indices where next.savedClips[clipIndex].folderID == id {
            next.savedClips[clipIndex].folderID = nil
            next.savedClips[clipIndex].modifiedAt = date
            let changedClipID = next.savedClips[clipIndex].id
            markPendingMutation(
                in: &next,
                id: changedClipID,
                kind: .savedClip,
                isDeletion: false,
                modifiedAt: date
            )
        }
        var nextPromotedOrder = next.folders.filter {
            $0.parentFolderID == deleted.parentFolderID
        }.count
        for child in promotedChildren.sorted(by: Self.folderOrder) {
            guard let childIndex = next.folders.firstIndex(where: { $0.id == child.id }) else {
                continue
            }
            next.folders[childIndex].parentFolderID = deleted.parentFolderID
            next.folders[childIndex].sortOrder = nextPromotedOrder
            next.folders[childIndex].modifiedAt = date
            nextPromotedOrder += 1
            markPendingMutation(
                in: &next,
                id: child.id,
                kind: .folder,
                isDeletion: false,
                modifiedAt: date
            )
        }
        normalizeSiblingOrder(parentFolderID: deleted.parentFolderID, in: &next, modifiedAt: nil)
        try await commit(next)
    }

    /// Removes a durable mutation hint only if it still exactly matches the value persisted by
    /// the sync outbox. A newer local edit remains pending.
    public func acknowledgePendingSavedLibraryMutation(
        _ mutation: PendingSavedLibraryMutation
    ) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        guard let index = next.pendingSavedLibraryMutations.firstIndex(of: mutation) else {
            return
        }
        next.pendingSavedLibraryMutations.remove(at: index)
        try await commit(next)
    }

    /// Applies the saved-library entities controlled by sync without ever touching history.
    /// IDs in the managed sets that are absent from the incoming arrays are tombstones. Local-only
    /// entities (for example, an oversized clip) are preserved.
    public func applySyncedSavedLibrary(
        savedClips: [SavedClip],
        folders: [ClipFolder],
        managedSavedClipIDs: Set<UUID>,
        managedFolderIDs: Set<UUID>,
        at _: Date = Date()
    ) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        // Read the journal while isolated in the same actor transaction. This is the final race
        // barrier: a local edit committed just before projection cannot be overwritten even if
        // the App layer captured an older pending-ID snapshot.
        let locallyPendingClipIDs = Set(
            state.pendingSavedLibraryMutations
                .filter { $0.kind == .savedClip }
                .map(\.id)
        )
        let locallyPendingFolderIDs = Set(
            state.pendingSavedLibraryMutations
                .filter { $0.kind == .folder }
                .map(\.id)
        )
        let incomingClips = savedClips.filter { !locallyPendingClipIDs.contains($0.id) }
        let incomingFolders = folders.filter { !locallyPendingFolderIDs.contains($0.id) }
        let syncedClipIDs = managedSavedClipIDs
            .union(incomingClips.map(\.id))
            .subtracting(locallyPendingClipIDs)
        let syncedFolderIDs = managedFolderIDs
            .union(incomingFolders.map(\.id))
            .subtracting(locallyPendingFolderIDs)
        var next = state
        next.savedClips.removeAll { syncedClipIDs.contains($0.id) }
        next.folders.removeAll { syncedFolderIDs.contains($0.id) }
        next.savedClips.append(contentsOf: incomingClips)
        next.folders.append(contentsOf: incomingFolders)

        let survivingFolderIDs = Set(next.folders.map(\.id))
        for index in next.savedClips.indices {
            guard let folderID = next.savedClips[index].folderID,
                  !survivingFolderIDs.contains(folderID)
            else { continue }
            next.savedClips[index].folderID = nil
        }
        try await commit(next)
    }

    /// Strictly removes account-scoped saved-library entities and their local mutation hints.
    ///
    /// Unlike `applySyncedSavedLibrary`, this operation deliberately does not preserve pending
    /// edits. It is used when an account boundary changes and data owned by the previous account
    /// must immediately disappear from ordinary library and search surfaces.
    public func removeAccountScopedSavedLibrary(
        savedClipIDs: Set<UUID>,
        folderIDs: Set<UUID>
    ) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        var next = state
        next.savedClips.removeAll { savedClipIDs.contains($0.id) }
        next.folders.removeAll { folderIDs.contains($0.id) }
        next.pendingSavedLibraryMutations.removeAll { mutation in
            switch mutation.kind {
            case .savedClip:
                savedClipIDs.contains(mutation.id)
            case .folder:
                folderIDs.contains(mutation.id)
            }
        }

        let survivingFolderIDs = Set(next.folders.map(\.id))
        for index in next.savedClips.indices {
            if let folderID = next.savedClips[index].folderID,
               !survivingFolderIDs.contains(folderID) {
                next.savedClips[index].folderID = nil
            }
        }
        for index in next.folders.indices {
            if let parentID = next.folders[index].parentFolderID,
               !survivingFolderIDs.contains(parentID) {
                next.folders[index].parentFolderID = nil
            }
        }

        try await commit(next)
    }

    /// Applies a reviewed multi-item mutation in one persistence commit. The expectations are
    /// captured by `BulkLibraryMutationPlanner`; any changed source aborts the entire eligible
    /// subset rather than silently applying an action to stale selections. History is immutable
    /// except for creating new Saved copies.
    @discardableResult
    public func applyBulkMutation(
        _ plan: BulkLibraryMutationPlan,
        authorize: (@Sendable () async -> Bool)? = nil,
        at date: Date = Date()
    ) async throws -> [SavedClip] {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard plan.eligibleCount > 0 else { throw BulkLibraryMutationError.emptySelection }
        var next = state
        var updated: [SavedClip] = []

        switch plan.operation {
        case let .saveHistory(folderID):
            try validateFolder(folderID, in: next)
            for expectation in plan.history {
                guard let history = next.history.first(where: { $0.id == expectation.id }),
                      history.modifiedAt == expectation.modifiedAt,
                      history.content.deduplicationFingerprint == expectation.contentFingerprint,
                      history.sensitivity == nil
                else { throw BulkLibraryMutationError.sourceChanged(expectation.id) }
                let saved = try SavedClip(
                    name: defaultSavedClipName(for: history.content),
                    content: history.content,
                    folderID: folderID,
                    sourceHistoryItemID: history.id,
                    createdAt: date,
                    sourceApplicationBundleIdentifier: history.sourceApplicationBundleIdentifier,
                    originatingDeviceIdentifier: history.originatingDeviceIdentifier,
                    captureContext: history.captureContext,
                    originallyCapturedAt: history.createdAt,
                    sensitivity: history.sensitivity,
                    pasteboardTypeIdentifiers: history.pasteboardTypeIdentifiers ?? []
                )
                next.savedClips.append(saved)
                markPendingMutation(
                    in: &next,
                    id: saved.id,
                    kind: .savedClip,
                    isDeletion: false,
                    modifiedAt: saved.modifiedAt
                )
                updated.append(saved)
            }
        case let .moveSaved(folderID):
            try validateFolder(folderID, in: next)
            try applyBulkSavedExpectations(plan.saved, in: &next, at: date) { clip in
                clip.folderID = folderID
            }
            updated = plan.saved.compactMap { expected in
                next.savedClips.first(where: { $0.id == expected.id })
            }
        case let .addTags(candidates):
            let addedTags = try ClipTag.normalize(candidates)
            try applyBulkSavedExpectations(plan.saved, in: &next, at: date) { clip in
                clip.tags = try ClipTag.normalize((clip.tags ?? []) + addedTags)
            }
            updated = plan.saved.compactMap { expected in
                next.savedClips.first(where: { $0.id == expected.id })
            }
        case let .setPinned(pinned):
            try applyBulkSavedExpectations(plan.saved, in: &next, at: date) { clip in
                clip.pinnedAt = pinned ? date : nil
            }
            updated = plan.saved.compactMap { expected in
                next.savedClips.first(where: { $0.id == expected.id })
            }
        }

        if let authorize, !(await authorize()) {
            throw BulkLibraryMutationError.authorizationChanged
        }
        try await commit(next)
        return updated
    }

    private func applyBulkSavedExpectations(
        _ expectations: [BulkSavedClipExpectation],
        in snapshot: inout ClipboardLibrarySnapshot,
        at date: Date,
        mutation: (inout SavedClip) throws -> Void
    ) throws {
        for expectation in expectations {
            guard let index = snapshot.savedClips.firstIndex(where: { $0.id == expectation.id }) else {
                throw BulkLibraryMutationError.sourceChanged(expectation.id)
            }
            let current = snapshot.savedClips[index]
            guard current.modifiedAt == expectation.modifiedAt,
                  current.folderID == expectation.folderID,
                  (current.tags ?? []) == expectation.tags,
                  current.pinnedAt == expectation.pinnedAt,
                  current.content.deduplicationFingerprint == expectation.contentFingerprint,
                  current.sensitivity == nil
            else { throw BulkLibraryMutationError.sourceChanged(expectation.id) }
            try mutation(&snapshot.savedClips[index])
            snapshot.savedClips[index].modifiedAt = date
            markPendingMutation(
                in: &snapshot,
                id: expectation.id,
                kind: .savedClip,
                isDeletion: false,
                modifiedAt: date
            )
        }
    }

    private func commit(_ candidate: ClipboardLibrarySnapshot) async throws {
        let normalized = try Self.normalizeAndValidate(candidate)
        try await persistence.save(normalized)
        state = normalized
        if searchIndex != nil {
            searchIndex = ClipSearchIndex(snapshot: normalized)
        }
    }

    private func markPendingMutation(
        in snapshot: inout ClipboardLibrarySnapshot,
        id: UUID,
        kind: PendingSavedLibraryMutation.EntityKind,
        isDeletion: Bool,
        modifiedAt: Date
    ) {
        snapshot.pendingSavedLibraryMutations.removeAll {
            $0.id == id && $0.kind == kind
        }
        snapshot.pendingSavedLibraryMutations.append(
            PendingSavedLibraryMutation(
                id: id,
                kind: kind,
                isDeletion: isDeletion,
                modifiedAt: modifiedAt
            )
        )
    }

    /// Swift actors are reentrant at `await` points. This gate keeps snapshot creation,
    /// persistence, and publication in a single ordered mutation transaction.
    private func acquireMutationPermit() async {
        if !isMutationInProgress {
            isMutationInProgress = true
            return
        }

        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationPermit() {
        guard !mutationWaiters.isEmpty else {
            isMutationInProgress = false
            return
        }
        let next = mutationWaiters.removeFirst()
        next.resume()
    }

    private func validateFolder(
        _ folderID: UUID?,
        in snapshot: ClipboardLibrarySnapshot
    ) throws {
        guard let folderID else { return }
        guard snapshot.folders.contains(where: { $0.id == folderID }) else {
            throw ClipboardLibraryError.folderNotFound(folderID)
        }
    }

    private func makeNewFolder(
        named name: String,
        parentFolderID: UUID?,
        in snapshot: ClipboardLibrarySnapshot,
        at date: Date
    ) throws -> ClipFolder {
        let validated = try validatedUniqueFolderName(
            name,
            excluding: nil,
            parentFolderID: parentFolderID,
            in: snapshot
        )
        let folder = try ClipFolder(
            name: validated,
            parentFolderID: parentFolderID,
            sortOrder: snapshot.folders.filter { $0.parentFolderID == parentFolderID }.count,
            createdAt: date
        )
        return folder
    }

    private func validatedUniqueFolderName(
        _ rawName: String,
        excluding excludedID: UUID?,
        parentFolderID: UUID?,
        in snapshot: ClipboardLibrarySnapshot
    ) throws -> String {
        let name = try validatedName(rawName)
        guard !snapshot.folders.contains(where: { folder in
            folder.id != excludedID
                && folder.parentFolderID == parentFolderID
                && folder.name.compare(
                    name,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
        }) else {
            throw ClipboardLibraryError.duplicateFolderName(name)
        }
        return name
    }

    private func normalizeSiblingOrder(
        parentFolderID: UUID?,
        in snapshot: inout ClipboardLibrarySnapshot,
        modifiedAt: Date?
    ) {
        let siblings = snapshot.folders
            .filter { $0.parentFolderID == parentFolderID }
            .sorted(by: Self.folderOrder)
        for (sortOrder, sibling) in siblings.enumerated() {
            guard let index = snapshot.folders.firstIndex(where: { $0.id == sibling.id }) else {
                continue
            }
            snapshot.folders[index].sortOrder = sortOrder
            if let modifiedAt { snapshot.folders[index].modifiedAt = modifiedAt }
        }
    }

    private static func folderOrder(_ lhs: ClipFolder, _ rhs: ClipFolder) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func descendantFolderIDs(
        of folderID: UUID,
        in snapshot: ClipboardLibrarySnapshot
    ) -> Set<UUID> {
        var result = Set<UUID>()
        var queue = snapshot.folders
            .filter { $0.parentFolderID == folderID }
            .map(\.id)
        while let current = queue.popLast() {
            guard result.insert(current).inserted else { continue }
            queue.append(contentsOf: snapshot.folders.compactMap {
                $0.parentFolderID == current ? $0.id : nil
            })
        }
        return result
    }

    private func noteContent(body: String, fallbackTitle: String) throws -> ClipContent {
        let storedBody = body.isEmpty ? fallbackTitle : body
        return try ClipContent(type: .plainText, text: storedBody)
    }

    private func validateEditExpectation(
        _ expectation: SavedClipEditExpectation,
        for clip: SavedClip
    ) throws {
        guard clip.name == expectation.name,
              clip.modifiedAt == expectation.modifiedAt,
              clip.folderID == expectation.folderID,
              clip.content.deduplicationFingerprint == expectation.contentFingerprint
        else {
            throw ClipboardLibraryError.savedItemChangedDuringEdit(clip.id)
        }
    }

    private func validateCombinedClipExpectation(
        _ expectation: ContextPackSourceExpectation,
        in snapshot: ClipboardLibrarySnapshot
    ) throws {
        let item = expectation.item
        let content: ClipContent
        let capturedAt: Date
        let sourceApplication: String?
        let sourceURL: URL?
        let sensitivity: ClipSensitivityMetadata?

        switch expectation.source {
        case .history:
            guard let source = snapshot.history.first(where: { $0.id == item.id }) else {
                throw ClipboardLibraryError.combinedClipSourceChanged(item.id)
            }
            content = source.content
            capturedAt = source.lastCapturedAt
            sourceApplication = source.captureContext?.sourceApplicationName
                ?? source.sourceApplicationBundleIdentifier
            sourceURL = source.captureContext?.sourceURL.flatMap(URL.init(string:))
            sensitivity = source.sensitivity
        case let .saved(folderID, kind):
            guard let source = snapshot.savedClips.first(where: { $0.id == item.id }),
                  source.folderID == folderID,
                  source.kind == kind,
                  source.name == item.title
            else {
                throw ClipboardLibraryError.combinedClipSourceChanged(item.id)
            }
            content = source.content
            capturedAt = source.modifiedAt
            sourceApplication = source.captureContext?.sourceApplicationName
                ?? source.sourceApplicationBundleIdentifier
            sourceURL = source.captureContext?.sourceURL.flatMap(URL.init(string:))
            sensitivity = source.sensitivity
        }

        let expectedMetadata = [
            "Content type": content.type.rawValue,
            "Approximate size": "\(content.estimatedStorageByteCount) bytes",
        ]
        guard sensitivity == nil,
              content.searchableText == item.textRepresentation,
              capturedAt == item.capturedAt,
              sourceApplication == item.sourceApplication,
              sourceURL == item.sourceURL,
              expectedMetadata == item.metadata
        else {
            throw ClipboardLibraryError.combinedClipSourceChanged(item.id)
        }
    }

    private func pruneHistory(
        in snapshot: inout ClipboardLibrarySnapshot,
        relativeTo referenceDate: Date
    ) {
        if let cutoff = snapshot.settings.retentionPolicy.cutoff(relativeTo: referenceDate) {
            snapshot.history.removeAll { $0.lastCapturedAt < cutoff }
        }
        let limit = snapshot.settings.effectiveMaximumHistoryItemCount
        if snapshot.history.count > limit {
            snapshot.history.removeLast(snapshot.history.count - limit)
        }
    }

    private static func removingCapturedContext(
        _ context: ClipCaptureContext?,
        device: Bool,
        location: Bool
    ) -> ClipCaptureContext? {
        guard var context else { return nil }
        if device {
            context.deviceLabel = nil
            context.operatingSystem = nil
        }
        if location { context.coarseLocation = nil }
        if context.sourceApplicationName == nil,
           context.sourceURL == nil,
           context.sourceDomain == nil,
           context.deviceLabel == nil,
           context.operatingSystem == nil,
           context.coarseLocation == nil
        {
            return nil
        }
        return context
    }

    private static func normalizeAndValidate(
        _ snapshot: ClipboardLibrarySnapshot
    ) throws -> ClipboardLibrarySnapshot {
        guard snapshot.schemaVersion == ClipboardLibrarySnapshot.currentSchemaVersion else {
            throw ClipboardLibraryError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }

        try validateUniqueIDs(snapshot.history.map(\.id))
        try validateUniqueIDs(snapshot.savedClips.map(\.id))
        try validateUniqueIDs(snapshot.folders.map(\.id))
        var pendingKeys = Set<String>()
        for mutation in snapshot.pendingSavedLibraryMutations {
            let key = "\(mutation.kind.rawValue):\(mutation.id.uuidString.lowercased())"
            guard pendingKeys.insert(key).inserted else {
                throw ClipboardLibraryError.duplicatePendingMutation(mutation.id, mutation.kind)
            }
        }
        if let invalid = snapshot.history.first(where: { !(1..<Int.max).contains($0.captureCount) }) {
            throw ClipboardLibraryError.invalidCaptureCount(invalid.id)
        }

        var normalized = snapshot
        for item in normalized.history where item.content.text.isEmpty {
            throw ClipboardLibraryError.emptyContent
        }
        for index in normalized.savedClips.indices {
            guard !normalized.savedClips[index].content.text.isEmpty else {
                throw ClipboardLibraryError.emptyContent
            }
            normalized.savedClips[index].name = try validatedName(normalized.savedClips[index].name)
        }
        for index in normalized.folders.indices {
            normalized.folders[index].name = try validatedName(normalized.folders[index].name)
        }
        normalized.history.sort {
            if $0.lastCapturedAt != $1.lastCapturedAt {
                return $0.lastCapturedAt > $1.lastCapturedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        let folderIDs = Set(normalized.folders.map(\.id))
        // Legacy/corrupt orphaned parents are safely repaired to the root. Cycles are not
        // guessable and fail closed so a malformed tree can never hang traversal or search.
        for index in normalized.folders.indices {
            if let parentID = normalized.folders[index].parentFolderID,
               !folderIDs.contains(parentID)
            {
                normalized.folders[index].parentFolderID = nil
            }
        }
        let foldersByID = Dictionary(uniqueKeysWithValues: normalized.folders.map { ($0.id, $0) })
        for folder in normalized.folders {
            var visited: Set<UUID> = [folder.id]
            var parentID = folder.parentFolderID
            while let current = parentID {
                guard visited.insert(current).inserted else {
                    throw ClipboardLibraryError.folderCycle(folder.id)
                }
                parentID = foldersByID[current]?.parentFolderID
            }
        }
        var siblingNames: [String: UUID] = [:]
        for folder in normalized.folders {
            let parentKey = folder.parentFolderID?.uuidString.lowercased() ?? "root"
            let foldedName = folder.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            let key = "\(parentKey):\(foldedName)"
            guard siblingNames.updateValue(folder.id, forKey: key) == nil else {
                throw ClipboardLibraryError.duplicateFolderName(folder.name)
            }
        }
        let parentIDs = Set(normalized.folders.map(\.parentFolderID))
        for parentID in parentIDs {
            let siblings = normalized.folders
                .filter { $0.parentFolderID == parentID }
                .sorted(by: folderOrder)
            for (sortOrder, sibling) in siblings.enumerated() {
                guard let index = normalized.folders.firstIndex(where: { $0.id == sibling.id }) else {
                    continue
                }
                normalized.folders[index].sortOrder = sortOrder
            }
        }
        normalized.folders.sort {
            let leftParent = $0.parentFolderID?.uuidString.lowercased() ?? ""
            let rightParent = $1.parentFolderID?.uuidString.lowercased() ?? ""
            if leftParent != rightParent { return leftParent < rightParent }
            return folderOrder($0, $1)
        }

        for index in normalized.savedClips.indices {
            if let folderID = normalized.savedClips[index].folderID,
               !folderIDs.contains(folderID)
            {
                normalized.savedClips[index].folderID = nil
            }
        }
        return normalized
    }

    private static func validateUniqueIDs(_ ids: [UUID]) throws {
        var seen: Set<UUID> = []
        for id in ids where !seen.insert(id).inserted {
            throw ClipboardLibraryError.duplicateIdentifier(id)
        }
    }
}
