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

    @Test("GitHub release decoding prefers macOS ZIP for in-app updater")
    func releaseDecodingAndPreferredAsset() throws {
        let payload = #"""
        {
          "tag_name": "v1.4.0",
          "name": "PixelCrusher 1.4.0",
          "body": "- Added in-app updater",
          "html_url": "https://github.com/lubomirmolin/pixelcrusher/releases/tag/v1.4.0",
          "assets": [
            {
              "name": "PixelCrusher.dmg",
              "browser_download_url": "https://example.com/PixelCrusher.dmg",
              "content_type": "application/x-apple-diskimage"
            },
            {
              "name": "PixelCrusher.zip",
              "browser_download_url": "https://example.com/PixelCrusher.zip",
              "content_type": "application/zip"
            }
          ]
        }
        """#

        let data = Data(payload.utf8)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        #expect(release.tagName == "v1.4.0")
        #expect(release.semanticVersion == SemanticVersion(parsing: "1.4.0"))
        #expect(release.preferredAsset(for: .macOS)?.name == "PixelCrusher.zip")
        #expect(release.preferredAssetURL(for: .macOS)?.absoluteString == "https://example.com/PixelCrusher.zip")
    }

    @Test("Equal current and latest versions are treated as up-to-date")
    func equalVersionIsNotUpdateAvailable() {
        let release = GitHubRelease(
            tagName: "v0.1.2",
            name: "PixelCrusher 0.1.2",
            body: nil,
            htmlURL: URL(string: "https://github.com/lubomirmolin/pixelcrusher/releases/tag/v0.1.2")!,
            assets: []
        )

        let result = UpdateCheckResult(
            currentVersion: SemanticVersion(parsing: "0.1.2")!,
            latestVersion: SemanticVersion(parsing: "0.1.2")!,
            release: release,
            preferredAsset: nil,
            downloadURL: release.htmlURL
        )

        #expect(result.isUpdateAvailable == false)
    }

    @Test("Latest version strictly greater than current is update-available")
    func newerVersionIsUpdateAvailable() {
        let release = GitHubRelease(
            tagName: "v0.1.3",
            name: "PixelCrusher 0.1.3",
            body: nil,
            htmlURL: URL(string: "https://github.com/lubomirmolin/pixelcrusher/releases/tag/v0.1.3")!,
            assets: []
        )

        let result = UpdateCheckResult(
            currentVersion: SemanticVersion(parsing: "0.1.2")!,
            latestVersion: SemanticVersion(parsing: "0.1.3")!,
            release: release,
            preferredAsset: nil,
            downloadURL: release.htmlURL
        )

        #expect(result.isUpdateAvailable == true)
    }

    @Test("Token resolver checks env first then defaults")
    func tokenResolverPriority() {
        let defaults = UserDefaults(suiteName: "UpdatesTests-\(UUID().uuidString)")!
        defaults.set("defaults-token", forKey: "PixelCrusherGitHubToken")

        let resolvedFromEnv = GitHubTokenResolver.resolve(
            environment: ["PIXELCRUSHER_GITHUB_TOKEN": "env-token"],
            defaults: defaults
        )
        #expect(resolvedFromEnv == "env-token")

        let resolvedFromDefaults = GitHubTokenResolver.resolve(environment: [:], defaults: defaults)
        #expect(resolvedFromDefaults == "defaults-token")
    }
}
