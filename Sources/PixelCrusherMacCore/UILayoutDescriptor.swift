import Foundation

public enum LeftPaneSectionID: String, Sendable, CaseIterable, Equatable {
    case header
    case dropZone
    case activeQueue
    case recentResults
}

public struct LeftPaneSectionDescriptor: Sendable, Equatable {
    public let id: LeftPaneSectionID
    public let isVisible: Bool

    public init(id: LeftPaneSectionID, isVisible: Bool) {
        self.id = id
        self.isVisible = isVisible
    }
}

public enum OptionsGroupID: String, Sendable, CaseIterable, Equatable {
    case general
    case dimensions
    case optimizers
}

public struct OptionsGroupDescriptor: Sendable, Equatable {
    public let id: OptionsGroupID
    public let title: String
    public let isVisible: Bool

    public init(id: OptionsGroupID, title: String, isVisible: Bool) {
        self.id = id
        self.title = title
        self.isVisible = isVisible
    }
}

public struct PixelCrusherLayoutContext: Sendable, Equatable {
    public var showHeader: Bool
    public var showDropZone: Bool
    public var showActiveQueue: Bool
    public var showRecentResults: Bool
    public var canRevealOutputFolder: Bool

    public init(
        showHeader: Bool = true,
        showDropZone: Bool = true,
        showActiveQueue: Bool = true,
        showRecentResults: Bool = true,
        canRevealOutputFolder: Bool = false
    ) {
        self.showHeader = showHeader
        self.showDropZone = showDropZone
        self.showActiveQueue = showActiveQueue
        self.showRecentResults = showRecentResults
        self.canRevealOutputFolder = canRevealOutputFolder
    }
}

public struct PixelCrusherLayoutDescriptor: Sendable, Equatable {
    public let leftPaneSections: [LeftPaneSectionDescriptor]
    public let optionsGroups: [OptionsGroupDescriptor]
    public let showsRevealOutputFolderAction: Bool

    public init(context: PixelCrusherLayoutContext = PixelCrusherLayoutContext()) {
        self.leftPaneSections = [
            LeftPaneSectionDescriptor(id: .header, isVisible: context.showHeader),
            LeftPaneSectionDescriptor(id: .dropZone, isVisible: context.showDropZone),
            LeftPaneSectionDescriptor(id: .activeQueue, isVisible: context.showActiveQueue),
            LeftPaneSectionDescriptor(id: .recentResults, isVisible: context.showRecentResults)
        ]

        self.optionsGroups = [
            OptionsGroupDescriptor(id: .general, title: "General", isVisible: true),
            OptionsGroupDescriptor(id: .dimensions, title: "Dimensions", isVisible: true),
            OptionsGroupDescriptor(id: .optimizers, title: "Optimizers", isVisible: true)
        ]

        self.showsRevealOutputFolderAction = context.canRevealOutputFolder
    }

    public func section(_ id: LeftPaneSectionID) -> LeftPaneSectionDescriptor? {
        leftPaneSections.first { $0.id == id }
    }

    public func optionsGroup(_ id: OptionsGroupID) -> OptionsGroupDescriptor? {
        optionsGroups.first { $0.id == id }
    }
}
