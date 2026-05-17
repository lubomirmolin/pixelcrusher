import Foundation
import CoreGraphics

public enum BackgroundRemovalSuitability: Sendable, Equatable {
    case ready(String)
    case warning(String)
    case unavailable(String)

    public var message: String {
        switch self {
        case .ready(let message), .warning(let message), .unavailable(let message):
            return message
        }
    }

    public var isAvailable: Bool {
        switch self {
        case .ready, .warning:
            return true
        case .unavailable:
            return false
        }
    }
}

public enum BackgroundRemovalModelVariant: String, Sendable, CaseIterable, Equatable {
    case fast
    case highQuality

    public var displayName: String {
        switch self {
        case .fast:
            return "Fast"
        case .highQuality:
            return "High Quality"
        }
    }

    public var detail: String {
        switch self {
        case .fast:
            return "Quantized RMBG-1.4 ONNX. Smaller download, lower memory use, slightly softer edges."
        case .highQuality:
            return "Full RMBG-1.4 ONNX. Larger download, heavier RAM use, better edge fidelity."
        }
    }

    public var shortLabel: String {
        switch self {
        case .fast:
            return "Quantized"
        case .highQuality:
            return "Full"
        }
    }

    public var remoteFilename: String {
        switch self {
        case .fast:
            return "model_quantized.onnx"
        case .highQuality:
            return "model.onnx"
        }
    }

    public var localFilename: String {
        remoteFilename
    }

    public var temporaryFilename: String {
        "\(remoteFilename).download"
    }

    public var downloadURL: URL {
        switch self {
        case .fast:
            return URL(string: "https://huggingface.co/briaai/RMBG-1.4/resolve/main/onnx/model_quantized.onnx")!
        case .highQuality:
            return URL(string: "https://huggingface.co/briaai/RMBG-1.4/resolve/main/onnx/model.onnx")!
        }
    }

    public var expectedDownloadBytes: Int64 {
        switch self {
        case .fast:
            return 44_403_226
        case .highQuality:
            return 176_153_355
        }
    }

    public var requiredInstallHeadroomBytes: Int64 {
        switch self {
        case .fast:
            return expectedDownloadBytes + 64 * 1_024 * 1_024
        case .highQuality:
            return expectedDownloadBytes + 192 * 1_024 * 1_024
        }
    }

    fileprivate var summaryToken: String {
        switch self {
        case .fast:
            return "rmbg-1.4-quantized"
        case .highQuality:
            return "rmbg-1.4-full"
        }
    }
}

public struct BackgroundRemovalModelStatus: Sendable, Equatable {
    public let model: BackgroundRemovalModelVariant
    public let isInstalled: Bool
    public let modelURL: URL
    public let installedBytes: Int64?
    public let downloadBytes: Int64
    public let suitability: BackgroundRemovalSuitability

    public init(
        model: BackgroundRemovalModelVariant,
        isInstalled: Bool,
        modelURL: URL,
        installedBytes: Int64?,
        downloadBytes: Int64,
        suitability: BackgroundRemovalSuitability
    ) {
        self.model = model
        self.isInstalled = isInstalled
        self.modelURL = modelURL
        self.installedBytes = installedBytes
        self.downloadBytes = downloadBytes
        self.suitability = suitability
    }
}

public struct BackgroundRemovalProgressUpdate: Sendable, Equatable {
    public let phase: String
    public let message: String

    public init(phase: String, message: String) {
        self.phase = phase
        self.message = message
    }
}

public struct BackgroundRemovalReport: Sendable, Equatable {
    public let sourceURL: URL
    public let outputURL: URL
    public let inputBytes: Int64
    public let outputBytes: Int64
    public let summary: String

    public init(sourceURL: URL, outputURL: URL, inputBytes: Int64, outputBytes: Int64, summary: String) {
        self.sourceURL = sourceURL
        self.outputURL = outputURL
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.summary = summary
    }
}

public enum BackgroundRemovalError: LocalizedError {
    case unsupportedInputFormat(String)
    case bundledRuntimeMissing
    case modelNotInstalled(BackgroundRemovalModelVariant)
    case insufficientDiskSpace
    case machineUnsupported(String)
    case downloadFailed(String)
    case runtimeFailed(String)
    case invalidOutputPath

    public var errorDescription: String? {
        switch self {
        case .unsupportedInputFormat(let ext):
            return "Background removal supports PNG and JPEG only (got \(ext))."
        case .bundledRuntimeMissing:
            return "Bundled background-removal runtime is missing from the app bundle."
        case .modelNotInstalled(let model):
            return "\(model.displayName) RMBG model is not installed yet. Download it first."
        case .insufficientDiskSpace:
            return "Not enough free disk space to install the RMBG model."
        case .machineUnsupported(let reason):
            return reason
        case .downloadFailed(let message):
            return message
        case .runtimeFailed(let message):
            return message
        case .invalidOutputPath:
            return "Could not determine an output path for the background-removed image."
        }
    }
}

public struct BackgroundRemovalClient: Sendable {
    private let environment: [String: String]
    private let bundledToolsDirectory: URL?
    private let removeToolURL: URL?
    private let modelRootDirectory: URL
    private let urlSession: URLSession
    private let compressionBackendClient: PixelCrusherBackendClient?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        bundledToolsDirectory: URL? = nil,
        removeToolURL: URL? = nil,
        modelRootDirectory: URL? = nil,
        urlSession: URLSession = .shared,
        compressionBackendClient: PixelCrusherBackendClient? = nil
    ) {
        self.environment = environment
        self.bundledToolsDirectory = bundledToolsDirectory ?? OptimizerToolDetector.defaultBundledToolsDirectory(bundle: bundle)
        self.removeToolURL = removeToolURL ?? Self.defaultRemoveToolURL(
            environment: environment,
            bundledToolsDirectory: bundledToolsDirectory ?? OptimizerToolDetector.defaultBundledToolsDirectory(bundle: bundle)
        )
        self.modelRootDirectory = modelRootDirectory ?? Self.defaultModelRootDirectory(environment: environment)
        self.urlSession = urlSession
        self.compressionBackendClient = compressionBackendClient
    }

    public func statuses() -> [BackgroundRemovalModelStatus] {
        BackgroundRemovalModelVariant.allCases.map(status(for:))
    }

    public func status(for model: BackgroundRemovalModelVariant) -> BackgroundRemovalModelStatus {
        let modelURL = installedModelURL(for: model)
        let isInstalled = FileManager.default.fileExists(atPath: modelURL.path)
        let installedBytes = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber)?.int64Value
        return BackgroundRemovalModelStatus(
            model: model,
            isInstalled: isInstalled,
            modelURL: modelURL,
            installedBytes: installedBytes,
            downloadBytes: model.expectedDownloadBytes,
            suitability: suitability(for: model, isInstalled: isInstalled)
        )
    }

    public func supportsInputFile(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg":
            return true
        default:
            return false
        }
    }

    public func downloadModel(
        _ model: BackgroundRemovalModelVariant,
        progressHandler: (@Sendable (BackgroundRemovalProgressUpdate) -> Void)? = nil
    ) async throws -> URL {
        let status = status(for: model)
        guard status.suitability.isAvailable else {
            throw BackgroundRemovalError.machineUnsupported(status.suitability.message)
        }

        let fileManager = FileManager.default
        let installedURL = status.modelURL
        if fileManager.fileExists(atPath: installedURL.path) {
            return installedURL
        }

        try fileManager.createDirectory(at: modelRootDirectory, withIntermediateDirectories: true)
        guard hasEnoughDiskSpace(requiredBytes: model.requiredInstallHeadroomBytes) else {
            throw BackgroundRemovalError.insufficientDiskSpace
        }

        progressHandler?(BackgroundRemovalProgressUpdate(phase: "download", message: "Downloading \(model.displayName) RMBG model"))
        let temporaryURL = modelRootDirectory.appendingPathComponent(model.temporaryFilename)
        let (downloadedURL, response) = try await urlSession.download(from: model.downloadURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw BackgroundRemovalError.downloadFailed("Model download did not return a successful response.")
        }

        try? fileManager.removeItem(at: temporaryURL)
        try fileManager.moveItem(at: downloadedURL, to: temporaryURL)

        let downloadedBytes = fileSize(at: temporaryURL)
        if downloadedBytes <= 0 {
            try? fileManager.removeItem(at: temporaryURL)
            throw BackgroundRemovalError.downloadFailed("Model download produced an empty file.")
        }

        if response.expectedContentLength > 0, response.expectedContentLength != downloadedBytes {
            try? fileManager.removeItem(at: temporaryURL)
            throw BackgroundRemovalError.downloadFailed("Model download appears truncated.")
        }

        progressHandler?(BackgroundRemovalProgressUpdate(phase: "install", message: "Installing \(model.displayName) RMBG model"))
        try? fileManager.removeItem(at: installedURL)
        try fileManager.moveItem(at: temporaryURL, to: installedURL)
        return installedURL
    }

    public func removeBackground(
        from inputURL: URL,
        modelVariant: BackgroundRemovalModelVariant,
        focusRect: CGRect? = nil,
        outputDirectory: URL? = nil,
        optimizer: OptimizerPreferences? = nil,
        progressHandler: (@Sendable (BackgroundRemovalProgressUpdate) -> Void)? = nil
    ) async throws -> BackgroundRemovalReport {
        guard supportsInputFile(inputURL) else {
            throw BackgroundRemovalError.unsupportedInputFormat(inputURL.pathExtension)
        }

        guard let removeToolURL else {
            throw BackgroundRemovalError.bundledRuntimeMissing
        }

        let status = status(for: modelVariant)
        guard status.suitability.isAvailable else {
            throw BackgroundRemovalError.machineUnsupported(status.suitability.message)
        }

        guard status.isInstalled else {
            throw BackgroundRemovalError.modelNotInstalled(modelVariant)
        }

        let modelURL = status.modelURL
        let outputURL = try Self.makeOutputURL(for: inputURL, outputDirectory: outputDirectory)
        let inputBytes = fileSize(at: inputURL)

        progressHandler?(BackgroundRemovalProgressUpdate(phase: "prepare", message: "Preparing \(modelVariant.displayName) background removal"))

        let process = Process()
        process.executableURL = removeToolURL
        var arguments = [
            "--model", modelURL.path,
            "--input", inputURL.path,
            "--output", outputURL.path,
        ]

        if let focusRect {
            let roi = [
                Int(focusRect.origin.x.rounded()),
                Int(focusRect.origin.y.rounded()),
                Int(focusRect.width.rounded()),
                Int(focusRect.height.rounded()),
            ].map(String.init).joined(separator: ",")
            arguments += ["--roi", roi]
        }

        process.arguments = arguments
        process.environment = mergedEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let decoder = JSONDecoder()
        var lineBuffer = Data()
        var finalResult: RMBGFinishedPayload?
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
                    progressHandler: progressHandler,
                    finalResult: &finalResult
                )
            }
        }

        if !lineBuffer.isEmpty {
            consumeLine(
                data: lineBuffer,
                decoder: decoder,
                progressHandler: progressHandler,
                finalResult: &finalResult
            )
        }

        process.waitUntilExit()
        let stderrText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw BackgroundRemovalError.runtimeFailed(stderrText.isEmpty ? "Background removal failed." : stderrText)
        }

        guard let finalResult else {
            throw BackgroundRemovalError.runtimeFailed("Background removal did not return a result.")
        }

        guard finalResult.success else {
            throw BackgroundRemovalError.runtimeFailed(finalResult.error ?? "Background removal failed.")
        }

        guard let outputPath = finalResult.outputPath else {
            throw BackgroundRemovalError.invalidOutputPath
        }

        let finalOutputURL = URL(fileURLWithPath: outputPath)
        let compressedOutputURL: URL
        let outputBytes: Int64
        let summary: String

        if let optimizer {
            let compressed = try compressRemovedBackground(
                sourceURL: finalOutputURL,
                originalInputBytes: inputBytes,
                modelVariant: modelVariant,
                optimizer: optimizer,
                progressHandler: progressHandler
            )
            compressedOutputURL = compressed.outputURL
            outputBytes = compressed.outputBytes
            summary = compressed.summary
        } else {
            compressedOutputURL = finalOutputURL
            outputBytes = finalResult.outputBytes ?? fileSize(at: finalOutputURL)
            let deltaPercent = inputBytes > 0 ? ((Double(outputBytes - inputBytes) / Double(inputBytes)) * 100.0) : 0.0
            summary = String(
                format: "background_removed=%@, size=%lldB->%lldB (%+.1f%%)",
                modelVariant.summaryToken,
                inputBytes,
                outputBytes,
                deltaPercent
            )
        }

        return BackgroundRemovalReport(
            sourceURL: inputURL,
            outputURL: compressedOutputURL,
            inputBytes: inputBytes,
            outputBytes: outputBytes,
            summary: summary
        )
    }

    public static func defaultModelRootDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["PIXELCRUSHER_MODEL_CACHE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
                .appendingPathComponent("rmbg-1.4", isDirectory: true)
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("PixelCrusher", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("rmbg-1.4", isDirectory: true)
    }

    public static func defaultRemoveToolURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledToolsDirectory: URL?
    ) -> URL? {
        let fileManager = FileManager.default
        if let override = environment["PIXELCRUSHER_RMBG_REMOVE_PATH"], !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        guard let bundledToolsDirectory else {
            return nil
        }

        let candidate = bundledToolsDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("rmbg-remove")
        return fileManager.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    private func installedModelURL(for model: BackgroundRemovalModelVariant) -> URL {
        modelRootDirectory.appendingPathComponent(model.localFilename)
    }

    private func suitability(for model: BackgroundRemovalModelVariant, isInstalled: Bool) -> BackgroundRemovalSuitability {
        guard removeToolURL != nil else {
            return .unavailable("Bundled background-removal runtime is missing.")
        }

        if !isInstalled && !hasEnoughDiskSpace(requiredBytes: model.requiredInstallHeadroomBytes) {
            return .unavailable("Not enough free disk space for the \(model.displayName.lowercased()) model download.")
        }

        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        switch model {
        case .fast:
            if physicalMemory < 4 * 1_024 * 1_024 * 1_024 {
                return .unavailable("This Mac has less than 4 GB of RAM. The fast RMBG model will have a bad time here.")
            }
            if physicalMemory < 8 * 1_024 * 1_024 * 1_024 {
                return .warning("The fast RMBG model should work, but Macs with under 8 GB RAM may be slow.")
            }
        case .highQuality:
            if physicalMemory < 8 * 1_024 * 1_024 * 1_024 {
                return .unavailable("This Mac has less than 8 GB of RAM. The full RMBG model is not a reasonable choice here.")
            }
            if physicalMemory < 16 * 1_024 * 1_024 * 1_024 {
                return .warning("The full RMBG model should work, but Macs with under 16 GB RAM may be slow.")
            }
        }

        #if arch(x86_64)
        return .warning("\(model.displayName) RMBG is available. Intel Macs should work, but Apple Silicon will be faster.")
        #else
        return .ready("\(model.displayName) RMBG is available for manual install on this Mac.")
        #endif
    }

    private func hasEnoughDiskSpace(requiredBytes: Int64) -> Bool {
        let probeURL = modelRootDirectory.deletingLastPathComponent()
        let values = try? probeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage {
            return available >= requiredBytes
        }
        return true
    }

    private func mergedEnvironment() -> [String: String] {
        var env = environment
        if let bundledToolsDirectory {
            env["PIXELCRUSHER_BUNDLED_TOOLS_DIR"] = bundledToolsDirectory.path
        }
        return env
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func consumeLine(
        data: Data,
        decoder: JSONDecoder,
        progressHandler: (@Sendable (BackgroundRemovalProgressUpdate) -> Void)?,
        finalResult: inout RMBGFinishedPayload?
    ) {
        guard let rawLine = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawLine.isEmpty,
              let lineData = rawLine.data(using: .utf8) else {
            return
        }

        if let status = try? decoder.decode(RMBGStatusEnvelope.self, from: lineData), status.event == "status" {
            progressHandler?(BackgroundRemovalProgressUpdate(phase: status.phase, message: status.message))
            return
        }

        if let finished = try? decoder.decode(RMBGFinishedEnvelope.self, from: lineData), finished.event == "finished" {
            finalResult = finished.payload
        }
    }

    private static func makeOutputURL(for inputURL: URL, outputDirectory: URL? = nil) throws -> URL {
        let directory = outputDirectory ?? inputURL.deletingLastPathComponent()
        let stem = inputURL.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else {
            throw BackgroundRemovalError.invalidOutputPath
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        for suffixIndex in 0..<100 {
            let suffix = suffixIndex == 0 ? "_nobg" : "_nobg_\(suffixIndex + 1)"
            let candidate = directory.appendingPathComponent("\(stem)\(suffix).png")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw BackgroundRemovalError.invalidOutputPath
    }

    private func compressRemovedBackground(
        sourceURL: URL,
        originalInputBytes: Int64,
        modelVariant: BackgroundRemovalModelVariant,
        optimizer: OptimizerPreferences,
        progressHandler: (@Sendable (BackgroundRemovalProgressUpdate) -> Void)?
    ) throws -> BackgroundRemovalReport {
        progressHandler?(BackgroundRemovalProgressUpdate(phase: "compress", message: "Compressing transparent PNG"))

        let backend = compressionBackendClient ?? PixelCrusherBackendClient(
            environment: environment,
            bundle: .main,
            bundledToolsDirectory: bundledToolsDirectory,
            outputDirectory: sourceURL.deletingLastPathComponent()
        )

        let compressionOptions = ImageProcessingOptions(
            overwriteOriginal: false,
            autoTrimTransparentBorders: false,
            fixedCropSize: nil,
            fixedCropOrigin: nil,
            fixedResizeSize: nil,
            fixedCropAnchor: .center,
            outputFormat: .png,
            optimizer: optimizer,
            outputSuffix: "-pixelcrusher"
        )

        let compressionReport = try backend.processImage(
            at: sourceURL,
            options: compressionOptions,
            outputDirectory: sourceURL.deletingLastPathComponent()
        )

        let fileManager = FileManager.default
        let compressedPath = compressionReport.outputURL
        try? fileManager.removeItem(at: sourceURL)
        try fileManager.moveItem(at: compressedPath, to: sourceURL)

        let finalBytes = fileSize(at: sourceURL)
        let deltaPercent = originalInputBytes > 0
            ? ((Double(finalBytes - originalInputBytes) / Double(originalInputBytes)) * 100.0)
            : 0.0
        let summary = String(
            format: "background_removed=%@ + compressed, size=%lldB->%lldB (%+.1f%%)",
            modelVariant.summaryToken,
            originalInputBytes,
            finalBytes,
            deltaPercent
        )

        return BackgroundRemovalReport(
            sourceURL: sourceURL,
            outputURL: sourceURL,
            inputBytes: originalInputBytes,
            outputBytes: finalBytes,
            summary: summary
        )
    }
}

private struct RMBGStatusEnvelope: Decodable {
    let event: String
    let phase: String
    let message: String
}

private struct RMBGFinishedEnvelope: Decodable {
    let event: String
    let payload: RMBGFinishedPayload
}

private struct RMBGFinishedPayload: Decodable {
    let success: Bool
    let outputPath: String?
    let outputBytes: Int64?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case success
        case outputPath = "output_path"
        case outputBytes = "output_bytes"
        case error
    }
}
