import Foundation

public struct ImageProcessingOptions: Sendable {
    public var overwriteOriginal: Bool
    public var autoTrimTransparentBorders: Bool
    public var fixedCropSize: CropSize?
    public var fixedCropAnchor: CropAnchor
    public var optimizer: OptimizerPreferences
    public var outputSuffix: String

    public init(
        overwriteOriginal: Bool = false,
        autoTrimTransparentBorders: Bool = true,
        fixedCropSize: CropSize? = nil,
        fixedCropAnchor: CropAnchor = .center,
        optimizer: OptimizerPreferences = OptimizerPreferences(),
        outputSuffix: String = "-processed"
    ) {
        self.overwriteOriginal = overwriteOriginal
        self.autoTrimTransparentBorders = autoTrimTransparentBorders
        self.fixedCropSize = fixedCropSize
        self.fixedCropAnchor = fixedCropAnchor
        self.optimizer = optimizer
        self.outputSuffix = outputSuffix
    }
}

public struct ImageProcessingReport: Sendable {
    public let inputURL: URL
    public let outputURL: URL
    public let pipelineName: String
    public let selectedTools: [String]
    public let inputBytes: Int64
    public let outputBytes: Int64
    public let warning: String?
    public let summary: String

    public init(
        inputURL: URL,
        outputURL: URL,
        pipelineName: String,
        selectedTools: [String],
        inputBytes: Int64,
        outputBytes: Int64,
        warning: String?,
        summary: String
    ) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.pipelineName = pipelineName
        self.selectedTools = selectedTools
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.warning = warning
        self.summary = summary
    }
}

public enum ImageProcessingError: LocalizedError {
    case unsupportedFormat(String)
    case backendBinaryMissing
    case backendProtocolError(String)
    case backendFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported file format: \(ext)"
        case .backendBinaryMissing:
            return "PixelCrusher backend binary (pixelcrusher-cli) is missing"
        case .backendProtocolError(let detail):
            return "Backend protocol error: \(detail)"
        case .backendFailed(let message):
            return message
        }
    }
}

public final class ImageProcessor: @unchecked Sendable {
    private let backend: PixelCrusherBackendClient

    public init(backend: PixelCrusherBackendClient = PixelCrusherBackendClient()) {
        self.backend = backend
    }

    public func processImage(
        at inputURL: URL,
        options: ImageProcessingOptions,
        statusHandler: (@Sendable (ProcessingStatusUpdate) -> Void)? = nil
    ) throws -> ImageProcessingReport {
        guard Self.isSupported(inputURL: inputURL) else {
            throw ImageProcessingError.unsupportedFormat(inputURL.pathExtension)
        }

        return try backend.processImage(at: inputURL, options: options, statusHandler: statusHandler)
    }

    private static func isSupported(inputURL: URL) -> Bool {
        ["png", "jpg", "jpeg", "svg", "gif"].contains(inputURL.pathExtension.lowercased())
    }
}

public struct PixelCrusherBackendClient: Sendable {
    private let cliExecutableURL: URL?
    private let environment: [String: String]
    private let bundledToolsDirectory: URL?
    private let outputDirectory: URL

    public init(
        cliExecutableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        bundledToolsDirectory: URL? = nil,
        outputDirectory: URL? = nil
    ) {
        self.environment = environment
        self.cliExecutableURL = cliExecutableURL ?? Self.defaultCLIExecutable(environment: environment, bundle: bundle)
        self.bundledToolsDirectory = bundledToolsDirectory ?? OptimizerToolDetector.defaultBundledToolsDirectory(bundle: bundle)
        self.outputDirectory = outputDirectory ?? Self.defaultOutputDirectory(environment: environment)
    }

    public func detectTools() throws -> [OptimizerToolStatus] {
        guard let executable = cliExecutableURL else {
            return OptimizerToolDetector(environment: environment, bundledToolsDirectory: bundledToolsDirectory).detect().statuses
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["diagnostics", "--json"]
        process.environment = mergedEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            throw ImageProcessingError.backendFailed(stderrText.isEmpty ? "Tool diagnostics failed" : stderrText)
        }

        let decoder = JSONDecoder()
        let statuses = try decoder.decode([CLIToolStatus].self, from: stdoutData)
        var byTool: [OptimizerTool: OptimizerToolStatus] = [:]

        for status in statuses {
            guard let tool = OptimizerTool(rawValue: status.name) else {
                continue
            }

            let source = status.sourceKind.flatMap(Self.mapSourceKind)
            byTool[tool] = OptimizerToolStatus(
                tool: tool,
                isAvailable: status.available,
                resolvedPath: status.source,
                source: source
            )
        }

        return OptimizerTool.allCases.map { tool in
            byTool[tool] ?? OptimizerToolStatus(tool: tool, isAvailable: false, resolvedPath: nil, source: nil)
        }
    }

    public func processImage(
        at inputURL: URL,
        options: ImageProcessingOptions,
        statusHandler: (@Sendable (ProcessingStatusUpdate) -> Void)? = nil
    ) throws -> ImageProcessingReport {
        guard let executable = cliExecutableURL else {
            throw ImageProcessingError.backendBinaryMissing
        }

        let request = CLIProcessRequest(
            inputPath: inputURL.path,
            outputDir: outputDirectory.path,
            options: CLIProcessOptions(from: options)
        )

        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["process", "--json"]
        process.environment = mergedEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        try process.run()

        stdinPipe.fileHandleForWriting.write(requestData)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
        try stdinPipe.fileHandleForWriting.close()

        let decoder = JSONDecoder()
        var lineBuffer = Data()
        var finalResult: CLIResultPayload?
        var finalError: String?

        let outputHandle = stdoutPipe.fileHandleForReading

        while true {
            let chunk = outputHandle.availableData
            if chunk.isEmpty {
                break
            }

            lineBuffer.append(chunk)
            while let newline = lineBuffer.firstIndex(of: 0x0A) {
                let lineData = lineBuffer.prefix(upTo: newline)
                lineBuffer.removeSubrange(...newline)
                consumeLine(
                    data: Data(lineData),
                    decoder: decoder,
                    statusHandler: statusHandler,
                    finalResult: &finalResult,
                    finalError: &finalError
                )
            }
        }

        if !lineBuffer.isEmpty {
            consumeLine(
                data: lineBuffer,
                decoder: decoder,
                statusHandler: statusHandler,
                finalResult: &finalResult,
                finalError: &finalError
            )
        }

        process.waitUntilExit()

        let stderrText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if let finalResult {
            return mapReport(inputURL: inputURL, payload: finalResult)
        }

        if let finalError {
            throw ImageProcessingError.backendFailed(finalError)
        }

        if process.terminationStatus != 0 {
            throw ImageProcessingError.backendFailed(
                stderrText.isEmpty ? "Backend exited with status \(process.terminationStatus)" : stderrText
            )
        }

        throw ImageProcessingError.backendProtocolError("No result payload returned by backend")
    }

    private func consumeLine(
        data: Data,
        decoder: JSONDecoder,
        statusHandler: (@Sendable (ProcessingStatusUpdate) -> Void)?,
        finalResult: inout CLIResultPayload?,
        finalError: inout String?
    ) {
        guard let rawLine = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawLine.isEmpty,
              let lineData = rawLine.data(using: .utf8)
        else {
            return
        }

        if let status = try? decoder.decode(CLIStatusEnvelope.self, from: lineData), status.type == "status" {
            statusHandler?(
                ProcessingStatusUpdate(
                    state: Self.mapState(status.state),
                    message: status.message
                )
            )
            return
        }

        if let resultEnvelope = try? decoder.decode(CLIResultEnvelope.self, from: lineData), resultEnvelope.type == "result" {
            if resultEnvelope.ok, let payload = resultEnvelope.result {
                finalResult = payload
            } else {
                finalError = resultEnvelope.error ?? "Unknown backend failure"
            }
        }
    }

    private func mapReport(inputURL: URL, payload: CLIResultPayload) -> ImageProcessingReport {
        let outputURL = URL(fileURLWithPath: payload.outputPath)
        let warning = payload.stagesRun.isEmpty ? "No optimizer stage was executed" : nil

        let deltaText: String
        if payload.inputSize <= 0 {
            deltaText = "+0.0%"
        } else {
            let delta = (Double(payload.outputSize) - Double(payload.inputSize)) / Double(payload.inputSize) * 100.0
            deltaText = String(format: "%+.1f%%", delta)
        }

        let summary = "pipeline=\(payload.format), tools=\(payload.stagesRun.joined(separator: "+")), size=\(payload.inputSize)B->\(payload.outputSize)B (\(deltaText))"

        return ImageProcessingReport(
            inputURL: inputURL,
            outputURL: outputURL,
            pipelineName: payload.format,
            selectedTools: payload.stagesRun,
            inputBytes: Int64(payload.inputSize),
            outputBytes: Int64(payload.outputSize),
            warning: warning,
            summary: summary
        )
    }

    private func mergedEnvironment() -> [String: String] {
        var env = environment
        if let bundledToolsDirectory {
            env["PIXELCRUSHER_BUNDLED_TOOLS_DIR"] = bundledToolsDirectory.path
        }
        return env
    }

    public static func defaultCLIExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> URL? {
        let fileManager = FileManager.default

        if let override = environment["PIXELCRUSHER_CLI_PATH"], !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        if let executablePath = bundle.executablePath {
            let appMacOSDir = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
            let sibling = appMacOSDir.appendingPathComponent("pixelcrusher-cli")
            if fileManager.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }

        if let resourceURL = bundle.resourceURL {
            let resourceBinary = resourceURL.appendingPathComponent("pixelcrusher-cli")
            if fileManager.isExecutableFile(atPath: resourceBinary.path) {
                return resourceBinary
            }
        }

        if let currentDir = environment["PWD"] {
            for profile in ["release", "debug"] {
                let devCandidate = URL(fileURLWithPath: currentDir)
                    .appendingPathComponent("crates/pixelcrusher-core/target/\(profile)/pixelcrusher-cli")
                if fileManager.isExecutableFile(atPath: devCandidate.path) {
                    return devCandidate
                }
            }
        }

        return nil
    }

    public static func defaultOutputDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["PIXELCRUSHER_OUTPUT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        return downloads.appendingPathComponent("PixelCrusher", isDirectory: true)
    }

    private static func mapState(_ state: String) -> ProcessingItemState {
        switch state {
        case "diagnosing", "processing", "preparing":
            return .preparing
        case "optimizing":
            return .optimizing
        case "saving":
            return .saving
        case "done", "completed":
            return .done
        case "failed":
            return .failed
        default:
            return .preparing
        }
    }

    private static func mapSourceKind(_ sourceKind: String) -> OptimizerToolResolutionSource? {
        switch sourceKind {
        case "environment_override":
            return .environmentOverride
        case "bundled":
            return .bundled
        case "host_path":
            return .hostPath
        default:
            return nil
        }
    }
}

private struct CLIProcessRequest: Encodable {
    let inputPath: String
    let outputDir: String
    let options: CLIProcessOptions

    enum CodingKeys: String, CodingKey {
        case inputPath = "input_path"
        case outputDir = "output_dir"
        case options
    }
}

private struct CLIProcessOptions: Encodable {
    let trimTransparent: Bool
    let dimensions: CLIDimensions
    let compression: CLICompression

    init(from options: ImageProcessingOptions) {
        trimTransparent = options.autoTrimTransparentBorders
        dimensions = CLIDimensions(
            cropWidth: options.fixedCropSize.map { UInt32($0.width) },
            cropHeight: options.fixedCropSize.map { UInt32($0.height) },
            resizeWidth: nil,
            resizeHeight: nil
        )
        compression = CLICompression(from: options.optimizer)
    }

    enum CodingKeys: String, CodingKey {
        case trimTransparent = "trim_transparent"
        case dimensions
        case compression
    }
}

private struct CLIDimensions: Encodable {
    let cropWidth: UInt32?
    let cropHeight: UInt32?
    let resizeWidth: UInt32?
    let resizeHeight: UInt32?

    enum CodingKeys: String, CodingKey {
        case cropWidth = "crop_width"
        case cropHeight = "crop_height"
        case resizeWidth = "resize_width"
        case resizeHeight = "resize_height"
    }
}

private struct CLICompression: Encodable {
    let quality: UInt8
    let pngQuantQualityMin: UInt8
    let pngQuantQualityMax: UInt8
    let runPNGQuant: Bool
    let pngQuantSpeed: UInt8
    let runPNGCrush: Bool
    let runZopfli: Bool
    let runPNGOUT: Bool
    let svgMultipass: Bool
    let gifOptimizationLevel: UInt8
    let gifLossyLevel: UInt16

    init(from preferences: OptimizerPreferences) {
        quality = UInt8(max(1, min(100, preferences.jpegQualityPercent)))
        pngQuantQualityMin = UInt8(max(0, min(100, preferences.pngLossyQualityMin)))
        pngQuantQualityMax = UInt8(max(0, min(100, preferences.pngLossyQualityMax)))
        runPNGQuant = preferences.pngLossyEnabled
        pngQuantSpeed = UInt8(max(1, min(11, preferences.pngQuantSpeed)))
        runPNGCrush = preferences.pngUsePNGCrush
        runZopfli = preferences.pngUseZopfli
        runPNGOUT = preferences.pngUsePNGOUT
        svgMultipass = preferences.svgMultipass
        gifOptimizationLevel = UInt8(max(1, min(3, preferences.gifOptimizationLevel)))
        gifLossyLevel = UInt16(max(0, min(200, preferences.gifLossyLevel)))
    }

    enum CodingKeys: String, CodingKey {
        case quality
        case pngQuantQualityMin = "png_quant_quality_min"
        case pngQuantQualityMax = "png_quant_quality_max"
        case runPNGQuant = "run_png_quant"
        case pngQuantSpeed = "png_quant_speed"
        case runPNGCrush = "run_pngcrush"
        case runZopfli = "run_zopfli"
        case runPNGOUT = "run_pngout"
        case svgMultipass = "svg_multipass"
        case gifOptimizationLevel = "gif_optimization_level"
        case gifLossyLevel = "gif_lossy_level"
    }
}

private struct CLIToolStatus: Decodable {
    let name: String
    let available: Bool
    let source: String?
    let sourceKind: String?

    enum CodingKeys: String, CodingKey {
        case name
        case available
        case source
        case sourceKind = "source_kind"
    }
}

private struct CLIStatusEnvelope: Decodable {
    let type: String
    let state: String
    let message: String
    let progress: Int?
}

private struct CLIResultEnvelope: Decodable {
    let type: String
    let ok: Bool
    let result: CLIResultPayload?
    let error: String?
}

private struct CLIResultPayload: Decodable {
    let inputPath: String
    let outputPath: String
    let format: String
    let inputSize: UInt64
    let outputSize: UInt64
    let durationMs: UInt64
    let stagesRun: [String]

    enum CodingKeys: String, CodingKey {
        case inputPath = "input_path"
        case outputPath = "output_path"
        case format
        case inputSize = "input_size"
        case outputSize = "output_size"
        case durationMs = "duration_ms"
        case stagesRun = "stages_run"
    }
}
