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
  echo '{"event":"status","payload":{"phase":"transform","message":"Processing image","progress_percent":45}}'
  echo '{"event":"status","payload":{"phase":"optimize","message":"Optimizing output","progress_percent":80}}'
  echo '{"event":"finished","payload":{"success":true,"report":{"source_path":"/tmp/input.png","destination_path":"\(outputPath)","asset_format":"png","input_bytes":100,"output_bytes":80,"elapsed_ms":15,"applied_stages":["pngquant","pngcrush"]},"error":null}}'
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
  echo '[{"tool":"cjpeg","is_available":true,"resolved_path":"/App/BundledTools/bin/cjpeg","resolution":"bundled"},{"tool":"pngquant","is_available":false,"resolved_path":null,"resolution":null}]'
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

    @Test("Backend request encodes crop anchor and resize transform")
    func encodesTransformOptions() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-transform-options-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("out.png").path
        let requestPath = tempDir.appendingPathComponent("request.json").path
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
  cat > "\(requestPath)"
  echo '{"event":"finished","payload":{"success":true,"report":{"source_path":"/tmp/input.png","destination_path":"\(outputPath)","asset_format":"png","input_bytes":100,"output_bytes":90,"elapsed_ms":11,"applied_stages":["pngquant"]},"error":null}}'
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

        _ = try client.processImage(
            at: inputFile,
            options: ImageProcessingOptions(
                autoTrimTransparentBorders: false,
                fixedCropSize: try CropSize(width: 256, height: 128),
                fixedCropOrigin: try CropOrigin(x: 32, y: 24),
                fixedResizeSize: try CropSize(width: 512, height: 256),
                fixedCropAnchor: .bottomRight,
                outputFormat: .jpeg
            )
        )

        let requestData = try #require(FileManager.default.contents(atPath: requestPath))
        let json = try JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        let options = json?["options"] as? [String: Any]
        let transform = options?["transform"] as? [String: Any]

        #expect(options?["trim_transparent"] as? Bool == false)
        #expect(transform?["crop_width"] as? Int == 256)
        #expect(transform?["crop_height"] as? Int == 128)
        #expect(transform?["crop_x"] as? Int == 32)
        #expect(transform?["crop_y"] as? Int == 24)
        #expect(transform?["crop_anchor"] as? String == "bottom_right")
        #expect(transform?["resize_width"] as? Int == 512)
        #expect(transform?["resize_height"] as? Int == 256)
        #expect(options?["output_format"] as? String == "jpeg")
    }

    @Test("Backend request encodes raster export size for format conversion")
    func encodesRasterConversionSize() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-raster-conversion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("out.png").path
        let requestPath = tempDir.appendingPathComponent("request.json").path
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
  cat > "\(requestPath)"
  echo '{"event":"finished","payload":{"success":true,"report":{"source_path":"/tmp/input.svg","destination_path":"\(outputPath)","asset_format":"png","input_bytes":100,"output_bytes":90,"elapsed_ms":11,"applied_stages":["pngquant"]},"error":null}}'
  exit 0
fi
exit 1
""".write(to: cliScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliScript.path)

        let inputFile = tempDir.appendingPathComponent("input.svg")
        try Data("<svg viewBox='0 0 10 10'></svg>".utf8).write(to: inputFile)

        let client = PixelCrusherBackendClient(
            cliExecutableURL: cliScript,
            environment: ProcessInfo.processInfo.environment,
            bundledToolsDirectory: nil,
            outputDirectory: tempDir
        )

        _ = try client.processImage(
            at: inputFile,
            options: ImageProcessingOptions(
                autoTrimTransparentBorders: false,
                fixedResizeSize: try CropSize(width: 2048, height: 2048),
                outputFormat: .png
            )
        )

        let requestData = try #require(FileManager.default.contents(atPath: requestPath))
        let json = try JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        let options = json?["options"] as? [String: Any]
        let transform = options?["transform"] as? [String: Any]

        #expect(transform?["resize_width"] as? Int == 2048)
        #expect(transform?["resize_height"] as? Int == 2048)
        #expect(options?["output_format"] as? String == "png")
    }

    @Test("Per-call output directory override is encoded in backend request")
    func processImageUsesPerCallOutputDirectoryOverride() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-output-override-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("out.png").path
        let requestPath = tempDir.appendingPathComponent("request.json").path
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
  cat > "\(requestPath)"
  echo '{"event":"finished","payload":{"success":true,"report":{"source_path":"/tmp/input.png","destination_path":"\(outputPath)","asset_format":"png","input_bytes":100,"output_bytes":90,"elapsed_ms":11,"applied_stages":["pngquant"]},"error":null}}'
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
            outputDirectory: tempDir.appendingPathComponent("client-default", isDirectory: true)
        )

        let perCallOutput = tempDir.appendingPathComponent("from-call", isDirectory: true)
        _ = try client.processImage(
            at: inputFile,
            options: ImageProcessingOptions(),
            outputDirectory: perCallOutput
        )

        let requestData = try #require(FileManager.default.contents(atPath: requestPath))
        let json = try JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        #expect(json?["output_dir"] as? String == perCallOutput.path)
    }
}
