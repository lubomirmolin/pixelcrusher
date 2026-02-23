import Testing
import Foundation
@testable import PixelCrusherMacCore

struct UpdatesTests {
    @Test("SemanticVersion parses tags and compares semantic precedence")
    func semanticVersionOrdering() {
        let stable = SemanticVersion(parsing: "v1.2.3")
        let pre = SemanticVersion(parsing: "1.2.3-beta.1")
        let nextPatch = SemanticVersion(parsing: "1.2.4")
        let short = SemanticVersion(parsing: "1.2")

        #expect(stable?.description == "1.2.3")
        #expect(pre?.description == "1.2.3-beta.1")
        #expect(short?.description == "1.2.0")

        #expect(pre! < stable!)
        #expect(stable! < nextPatch!)
        #expect(SemanticVersion(parsing: "1.10.0")! > SemanticVersion(parsing: "1.2.9")!)
    }

    @Test("GitHub release decoding picks preferred macOS installer URL")
    func releaseDecodingAndPreferredAsset() throws {
        let payload = #"""
        {
          "tag_name": "v1.4.0",
          "name": "PixelCrusher 1.4.0",
          "body": "- Added manual update checks\n- Added release artifacts",
          "html_url": "https://github.com/lubomirmolin/pixelcrusher/releases/tag/v1.4.0",
          "assets": [
            {
              "name": "PixelCrusher-setup.exe",
              "browser_download_url": "https://example.com/PixelCrusher-setup.exe",
              "content_type": "application/octet-stream"
            },
            {
              "name": "PixelCrusher.dmg",
              "browser_download_url": "https://example.com/PixelCrusher.dmg",
              "content_type": "application/x-apple-diskimage"
            }
          ]
        }
        """#

        let data = Data(payload.utf8)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        #expect(release.tagName == "v1.4.0")
        #expect(release.semanticVersion == SemanticVersion(parsing: "1.4.0"))
        #expect(release.preferredAssetURL(for: .macOS)?.absoluteString == "https://example.com/PixelCrusher.dmg")
        #expect(release.preferredAssetURL(for: .windows)?.absoluteString == "https://example.com/PixelCrusher-setup.exe")
    }
}
