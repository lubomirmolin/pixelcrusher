import Foundation
import PixelCrusherMacCore

extension Notification.Name {
    static let pixelCrusherOpenFiles = Notification.Name("PixelCrusherOpenFiles")
}

@MainActor
final class ExternalOpenFilesCoordinator {
    static let shared = ExternalOpenFilesCoordinator()

    private var pending: [URL] = []

    func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else {
            return
        }
        pending.append(contentsOf: urls)
        NotificationCenter.default.post(name: .pixelCrusherOpenFiles, object: nil)
    }

    func drain() -> [URL] {
        let urls = pending
        pending.removeAll(keepingCapacity: true)
        return urls
    }
}

struct ProcessingResult: Identifiable {
    let id: UUID
    let inputURL: URL
    let enqueuedOrder: Int
    var outputURL: URL?
    var inputBytes: Int64?
    var outputBytes: Int64?
    var success: Bool
    var state: ProcessingItemState
    var statusText: String
    var detailText: String?
    var warning: String?

    var canOpenFolder: Bool {
        outputURL != nil
    }
}

struct PunchCropTransform: Equatable {
    let width: Int
    let height: Int
    let x: Int?
    let y: Int?
    let anchor: CropAnchor
}

enum DropValidationState {
    case idle
    case supported
    case unsupported
}

struct CompressionProfileSettings {
    let jpegQualityPercent: Double
    let pngLossyEnabled: Bool
    let pngLossyQualityMin: Double
    let pngLossyQualityMax: Double
    let pngUsePNGCrush: Bool
    let pngUseZopfli: Bool
}

enum CompressionProfile: CaseIterable {
    case balanced
    case high
    case smallest

    var label: String {
        switch self {
        case .balanced:
            return "Balanced"
        case .high:
            return "High Quality"
        case .smallest:
            return "Smallest Size"
        }
    }

    var settings: CompressionProfileSettings {
        switch self {
        case .balanced:
            return CompressionProfileSettings(
                jpegQualityPercent: 82,
                pngLossyEnabled: true,
                pngLossyQualityMin: 60,
                pngLossyQualityMax: 90,
                pngUsePNGCrush: true,
                pngUseZopfli: false
            )
        case .high:
            return CompressionProfileSettings(
                jpegQualityPercent: 92,
                pngLossyEnabled: false,
                pngLossyQualityMin: 75,
                pngLossyQualityMax: 98,
                pngUsePNGCrush: true,
                pngUseZopfli: true
            )
        case .smallest:
            return CompressionProfileSettings(
                jpegQualityPercent: 70,
                pngLossyEnabled: true,
                pngLossyQualityMin: 45,
                pngLossyQualityMax: 75,
                pngUsePNGCrush: true,
                pngUseZopfli: true
            )
        }
    }
}
