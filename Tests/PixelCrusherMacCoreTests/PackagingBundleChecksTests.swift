import Testing
import Foundation
@testable import PixelCrusherMacCore

struct PackagingBundleChecksTests {
    @Test("Bundled tooling verifier catches missing required binaries")
    func catchesMissingRequired() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-package-check-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundledTools = tempDir.appendingPathComponent("BundledTools", isDirectory: true)
        let binDir = bundledTools.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        try makeExecutable(at: binDir.appendingPathComponent("cjpeg"))
        try makeExecutable(at: binDir.appendingPathComponent("pngquant"))

        let missing = BundledToolingVerifier.missingRequiredTools(inBundledToolsDirectory: bundledTools)
        #expect(missing.contains(.pngcrush))
        #expect(missing.contains(.svgo))
        #expect(missing.contains(.gifsicle))
    }

    @Test("Bundled tooling verifier passes when all required binaries exist")
    func passesWhenComplete() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-package-check-complete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appBundle = tempDir.appendingPathComponent("PixelCrusher.app", isDirectory: true)
        let bundledTools = BundledToolingVerifier.bundledToolsDirectory(inAppBundle: appBundle)
        let binDir = bundledTools.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        for tool in OptimizerTool.requiredBundledTools {
            try makeExecutable(at: binDir.appendingPathComponent(tool.preferredExecutableNames[0]))
        }

        let missing = BundledToolingVerifier.missingRequiredTools(inAppBundle: appBundle)
        #expect(missing.isEmpty)
    }

    @Test("Built app bundle contains required bundled binaries when provided")
    func builtAppBundleCheckIfProvided() {
        guard let appPath = ProcessInfo.processInfo.environment["PIXELCRUSHER_APP_BUNDLE_UNDER_TEST"], !appPath.isEmpty else {
            return
        }

        let appURL = URL(fileURLWithPath: appPath)
        let missing = BundledToolingVerifier.missingRequiredTools(inAppBundle: appURL)
        #expect(missing.isEmpty)
    }

    private func makeExecutable(at url: URL) throws {
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
