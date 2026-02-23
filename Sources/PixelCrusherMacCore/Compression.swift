import Foundation

public enum OptimizerTool: String, Sendable, CaseIterable, Hashable {
    case cjpeg
    case pngquant
    case pngcrush
    case zopflipng
    case pngout
    case svgo
    case gifsicle

    public static let requiredBundledTools: [OptimizerTool] = [.cjpeg, .pngquant, .pngcrush, .svgo, .gifsicle]
    public static let optionalBundledTools: [OptimizerTool] = [.zopflipng, .pngout]

    public var isRequiredBundledTool: Bool {
        Self.requiredBundledTools.contains(self)
    }

    public var displayName: String {
        switch self {
        case .cjpeg:
            return "MozJPEG (cjpeg)"
        case .pngquant:
            return "pngquant"
        case .pngcrush:
            return "pngcrush"
        case .zopflipng:
            return "zopflipng"
        case .pngout:
            return "pngout"
        case .svgo:
            return "SVGO"
        case .gifsicle:
            return "gifsicle"
        }
    }

    public var preferredExecutableNames: [String] {
        switch self {
        case .cjpeg:
            return ["cjpeg", "mozjpeg"]
        case .pngquant:
            return ["pngquant"]
        case .pngcrush:
            return ["pngcrush"]
        case .zopflipng:
            return ["zopflipng"]
        case .pngout:
            return ["pngout"]
        case .svgo:
            return ["svgo"]
        case .gifsicle:
            return ["gifsicle"]
        }
    }

    public var environmentOverrideKey: String {
        "PIXELCRUSHER_\(rawValue.uppercased())_PATH"
    }
}

public enum OptimizerToolResolutionSource: String, Sendable, Equatable {
    case environmentOverride
    case bundled
    case hostPath
}

public struct OptimizerToolStatus: Sendable, Equatable {
    public let tool: OptimizerTool
    public let isAvailable: Bool
    public let resolvedPath: String?
    public let source: OptimizerToolResolutionSource?

    public init(tool: OptimizerTool, isAvailable: Bool, resolvedPath: String?, source: OptimizerToolResolutionSource?) {
        self.tool = tool
        self.isAvailable = isAvailable
        self.resolvedPath = resolvedPath
        self.source = source
    }
}

public struct OptimizerToolchain: Sendable, Equatable {
    private let executableByTool: [OptimizerTool: URL]
    private let sourceByTool: [OptimizerTool: OptimizerToolResolutionSource]

    public init(
        executableByTool: [OptimizerTool: URL],
        sourceByTool: [OptimizerTool: OptimizerToolResolutionSource] = [:]
    ) {
        self.executableByTool = executableByTool
        self.sourceByTool = sourceByTool
    }

    public static let empty = OptimizerToolchain(executableByTool: [:])

    public func executableURL(for tool: OptimizerTool) -> URL? {
        executableByTool[tool]
    }

    public func source(for tool: OptimizerTool) -> OptimizerToolResolutionSource? {
        sourceByTool[tool]
    }

    public func isAvailable(_ tool: OptimizerTool) -> Bool {
        executableByTool[tool] != nil
    }

    public var statuses: [OptimizerToolStatus] {
        OptimizerTool.allCases.map { tool in
            OptimizerToolStatus(
                tool: tool,
                isAvailable: isAvailable(tool),
                resolvedPath: executableByTool[tool]?.path,
                source: sourceByTool[tool]
            )
        }
    }
}

public struct OptimizerToolDetector: Sendable {
    public let environment: [String: String]
    public let searchPaths: [String]
    public let bundledToolsDirectory: URL?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledToolsDirectory: URL? = nil,
        bundle: Bundle = .main
    ) {
        self.environment = environment
        self.searchPaths = environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []

        if let envOverride = environment["PIXELCRUSHER_BUNDLED_TOOLS_DIR"], !envOverride.isEmpty {
            self.bundledToolsDirectory = URL(fileURLWithPath: envOverride)
        } else if let bundledToolsDirectory {
            self.bundledToolsDirectory = bundledToolsDirectory
        } else {
            self.bundledToolsDirectory = Self.defaultBundledToolsDirectory(bundle: bundle)
        }
    }

    public func detect() -> OptimizerToolchain {
        var resolved: [OptimizerTool: URL] = [:]
        var sourceByTool: [OptimizerTool: OptimizerToolResolutionSource] = [:]
        let fileManager = FileManager.default

        for tool in OptimizerTool.allCases {
            if let override = environment[tool.environmentOverrideKey], !override.isEmpty {
                let overrideURL = URL(fileURLWithPath: override)
                if fileManager.isExecutableFile(atPath: overrideURL.path) {
                    resolved[tool] = overrideURL
                    sourceByTool[tool] = .environmentOverride
                    continue
                }
            }

            if let bundled = findBundledExecutable(for: tool, fileManager: fileManager) {
                resolved[tool] = bundled
                sourceByTool[tool] = .bundled
                continue
            }

            for name in tool.preferredExecutableNames {
                if let path = findExecutable(named: name, fileManager: fileManager) {
                    resolved[tool] = URL(fileURLWithPath: path)
                    sourceByTool[tool] = .hostPath
                    break
                }
            }
        }

        return OptimizerToolchain(executableByTool: resolved, sourceByTool: sourceByTool)
    }

    public static func defaultBundledToolsDirectory(bundle: Bundle = .main) -> URL? {
        let fileManager = FileManager.default

        if let resourceURL = bundle.resourceURL {
            let bundled = resourceURL.appendingPathComponent("BundledTools", isDirectory: true)
            if fileManager.fileExists(atPath: bundled.path) {
                return bundled
            }
        }

        if let executablePath = bundle.executablePath {
            let executableURL = URL(fileURLWithPath: executablePath)
            let candidate = executableURL
                .deletingLastPathComponent()
                .appendingPathComponent("../Resources/BundledTools", isDirectory: true)
                .standardizedFileURL
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private func findBundledExecutable(for tool: OptimizerTool, fileManager: FileManager) -> URL? {
        guard let bundledToolsDirectory else {
            return nil
        }

        for name in tool.preferredExecutableNames {
            let candidate = bundledToolsDirectory
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent(name)

            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private func findExecutable(named name: String, fileManager: FileManager) -> String? {
        if name.hasPrefix("/") {
            return fileManager.isExecutableFile(atPath: name) ? name : nil
        }

        for base in searchPaths where !base.isEmpty {
            let candidate = URL(fileURLWithPath: base).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }
}

public struct OptimizerPreferences: Sendable, Equatable {
    public var jpegQualityPercent: Int

    public var pngLossyEnabled: Bool
    public var pngLossyQualityMin: Int
    public var pngLossyQualityMax: Int
    public var pngQuantSpeed: Int
    public var pngUsePNGCrush: Bool
    public var pngUseZopfli: Bool
    public var pngUsePNGOUT: Bool

    public var svgMultipass: Bool

    public var gifOptimizationLevel: Int
    public var gifLossyLevel: Int

    public init(
        jpegQualityPercent: Int = 82,
        pngLossyEnabled: Bool = false,
        pngLossyQualityMin: Int = 65,
        pngLossyQualityMax: Int = 85,
        pngQuantSpeed: Int = 3,
        pngUsePNGCrush: Bool = true,
        pngUseZopfli: Bool = true,
        pngUsePNGOUT: Bool = false,
        svgMultipass: Bool = true,
        gifOptimizationLevel: Int = 3,
        gifLossyLevel: Int = 0
    ) {
        self.jpegQualityPercent = max(1, min(100, jpegQualityPercent))
        self.pngLossyEnabled = pngLossyEnabled
        self.pngLossyQualityMin = max(0, min(100, pngLossyQualityMin))
        self.pngLossyQualityMax = max(0, min(100, pngLossyQualityMax))
        if self.pngLossyQualityMax < self.pngLossyQualityMin {
            swap(&self.pngLossyQualityMin, &self.pngLossyQualityMax)
        }
        self.pngQuantSpeed = max(1, min(11, pngQuantSpeed))
        self.pngUsePNGCrush = pngUsePNGCrush
        self.pngUseZopfli = pngUseZopfli
        self.pngUsePNGOUT = pngUsePNGOUT
        self.svgMultipass = svgMultipass
        self.gifOptimizationLevel = max(1, min(3, gifOptimizationLevel))
        self.gifLossyLevel = max(0, min(200, gifLossyLevel))
    }
}
