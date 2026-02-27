import CoreGraphics
import Testing
@testable import PixelCrusherMacCore

struct AspectRatioResizeTests {
    @Test("Missing width is derived from source aspect ratio when locked")
    func computesWidthFromHeight() {
        let resolved = AspectRatioResize.resolve(
            width: nil,
            height: 600,
            lockAspectRatio: true,
            sourceSize: CGSize(width: 4000, height: 2000)
        )

        #expect(resolved.width == 1200)
        #expect(resolved.height == 600)
    }

    @Test("Missing height is derived from source aspect ratio when locked")
    func computesHeightFromWidth() {
        let resolved = AspectRatioResize.resolve(
            width: 320,
            height: nil,
            lockAspectRatio: true,
            sourceSize: CGSize(width: 1920, height: 1080)
        )

        #expect(resolved.width == 320)
        #expect(resolved.height == 180)
    }

    @Test("No derivation happens when aspect lock is disabled")
    func leavesDimensionsUntouchedWhenUnlocked() {
        let resolved = AspectRatioResize.resolve(
            width: nil,
            height: 400,
            lockAspectRatio: false,
            sourceSize: CGSize(width: 1920, height: 1080)
        )

        #expect(resolved.width == nil)
        #expect(resolved.height == 400)
    }
}
