import Foundation

public enum ProcessingItemState: String, Sendable, CaseIterable, Codable {
    case queued
    case preparing
    case optimizing
    case saving
    case done
    case failed

    public var isTerminal: Bool {
        switch self {
        case .done, .failed:
            return true
        default:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .queued:
            return "Queued"
        case .preparing:
            return "Preparing"
        case .optimizing:
            return "Optimizing"
        case .saving:
            return "Saving"
        case .done:
            return "Done"
        case .failed:
            return "Failed"
        }
    }
}

public struct ProcessingStatusContext: Sendable, Equatable {
    public var pipelineName: String?

    public init(pipelineName: String? = nil) {
        self.pipelineName = pipelineName
    }
}

public struct ProcessingStatusUpdate: Sendable, Equatable {
    public let state: ProcessingItemState
    public let message: String

    public init(state: ProcessingItemState, message: String) {
        self.state = state
        self.message = message
    }
}

public enum ProcessingStatusTextFormatter {
    public static func text(for state: ProcessingItemState, context: ProcessingStatusContext = ProcessingStatusContext()) -> String {
        switch state {
        case .queued:
            return "Queued"
        case .preparing:
            return "Preparing image"
        case .optimizing:
            if let pipelineName = context.pipelineName, !pipelineName.isEmpty {
                return "Optimizing (\(pipelineName))"
            }
            return "Optimizing"
        case .saving:
            return "Writing output"
        case .done:
            return "Done"
        case .failed:
            return "Failed"
        }
    }
}
