import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PixelCrusherMacCore
import Foundation

struct ProcessingResult: Identifiable {
    let id: UUID
    let inputURL: URL
    let enqueuedOrder: Int
    var outputURL: URL?
    var success: Bool
    var state: ProcessingItemState
    var statusText: String
    var detailText: String?
    var warning: String?

    var canOpenFolder: Bool {
        outputURL != nil
    }
}

enum LaunchMode {
    case ui
    case batch([URL])
}

struct CommandLineParser {
    static func parse(arguments: [String]) -> LaunchMode {
        let args = Array(arguments.dropFirst())

        if let batchIndex = args.firstIndex(of: "--batch") {
            let paths = args.dropFirst(batchIndex + 1)
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: $0) }
            return .batch(paths)
        }

        let candidateFileArgs = args.filter {
            !$0.hasPrefix("-") && !$0.hasPrefix("-psn_")
        }.map { URL(fileURLWithPath: $0) }

        if !candidateFileArgs.isEmpty {
            return .batch(candidateFileArgs)
        }

        return .ui
    }
}

struct CLIRunner {
    static func runIfNeeded() -> Bool {
        switch CommandLineParser.parse(arguments: CommandLine.arguments) {
        case .ui:
            return false
        case .batch(let urls):
            let processor = ImageProcessor()
            let options = ImageProcessingOptions(
                overwriteOriginal: false,
                autoTrimTransparentBorders: true,
                fixedCropSize: nil,
                fixedCropAnchor: .center,
                optimizer: OptimizerPreferences(),
                outputSuffix: "-pixelcrusher"
            )

            if urls.isEmpty {
                fputs("No files provided for --batch\n", stderr)
                return true
            }

            for url in urls {
                do {
                    let report = try processor.processImage(at: url, options: options)
                    print("OK \(url.lastPathComponent) -> \(report.outputURL.path) [\(report.summary)]")
                } catch {
                    fputs("ERR \(url.lastPathComponent): \(error.localizedDescription)\n", stderr)
                }
            }
            return true
        }
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    private enum DefaultsKey {
        static let overwriteOriginal = "overwriteOriginal"
        static let autoTrimTransparentBorders = "autoTrimTransparentBorders"
        static let fixedCropEnabled = "fixedCropEnabled"
        static let fixedCropWidth = "fixedCropWidth"
        static let fixedCropHeight = "fixedCropHeight"
        static let cropAnchor = "cropAnchor"

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
    private let processor = ImageProcessor()

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

    @Published var cropAnchor: CropAnchor {
        didSet { defaults.set(cropAnchor.rawValue, forKey: DefaultsKey.cropAnchor) }
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

    @Published private(set) var pendingCount = 0
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var activeItemName: String?
    @Published private(set) var isQueueRunning = false
    @Published private(set) var toolStatuses: [OptimizerToolStatus] = []

    private var queueStateMachine = ProcessingQueueStateMachine()
    private var resultIndexByID: [UUID: Int] = [:]
    private var queueWorkerTask: Task<Void, Never>?
    private var currentJobTask: Task<ImageProcessingReport, Error>?
    private var stopAfterCurrent = false

    var overallProgress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        overwriteOriginal = defaults.object(forKey: DefaultsKey.overwriteOriginal) as? Bool ?? false
        autoTrimTransparentBorders = defaults.object(forKey: DefaultsKey.autoTrimTransparentBorders) as? Bool ?? true
        fixedCropEnabled = defaults.object(forKey: DefaultsKey.fixedCropEnabled) as? Bool ?? false
        fixedCropWidth = defaults.string(forKey: DefaultsKey.fixedCropWidth) ?? "1024"
        fixedCropHeight = defaults.string(forKey: DefaultsKey.fixedCropHeight) ?? "1024"

        if let rawAnchor = defaults.string(forKey: DefaultsKey.cropAnchor),
           let anchor = CropAnchor(rawValue: rawAnchor) {
            cropAnchor = anchor
        } else {
            cropAnchor = .center
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

        refreshToolAvailability()
    }

    func refreshToolAvailability() {
        if let statuses = try? PixelCrusherBackendClient().detectTools() {
            toolStatuses = statuses
        } else {
            toolStatuses = OptimizerToolDetector().detect().statuses
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
                    Task { @MainActor [weak self] in
                        self?.appendImmediateFailure(
                            inputURL: URL(fileURLWithPath: "unknown"),
                            message: "Drop error: \(error.localizedDescription)"
                        )
                    }
                    return
                }

                guard let droppedURL = Self.extractFileURL(from: item) else {
                    Task { @MainActor [weak self] in
                        self?.appendImmediateFailure(
                            inputURL: URL(fileURLWithPath: "unknown"),
                            message: "Could not decode dropped file URL"
                        )
                    }
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
        panel.allowedContentTypes = [
            UTType.png,
            UTType.jpeg,
            UTType.gif,
            UTType(filenameExtension: "svg")
        ].compactMap { $0 }

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

    func cancelQueuedJobs() {
        let cancelledIDs = queueStateMachine.cancelQueuedJobs()

        for id in cancelledIDs {
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
        currentJobTask?.cancel()

        if let activeID = queueStateMachine.progress.activeItemID,
           let index = resultIndexByID[activeID],
           !results[index].state.isTerminal {
            results[index].statusText += " (cancel requested)"
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

    private func enqueueInput(url: URL) {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            appendImmediateFailure(inputURL: url, message: "Input path does not exist")
            return
        }

        if isDirectory.boolValue {
            if !folderRoots.contains(url) {
                folderRoots.append(url)
            }

            let files = collectSupportedFiles(in: url)
            if files.isEmpty {
                appendImmediateFailure(
                    inputURL: url,
                    message: "No supported images found in folder (PNG/JPG/JPEG/SVG/GIF)"
                )
                return
            }

            for file in files {
                enqueueFile(file)
            }
            return
        }

        guard Self.isSupportedFile(url) else {
            appendImmediateFailure(
                inputURL: url,
                message: "Skipped (supported: PNG/JPG/JPEG/SVG/GIF)"
            )
            return
        }

        enqueueFile(url)
    }

    private func enqueueFile(_ fileURL: URL) {
        let queuedItem = queueStateMachine.enqueue(inputURL: fileURL)
        let result = ProcessingResult(
            id: queuedItem.id,
            inputURL: fileURL,
            enqueuedOrder: queuedItem.enqueuedOrder,
            outputURL: nil,
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

    private func appendImmediateFailure(inputURL: URL, message: String) {
        let result = ProcessingResult(
            id: UUID(),
            inputURL: inputURL,
            enqueuedOrder: 0,
            outputURL: nil,
            success: false,
            state: .failed,
            statusText: message,
            detailText: nil,
            warning: nil
        )
        results.append(result)
        refreshQueueProgress()
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
            currentJobTask = nil
            stopAfterCurrent = false
            refreshQueueProgress()
        }

        while true {
            guard let nextItem = queueStateMachine.dequeueNextQueued() else {
                break
            }

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
            let options = currentOptions()
            let processor = self.processor

            let statusBridge: @Sendable (ProcessingStatusUpdate) -> Void = { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.apply(update: update, for: nextItem.id)
                }
            }

            let jobTask = Task.detached(priority: .userInitiated) {
                try processor.processImage(at: inputURL, options: options, statusHandler: statusBridge)
            }
            currentJobTask = jobTask

            do {
                let report = try await jobTask.value
                currentJobTask = nil
                completeJob(id: nextItem.id, report: report)
            } catch is CancellationError {
                currentJobTask = nil
                failJob(id: nextItem.id, message: "Cancelled")
            } catch {
                currentJobTask = nil
                failJob(id: nextItem.id, message: error.localizedDescription)
            }

            refreshQueueProgress()

            if stopAfterCurrent {
                stopAfterCurrent = false
                break
            }
        }
    }

    private func completeJob(id: UUID, report: ImageProcessingReport) {
        try? queueStateMachine.transition(id: id, to: .done)

        guard let index = resultIndexByID[id] else { return }
        results[index].outputURL = report.outputURL
        results[index].success = true
        results[index].state = .done
        results[index].statusText = "Done"
        results[index].detailText = report.summary
        results[index].warning = report.warning
    }

    private func failJob(id: UUID, message: String) {
        try? queueStateMachine.transition(id: id, to: .failed)

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

        if let activeID = progress.activeItemID,
           let index = resultIndexByID[activeID] {
            activeItemName = results[index].inputURL.lastPathComponent
        } else {
            activeItemName = nil
        }
    }

    private func currentOptions() -> ImageProcessingOptions {
        let fixedSize: CropSize?

        if fixedCropEnabled,
           let width = Int(fixedCropWidth),
           let height = Int(fixedCropHeight),
           width > 0,
           height > 0 {
            fixedSize = try? CropSize(width: width, height: height)
        } else {
            fixedSize = nil
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

        return ImageProcessingOptions(
            overwriteOriginal: overwriteOriginal,
            autoTrimTransparentBorders: autoTrimTransparentBorders,
            fixedCropSize: fixedSize,
            fixedCropAnchor: cropAnchor,
            optimizer: optimizer,
            outputSuffix: "-pixelcrusher"
        )
    }

    private func collectSupportedFiles(in folderURL: URL) -> [URL] {
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

    nonisolated private static func isSupportedFile(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "svg", "gif"].contains(url.pathExtension.lowercased())
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

struct ContentView: View {
    @StateObject private var model = AppViewModel()

    @State private var profile: CompressionProfile = .balanced
    @State private var showAdvanced = false

    @State private var cropTarget: ProcessingResult?
    @State private var resizeTarget: ProcessingResult?
    @State private var folderCropTarget: URL?
    @State private var folderResizeTarget: URL?

    @State private var cropDraftWidth = ""
    @State private var cropDraftHeight = ""
    @State private var cropDraftAnchor: CropAnchor = .center

    @State private var resizeDraftWidth = ""
    @State private var resizeDraftHeight = ""
    @State private var resizeDraftLock = true

    @State private var folderCropPreset = "1024"
    @State private var folderCropAnchor: CropAnchor = .center
    @State private var folderResizePreset = "1024"
    @State private var folderResizeLock = true

    @State private var folderBatchSummary: [String: String] = [:]
    @State private var itemSummary: [UUID: String] = [:]

    private let sizePresets: [(id: String, label: String, width: String, height: String)] = [
        ("original", "Original size", "", ""),
        ("512", "512 × 512", "512", "512"),
        ("1024", "1024 × 1024", "1024", "1024"),
        ("2048", "2048 × 2048", "2048", "2048")
    ]

    private var queuePercentText: String {
        guard model.totalCount > 0 else { return "0%" }
        return "\(Int((model.overallProgress * 100).rounded()))%"
    }

    private var isEmptyState: Bool {
        model.results.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            HStack(spacing: 0) {
                mainPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                sidebarPane
                    .frame(width: 360)
                    .frame(maxHeight: .infinity)
            }

            Divider()

            footerStatusRow
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .frame(minWidth: 1080, minHeight: 700)
        .sheet(item: $cropTarget) { result in
            cropSheet(for: result)
        }
        .sheet(item: $resizeTarget) { result in
            resizeSheet(for: result)
        }
        .sheet(item: Binding<FolderSheetTarget?>(
            get: { folderCropTarget.map(FolderSheetTarget.init(url:)) },
            set: { folderCropTarget = $0?.url }
        )) { target in
            folderCropSheet(for: target.url)
        }
        .sheet(item: Binding<FolderSheetTarget?>(
            get: { folderResizeTarget.map(FolderSheetTarget.init(url:)) },
            set: { folderResizeTarget = $0?.url }
        )) { target in
            folderResizeSheet(for: target.url)
        }
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pixel Crusher")
                    .font(.title3.weight(.semibold))
                Text("Clean batch workflow for files and folders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Profile", selection: $profile) {
                ForEach(CompressionProfile.allCases, id: \.self) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 170)
            .onChange(of: profile) { next in
                applyProfile(next)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var mainPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isEmptyState {
                    emptyDropZone
                } else {
                    compactDropZone
                    queuePanel
                    folderPanel
                    resultsPanel
                }
            }
            .padding(16)
        }
    }

    private var sidebarPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                DisclosureGroup("Advanced controls", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        generalOptionsGroup
                        dimensionsOptionsGroup
                        optimizerOptionsGroup
                        UpdateOptionsCard()
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline.weight(.medium))
            }
            .padding(14)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
    }

    private var emptyDropZone: some View {
        PaneCard {
            VStack(spacing: 12) {
                Spacer(minLength: 24)
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 30))
                    .foregroundStyle(model.isDropTargeted ? Color.accentColor : Color.secondary)

                Text("Drop files to crush")
                    .font(.title3.weight(.semibold))

                Text("PNG · JPG · SVG · GIF")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Browse Files") {
                        model.chooseFiles()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Browse Folder") {
                        model.chooseFolder()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted) { providers in
            model.handleDrop(providers: providers)
        }
    }

    private var compactDropZone: some View {
        PaneCard {
            HStack {
                Text("Add more files or folders")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Browse Files") {
                    model.chooseFiles()
                }
                .buttonStyle(.bordered)
                Button("Browse Folder") {
                    model.chooseFolder()
                }
                .buttonStyle(.bordered)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted) { providers in
            model.handleDrop(providers: providers)
        }
    }

    private var queuePanel: some View {
        PaneCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Queue")
                        .font(.headline)
                    Spacer()
                    Text("\(model.completedCount) / \(model.totalCount) done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: model.overallProgress)
                    .progressViewStyle(.linear)

                HStack {
                    Text(model.activeItemName ?? "Queue idle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(queuePercentText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var folderPanel: some View {
        PaneCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Folder workflow")
                        .font(.headline)
                    Spacer()
                    Text("\(model.folderRoots.count) roots")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.folderRoots.isEmpty {
                    Text("Drop or browse a folder to enable nested batch controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.folderRoots, id: \.path) { root in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(root.lastPathComponent)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Button("Folder Crop") {
                                    folderCropTarget = root
                                    folderCropPreset = "1024"
                                    folderCropAnchor = model.cropAnchor
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Button("Folder Resize") {
                                    folderResizeTarget = root
                                    folderResizePreset = "1024"
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            if let summary = folderBatchSummary[root.path] {
                                Text(summary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            let entries = nestedEntries(for: root)
                            if entries.isEmpty {
                                Text("No queued/processed files from this folder yet")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(entries, id: \.self) { entry in
                                    Text("• \(entry)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.38))
                        )
                    }
                }
            }
        }
    }

    private var resultsPanel: some View {
        PaneCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Processed items")
                        .font(.headline)
                    Spacer()
                    Button("Reveal Output Folder") {
                        model.openLatestOutputFolder()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.results.contains(where: { $0.outputURL != nil }))
                }

                ForEach(Array(model.results.reversed())) { result in
                    HStack(alignment: .center, spacing: 10) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.22))
                            .frame(width: 34, height: 34)
                            .overlay(
                                Text(String(result.inputURL.lastPathComponent.prefix(1)).uppercased())
                                    .font(.caption.weight(.semibold))
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.inputURL.lastPathComponent)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)

                            Text(result.statusText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            if let summary = itemSummary[result.id] {
                                Text(summary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if let delta = sizeDeltaBadge(for: result) {
                            Text(delta.text)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(delta.color.opacity(0.18), in: Capsule())
                                .foregroundStyle(delta.color)
                        }

                        Button("Crop") {
                            cropTarget = result
                            cropDraftWidth = model.fixedCropWidth
                            cropDraftHeight = model.fixedCropHeight
                            cropDraftAnchor = model.cropAnchor
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Resize") {
                            resizeTarget = result
                            resizeDraftWidth = ""
                            resizeDraftHeight = ""
                            resizeDraftLock = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.36))
                    )
                }
            }
        }
    }

    private var generalOptionsGroup: some View {
        PaneCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("General")
                    .font(.headline)
                Toggle("Auto-trim empty space", isOn: $model.autoTrimTransparentBorders)
                Toggle("Overwrite original files", isOn: $model.overwriteOriginal)
            }
        }
    }

    private var dimensionsOptionsGroup: some View {
        PaneCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Dimensions")
                    .font(.headline)

                Toggle("Enable fixed crop", isOn: $model.fixedCropEnabled)

                HStack {
                    Text("Width")
                    Spacer()
                    TextField("1024", text: $model.fixedCropWidth)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .disabled(!model.fixedCropEnabled)
                }

                HStack {
                    Text("Height")
                    Spacer()
                    TextField("1024", text: $model.fixedCropHeight)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .disabled(!model.fixedCropEnabled)
                }

                Picker("Anchor", selection: $model.cropAnchor) {
                    Text("Center").tag(CropAnchor.center)
                    Text("Top Left").tag(CropAnchor.topLeft)
                    Text("Top Right").tag(CropAnchor.topRight)
                    Text("Bottom Left").tag(CropAnchor.bottomLeft)
                    Text("Bottom Right").tag(CropAnchor.bottomRight)
                }
                .pickerStyle(.menu)
                .disabled(!model.fixedCropEnabled)
            }
        }
    }

    private var optimizerOptionsGroup: some View {
        PaneCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Optimizers")
                        .font(.headline)
                    Spacer()
                    Button("Refresh tools") {
                        model.refreshToolAvailability()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                HStack {
                    Text("JPEG quality")
                    Spacer()
                    Text("\(Int(model.jpegQualityPercent.rounded()))%")
                        .font(.system(.body, design: .monospaced))
                }
                Slider(value: $model.jpegQualityPercent, in: 1...100, step: 1)

                Toggle("PNG lossy (pngquant)", isOn: $model.pngLossyEnabled)
                Toggle("PNG crush", isOn: $model.pngUsePNGCrush)
                Toggle("PNG zopfli", isOn: $model.pngUseZopfli)
                Toggle("PNGOUT", isOn: $model.pngUsePNGOUT)

                ForEach(model.toolStatuses, id: \.tool.rawValue) { status in
                    HStack(spacing: 6) {
                        Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(status.isAvailable ? .green : .secondary)
                            .font(.caption)
                        Text(status.tool.displayName)
                            .font(.caption)
                        Spacer()
                        Text(sourceLabel(for: status.source))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footerStatusRow: some View {
        HStack(spacing: 10) {
            Label("Queue", systemImage: model.isQueueRunning ? "gearshape.2.fill" : "clock")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.1)))

            Text(model.isQueueRunning ? "Processing \(model.completedCount)/\(model.totalCount)" : "Ready")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(model.bundledDiagnosticsLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func applyProfile(_ profile: CompressionProfile) {
        switch profile {
        case .balanced:
            model.jpegQualityPercent = 82
            model.pngLossyEnabled = true
            model.pngLossyQualityMin = 60
            model.pngLossyQualityMax = 90
            model.pngUsePNGCrush = true
            model.pngUseZopfli = false
        case .qualityFirst:
            model.jpegQualityPercent = 92
            model.pngLossyEnabled = false
            model.pngLossyQualityMin = 75
            model.pngLossyQualityMax = 98
            model.pngUsePNGCrush = true
            model.pngUseZopfli = true
        case .smallest:
            model.jpegQualityPercent = 70
            model.pngLossyEnabled = true
            model.pngLossyQualityMin = 45
            model.pngLossyQualityMax = 75
            model.pngUsePNGCrush = true
            model.pngUseZopfli = true
        }
    }

    private func nestedEntries(for root: URL) -> [String] {
        let rootPath = root.path
        return model.results
            .map(\.inputURL.path)
            .filter { $0.hasPrefix(rootPath) }
            .map { path in
                let relative = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return relative.isEmpty ? basename(path) : relative
            }
            .prefix(8)
            .map { $0 }
    }

    private func basename(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func sizeDeltaBadge(for result: ProcessingResult) -> (text: String, color: Color)? {
        guard let detail = result.detailText,
              let range = detail.range(of: #"\([+-]\d+\.\d%\)"#, options: .regularExpression) else {
            return nil
        }

        let token = String(detail[range].dropFirst().dropLast())

        if token.hasPrefix("-") {
            return (token, .green)
        }

        if token.hasPrefix("+") {
            return (token, .red)
        }

        return (token, .secondary)
    }

    private func sourceLabel(for source: OptimizerToolResolutionSource?) -> String {
        switch source {
        case .bundled:
            return "bundled"
        case .hostPath:
            return "host"
        case .environmentOverride:
            return "env"
        case nil:
            return "detected"
        }
    }

    private func cropSheet(for result: ProcessingResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Crop image")
                .font(.headline)
            Text(result.inputURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Width", text: $cropDraftWidth)
                    .textFieldStyle(.roundedBorder)
                TextField("Height", text: $cropDraftHeight)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("Anchor", selection: $cropDraftAnchor) {
                Text("Center").tag(CropAnchor.center)
                Text("Top Left").tag(CropAnchor.topLeft)
                Text("Top Right").tag(CropAnchor.topRight)
                Text("Bottom Left").tag(CropAnchor.bottomLeft)
                Text("Bottom Right").tag(CropAnchor.bottomRight)
            }
            .pickerStyle(.menu)

            HStack {
                Spacer()
                Button("Cancel") {
                    cropTarget = nil
                }
                Button("Apply Crop") {
                    model.fixedCropEnabled = true
                    model.fixedCropWidth = cropDraftWidth
                    model.fixedCropHeight = cropDraftHeight
                    model.cropAnchor = cropDraftAnchor
                    itemSummary[result.id] = "Crop \(cropDraftWidth.isEmpty ? "auto" : cropDraftWidth)×\(cropDraftHeight.isEmpty ? "auto" : cropDraftHeight)"
                    cropTarget = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private func resizeSheet(for result: ProcessingResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resize image")
                .font(.headline)
            Text(result.inputURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Width", text: $resizeDraftWidth)
                    .textFieldStyle(.roundedBorder)
                TextField("Height", text: $resizeDraftHeight)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("Lock aspect ratio", isOn: $resizeDraftLock)

            HStack {
                Spacer()
                Button("Cancel") {
                    resizeTarget = nil
                }
                Button("Apply Resize") {
                    itemSummary[result.id] = "Resize \(resizeDraftWidth.isEmpty ? "auto" : resizeDraftWidth)×\(resizeDraftHeight.isEmpty ? "auto" : resizeDraftHeight)"
                    resizeTarget = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private func folderCropSheet(for folder: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Folder crop settings")
                .font(.headline)
            Text(folder.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Size", selection: $folderCropPreset) {
                ForEach(sizePresets, id: \.id) { preset in
                    Text(preset.label).tag(preset.id)
                }
            }
            .pickerStyle(.menu)

            Picker("Anchor", selection: $folderCropAnchor) {
                Text("Center").tag(CropAnchor.center)
                Text("Top Left").tag(CropAnchor.topLeft)
                Text("Top Right").tag(CropAnchor.topRight)
                Text("Bottom Left").tag(CropAnchor.bottomLeft)
                Text("Bottom Right").tag(CropAnchor.bottomRight)
            }
            .pickerStyle(.menu)

            HStack {
                Spacer()
                Button("Cancel") {
                    folderCropTarget = nil
                }
                Button("Apply to Folder") {
                    if let preset = sizePresets.first(where: { $0.id == folderCropPreset }) {
                        model.fixedCropEnabled = preset.id != "original"
                        model.fixedCropWidth = preset.width
                        model.fixedCropHeight = preset.height
                        model.cropAnchor = folderCropAnchor
                        folderBatchSummary[folder.path] = "Crop \(preset.label) · Anchor \(folderCropAnchor.rawValue)"
                    }
                    folderCropTarget = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private func folderResizeSheet(for folder: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Folder resize settings")
                .font(.headline)
            Text(folder.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Size", selection: $folderResizePreset) {
                ForEach(sizePresets, id: \.id) { preset in
                    Text(preset.label).tag(preset.id)
                }
            }
            .pickerStyle(.menu)

            Toggle("Lock aspect ratio", isOn: $folderResizeLock)

            HStack {
                Spacer()
                Button("Cancel") {
                    folderResizeTarget = nil
                }
                Button("Apply to Folder") {
                    if let preset = sizePresets.first(where: { $0.id == folderResizePreset }) {
                        folderBatchSummary[folder.path] = "Resize \(preset.label) · Lock \(folderResizeLock ? "on" : "off")"
                    }
                    folderResizeTarget = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 360)
    }
}

private enum CompressionProfile: CaseIterable {
    case balanced
    case qualityFirst
    case smallest

    var label: String {
        switch self {
        case .balanced:
            return "Balanced"
        case .qualityFirst:
            return "Quality First"
        case .smallest:
            return "Smallest Size"
        }
    }
}

private struct FolderSheetTarget: Identifiable {
    let id: String
    let url: URL

    init(url: URL) {
        self.url = url
        self.id = url.path
    }
}

private struct PaneCard<Content: View>: View {
    @ViewBuilder private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.52))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

struct PixelCrusherDesktopApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.automatic)
    }
}

if !CLIRunner.runIfNeeded() {
    PixelCrusherDesktopApp.main()
}
