import CoreGraphics

public enum AspectRatioResize {
    /// Resolves a missing width/height while preserving the source aspect ratio.
    ///
    /// Behavior intentionally mirrors the macOS resize sheet implementation:
    /// - Only computes a missing side when aspect lock is enabled.
    /// - Requires a positive known side and a valid source size.
    /// - Uses rounded pixel math and clamps to at least 1px.
    public static func resolve(
        width: Int?,
        height: Int?,
        lockAspectRatio: Bool,
        sourceSize: CGSize?
    ) -> (width: Int?, height: Int?) {
        guard lockAspectRatio,
              let sourceSize,
              sourceSize.width > 0,
              sourceSize.height > 0 else {
            return (width, height)
        }

        if width == nil,
           let knownHeight = height,
           knownHeight > 0 {
            let computedWidth = max(1, Int((CGFloat(knownHeight) * sourceSize.width / sourceSize.height).rounded()))
            return (computedWidth, height)
        }

        if height == nil,
           let knownWidth = width,
           knownWidth > 0 {
            let computedHeight = max(1, Int((CGFloat(knownWidth) * sourceSize.height / sourceSize.width).rounded()))
            return (width, computedHeight)
        }

        return (width, height)
    }
}
