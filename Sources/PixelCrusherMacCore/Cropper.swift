import Foundation

public enum CropError: LocalizedError {
    case invalidCropSize
    case invalidCropOrigin

    public var errorDescription: String? {
        switch self {
        case .invalidCropSize:
            return "Crop width/height must be positive"
        case .invalidCropOrigin:
            return "Crop origin must be non-negative"
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

public struct CropOrigin: Sendable, Equatable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) throws {
        guard x >= 0, y >= 0 else {
            throw CropError.invalidCropOrigin
        }
        self.x = x
        self.y = y
    }
}
