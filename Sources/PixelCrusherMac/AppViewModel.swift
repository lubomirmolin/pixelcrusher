import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PixelCrusherMacCore

enum AutomationActionKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case compression
    case removeBackground
    case resize
    case convertFormat
    case trimTransparentBorders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compression:
            return "Compress Image"
        case .removeBackground:
            return "Remove Background"
        case .resize:
            return "Resize"
        case .convertFormat:
            return "Convert Format"
        case .trimTransparentBorders:
            return "Trim Transparent Edges"
        }
    }

    var subtitle: String {
        switch self {
        case .compression:
            return "Optimize size and quality"
        case .removeBackground:
            return "Isolate main subject"
        case .resize:
            return "Scale to target dimensions"
        case .convertFormat:
            return "Save in another format"
        case .trimTransparentBorders:
            return "Remove empty alpha bounds"
        }
    }

    var symbolName: String {
        switch self {
        case .compression:
            return "doc.zipper"
        case .removeBackground:
            return "wand.and.rays"
        case .resize:
            return "arrow.up.left.and.arrow.down.right"
        case .convertFormat:
            return "arrow.triangle.2.circlepath"
        case .trimTransparentBorders:
            return "crop"
        }
    }

    var canRemove: Bool {
        self != .compression
    }

    static let defaultChain: [AutomationActionKind] = [.compression]
}

@MainActor
final class AppViewModel: ObservableObject {
    private enum DefaultsKey {
        static let overwriteOriginal = "overwriteOriginal"
        static let autoTrimTransparentBorders = "autoTrimTransparentBorders"
        static let fixedCropEnabled = "fixedCropEnabled"
        static let fixedCropWidth = "fixedCropWidth"
        static let fixedCropHeight = "fixedCropHeight"
        static let fixedCropX = "fixedCropX"
        static let fixedCropY = "fixedCropY"
        static let cropAnchor = "cropAnchor"
        static let fixedResizeEnabled = "fixedResizeEnabled"
        static let fixedResizeWidth = "fixedResizeWidth"
        static let fixedResizeHeight = "fixedResizeHeight"
        static let autoResizeLongestSideEnabled = "autoResizeLongestSideEnabled"
        static let autoResizeLongestSide = "autoResizeLongestSide"
        static let autoConvertOutputFormat = "autoConvertOutputFormat"
        static let automationActionOrder = "automationActionOrder"
        static let backgroundRemovalModel = "backgroundRemovalModel"

        static let jpegQualityPercent = "jpegQualityPercent"

        static let pngLossyEnabled = "pngLossyEnabled"
        static let pngLossyQualityMin = "pngLossyQualityMin"
        static let pngLossyQualityMax = "pngLossyQualityMax"
        static let pngQuantSpeed = "pngQuantSpeed"
        static let pngUsePNGCrush = "pngUsePNGCrush"
        static let pngUseZopfli = "pngUseZopfli"
        static let pngUsePNGOUT = "pngUsePNGOUT"

        static let svgMultipass = "svgMultipass"

        static let gifOptimizationLevel = "gifOptimizationLevel"
        static let gifLossyLevel = "gifLossyLevel"
    }

    private let defaults: UserDefaults
    private let backendClient: PixelCrusherBackendClient
    private let processor: ImageProcessor
    private let backgroundRemovalClient: BackgroundRemovalClient
    nonisolated static let supportedFormatsLabel = SupportedAssetFormats.imageFormatsLabel
    nonisolated static let supportedImageUTTypes: [UTType] = [
        .png,
        .jpeg,
        .gif,
        UTType(filenameExtension: "svg"),
        UTType(filenameExtension: "webp")
    ].compactMap { $0 }
    nonisolated static let supportedImageTypeIdentifiers: [String] = supportedImageUTTypes.map(\.identifier)
    nonisolated static let folderTypeIdentifiers: [String] = [UTType.folder.identifier]

    @Published var overwriteOriginal: Bool {
        didSet { defaults.set(overwriteOriginal, forKey: DefaultsKey.overwriteOriginal) }
    }

    @Published var autoTrimTransparentBorders: Bool {
        didSet { defaults.set(autoTrimTransparentBorders, forKey: DefaultsKey.autoTrimTransparentBorders) }
    }

    @Published var fixedCropEnabled: Bool {
        didSet { defaults.set(fixedCropEnabled, forKey: DefaultsKey.fixedCropEnabled) }
    }

    @Published var fixedCropWidth: String {
        didSet { defaults.set(fixedCropWidth, forKey: DefaultsKey.fixedCropWidth) }
    }

    @Published var fixedCropHeight: String {
        didSet { defaults.set(fixedCropHeight, forKey: DefaultsKey.fixedCropHeight) }
    }

    @Published var fixedCropX: String {
        didSet { defaults.set(fixedCropX, forKey: DefaultsKey.fixedCropX) }
    }

    @Published var fixedCropY: String {
        didSet { defaults.set(fixedCropY, forKey: DefaultsKey.fixedCropY) }
    }

    @Published var cropAnchor: CropAnchor {
        didSet { defaults.set(cropAnchor.rawValue, forKey: DefaultsKey.cropAnchor) }
    }

    @Published var fixedResizeEnabled: Bool {
        didSet { defaults.set(fixedResizeEnabled, forKey: DefaultsKey.fixedResizeEnabled) }
    }

    @Published var fixedResizeWidth: String {
        didSet { defaults.set(fixedResizeWidth, forKey: DefaultsKey.fixedResizeWidth) }
    }

    @Published var fixedResizeHeight: String {
        didSet { defaults.set(fixedResizeHeight, forKey: DefaultsKey.fixedResizeHeight) }
    }

    @Published var autoResizeLongestSideEnabled: Bool {
        didSet { defaults.set(autoResizeLongestSideEnabled, forKey: DefaultsKey.autoResizeLongestSideEnabled) }
    }

    @Published var autoResizeLongestSide: String {
        didSet { defaults.set(autoResizeLongestSide, forKey: DefaultsKey.autoResizeLongestSide) }
    }

    @Published var autoConvertOutputFormat: OutputImageFormat? {
        didSet { defaults.set(autoConvertOutputFormat?.rawValue, forKey: DefaultsKey.autoConvertOutputFormat) }
    }

    @Published var automationActions: [AutomationActionKind] {
        didSet { persistAutomationActions() }
    }

    @Published var selectedBackgroundRemovalModel: BackgroundRemovalModelVariant {
        didSet { defaults.set(selectedBackgroundRemovalModel.rawValue, forKey: DefaultsKey.backgroundRemovalModel) }
    }

    @Published var jpegQualityPercent: Double {
        didSet { defaults.set(jpegQualityPercent, forKey: DefaultsKey.jpegQualityPercent) }
    }

    @Published var pngLossyEnabled: Bool {
        didSet { defaults.set(pngLossyEnabled, forKey: DefaultsKey.pngLossyEnabled) }
    }

    @Published var pngLossyQualityMin: Double {
        didSet { defaults.set(pngLossyQualityMin, forKey: DefaultsKey.pngLossyQualityMin) }
    }

    @Published var pngLossyQualityMax: Double {
        didSet { defaults.set(pngLossyQualityMax, forKey: DefaultsKey.pngLossyQualityMax) }
    }

    @Published var pngQuantSpeed: Double {
        didSet { defaults.set(pngQuantSpeed, forKey: DefaultsKey.pngQuantSpeed) }
    }

    @Published var pngUsePNGCrush: Bool {
        didSet { defaults.set(pngUsePNGCrush, forKey: DefaultsKey.pngUsePNGCrush) }
    }

    @Published var pngUseZopfli: Bool {
        didSet { defaults.set(pngUseZopfli, forKey: DefaultsKey.pngUseZopfli) }
    }

    @Published var pngUsePNGOUT: Bool {
        didSet { defaults.set(pngUsePNGOUT, forKey: DefaultsKey.pngUsePNGOUT) }
    }

    @Published var svgMultipass: Bool {
        didSet { defaults.set(svgMultipass, forKey: DefaultsKey.svgMultipass) }
    }

    @Published var gifOptimizationLevel: Double {
        didSet { defaults.set(gifOptimizationLevel, forKey: DefaultsKey.gifOptimizationLevel) }
    }

    @Published var gifLossyLevel: Double {
        didSet { defaults.set(gifLossyLevel, forKey: DefaultsKey.gifLossyLevel) }
    }

    @Published var isDropTargeted = false
    @Published private(set) var results: [ProcessingResult] = []
    @Published private(set) var folderRoots: [URL] = []
    @Published private(set) var latestFolderDropSession: FolderDropSession?

    @Published private(set) var pendingCount = 0
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var activeItemID: UUID?
    @Published private(set) var activeItemName: String?
    @Published private(set) var isQueueRunning = false
    @Published private(set) var toolStatuses: [OptimizerToolStatus] = []
    @Published private(set) var isBackgroundRemovalBusy = false

    private var queueStateMachine = ProcessingQueueStateMachine()
    private var resultIndexByID: [UUID: Int] = [:]
    private var optionsOverrideByID: [UUID: ImageProcessingOptions] = [:]
    private var outputDirectoryOverrideByID: [UUID: URL] = [:]
    private var automationActionsByID: [UUID: [AutomationActionKind]] = [:]
    private var queueWorkerTask: Task<Void, Never>?
    private var currentJobTasks: [UUID: Task<ImageProcessingReport, Error>] = [:]
    private var stopAfterCurrent = false

    private enum JobCompletionOutcome: Sendable {
        case success(ImageProcessingReport)
        case cancelled
        case failure(String)
    }

    var overallProgress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    init(
        defaults: UserDefaults = .standard,
        backendClient: PixelCrusherBackendClient = PixelCrusherBackendClient()
    ) {
        self.defaults = defaults
        self.backendClient = backendClient
        self.processor = ImageProcessor(backend: backendClient)
        self.backgroundRemovalClient = BackgroundRemovalClient(
            environment: ProcessInfo.processInfo.environment,
            bundledToolsDirectory: OptimizerToolDetector.defaultBundledToolsDirectory(bundle: .main)
        )

        overwriteOriginal = defaults.object(forKey: DefaultsKey.overwriteOriginal) as? Bool ?? false
        autoTrimTransparentBorders = defaults.object(forKey: DefaultsKey.autoTrimTransparentBorders) as? Bool ?? true
        fixedCropEnabled = defaults.object(forKey: DefaultsKey.fixedCropEnabled) as? Bool ?? false
        fixedCropWidth = defaults.string(forKey: DefaultsKey.fixedCropWidth) ?? "1024"
        fixedCropHeight = defaults.string(forKey: DefaultsKey.fixedCropHeight) ?? "1024"
        fixedCropX = defaults.string(forKey: DefaultsKey.fixedCropX) ?? "0"
        fixedCropY = defaults.string(forKey: DefaultsKey.fixedCropY) ?? "0"

        if let rawAnchor = defaults.string(forKey: DefaultsKey.cropAnchor),
           let anchor = CropAnchor(rawValue: rawAnchor) {
            cropAnchor = anchor
        } else {
            cropAnchor = .center
        }
        let persistedFixedResizeEnabled = defaults.object(forKey: DefaultsKey.fixedResizeEnabled) as? Bool ?? false
        fixedResizeEnabled = persistedFixedResizeEnabled
        fixedResizeWidth = defaults.string(forKey: DefaultsKey.fixedResizeWidth) ?? ""
        fixedResizeHeight = defaults.string(forKey: DefaultsKey.fixedResizeHeight) ?? ""
        autoResizeLongestSideEnabled = defaults.object(forKey: DefaultsKey.autoResizeLongestSideEnabled) as? Bool ?? false
        autoResizeLongestSide = defaults.string(forKey: DefaultsKey.autoResizeLongestSide) ?? "1024"
        if let persistedFormat = defaults.string(forKey: DefaultsKey.autoConvertOutputFormat) {
            autoConvertOutputFormat = OutputImageFormat(rawValue: persistedFormat)
        } else {
            autoConvertOutputFormat = nil
        }
        automationActions = Self.persistedAutomationActions(defaults: defaults)
        if let persistedBackgroundModel = defaults.string(forKey: DefaultsKey.backgroundRemovalModel),
           let modelVariant = BackgroundRemovalModelVariant(rawValue: persistedBackgroundModel) {
            selectedBackgroundRemovalModel = modelVariant
        } else {
            selectedBackgroundRemovalModel = .fast
        }

        jpegQualityPercent = defaults.object(forKey: DefaultsKey.jpegQualityPercent) as? Double ?? 82

        pngLossyEnabled = defaults.object(forKey: DefaultsKey.pngLossyEnabled) as? Bool ?? false
        pngLossyQualityMin = defaults.object(forKey: DefaultsKey.pngLossyQualityMin) as? Double ?? 65
        pngLossyQualityMax = defaults.object(forKey: DefaultsKey.pngLossyQualityMax) as? Double ?? 85
        pngQuantSpeed = defaults.object(forKey: DefaultsKey.pngQuantSpeed) as? Double ?? 3
        pngUsePNGCrush = defaults.object(forKey: DefaultsKey.pngUsePNGCrush) as? Bool ?? true
        pngUseZopfli = defaults.object(forKey: DefaultsKey.pngUseZopfli) as? Bool ?? true
        pngUsePNGOUT = defaults.object(forKey: DefaultsKey.pngUsePNGOUT) as? Bool ?? false

        svgMultipass = defaults.object(forKey: DefaultsKey.svgMultipass) as? Bool ?? true

        gifOptimizationLevel = defaults.object(forKey: DefaultsKey.gifOptimizationLevel) as? Double ?? 3
        gifLossyLevel = defaults.object(forKey: DefaultsKey.gifLossyLevel) as? Double ?? 0

        if persistedFixedResizeEnabled {
            // Resize is applied per-image from the results list; clear legacy global state.
            fixedResizeEnabled = false
        }

        refreshToolAvailability()
    }

    func backgroundRemovalStatuses() -> [BackgroundRemovalModelStatus] {
        backgroundRemovalClient.statuses()
    }

    var availableAutomationActions: [AutomationActionKind] {
        AutomationActionKind.allCases.filter { action in
            action != .compression && !automationActions.contains(action)
        }
    }

    func addAutomationAction(_ action: AutomationActionKind) {
        guard action != .compression, !automationActions.contains(action) else {
            return
        }
        automationActions.append(action)
    }

    func removeAutomationAction(_ action: AutomationActionKind) {
        guard action.canRemove else {
            return
        }
        automationActions.removeAll { $0 == action }
        ensureCompressionAction()
    }

    func moveAutomationAction(_ action: AutomationActionKind, direction: Int) {
        guard let sourceIndex = automationActions.firstIndex(of: action) else {
            return
        }

        let targetIndex = sourceIndex + direction
        guard automationActions.indices.contains(targetIndex) else {
            return
        }

        automationActions.swapAt(sourceIndex, targetIndex)
        ensureCompressionAction()
    }

    func downloadBackgroundRemovalModel(
        _ modelVariant: BackgroundRemovalModelVariant,
        progressHandler: @escaping @Sendable (BackgroundRemovalProgressUpdate) -> Void
    ) async throws {
        guard !isBackgroundRemovalBusy else {
            throw BackgroundRemovalError.runtimeFailed("Background removal is already running.")
        }

        isBackgroundRemovalBusy = true
        defer { isBackgroundRemovalBusy = false }

        let client = backgroundRemovalClient
        _ = try await Task.detached(priority: .userInitiated) {
            try await client.downloadModel(
                modelVariant,
                progressHandler: progressHandler
            )
        }.value
    }

    func supportsBackgroundRemoval(for sourceURL: URL) -> Bool {
        backgroundRemovalClient.supportsInputFile(sourceURL)
    }

    func removeBackground(
        from sourceURL: URL,
        modelVariant: BackgroundRemovalModelVariant,
        focusRect: CGRect? = nil,
        progressHandler: @escaping @Sendable (BackgroundRemovalProgressUpdate) -> Void
    ) async throws -> ProcessingResult {
        guard !isBackgroundRemovalBusy else {
            throw BackgroundRemovalError.runtimeFailed("Background removal is already running.")
        }

        isBackgroundRemovalBusy = true
        defer { isBackgroundRemovalBusy = false }

        let client = backgroundRemovalClient
        let optimizer = currentOptions(enabledActions: [.compression]).optimizer
        let report = try await Task.detached(priority: .userInitiated) {
            try await client.removeBackground(
                from: sourceURL,
                modelVariant: modelVariant,
                focusRect: focusRect,
                optimizer: optimizer,
                progressHandler: progressHandler
            )
        }.value

        let derivedResult = ProcessingResult(
            id: UUID(),
            inputURL: report.sourceURL,
            enqueuedOrder: nextDerivedResultOrder(),
            outputURL: report.outputURL,
            inputBytes: report.inputBytes,
            outputBytes: report.outputBytes,
            success: true,
            state: .done,
            statusText: "Background removed",
            detailText: report.summary,
            warning: nil
        )

        results.append(derivedResult)
        resultIndexByID[derivedResult.id] = results.count - 1
        return derivedResult
    }

    func applyCompressionProfile(_ profile: CompressionProfile) {
        let settings = profile.settings
        jpegQualityPercent = settings.jpegQualityPercent
        pngLossyEnabled = settings.pngLossyEnabled
        pngLossyQualityMin = settings.pngLossyQualityMin
        pngLossyQualityMax = settings.pngLossyQualityMax
        pngUsePNGCrush = settings.pngUsePNGCrush
        pngUseZopfli = settings.pngUseZopfli
    }

    func refreshToolAvailability() {
        let backend = backendClient
        Task {
            let statuses = await Task.detached(priority: .utility) {
                if let detected = try? backend.detectTools() {
                    return detected
                }
                return OptimizerToolDetector().detect().statuses
            }.value

            toolStatuses = statuses
        }
    }

    var bundledRequiredReadyCount: Int {
        toolStatuses.filter { $0.tool.isRequiredBundledTool && $0.source == .bundled }.count
    }

    var bundledRequiredTotalCount: Int {
        OptimizerTool.requiredBundledTools.count
    }

    var requiredAvailableCount: Int {
        toolStatuses.filter { $0.tool.isRequiredBundledTool && $0.isAvailable }.count
    }

    var bundledDiagnosticsLine: String {
        if bundledRequiredReadyCount == bundledRequiredTotalCount {
            return "Bundled optimizers ready (\(bundledRequiredReadyCount)/\(bundledRequiredTotalCount))"
        }

        return "Bundled optimizers \(bundledRequiredReadyCount)/\(bundledRequiredTotalCount) · Available with host fallback \(requiredAvailableCount)/\(bundledRequiredTotalCount)"
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        let fileURLType = UTType.fileURL.identifier
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(fileURLType) }
        guard !matching.isEmpty else { return false }

        for provider in matching {
            provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { [weak self] item, error in
                if let error {
                    Self.enqueueDropFailure(on: self, message: "Drop error: \(error.localizedDescription)")
                    return
                }

                guard let droppedURL = Self.extractFileURL(from: item) else {
                    Self.enqueueDropFailure(on: self, message: "Could not decode dropped file URL")
                    return
                }

                Task { @MainActor [weak self] in
                    self?.enqueueInput(url: droppedURL)
                }
            }
        }

        return true
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.supportedImageUTTypes

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            enqueueInput(url: url)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folder = panel.url else { return }
        enqueueInput(url: folder)
    }

    func enqueueExternal(urls: [URL], optionsOverride: ImageProcessingOptions? = nil) {
        for url in urls {
            enqueueInput(url: url, optionsOverride: optionsOverride)
        }
    }

    func enqueueCroppedImage(sourceURL: URL, width: Int, height: Int, x: Int, y: Int) {
        guard let cropSize = try? CropSize(width: width, height: height) else {
            return
        }

        let cropOrigin = try? CropOrigin(x: max(0, x), y: max(0, y))
        let options = currentOptions(manualCrop: (size: cropSize, origin: cropOrigin), enabledActions: [.compression])
        enqueueExternal(urls: [sourceURL], optionsOverride: options)
    }

    func enqueueResizedImage(sourceURL: URL, width: Int, height: Int) {
        guard let resizeSize = try? CropSize(width: width, height: height) else {
            return
        }

        var options = currentOptions(enabledActions: [.compression])
        options.fixedResizeSize = resizeSize
        enqueueExternal(urls: [sourceURL], optionsOverride: options)
    }

    func availableConversionFormats(for sourceURL: URL) -> [OutputImageFormat] {
        if sourceURL.pathExtension.caseInsensitiveCompare("svg") == .orderedSame {
            return OutputImageFormat.allCases
        }

        guard let sourceFormat = OutputImageFormat.fromPathExtension(sourceURL.pathExtension) else {
            return []
        }

        return OutputImageFormat.allCases.filter { $0 != sourceFormat }
    }

    func enqueueConvertedImage(sourceURL: URL, to targetFormat: OutputImageFormat) {
        enqueueConvertedImage(sourceURL: sourceURL, to: targetFormat, rasterSize: nil)
    }

    func enqueueConvertedImage(sourceURL: URL, to targetFormat: OutputImageFormat, rasterSize: CropSize?) {
        if let sourceFormat = OutputImageFormat.fromPathExtension(sourceURL.pathExtension),
           sourceFormat == targetFormat {
            return
        }

        var options = currentOptions(enabledActions: [.compression])
        options.outputFormat = targetFormat
        if let rasterSize {
            options.fixedResizeSize = rasterSize
        }
        enqueueExternal(urls: [sourceURL], optionsOverride: options)
    }

    func punchCropTransform(for id: UUID) -> PunchCropTransform? {
        guard let options = optionsOverrideByID[id],
              let size = options.fixedCropSize else {
            return nil
        }

        return PunchCropTransform(
            width: size.width,
            height: size.height,
            x: options.fixedCropOrigin?.x,
            y: options.fixedCropOrigin?.y,
            anchor: options.fixedCropAnchor
        )
    }

    func cancelQueuedJobs() {
        let cancelledIDs = queueStateMachine.cancelQueuedJobs()

        for id in cancelledIDs {
            optionsOverrideByID[id] = nil
            outputDirectoryOverrideByID[id] = nil
            automationActionsByID[id] = nil
            guard let index = resultIndexByID[id] else { continue }
            results[index].success = false
            results[index].state = .failed
            results[index].statusText = "Cancelled before processing"
            results[index].detailText = nil
            results[index].warning = nil
        }

        refreshQueueProgress()
    }

    func cancelAllJobs() {
        stopAfterCurrent = true
        cancelQueuedJobs()
        for (id, task) in currentJobTasks {
            if let index = resultIndexByID[id],
               !results[index].state.isTerminal,
               !results[index].statusText.contains("(cancel requested)") {
                results[index].statusText += " (cancel requested)"
            }
            task.cancel()
        }
    }

    func openOutputFolder(for result: ProcessingResult) {
        guard let output = result.outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([output])
    }

    func openLatestOutputFolder() {
        guard let output = results.reversed().first(where: { $0.outputURL != nil })?.outputURL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([output])
    }

    private func enqueueInput(url: URL, optionsOverride: ImageProcessingOptions? = nil) {
        let automationActionsOverride = optionsOverride == nil ? Self.normalizedAutomationActions(automationActions) : [.compression]
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            appendImmediateFailure(inputURL: url, message: "Input path does not exist")
            return
        }

        if isDirectory.boolValue {
            let folderSession = FolderDropSession(
                id: UUID(),
                folderURL: url
            )
            latestFolderDropSession = folderSession

            if !folderRoots.contains(url) {
                folderRoots.append(url)
            }

            let folderURL = url
            let outputRoot = Self.folderOutputRoot(for: folderURL)
            Task {
                let files = await Task.detached(priority: .userInitiated) {
                    Self.collectSupportedFiles(in: folderURL)
                }.value
                for file in files {
                    let outputDirectory = Self.folderOutputDirectory(
                        for: file,
                        folderRoot: folderURL,
                        outputRoot: outputRoot
                    )
                    enqueueFile(
                        file,
                        optionsOverride: optionsOverride,
                        outputDirectoryOverride: outputDirectory,
                        automationActionsOverride: automationActionsOverride
                    )
                }
            }
            return
        }

        guard Self.isSupportedFile(url) else {
            return
        }

        enqueueFile(url, optionsOverride: optionsOverride, automationActionsOverride: automationActionsOverride)
    }

    private func enqueueFile(
        _ fileURL: URL,
        optionsOverride: ImageProcessingOptions? = nil,
        outputDirectoryOverride: URL? = nil,
        automationActionsOverride: [AutomationActionKind]
    ) {
        let queuedItem = queueStateMachine.enqueue(inputURL: fileURL)
        if let optionsOverride {
            optionsOverrideByID[queuedItem.id] = optionsOverride
        }
        if let outputDirectoryOverride {
            outputDirectoryOverrideByID[queuedItem.id] = outputDirectoryOverride
        }
        automationActionsByID[queuedItem.id] = Self.normalizedAutomationActions(automationActionsOverride)
        let result = ProcessingResult(
            id: queuedItem.id,
            inputURL: fileURL,
            enqueuedOrder: queuedItem.enqueuedOrder,
            outputURL: nil,
            inputBytes: fileSize(at: fileURL),
            outputBytes: nil,
            success: false,
            state: .queued,
            statusText: ProcessingStatusTextFormatter.text(for: .queued),
            detailText: nil,
            warning: nil
        )

        results.append(result)
        resultIndexByID[result.id] = results.count - 1

        refreshQueueProgress()
        startQueueWorkerIfNeeded()
    }

    private func nextDerivedResultOrder() -> Int {
        (results.map(\.enqueuedOrder).max() ?? 0) + 1
    }

    private func appendImmediateFailure(inputURL: URL, message: String) {
        let result = ProcessingResult(
            id: UUID(),
            inputURL: inputURL,
            enqueuedOrder: 0,
            outputURL: nil,
            inputBytes: fileSize(at: inputURL),
            outputBytes: nil,
            success: false,
            state: .failed,
            statusText: message,
            detailText: nil,
            warning: nil
        )
        results.append(result)
        refreshQueueProgress()
    }

    func consumeLatestFolderDropSession() -> FolderDropSession? {
        let session = latestFolderDropSession
        latestFolderDropSession = nil
        return session
    }

    private func startQueueWorkerIfNeeded() {
        guard queueWorkerTask == nil else { return }

        queueWorkerTask = Task { [weak self] in
            await self?.runQueueWorker()
        }
    }

    private func runQueueWorker() async {
        defer {
            queueWorkerTask = nil
            currentJobTasks.removeAll()
            stopAfterCurrent = false
            refreshQueueProgress()
        }

        while true {
            if !stopAfterCurrent {
                scheduleQueuedJobsIfPossible()
            }

            if currentJobTasks.isEmpty {
                if queueStateMachine.progress.pendingCount == 0 {
                    break
                }
                await Task.yield()
                continue
            }

            guard let completion = await waitForNextCompletion() else {
                continue
            }

            currentJobTasks[completion.id] = nil

            switch completion.outcome {
            case .success(let report):
                completeJob(id: completion.id, report: report)
            case .cancelled:
                failJob(id: completion.id, message: "Cancelled")
            case .failure(let message):
                failJob(id: completion.id, message: message)
            }

            refreshQueueProgress()

            if stopAfterCurrent && currentJobTasks.isEmpty {
                stopAfterCurrent = false
                break
            }
        }
    }

    private func scheduleQueuedJobsIfPossible() {
        while currentJobTasks.count < preferredParallelism,
              let nextItem = queueStateMachine.dequeueNextQueued() {
            apply(
                update: ProcessingStatusUpdate(
                    state: .preparing,
                    message: ProcessingStatusTextFormatter.text(for: .preparing)
                ),
                for: nextItem.id
            )

            guard let index = resultIndexByID[nextItem.id] else {
                continue
            }

            let inputURL = results[index].inputURL
            let actions = automationActionsByID[nextItem.id] ?? Self.normalizedAutomationActions(automationActions)
            let options = optionsOverrideByID[nextItem.id] ?? currentOptions(enabledActions: actions)
            let outputDirectory = outputDirectoryOverrideByID[nextItem.id]
            let processor = self.processor
            let backgroundRemovalClient = self.backgroundRemovalClient
            let backgroundRemovalModel = selectedBackgroundRemovalModel

            let statusBridge: @Sendable (ProcessingStatusUpdate) -> Void = { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.apply(update: update, for: nextItem.id)
                }
            }

            currentJobTasks[nextItem.id] = Task.detached(priority: .userInitiated) {
                try await Self.processAutomatedImage(
                    at: inputURL,
                    actions: actions,
                    options: options,
                    outputDirectory: outputDirectory,
                    processor: processor,
                    backgroundRemovalClient: backgroundRemovalClient,
                    backgroundRemovalModel: backgroundRemovalModel,
                    statusHandler: statusBridge
                )
            }
        }
    }

    private var preferredParallelism: Int {
        let options = currentOptions(enabledActions: AutomationActionKind.allCases)

        if options.optimizer.pngUseZopfli || options.optimizer.pngUsePNGOUT {
            return 1
        }

        let cores = ProcessInfo.processInfo.activeProcessorCount
        let cpuBound = max(1, min(4, cores))
        let preferred = max(2, min(4, cores / 2))
        return min(cpuBound, preferred)
    }

    nonisolated private static func processAutomatedImage(
        at inputURL: URL,
        actions requestedActions: [AutomationActionKind],
        options baseOptions: ImageProcessingOptions,
        outputDirectory: URL?,
        processor: ImageProcessor,
        backgroundRemovalClient: BackgroundRemovalClient,
        backgroundRemovalModel: BackgroundRemovalModelVariant,
        statusHandler: @escaping @Sendable (ProcessingStatusUpdate) -> Void
    ) async throws -> ImageProcessingReport {
        let actions = normalizedAutomationActions(requestedActions)
        guard actions.contains(.removeBackground) else {
            return try processor.processImage(
                at: inputURL,
                options: baseOptions,
                outputDirectory: outputDirectory,
                statusHandler: statusHandler
            )
        }

        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("PixelCrusherAutomation-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let originalInputBytes = byteSize(at: inputURL)
        let finalOutputDirectory = outputDirectory ?? inputURL.deletingLastPathComponent()
        var currentURL = inputURL
        var lastReport: ImageProcessingReport?
        var pendingBackendActions: [AutomationActionKind] = []

        func removeIntermediateIfNeeded(_ url: URL) {
            guard url != inputURL,
                  url.path.hasPrefix(temporaryDirectory.path) else {
                return
            }
            try? fileManager.removeItem(at: url)
        }

        func reportForAutomation(
            outputURL: URL,
            outputBytes: Int64,
            pipelineName: String,
            selectedTools: [String],
            warning: String?,
            summary: String
        ) -> ImageProcessingReport {
            let deltaPercent = originalInputBytes > 0
                ? ((Double(outputBytes - originalInputBytes) / Double(originalInputBytes)) * 100.0)
                : 0.0
            let actionSummary = actions.map(\.title).joined(separator: " > ")
            return ImageProcessingReport(
                inputURL: inputURL,
                outputURL: outputURL,
                pipelineName: pipelineName,
                selectedTools: selectedTools,
                inputBytes: originalInputBytes,
                outputBytes: outputBytes,
                warning: warning,
                summary: String(
                    format: "automation=%@, size=%lldB->%lldB (%+.1f%%), %@",
                    actionSummary,
                    originalInputBytes,
                    outputBytes,
                    deltaPercent,
                    summary
                )
            )
        }

        func flushBackendActions(isFinal: Bool, stepIndex: Int) throws {
            guard !pendingBackendActions.isEmpty else {
                return
            }

            var segmentOptions = backendOptions(from: baseOptions, enabledActions: pendingBackendActions)
            segmentOptions.outputSuffix = isFinal ? baseOptions.outputSuffix : "-automation-\(stepIndex)"
            let destinationDirectory = isFinal ? finalOutputDirectory : temporaryDirectory
            let previousURL = currentURL
            let report = try processor.processImage(
                at: currentURL,
                options: segmentOptions,
                outputDirectory: destinationDirectory,
                statusHandler: statusHandler
            )
            currentURL = report.outputURL
            removeIntermediateIfNeeded(previousURL)
            pendingBackendActions.removeAll()
            lastReport = reportForAutomation(
                outputURL: report.outputURL,
                outputBytes: report.outputBytes,
                pipelineName: report.pipelineName,
                selectedTools: report.selectedTools,
                warning: report.warning,
                summary: report.summary
            )
        }

        for (index, action) in actions.enumerated() {
            if action == .removeBackground {
                try flushBackendActions(isFinal: false, stepIndex: index)
                let previousURL = currentURL
                let hasRemainingActions = actions.dropFirst(index + 1).contains { $0 != .removeBackground }
                let destinationDirectory = hasRemainingActions ? temporaryDirectory : finalOutputDirectory

                let backgroundReport = try await backgroundRemovalClient.removeBackground(
                    from: currentURL,
                    modelVariant: backgroundRemovalModel,
                    outputDirectory: destinationDirectory
                ) { update in
                    statusHandler(ProcessingStatusUpdate(state: .optimizing, message: update.message))
                }

                currentURL = backgroundReport.outputURL
                removeIntermediateIfNeeded(previousURL)
                lastReport = reportForAutomation(
                    outputURL: backgroundReport.outputURL,
                    outputBytes: backgroundReport.outputBytes,
                    pipelineName: "background-removal",
                    selectedTools: [backgroundRemovalModel.displayName],
                    warning: nil,
                    summary: backgroundReport.summary
                )
            } else {
                pendingBackendActions.append(action)
            }
        }

        try flushBackendActions(isFinal: true, stepIndex: actions.count)

        guard let lastReport else {
            throw ImageProcessingError.backendProtocolError("Automation chain did not produce an output")
        }
        return lastReport
    }

    nonisolated private static func backendOptions(
        from baseOptions: ImageProcessingOptions,
        enabledActions: [AutomationActionKind]
    ) -> ImageProcessingOptions {
        let actionSet = Set(enabledActions)
        var options = baseOptions
        if !actionSet.contains(.resize) {
            options.fixedResizeSize = nil
            options.maxResizeLongestSide = nil
        }
        if !actionSet.contains(.convertFormat) {
            options.outputFormat = nil
        }
        if !actionSet.contains(.trimTransparentBorders) {
            options.autoTrimTransparentBorders = false
        }
        return options
    }

    private func waitForNextCompletion() async -> (id: UUID, outcome: JobCompletionOutcome)? {
        guard !currentJobTasks.isEmpty else {
            return nil
        }

        return await withTaskGroup(of: (UUID, JobCompletionOutcome).self) { group in
            for (id, task) in currentJobTasks {
                group.addTask {
                    do {
                        let report = try await task.value
                        return (id, .success(report))
                    } catch is CancellationError {
                        return (id, .cancelled)
                    } catch {
                        return (id, .failure(error.localizedDescription))
                    }
                }
            }

            let completion = await group.next()
            group.cancelAll()
            return completion
        }
    }

    private func completeJob(id: UUID, report: ImageProcessingReport) {
        try? queueStateMachine.transition(id: id, to: .done)
        optionsOverrideByID[id] = nil
        outputDirectoryOverrideByID[id] = nil
        automationActionsByID[id] = nil

        guard let index = resultIndexByID[id] else { return }
        results[index].outputURL = report.outputURL
        results[index].inputBytes = report.inputBytes
        results[index].outputBytes = report.outputBytes
        results[index].success = true
        results[index].state = .done
        results[index].statusText = "Done"
        results[index].detailText = report.summary
        results[index].warning = report.warning
    }

    private func failJob(id: UUID, message: String) {
        try? queueStateMachine.transition(id: id, to: .failed)
        optionsOverrideByID[id] = nil
        outputDirectoryOverrideByID[id] = nil
        automationActionsByID[id] = nil

        guard let index = resultIndexByID[id] else { return }
        results[index].success = false
        results[index].state = .failed
        results[index].statusText = message
        results[index].detailText = nil
        results[index].warning = nil
    }

    private func apply(update: ProcessingStatusUpdate, for id: UUID) {
        if !update.state.isTerminal {
            try? queueStateMachine.transition(id: id, to: update.state)
        }

        guard let index = resultIndexByID[id], !results[index].state.isTerminal else {
            refreshQueueProgress()
            return
        }

        results[index].state = update.state
        results[index].statusText = update.message
        refreshQueueProgress()
    }

    private func refreshQueueProgress() {
        let progress = queueStateMachine.progress
        pendingCount = progress.pendingCount
        completedCount = progress.completedCount
        totalCount = progress.totalCount
        isQueueRunning = progress.isRunning
        activeItemID = progress.activeItemID

        if let activeID = progress.activeItemID,
           let index = resultIndexByID[activeID] {
            activeItemName = results[index].inputURL.lastPathComponent
        } else {
            activeItemName = nil
        }
    }

    private func fileSize(at url: URL) -> Int64? {
        guard url.isFileURL else {
            return nil
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }

        return size.int64Value
    }

    private func persistAutomationActions() {
        let normalized = Self.normalizedAutomationActions(automationActions)
        guard normalized == automationActions else {
            automationActions = normalized
            return
        }

        let rawActions = normalized.map(\.rawValue)
        defaults.set(rawActions, forKey: DefaultsKey.automationActionOrder)
    }

    private func ensureCompressionAction() {
        let normalized = Self.normalizedAutomationActions(automationActions)
        guard normalized != automationActions else {
            return
        }
        automationActions = normalized
    }

    private static func persistedAutomationActions(defaults: UserDefaults) -> [AutomationActionKind] {
        guard let rawActions = defaults.stringArray(forKey: DefaultsKey.automationActionOrder) else {
            return AutomationActionKind.defaultChain
        }

        let actions = rawActions.compactMap(AutomationActionKind.init(rawValue:))
        return normalizedAutomationActions(actions)
    }

    nonisolated private static func normalizedAutomationActions(_ actions: [AutomationActionKind]) -> [AutomationActionKind] {
        var seen: Set<AutomationActionKind> = []
        var normalized = actions.filter { action in
            guard !seen.contains(action) else {
                return false
            }
            seen.insert(action)
            return true
        }

        if !normalized.contains(.compression) {
            normalized.insert(.compression, at: 0)
        }

        return normalized
    }

    nonisolated private static func byteSize(at url: URL) -> Int64 {
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }

        return size.int64Value
    }

    private func currentOptions(
        manualCrop: (size: CropSize, origin: CropOrigin?)? = nil,
        enabledActions: [AutomationActionKind]? = nil
    ) -> ImageProcessingOptions {
        let enabledActionSet = Set(enabledActions ?? Self.normalizedAutomationActions(automationActions))
        let fixedCropSize = manualCrop?.size
        let fixedCropOrigin = manualCrop?.origin

        let fixedResizeSize: CropSize?
        if enabledActionSet.contains(.resize),
           fixedResizeEnabled,
           let width = Int(fixedResizeWidth),
           let height = Int(fixedResizeHeight),
           width > 0,
           height > 0 {
            fixedResizeSize = try? CropSize(width: width, height: height)
        } else {
            fixedResizeSize = nil
        }

        let optimizer = OptimizerPreferences(
            jpegQualityPercent: Int(jpegQualityPercent.rounded()),
            pngLossyEnabled: pngLossyEnabled,
            pngLossyQualityMin: Int(pngLossyQualityMin.rounded()),
            pngLossyQualityMax: Int(pngLossyQualityMax.rounded()),
            pngQuantSpeed: Int(pngQuantSpeed.rounded()),
            pngUsePNGCrush: pngUsePNGCrush,
            pngUseZopfli: pngUseZopfli,
            pngUsePNGOUT: pngUsePNGOUT,
            svgMultipass: svgMultipass,
            gifOptimizationLevel: Int(gifOptimizationLevel.rounded()),
            gifLossyLevel: Int(gifLossyLevel.rounded())
        )

        // Manual crop should be authoritative; running transparent auto-trim first can
        // collapse the crop source bounds and make the selected crop appear ineffective.
        let shouldTrimTransparent = enabledActionSet.contains(.trimTransparentBorders)
            && autoTrimTransparentBorders
            && fixedCropSize == nil
        let maxResizeLongestSide: Int?
        if enabledActionSet.contains(.resize),
           autoResizeLongestSideEnabled,
           let value = Int(autoResizeLongestSide),
           value > 0 {
            maxResizeLongestSide = value
        } else {
            maxResizeLongestSide = nil
        }

        return ImageProcessingOptions(
            overwriteOriginal: overwriteOriginal,
            autoTrimTransparentBorders: shouldTrimTransparent,
            fixedCropSize: fixedCropSize,
            fixedCropOrigin: fixedCropOrigin,
            fixedResizeSize: fixedResizeSize,
            maxResizeLongestSide: maxResizeLongestSide,
            fixedCropAnchor: cropAnchor,
            outputFormat: enabledActionSet.contains(.convertFormat) ? autoConvertOutputFormat : nil,
            optimizer: optimizer,
            outputSuffix: "-pixelcrusher"
        )
    }

    nonisolated private static func enqueueDropFailure(on model: AppViewModel?, message: String) {
        Task { @MainActor [weak model] in
            model?.appendImmediateFailure(
                inputURL: URL(fileURLWithPath: "unknown"),
                message: message
            )
        }
    }

    nonisolated private static func collectSupportedFiles(in folderURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard Self.isSupportedFile(fileURL) else { continue }
            files.append(fileURL)
        }

        return files.sorted { $0.path < $1.path }
    }

    nonisolated private static func folderOutputRoot(for folderURL: URL) -> URL {
        let parent = folderURL.deletingLastPathComponent()
        return parent.appendingPathComponent("\(folderURL.lastPathComponent) pixelcrusher", isDirectory: true)
    }

    nonisolated private static func folderOutputDirectory(
        for fileURL: URL,
        folderRoot: URL,
        outputRoot: URL
    ) -> URL {
        let standardizedFolderRoot = folderRoot.standardizedFileURL.path
        let standardizedInputParent = fileURL.deletingLastPathComponent().standardizedFileURL.path

        if standardizedInputParent == standardizedFolderRoot {
            return outputRoot
        }

        let rootPrefix = standardizedFolderRoot.hasSuffix("/") ? standardizedFolderRoot : "\(standardizedFolderRoot)/"
        guard standardizedInputParent.hasPrefix(rootPrefix) else {
            return outputRoot
        }

        let relativeParent = String(standardizedInputParent.dropFirst(rootPrefix.count))
        guard !relativeParent.isEmpty else {
            return outputRoot
        }

        return outputRoot.appendingPathComponent(relativeParent, isDirectory: true)
    }

    nonisolated private static func isSupportedFile(_ url: URL) -> Bool {
        SupportedAssetFormats.isSupportedImageURL(url)
    }

    nonisolated private static func extractFileURL(from item: NSSecureCoding?) -> URL? {
        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8),
           let url = URL(string: string) {
            return url
        }

        if let url = item as? URL {
            return url
        }

        if let nsurl = item as? NSURL {
            return nsurl as URL
        }

        if let string = item as? String,
           let url = URL(string: string) {
            return url
        }

        return nil
    }
}
