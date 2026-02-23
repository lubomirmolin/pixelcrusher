import Testing
import Foundation
@testable import PixelCrusherMacCore

final class StateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [ProcessingItemState] = []

    func append(_ state: ProcessingItemState) {
        lock.lock()
        states.append(state)
        lock.unlock()
    }

    func snapshot() -> [ProcessingItemState] {
        lock.lock()
        defer { lock.unlock() }
        return states
    }
}

struct BackendInvocationTests {
    @Test("Default output directory resolves to input parent path")
    func defaultOutputDirectoryUsesInputParentByDefault() {
        let input = URL(fileURLWithPath: "/path/to/file.png")
        let resolved = PixelCrusherBackendClient.defaultOutputDirectory(for: input, environment: [:])
        #expect(resolved.path == "/path/to")
    }

    @Test("PIXELCRUSHER_OUTPUT_DIR override is honored")
    func outputDirectoryOverrideIsHonored() {
        let input = URL(fileURLWithPath: "/path/to/file.png")
        let resolved = PixelCrusherBackendClient.defaultOutputDirectory(
            for: input,
            environment: ["PIXELCRUSHER_OUTPUT_DIR": "/custom/output"]
        )
        #expect(resolved.path == "/custom/output")
    }

    @Test("Backend client parses status and result JSON lines from CLI")
    func parsesProcessStream() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-backend-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("out.png").path
        let cliScript = tempDir.appendingPathComponent("fake-pixelcrusher-cli")

        try """
#!/bin/sh
set -e
cmd="$1"
if [ "$cmd" = "diagnostics" ]; then
  echo '[]'
  exit 0
fi
if [ "$cmd" = "process" ]; then
  cat >/dev/null
  echo '{"type":"status","state":"processing","message":"Processing image","progress":45}'
  echo '{"type":"status","state":"optimizing","message":"Optimizing output","progress":80}'
  echo '{"type":"result","ok":true,"result":{"input_path":"/tmp/input.png","output_path":"\(outputPath)","format":"png","input_size":100,"output_size":80,"duration_ms":15,"stages_run":["pngquant","pngcrush"]}}'
  exit 0
fi
exit 1
""".write(to: cliScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliScript.path)

        let inputFile = tempDir.appendingPathComponent("input.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: inputFile)

        let client = PixelCrusherBackendClient(
            cliExecutableURL: cliScript,
            environment: ProcessInfo.processInfo.environment,
            bundledToolsDirectory: nil,
            outputDirectory: tempDir
        )

        let collector = StateCollector()
        let report = try client.processImage(at: inputFile, options: ImageProcessingOptions()) { update in
            collector.append(update.state)
        }

        let seenStates = collector.snapshot()
        #expect(seenStates.contains(.preparing))
        #expect(seenStates.contains(.optimizing))
        #expect(report.outputURL.path == outputPath)
        #expect(report.selectedTools == ["pngquant", "pngcrush"])
    }

    @Test("Backend diagnostics JSON maps to optimizer statuses")
    func parsesDiagnostics() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-backend-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cliScript = tempDir.appendingPathComponent("fake-pixelcrusher-cli")
        try """
#!/bin/sh
set -e
cmd="$1"
if [ "$cmd" = "diagnostics" ]; then
  echo '[{"name":"cjpeg","available":true,"source":"/App/BundledTools/bin/cjpeg","source_kind":"bundled"},{"name":"pngquant","available":false,"source":null,"source_kind":null}]'
  exit 0
fi
echo '{"type":"result","ok":false,"error":"not implemented"}'
exit 1
""".write(to: cliScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliScript.path)

        let client = PixelCrusherBackendClient(
            cliExecutableURL: cliScript,
            environment: ProcessInfo.processInfo.environment,
            bundledToolsDirectory: nil,
            outputDirectory: tempDir
        )

        let statuses = try client.detectTools()
        let cjpeg = statuses.first { $0.tool == .cjpeg }
        let pngquant = statuses.first { $0.tool == .pngquant }

        #expect(cjpeg?.isAvailable == true)
        #expect(cjpeg?.source == .bundled)
        #expect(pngquant?.isAvailable == false)
    }
}
