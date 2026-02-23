import Foundation

public enum CropError: LocalizedError {
    case invalidCropSize

    public var errorDescription: String? {
        switch self {
        case .invalidCropSize:
            return "Crop width/height must be positive"
        }
    }
}

public enum CropAnchor: String, CaseIterable, Sendable {
    case center
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

public struct CropSize: Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw CropError.invalidCropSize
        }
        self.width = width
        self.height = height
    }
}
