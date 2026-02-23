import Testing
import Foundation
@testable import PixelCrusherMacCore

struct ToolResolverTests {
    @Test("Bundled tools take precedence over host PATH")
    func bundledPrecedence() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-toolresolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundledBin = tempDir.appendingPathComponent("bundled/bin", isDirectory: true)
        let hostBin = tempDir.appendingPathComponent("host/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bundledBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hostBin, withIntermediateDirectories: true)

        let bundledPNGQuant = bundledBin.appendingPathComponent("pngquant")
        let hostPNGQuant = hostBin.appendingPathComponent("pngquant")
        try makeExecutable(at: bundledPNGQuant, text: "#!/bin/sh\necho bundled\n")
        try makeExecutable(at: hostPNGQuant, text: "#!/bin/sh\necho host\n")

        let detector = OptimizerToolDetector(
            environment: ["PATH": hostBin.path],
            bundledToolsDirectory: tempDir.appendingPathComponent("bundled", isDirectory: true)
        )

        let chain = detector.detect()
        #expect(chain.executableURL(for: .pngquant)?.path == bundledPNGQuant.path)
        #expect(chain.source(for: .pngquant) == .bundled)
    }

    @Test("Host PATH is used when bundled binary is missing")
    func hostFallbackWhenBundledMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-toolresolver-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundledRoot = tempDir.appendingPathComponent("bundled", isDirectory: true)
        let hostBin = tempDir.appendingPathComponent("host/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bundledRoot.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hostBin, withIntermediateDirectories: true)

        let hostPNGCrush = hostBin.appendingPathComponent("pngcrush")
        try makeExecutable(at: hostPNGCrush, text: "#!/bin/sh\necho host\n")

        let detector = OptimizerToolDetector(
            environment: ["PATH": hostBin.path],
            bundledToolsDirectory: bundledRoot
        )

        let chain = detector.detect()
        #expect(chain.executableURL(for: .pngcrush)?.path == hostPNGCrush.path)
        #expect(chain.source(for: .pngcrush) == .hostPath)
    }

    @Test("Environment override has highest priority")
    func environmentOverrideWins() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-toolresolver-override-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundledBin = tempDir.appendingPathComponent("bundled/bin", isDirectory: true)
        let hostBin = tempDir.appendingPathComponent("host/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bundledBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hostBin, withIntermediateDirectories: true)

        let bundledGIFSicle = bundledBin.appendingPathComponent("gifsicle")
        let hostGIFSicle = hostBin.appendingPathComponent("gifsicle")
        let overrideGIFSicle = tempDir.appendingPathComponent("override-gifsicle")

        try makeExecutable(at: bundledGIFSicle, text: "#!/bin/sh\necho bundled\n")
        try makeExecutable(at: hostGIFSicle, text: "#!/bin/sh\necho host\n")
        try makeExecutable(at: overrideGIFSicle, text: "#!/bin/sh\necho override\n")

        let detector = OptimizerToolDetector(
            environment: [
                "PATH": hostBin.path,
                OptimizerTool.gifsicle.environmentOverrideKey: overrideGIFSicle.path
            ],
            bundledToolsDirectory: tempDir.appendingPathComponent("bundled", isDirectory: true)
        )

        let chain = detector.detect()
        #expect(chain.executableURL(for: .gifsicle)?.path == overrideGIFSicle.path)
        #expect(chain.source(for: .gifsicle) == .environmentOverride)
    }

    private func makeExecutable(at url: URL, text: String) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
