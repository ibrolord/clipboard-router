import Foundation

/// A process-memory-only circular buffer. It intentionally exposes no Codable or persistence API.
public actor PrivateSession<Element: Sendable> {
    public nonisolated let capacity: Int

    private var storage: [Element?]
    private var oldestIndex = 0
    private var elementCount = 0
    private var active = false

    public init(capacity: Int) throws {
        guard capacity > 0 else {
            throw PrivateSessionError.invalidCapacity(capacity)
        }
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)
    }

    public var isActive: Bool {
        active
    }

    public var count: Int {
        elementCount
    }

    /// Starting a session always destroys any values left from an earlier session.
    public func begin() {
        eraseStorage()
        active = true
    }

    /// Appends an element while snapshots remain ordered from oldest to newest.
    public func append(_ element: Element) throws {
        guard active else {
            throw PrivateSessionError.sessionInactive
        }

        if elementCount < capacity {
            let insertionIndex = (oldestIndex + elementCount) % capacity
            storage[insertionIndex] = element
            elementCount += 1
        } else {
            storage[oldestIndex] = element
            oldestIndex = (oldestIndex + 1) % capacity
        }
    }

    public func snapshot() -> [Element] {
        guard active, elementCount > 0 else { return [] }
        return (0 ..< elementCount).compactMap { offset in
            storage[(oldestIndex + offset) % capacity]
        }
    }

    /// Clears captured values while keeping the current private session active.
    public func clear() {
        eraseStorage()
    }

    /// Ending a session destroys all buffered values before marking it inactive.
    public func end() {
        eraseStorage()
        active = false
    }

    private func eraseStorage() {
        for index in storage.indices {
            storage[index] = nil
        }
        oldestIndex = 0
        elementCount = 0
    }
}

public enum PrivateSessionError: Error, Equatable, LocalizedError, Sendable {
    case invalidCapacity(Int)
    case sessionInactive

    public var errorDescription: String? {
        switch self {
        case let .invalidCapacity(capacity):
            "Private Session capacity \(capacity) must be greater than zero."
        case .sessionInactive:
            "Private Session must be started before capturing clips."
        }
    }
}
