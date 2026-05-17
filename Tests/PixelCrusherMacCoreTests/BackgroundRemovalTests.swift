import Testing
import Foundation
@testable import PixelCrusherMacCore

final class BackgroundRemovalUpdateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [BackgroundRemovalProgressUpdate] = []

    func append(_ update: BackgroundRemovalProgressUpdate) {
        lock.lock()
        updates.append(update)
        lock.unlock()
    }

    func snapshot() -> [BackgroundRemovalProgressUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }
}

struct BackgroundRemovalTests {
    @Test("Model cache directory honors PIXELCRUSHER_MODEL_CACHE_DIR override")
    func modelCacheOverrideIsHonored() {
        let root = BackgroundRemovalClient.defaultModelRootDirectory(
            environment: ["PIXELCRUSHER_MODEL_CACHE_DIR": "/tmp/pixelcrusher-models"]
        )
        #expect(root.path == "/tmp/pixelcrusher-models/rmbg-1.4")
    }

    @Test("Background removal status tracks each installed model variant")
    func statusesReflectInstalledModels() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-rmbg-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tool = tempDir.appendingPathComponent("rmbg-remove")
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let modelRoot = tempDir.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        let fastModel = modelRoot.appendingPathComponent("model_quantized.onnx")
        let fullModel = modelRoot.appendingPathComponent("model.onnx")
        try Data([1, 2, 3, 4]).write(to: fastModel)
        try Data([9, 8, 7, 6, 5]).write(to: fullModel)

        let client = BackgroundRemovalClient(
            removeToolURL: tool,
            modelRootDirectory: modelRoot
        )

        let statuses = client.statuses()
        let fastStatus = try #require(statuses.first(where: { $0.model == .fast }))
        let fullStatus = try #require(statuses.first(where: { $0.model == .highQuality }))

        #expect(fastStatus.isInstalled)
        #expect(fastStatus.modelURL.path == fastModel.path)
        #expect(fastStatus.installedBytes == 4)
        #expect(fullStatus.isInstalled)
        #expect(fullStatus.modelURL.path == fullModel.path)
        #expect(fullStatus.installedBytes == 5)
    }

    @Test("Explicit model download installs only the selected variant")
    func downloadModelInstallsSelectedVariant() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-rmbg-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tool = tempDir.appendingPathComponent("rmbg-remove")
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let payload = Data("fast-model".utf8)
        MockModelDownloadURLProtocol.payload = payload
        MockModelDownloadURLProtocol.statusCode = 200
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockModelDownloadURLProtocol.self]
        let session = URLSession(configuration: config)

        let client = BackgroundRemovalClient(
            removeToolURL: tool,
            modelRootDirectory: tempDir.appendingPathComponent("models", isDirectory: true),
            urlSession: session
        )

        let collector = BackgroundRemovalUpdateCollector()
        let installedURL = try await client.downloadModel(.fast) { update in
            collector.append(update)
        }

        let installedData = try Data(contentsOf: installedURL)
        let updates = collector.snapshot()
        #expect(installedURL.lastPathComponent == "model_quantized.onnx")
        #expect(installedData == payload)
        #expect(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("models/model.onnx").path) == false)
        #expect(updates.contains { $0.phase == "download" })
        #expect(updates.contains { $0.phase == "install" })
    }

    @Test("Background removal requires the chosen model to be installed first")
    func removeBackgroundRequiresInstalledModel() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-rmbg-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tool = tempDir.appendingPathComponent("rmbg-remove")
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let input = tempDir.appendingPathComponent("input.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: input)

        let client = BackgroundRemovalClient(
            removeToolURL: tool,
            modelRootDirectory: tempDir.appendingPathComponent("models", isDirectory: true)
        )

        do {
            _ = try await client.removeBackground(from: input, modelVariant: .fast)
            Issue.record("Expected modelNotInstalled error")
        } catch let error as BackgroundRemovalError {
            switch error {
            case .modelNotInstalled(let model):
                #expect(model == .fast)
            default:
                Issue.record("Unexpected error: \(error.localizedDescription)")
            }
        }
    }

    @Test("Background removal invocation streams status and encodes ROI for the selected model")
    func removeBackgroundInvocationUsesExpectedArguments() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-rmbg-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let argsPath = tempDir.appendingPathComponent("args.txt")
        let tool = tempDir.appendingPathComponent("rmbg-remove")
        try """
#!/bin/sh
set -e
printf '%s\n' "$@" > "\(argsPath.path)"
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--output" ]; then
    out="$2"
  fi
  shift
  if [ $# -gt 0 ]; then
    shift
  fi
done
printf '{"event":"status","phase":"segmenting","message":"Running background removal"}\n'
printf 'png' > "$out"
printf '{"event":"finished","payload":{"success":true,"output_path":"%s","output_bytes":3}}\n' "$out"
""".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let modelRoot = tempDir.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        let fastModel = modelRoot.appendingPathComponent("model_quantized.onnx")
        try Data([9, 9, 9]).write(to: fastModel)

        let input = tempDir.appendingPathComponent("input.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: input)

        let client = BackgroundRemovalClient(
            removeToolURL: tool,
            modelRootDirectory: modelRoot
        )

        let collector = BackgroundRemovalUpdateCollector()
        let report = try await client.removeBackground(
            from: input,
            modelVariant: .fast,
            focusRect: CGRect(x: 12, y: 34, width: 56, height: 78)
        ) { update in
            collector.append(update)
        }

        let args = try String(contentsOf: argsPath, encoding: .utf8)
        let updates = collector.snapshot()
        #expect(args.contains("--model"))
        #expect(args.contains(fastModel.path))
        #expect(args.contains("--input"))
        #expect(args.contains("--output"))
        #expect(args.contains("--roi"))
        #expect(args.contains("12,34,56,78"))
        #expect(updates.contains { $0.phase == "segmenting" })
        #expect(report.outputURL.lastPathComponent == "input_nobg.png")
        #expect(report.inputBytes == 4)
        #expect(report.outputBytes == 3)
    }

    @Test("Background removal result is recompressed before it is returned")
    func removeBackgroundRecompressesOutput() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-rmbg-compress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let removeTool = tempDir.appendingPathComponent("rmbg-remove")
        try """
#!/bin/sh
set -e
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--output" ]; then
    out="$2"
  fi
  shift
  if [ $# -gt 0 ]; then
    shift
  fi
done
printf '{"event":"finished","payload":{"success":true,"output_path":"%s","output_bytes":7}}\n' "$out"
printf 'rawmask' > "$out"
""".write(to: removeTool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: removeTool.path)

        let compressionScript = tempDir.appendingPathComponent("fake-pixelcrusher-cli")
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
  out="\(tempDir.appendingPathComponent("input_nobg_pixelcrusher.png").path)"
  printf 'compressed' > "$out"
  echo '{"event":"finished","payload":{"success":true,"report":{"source_path":"/tmp/input_nobg.png","destination_path":"'"$out"'","asset_format":"png","input_bytes":7,"output_bytes":10,"elapsed_ms":4,"applied_stages":["pngquant","pngcrush"]},"error":null}}'
  exit 0
fi
exit 1
""".write(to: compressionScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: compressionScript.path)

        let modelRoot = tempDir.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        try Data([9, 9, 9]).write(to: modelRoot.appendingPathComponent("model_quantized.onnx"))

        let input = tempDir.appendingPathComponent("input.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: input)

        let compressionClient = PixelCrusherBackendClient(
            cliExecutableURL: compressionScript,
            environment: ProcessInfo.processInfo.environment,
            bundledToolsDirectory: nil,
            outputDirectory: tempDir
        )

        let client = BackgroundRemovalClient(
            removeToolURL: removeTool,
            modelRootDirectory: modelRoot,
            compressionBackendClient: compressionClient
        )

        let collector = BackgroundRemovalUpdateCollector()
        let report = try await client.removeBackground(
            from: input,
            modelVariant: .fast,
            optimizer: OptimizerPreferences(
                jpegQualityPercent: 82,
                pngLossyEnabled: true,
                pngLossyQualityMin: 60,
                pngLossyQualityMax: 90,
                pngQuantSpeed: 3,
                pngUsePNGCrush: true,
                pngUseZopfli: false,
                pngUsePNGOUT: false,
                svgMultipass: true,
                gifOptimizationLevel: 3,
                gifLossyLevel: 0
            )
        ) { update in
            collector.append(update)
        }

        let updates = collector.snapshot()
        let finalData = try Data(contentsOf: report.outputURL)
        #expect(report.outputURL.lastPathComponent == "input_nobg.png")
        #expect(String(data: finalData, encoding: .utf8) == "compressed")
        #expect(updates.contains { $0.phase == "compress" })
    }
}

private final class MockModelDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: Self.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(Self.payload.count)]
              ) else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
