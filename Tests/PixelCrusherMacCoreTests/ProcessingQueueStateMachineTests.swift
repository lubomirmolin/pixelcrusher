import Testing
import Foundation
@testable import PixelCrusherMacCore

struct ProcessingQueueStateMachineTests {
    @Test("Queue running indicator clears when all items are terminal")
    func queueStopsRunningAfterTerminalStates() throws {
        var queue = ProcessingQueueStateMachine()

        let first = queue.enqueue(inputURL: URL(fileURLWithPath: "/tmp/first.png"))
        let second = queue.enqueue(inputURL: URL(fileURLWithPath: "/tmp/second.png"))

        let dequeuedFirst = queue.dequeueNextQueued()
        #expect(dequeuedFirst?.id == first.id)

        try queue.transition(id: first.id, to: .done)

        let dequeuedSecond = queue.dequeueNextQueued()
        #expect(dequeuedSecond?.id == second.id)

        try queue.transition(id: second.id, to: .failed)

        let progress = queue.progress
        #expect(progress.pendingCount == 0)
        #expect(progress.activeItemID == nil)
        #expect(progress.completedCount == 2)
        #expect(progress.totalCount == 2)
        #expect(progress.isRunning == false)
    }

    @Test("Done transition is accepted from preparing and optimizing states")
    func doneTransitionAcceptedFromActiveStates() throws {
        var queue = ProcessingQueueStateMachine()

        let preparingItem = queue.enqueue(inputURL: URL(fileURLWithPath: "/tmp/preparing.png"))
        _ = queue.dequeueNextQueued()
        try queue.transition(id: preparingItem.id, to: .done)
        #expect(queue.item(id: preparingItem.id)?.state == .done)

        let optimizingItem = queue.enqueue(inputURL: URL(fileURLWithPath: "/tmp/optimizing.png"))
        _ = queue.dequeueNextQueued()
        try queue.transition(id: optimizingItem.id, to: .optimizing)
        try queue.transition(id: optimizingItem.id, to: .done)
        #expect(queue.item(id: optimizingItem.id)?.state == .done)
    }
}
