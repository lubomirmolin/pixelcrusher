import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PixelCrusherMacCore
import Foundation
import ImageIO
import CoreImage

struct ProcessingResult: Identifiable {
    let id: UUID
    let inputURL: URL
    let enqueuedOrder: Int
    var outputURL: URL?
    var inputBytes: Int64?
    var outputBytes: Int64?
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
    @Published private(set) var activeItemID: UUID?
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
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model = AppViewModel()
    private let windowOpacity: CGFloat = 1.0
    private let processingScrollBottomID = "processing-scroll-bottom"

    @State private var profile: CompressionProfile = .balanced
    @State private var showUpdateSheet = false

    @State private var cropTarget: ProcessingResult?
    @State private var resizeTarget: ProcessingResult?

    @State private var cropDraftWidth = ""
    @State private var cropDraftHeight = ""
    @State private var cropDraftAnchor: CropAnchor = .center

    @State private var resizeDraftWidth = ""
    @State private var resizeDraftHeight = ""
    @State private var resizeDraftLock = true

    @State private var itemSummary: [UUID: String] = [:]
    @State private var punchSession: PunchSession?
    @State private var playedPunchIDs: Set<UUID> = []

    private var isEmptyState: Bool {
        model.results.isEmpty && punchSession == nil && !model.isQueueRunning
    }

    private var showBottomHint: Bool {
        !model.results.isEmpty || punchSession != nil || model.isQueueRunning
    }

    private var processedItems: [ProcessingResult] {
        model.results
            .filter { $0.state == .done || $0.state == .failed }
            .sorted { lhs, rhs in
                lhs.enqueuedOrder > rhs.enqueuedOrder
            }
    }

    var body: some View {
        ZStack {
            WindowBlurBackdrop(material: .windowBackground)
                .ignoresSafeArea()

            Color(nsColor: colorScheme == .dark
                ? NSColor(calibratedWhite: 0.0, alpha: 0.34)
                : NSColor(calibratedWhite: 1.0, alpha: 0.16)
            )
            .ignoresSafeArea()

            appSurface

            if model.isDropTargeted {
                dragOverlay
            }
        }
        .frame(minWidth: 980, minHeight: 700)
        .background(WindowAppearanceConfigurator(opacity: windowOpacity))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted) { providers in
            model.handleDrop(providers: providers)
        }
        .onAppear {
            applyProfile(profile)
        }
        .onChange(of: model.activeItemID) { _ in
            syncPunchSession()
        }
        .onChange(of: model.results.count) { _ in
            syncPunchSession()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Update") {
                    showUpdateSheet = true
                }

                Toggle("Autocrop", isOn: $model.autoTrimTransparentBorders)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Trim transparent borders automatically during processing")

                Picker("Profile", selection: $profile) {
                    ForEach(CompressionProfile.allCases, id: \.self) { value in
                        Text(value.label).tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
                .onChange(of: profile) { next in
                    applyProfile(next)
                }
            }
        }
        .sheet(isPresented: $showUpdateSheet) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Updates")
                        .font(.headline)
                    Spacer()
                    Button("Done") {
                        showUpdateSheet = false
                    }
                    .buttonStyle(.bordered)
                }
                UpdateOptionsCard()
            }
            .padding(16)
            .frame(width: 460)
        }
        .sheet(item: $cropTarget) { result in
            cropSheet(for: result)
        }
        .sheet(item: $resizeTarget) { result in
            resizeSheet(for: result)
        }
    }

    private var appSurface: some View {
        VStack(spacing: 0) {
            mainPane

            if showBottomHint {
                bottomHintBar
            }
        }
    }

    private var mainPane: some View {
        Group {
            if isEmptyState {
                emptyStatePane
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 14) {
                            if !processedItems.isEmpty {
                                ForEach(processedItems) { result in
                                    resultRow(for: result)
                                }
                            }

                            if let active = punchSession {
                                punchSection(for: active)
                            } else if model.isQueueRunning {
                                idleProcessingSection
                            }

                            if processedItems.isEmpty && !model.isQueueRunning && punchSession == nil {
                                Text("Add files to start crushing.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 24)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(processingScrollBottomID)
                        }
                        .padding(16)
                    }
                    .onChange(of: model.results.count) { _ in
                        scrollToProcessingBottom(proxy)
                    }
                    .onChange(of: punchSession?.id) { _ in
                        scrollToProcessingBottom(proxy)
                    }
                }
                .background(Color(nsColor: colorScheme == .dark
                    ? NSColor(calibratedWhite: 0.07, alpha: 0.82)
                    : NSColor(calibratedWhite: 0.92, alpha: 0.82)
                ))
            }
        }
    }

    private func scrollToProcessingBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(processingScrollBottomID, anchor: .bottom)
            }
        }
    }

    private var emptyStatePane: some View {
        ZStack {
            Color(nsColor: colorScheme == .dark
                ? NSColor(calibratedWhite: 0.14, alpha: 0.74)
                : NSColor(calibratedWhite: 0.86, alpha: 0.76)
            )

            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.45))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .foregroundStyle(Color.secondary.opacity(0.35))
                        )
                        .frame(width: 124, height: 124)

                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.7))
                }

                Text("Drag & Drop images here")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("or")
                    .font(.title3)
                    .foregroundStyle(.secondary.opacity(0.8))

                Button("Browse Files") {
                    model.chooseFiles()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var idleProcessingSection: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text("Processing \(model.activeItemName ?? "queued images")…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 20)
    }

    private func punchSection(for session: PunchSession) -> some View {
        VStack(spacing: 10) {
            PunchEffectView(inputURL: session.inputURL) {
                guard punchSession?.id == session.id else {
                    return
                }
                playedPunchIDs.insert(session.id)
                punchSession = nil
            }
            .id(session.id)
            .frame(width: 280, height: 240)

            Text("Crushing \(session.inputURL.lastPathComponent)…")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func resultRow(for result: ProcessingResult) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ResultThumbnail(url: result.inputURL)

            VStack(alignment: .leading, spacing: 7) {
                Text(result.inputURL.lastPathComponent)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.86) : Color.primary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(formatBytes(result.inputBytes))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.55) : .secondary)

                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.5) : .secondary)

                    Text(formatBytes(result.outputBytes))
                        .foregroundStyle(result.state == .done ? Color.green.opacity(0.92) : .secondary)
                        .fontWeight(result.state == .done ? .semibold : .regular)

                    if let delta = sizeDelta(for: result) {
                        Text(delta.text)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(delta.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .foregroundStyle(delta.color)
                    }
                }
                .font(.system(size: 12, weight: .medium))
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                actionGlyphButton(symbol: "crop", help: "Crop image") {
                    cropTarget = result
                    cropDraftWidth = model.fixedCropWidth
                    cropDraftHeight = model.fixedCropHeight
                    cropDraftAnchor = model.cropAnchor
                }

                actionGlyphButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Resize image") {
                    resizeTarget = result
                    resizeDraftWidth = ""
                    resizeDraftHeight = ""
                    resizeDraftLock = true
                }
            }

            Image(systemName: result.state == .done ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(result.state == .done ? Color.green.opacity(0.92) : Color.orange)
                .font(.system(size: 24, weight: .medium))
                .frame(width: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: colorScheme == .dark
                    ? NSColor(calibratedWhite: 0.17, alpha: 0.92)
                    : NSColor(calibratedWhite: 1.0, alpha: 1)
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.1 : 0.08), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.25), value: result.state)
    }

    private var bottomHintBar: some View {
        HStack(spacing: 8) {
            Text("Drag and drop to process more images")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.isQueueRunning {
                Text("•")
                    .foregroundStyle(.secondary)
                Text("\(model.completedCount)/\(model.totalCount) done")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(nsColor: colorScheme == .dark
                        ? NSColor(calibratedWhite: 0.19, alpha: 0.94)
                        : NSColor(calibratedWhite: 0.95, alpha: 1)
                    ),
                    Color(nsColor: colorScheme == .dark
                        ? NSColor(calibratedWhite: 0.14, alpha: 0.94)
                        : NSColor(calibratedWhite: 0.9, alpha: 1)
                    )
                ]),
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
    }

    private func actionGlyphButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.82) : Color.primary)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.03 : 0.9))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.2 : 0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var dragOverlay: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [10]))
            .foregroundStyle(Color.accentColor.opacity(0.8))
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
            )
            .overlay(
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Drop to crush")
                        .fontWeight(.semibold)
                }
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
            )
            .padding(30)
            .allowsHitTesting(false)
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
        case .high:
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

    private func sizeDelta(for result: ProcessingResult) -> (text: String, color: Color)? {
        guard let inputBytes = result.inputBytes,
              let outputBytes = result.outputBytes,
              inputBytes > 0 else {
            return nil
        }

        let delta = (Double(outputBytes) - Double(inputBytes)) / Double(inputBytes)
        let absolute = Int((abs(delta) * 100.0).rounded())

        if delta < 0 {
            return ("-\(absolute)%", .green)
        }

        if delta > 0 {
            return ("+\(absolute)%", .red)
        }

        return ("0%", .secondary)
    }

    private func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else {
            return "—"
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    private func syncPunchSession() {
        guard let activeID = model.activeItemID else {
            return
        }

        if punchSession?.id == activeID || playedPunchIDs.contains(activeID) {
            return
        }

        guard let result = model.results.first(where: { $0.id == activeID }) else {
            return
        }

        punchSession = PunchSession(id: activeID, inputURL: result.inputURL)
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
}

private struct WindowAppearanceConfigurator: NSViewRepresentable {
    let opacity: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            apply(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            apply(to: nsView.window)
        }
    }

    private func apply(to window: NSWindow?) {
        guard let window else {
            return
        }

        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = opacity
    }
}

private struct WindowBlurBackdrop: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = .withinWindow
        nsView.state = .active
        nsView.isEmphasized = false
    }
}

private struct PunchSession: Equatable {
    let id: UUID
    let inputURL: URL
}

private struct ResultThumbnail: View {
    let url: URL

    var body: some View {
        ZStack {
            if let image = PixelCrusherImageLoader.orientedNSImage(from: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .clipped()
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 74, height: 74)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct PunchEffectView: View {
    let inputURL: URL
    let onComplete: () -> Void

    @State private var animator: PunchAnimator?
    @State private var didFinish = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: didFinish)) { timeline in
            Canvas { context, size in
                guard let animator else {
                    return
                }

                let finished = animator.render(into: &context, at: timeline.date, canvasSize: size)
                if finished && !didFinish {
                    DispatchQueue.main.async {
                        guard !didFinish else { return }
                        didFinish = true
                        onComplete()
                    }
                }
            }
        }
        .onAppear {
            animator = PunchAnimator(inputURL: inputURL)
            didFinish = false
        }
    }
}

private struct PunchBlock {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let color: Color
}

private struct PunchParticle {
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    var size: CGFloat
    var color: Color
}

private final class PunchAnimator {
    private let sampler: PunchColorSampler?
    private let fistImage: CGImage?
    private let imageSize: CGSize
    private var cornerBlocks: [PunchBlock] = []
    private var bodyBlocks: [PunchBlock] = []
    private var particles: [PunchParticle] = []

    private var startDate: Date?
    private var lastTickDate: Date?
    private var phase = 0
    private var completed = false

    init(inputURL: URL) {
        self.sampler = PunchColorSampler(fileURL: inputURL)
        self.fistImage = Self.loadFistImage()
        let maxDimension: CGFloat = 160
        let aspectRatio = self.sampler?.aspectRatio ?? 1
        self.imageSize = Self.fittedImageSize(maxDimension: maxDimension, aspectRatio: aspectRatio)
        buildBlockMap(imageWidth: imageSize.width, imageHeight: imageSize.height)
    }

    func render(into context: inout GraphicsContext, at date: Date, canvasSize: CGSize) -> Bool {
        if startDate == nil {
            startDate = date
            lastTickDate = date
        }

        guard let startDate else {
            return false
        }

        let elapsed = date.timeIntervalSince(startDate)
        let dt = min(max(date.timeIntervalSince(lastTickDate ?? date), 1.0 / 120.0), 1.0 / 20.0)
        lastTickDate = date

        if elapsed >= 4.0 {
            completed = true
        }

        triggerPhasesIfNeeded(elapsed: elapsed, canvasSize: canvasSize)
        stepParticles(deltaTime: dt, canvasSize: canvasSize)
        drawScene(context: &context, elapsed: elapsed, canvasSize: canvasSize)

        return completed
    }

    private func drawScene(context: inout GraphicsContext, elapsed: TimeInterval, canvasSize: CGSize) {
        let imageFrame = imageFrame(in: canvasSize)
        let imgW = imageFrame.width
        let imgH = imageFrame.height
        let imgX = imageFrame.minX
        let imgY = imageFrame.minY

        let alpha: CGFloat
        if elapsed > 3.5 {
            alpha = max(0, 1 - CGFloat((elapsed - 3.5) / 0.5))
        } else {
            alpha = 1
        }

        let shakeRange = (elapsed > 1.0 && elapsed < 1.15) || (elapsed > 2.2 && elapsed < 2.3)
        let shakeX = shakeRange ? CGFloat.random(in: -5...5) : 0
        let shakeY = shakeRange ? CGFloat.random(in: -5...5) : 0

        var transformed = context
        transformed.opacity = alpha
        transformed.translateBy(x: shakeX, y: shakeY)

        if elapsed < 1.0 {
            let pixelSize = elapsed < 0.6 ? 1 + CGFloat(elapsed / 0.6) * 7 : 8
            drawPixelatedImage(
                context: &transformed,
                imageX: imgX,
                imageY: imgY,
                imageW: imgW,
                imageH: imgH,
                pixelSize: pixelSize
            )
        } else if elapsed < 2.2 {
            for block in bodyBlocks {
                let rect = CGRect(
                    x: imgX + block.x,
                    y: imgY + block.y,
                    width: block.width,
                    height: block.height
                )
                transformed.fill(Path(rect), with: .color(block.color))
            }
        }

        if elapsed > 0.6 && elapsed <= 2.2 {
            drawFist(context: &transformed, elapsed: elapsed, imageY: imgY, canvasWidth: canvasSize.width)
        }

        for particle in particles {
            let rect = CGRect(x: particle.x, y: particle.y, width: particle.size, height: particle.size)
            context.fill(Path(rect), with: .color(particle.color))
        }
    }

    private func drawPixelatedImage(
        context: inout GraphicsContext,
        imageX: CGFloat,
        imageY: CGFloat,
        imageW: CGFloat,
        imageH: CGFloat,
        pixelSize: CGFloat
    ) {
        let step = max(1, Int(pixelSize.rounded()))

        let maxY = Int(ceil(imageH))
        let maxX = Int(ceil(imageW))

        for y in stride(from: 0, to: maxY, by: step) {
            for x in stride(from: 0, to: maxX, by: step) {
                let cellW = min(CGFloat(step), imageW - CGFloat(x))
                let cellH = min(CGFloat(step), imageH - CGFloat(y))
                guard cellW > 0, cellH > 0 else {
                    continue
                }

                let nx = min(max((CGFloat(x) + cellW * 0.5) / imageW, 0), 1)
                let ny = min(max((CGFloat(y) + cellH * 0.5) / imageH, 0), 1)
                let color = sampler?.color(atNormalizedX: nx, y: ny) ?? Color.accentColor
                let rect = CGRect(
                    x: imageX + CGFloat(x),
                    y: imageY + CGFloat(y),
                    width: cellW,
                    height: cellH
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
    }

    private func drawFist(context: inout GraphicsContext, elapsed: TimeInterval, imageY: CGFloat, canvasWidth: CGFloat) {
        let fistW: CGFloat = 100
        let fistH: CGFloat = 140
        let fistX = (canvasWidth - fistW) * 0.5
        let targetY = imageY - fistH + 25

        let fistY: CGFloat
        if elapsed > 0.6 && elapsed <= 1.0 {
            let p = CGFloat((elapsed - 0.6) / 0.4)
            fistY = -fistH + (targetY + fistH) * (p * p * p)
        } else if elapsed <= 1.6 {
            fistY = targetY
        } else {
            let p = CGFloat((elapsed - 1.6) / 0.6)
            fistY = targetY - (targetY + fistH) * (p * p)
        }

        if let fistImage {
            context.draw(
                Image(decorative: fistImage, scale: 1),
                in: CGRect(x: fistX, y: fistY, width: fistW, height: fistH)
            )
        } else {
            let fist = Text("👊")
                .font(.system(size: 82))
            context.draw(fist, at: CGPoint(x: fistX + fistW * 0.5, y: fistY + fistH * 0.56), anchor: .center)
        }
    }

    private func triggerPhasesIfNeeded(elapsed: TimeInterval, canvasSize: CGSize) {
        let imageFrame = imageFrame(in: canvasSize)
        let imageX = imageFrame.minX
        let imageY = imageFrame.minY

        if elapsed >= 1.0 && phase == 0 {
            phase = 1
            for block in cornerBlocks {
                particles.append(PunchParticle(
                    x: imageX + block.x,
                    y: imageY + block.y,
                    vx: CGFloat.random(in: 1...7),
                    vy: CGFloat.random(in: -2...2),
                    size: max(2, min(block.width, block.height)),
                    color: block.color
                ))
            }
        }

        if elapsed >= 2.2 && phase == 1 {
            phase = 2
            for block in bodyBlocks {
                particles.append(PunchParticle(
                    x: imageX + block.x,
                    y: imageY + block.y,
                    vx: CGFloat.random(in: -4...4),
                    vy: CGFloat.random(in: -4...1),
                    size: max(2, min(block.width, block.height)),
                    color: block.color
                ))
            }
        }
    }

    private func stepParticles(deltaTime: TimeInterval, canvasSize: CGSize) {
        let floorY = canvasSize.height - 15
        let frameFactor = CGFloat(deltaTime * 60.0)

        for index in particles.indices {
            particles[index].vy += 0.8 * frameFactor
            particles[index].x += particles[index].vx * frameFactor
            particles[index].y += particles[index].vy * frameFactor

            if particles[index].y > floorY - particles[index].size {
                particles[index].y = floorY - particles[index].size
                particles[index].vy *= -0.3
                particles[index].vx *= 0.7
            }
        }
    }

    private func buildBlockMap(imageWidth: CGFloat, imageHeight: CGFloat) {
        let blockSize: CGFloat = 8
        let cols = max(1, Int(ceil(imageWidth / blockSize)))
        let rows = max(1, Int(ceil(imageHeight / blockSize)))

        for row in 0..<rows {
            for col in 0..<cols {
                let x = CGFloat(col) * blockSize
                let y = CGFloat(row) * blockSize
                let blockWidth = min(blockSize, imageWidth - x)
                let blockHeight = min(blockSize, imageHeight - y)
                guard blockWidth > 0, blockHeight > 0 else {
                    continue
                }

                let nx = min(max((x + blockWidth * 0.5) / imageWidth, 0), 1)
                let ny = min(max((y + blockHeight * 0.5) / imageHeight, 0), 1)
                let color = sampler?.color(atNormalizedX: nx, y: ny) ?? Color.blue
                let block = PunchBlock(
                    x: x,
                    y: y,
                    width: blockWidth,
                    height: blockHeight,
                    color: color
                )
                let noise = Double.random(in: -2...2)

                if Double(row + col) + noise > (Double(rows + cols) * 0.67) {
                    cornerBlocks.append(block)
                } else {
                    bodyBlocks.append(block)
                }
            }
        }
    }

    private func imageFrame(in canvasSize: CGSize) -> CGRect {
        let containerHeight: CGFloat = 160
        let x = (canvasSize.width - imageSize.width) * 0.5
        let y = 48 + (containerHeight - imageSize.height) * 0.5
        return CGRect(x: x, y: y, width: imageSize.width, height: imageSize.height)
    }

    private static func fittedImageSize(maxDimension: CGFloat, aspectRatio: CGFloat) -> CGSize {
        let clampedAspect = max(aspectRatio, 0.01)
        if clampedAspect >= 1 {
            return CGSize(width: maxDimension, height: maxDimension / clampedAspect)
        }
        return CGSize(width: maxDimension * clampedAspect, height: maxDimension)
    }

    private static func loadFistImage() -> CGImage? {
        let bundled = Bundle.main.url(forResource: "fist", withExtension: "png")
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("fist.png")
        let candidates = [bundled, local].compactMap { $0 }

        for url in candidates {
            guard let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                continue
            }
            return cgImage
        }

        return nil
    }
}

private final class PunchColorSampler {
    private let width: Int
    private let height: Int
    private let rgba: [UInt8]
    var aspectRatio: CGFloat {
        guard height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }

    init?(fileURL: URL) {
        guard let cgImage = PixelCrusherImageLoader.orientedCGImage(from: fileURL) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height

        var storage = [UInt8](repeating: 0, count: width * height * 4)
        let bytesPerRow = width * 4

        let rendered = storage.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }

            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard rendered else {
            return nil
        }

        self.width = width
        self.height = height
        self.rgba = storage
    }

    func color(atNormalizedX x: CGFloat, y: CGFloat) -> Color {
        let clampedX = min(max(x, 0), 1)
        let clampedY = min(max(y, 0), 1)

        let px = Int(clampedX * CGFloat(max(width - 1, 0)))
        let py = Int(clampedY * CGFloat(max(height - 1, 0)))
        let index = ((py * width) + px) * 4

        guard index >= 0, index + 3 < rgba.count else {
            return .blue
        }

        return Color(
            red: Double(rgba[index]) / 255.0,
            green: Double(rgba[index + 1]) / 255.0,
            blue: Double(rgba[index + 2]) / 255.0,
            opacity: Double(rgba[index + 3]) / 255.0
        )
    }
}

private enum PixelCrusherImageLoader {
    static func orientedNSImage(from url: URL) -> NSImage? {
        guard let cgImage = orientedCGImage(from: url) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func orientedCGImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientationRaw = (properties?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up

        guard orientation != .up else {
            return image
        }

        let ciImage = CIImage(cgImage: image).oriented(orientation)
        let ciContext = CIContext(options: nil)
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }
}

private enum CompressionProfile: CaseIterable {
    case balanced
    case high
    case smallest

    var label: String {
        switch self {
        case .balanced:
            return "Balanced"
        case .high:
            return "High Quality"
        case .smallest:
            return "Smallest Size"
        }
    }
}

struct PixelCrusherDesktopApp: App {
    var body: some Scene {
        WindowGroup("Pixel Crusher") {
            ContentView()
        }
        .windowResizability(.automatic)
    }
}

if !CLIRunner.runIfNeeded() {
    PixelCrusherDesktopApp.main()
}
