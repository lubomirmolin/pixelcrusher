import Foundation

/// Canonical image-format definitions shared by UI and processing layers.
///
/// Keeping these values centralized prevents subtle drift between drag/drop
/// validation, queue filtering, and backend invocation guards.
public enum SupportedAssetFormats {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "svg", "gif"]
    public static let imageFormatsLabel = "PNG/JPG/JPEG/SVG/GIF"

    public static func isSupportedImageURL(_ url: URL) -> Bool {
        isSupportedImageExtension(url.pathExtension)
    }

    public static func isSupportedImageExtension(_ pathExtension: String) -> Bool {
        imageExtensions.contains(pathExtension.lowercased())
    }
}
