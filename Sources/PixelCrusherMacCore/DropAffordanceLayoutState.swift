import Foundation

public struct PixelCrusherDropAffordanceLayoutState: Sendable, Equatable {
    public let hasItems: Bool

    public init(hasItems: Bool) {
        self.hasItems = hasItems
    }

    public var showsTopAddMoreCTA: Bool {
        !hasItems
    }

    public var showsBottomDragHint: Bool {
        hasItems
    }

    public var usesFullWindowDropTarget: Bool {
        true
    }
}
