import Foundation

public struct ProcessingQueueItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let inputURL: URL
    public let enqueuedOrder: Int
    public var state: ProcessingItemState

    public init(id: UUID = UUID(), inputURL: URL, enqueuedOrder: Int, state: ProcessingItemState) {
        self.id = id
        self.inputURL = inputURL
        self.enqueuedOrder = enqueuedOrder
        self.state = state
    }
}

public struct ProcessingQueueProgress: Sendable, Equatable {
    public let pendingCount: Int
    public let activeItemID: UUID?
    public let completedCount: Int
    public let totalCount: Int

    public init(pendingCount: Int, activeItemID: UUID?, completedCount: Int, totalCount: Int) {
        self.pendingCount = pendingCount
        self.activeItemID = activeItemID
        self.completedCount = completedCount
        self.totalCount = totalCount
    }

    public var isRunning: Bool {
        activeItemID != nil || pendingCount > 0
    }
}

public enum ProcessingQueueTransitionError: Error, Equatable {
    case itemNotFound
    case invalidTransition(from: ProcessingItemState, to: ProcessingItemState)
}

public struct ProcessingQueueStateMachine: Sendable {
    private var orderedIDs: [UUID] = []
    private var itemsByID: [UUID: ProcessingQueueItem] = [:]

    public init() {}

    @discardableResult
    public mutating func enqueue(inputURL: URL) -> ProcessingQueueItem {
        let item = ProcessingQueueItem(
            inputURL: inputURL,
            enqueuedOrder: orderedIDs.count + 1,
            state: .queued
        )
        orderedIDs.append(item.id)
        itemsByID[item.id] = item
        return item
    }

    @discardableResult
    public mutating func dequeueNextQueued() -> ProcessingQueueItem? {
        guard let nextID = orderedIDs.first(where: { itemsByID[$0]?.state == .queued }) else {
            return nil
        }

        try? transition(id: nextID, to: .preparing)
        return itemsByID[nextID]
    }

    public mutating func transition(id: UUID, to newState: ProcessingItemState) throws {
        guard var item = itemsByID[id] else {
            throw ProcessingQueueTransitionError.itemNotFound
        }

        if item.state == newState {
            return
        }

        guard Self.isValidTransition(from: item.state, to: newState) else {
            throw ProcessingQueueTransitionError.invalidTransition(from: item.state, to: newState)
        }

        item.state = newState
        itemsByID[id] = item
    }

    @discardableResult
    public mutating func cancelQueuedJobs() -> [UUID] {
        var cancelled: [UUID] = []
        for id in orderedIDs {
            guard let item = itemsByID[id], item.state == .queued else {
                continue
            }
            cancelled.append(id)
            try? transition(id: id, to: .failed)
        }
        return cancelled
    }

    public func item(id: UUID) -> ProcessingQueueItem? {
        itemsByID[id]
    }

    public func orderedItems() -> [ProcessingQueueItem] {
        orderedIDs.compactMap { itemsByID[$0] }
    }

    public var progress: ProcessingQueueProgress {
        let items = orderedItems()

        let pending = items.filter { $0.state == .queued }.count
        let completed = items.filter { $0.state.isTerminal }.count
        let active = items.first {
            switch $0.state {
            case .preparing, .optimizing, .saving:
                return true
            case .queued, .done, .failed:
                return false
            }
        }?.id

        return ProcessingQueueProgress(
            pendingCount: pending,
            activeItemID: active,
            completedCount: completed,
            totalCount: items.count
        )
    }

    private static func isValidTransition(from old: ProcessingItemState, to new: ProcessingItemState) -> Bool {
        switch (old, new) {
        case (.queued, .preparing),
             (.queued, .failed),
             (.preparing, .optimizing),
             (.preparing, .saving),
             (.preparing, .failed),
             (.optimizing, .saving),
             (.optimizing, .failed),
             (.saving, .done),
             (.saving, .failed):
            return true
        default:
            return false
        }
    }
}
