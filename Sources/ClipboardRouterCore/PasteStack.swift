import Foundation

public struct PasteStackEntry<Payload: Sendable>: Identifiable, Sendable {
    public let id: UUID
    public let payload: Payload

    public init(id: UUID = UUID(), payload: Payload) {
        self.id = id
        self.payload = payload
    }
}

extension PasteStackEntry: Equatable where Payload: Equatable {}

public enum PasteStackAction: String, Codable, Equatable, Sendable {
    case copy
    case paste
}

public struct PasteStackAttempt<Payload: Sendable>: Identifiable, Sendable {
    public let id: UUID
    public let action: PasteStackAction
    public let entry: PasteStackEntry<Payload>

    fileprivate init(id: UUID, action: PasteStackAction, entry: PasteStackEntry<Payload>) {
        self.id = id
        self.action = action
        self.entry = entry
    }
}

extension PasteStackAttempt: Equatable where Payload: Equatable {}

public enum PasteStackAttemptOutcome: Equatable, Sendable {
    case succeeded
    case failed
}

/// A FIFO workflow over immutable payloads. Failed and stale attempts never move the cursor.
public struct PasteStack<Payload: Sendable>: Sendable {
    public private(set) var entries: [PasteStackEntry<Payload>]
    private var cursor: Int
    private var activeAttempt: ActiveAttempt?

    public init(entries: [PasteStackEntry<Payload>] = []) throws {
        var identifiers = Set<UUID>()
        for entry in entries where !identifiers.insert(entry.id).inserted {
            throw PasteStackError.duplicateEntry(entry.id)
        }
        self.entries = entries
        cursor = 0
        activeAttempt = nil
    }

    public var currentEntry: PasteStackEntry<Payload>? {
        entries.indices.contains(cursor) ? entries[cursor] : nil
    }

    public var currentIndex: Int? {
        currentEntry == nil ? nil : cursor
    }

    public var isComplete: Bool {
        !entries.isEmpty && cursor == entries.endIndex
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public mutating func enqueue(_ entry: PasteStackEntry<Payload>) throws {
        guard !entries.contains(where: { $0.id == entry.id }) else {
            throw PasteStackError.duplicateEntry(entry.id)
        }
        entries.append(entry)
    }

    /// Begins (or returns) the attempt for the current FIFO entry without advancing it.
    public mutating func next(action: PasteStackAction) -> PasteStackAttempt<Payload>? {
        guard let entry = currentEntry else {
            return nil
        }

        if let activeAttempt {
            return PasteStackAttempt(
                id: activeAttempt.id,
                action: activeAttempt.action,
                entry: entry
            )
        }

        let attempt = ActiveAttempt(id: UUID(), action: action)
        activeAttempt = attempt
        return PasteStackAttempt(id: attempt.id, action: action, entry: entry)
    }

    /// Only a confirmed success advances automatically. A failure leaves the current entry intact.
    @discardableResult
    public mutating func confirm(
        attemptID: UUID,
        outcome: PasteStackAttemptOutcome
    ) throws -> PasteStackEntry<Payload>? {
        guard let activeAttempt, activeAttempt.id == attemptID else {
            throw PasteStackError.staleAttempt(attemptID)
        }

        self.activeAttempt = nil
        if outcome == .succeeded {
            cursor += 1
        }
        return currentEntry
    }

    /// Explicit user navigation to the preceding entry. This is not an automatic attempt result.
    @discardableResult
    public mutating func previous() -> PasteStackEntry<Payload>? {
        activeAttempt = nil
        if cursor > 0 {
            cursor -= 1
        }
        return currentEntry
    }

    /// Explicitly skips the current entry without representing the action as a successful paste.
    @discardableResult
    public mutating func skip() -> PasteStackEntry<Payload>? {
        activeAttempt = nil
        if currentEntry != nil {
            cursor += 1
        }
        return currentEntry
    }

    @discardableResult
    public mutating func restart() -> PasteStackEntry<Payload>? {
        activeAttempt = nil
        cursor = 0
        return currentEntry
    }

    public mutating func clear() {
        activeAttempt = nil
        cursor = 0
        entries.removeAll(keepingCapacity: false)
    }

    private struct ActiveAttempt: Sendable {
        let id: UUID
        let action: PasteStackAction
    }
}

public enum PasteStackError: Error, Equatable, LocalizedError, Sendable {
    case duplicateEntry(UUID)
    case staleAttempt(UUID)

    public var errorDescription: String? {
        switch self {
        case let .duplicateEntry(id):
            "Paste Stack entry \(id) already exists."
        case let .staleAttempt(id):
            "Paste Stack attempt \(id) is no longer active."
        }
    }
}
