import Foundation
import Testing
@testable import PixelCrusherMacCore

struct SupportedAssetFormatsTests {
    @Test("Supported image URL detection is case-insensitive")
    func detectsSupportedImageURLIgnoringCase() {
        #expect(SupportedAssetFormats.isSupportedImageURL(URL(fileURLWithPath: "/tmp/test.PNG")))
        #expect(SupportedAssetFormats.isSupportedImageURL(URL(fileURLWithPath: "/tmp/test.JpEg")))
        #expect(!SupportedAssetFormats.isSupportedImageURL(URL(fileURLWithPath: "/tmp/test.txt")))
    }

    @Test("Supported image extension lookup is normalized")
    func detectsSupportedExtensionIgnoringCase() {
        #expect(SupportedAssetFormats.isSupportedImageExtension("SVG"))
        #expect(SupportedAssetFormats.isSupportedImageExtension("gif"))
        #expect(SupportedAssetFormats.isSupportedImageExtension("webp"))
    }
}
