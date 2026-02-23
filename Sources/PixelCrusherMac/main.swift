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

                guard let fileURL = Self.extractFileURL(from: item) else {
                    Task { @MainActor [weak self] in
                        self?.appendImmediateFailure(
                            inputURL: URL(fileURLWithPath: "unknown"),
                            message: "Could not decode dropped file URL"
                        )
                    }
                    return
                }

                let allowed = ["png", "jpg", "jpeg", "svg", "gif"]
                guard allowed.contains(fileURL.pathExtension.lowercased()) else {
                    Task { @MainActor [weak self] in
                        self?.appendImmediateFailure(
                            inputURL: fileURL,
                            message: "Skipped (supported: PNG/JPG/JPEG/SVG/GIF)"
                        )
                    }
                    return
                }

                Task { @MainActor [weak self] in
                    self?.enqueue(fileURL: fileURL)
                }
            }
        }

        return true
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

    private func enqueue(fileURL: URL) {
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

    private var layoutDescriptor: PixelCrusherLayoutDescriptor {
        PixelCrusherLayoutDescriptor(
            context: PixelCrusherLayoutContext(
                showHeader: true,
                showDropZone: true,
                showActiveQueue: true,
                showRecentResults: true,
                canRevealOutputFolder: model.results.contains(where: { $0.outputURL != nil })
            )
        )
    }

    private var queuePercentText: String {
        guard model.totalCount > 0 else { return "0%" }
        return "\(Int((model.overallProgress * 100).rounded()))%"
    }

    private var readinessText: String {
        if model.isQueueRunning {
            return "Processing \(model.completedCount)/\(model.totalCount)"
        }

        if model.totalCount == 0 {
            return "Ready for new files"
        }

        return "Idle · \(model.completedCount) completed"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                rightPane
                    .frame(width: 360)
                    .frame(maxHeight: .infinity)
            }

            Divider()

            footerStatusRow
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .frame(minWidth: 1100, minHeight: 700)
    }

    private var leftPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if sectionVisible(.header) {
                    headerBlock
                }

                if sectionVisible(.dropZone) {
                    dropZone
                }

                if sectionVisible(.activeQueue) {
                    queuePanel
                }

                if sectionVisible(.recentResults) {
                    resultsPanel
                }
            }
            .padding(18)
        }
    }

    private var rightPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Options")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                if optionsGroupVisible(.general) {
                    generalOptionsGroup
                }

                if optionsGroupVisible(.dimensions) {
                    dimensionsOptionsGroup
                }

                if optionsGroupVisible(.optimizers) {
                    optimizerOptionsGroup
                }

                UpdateOptionsCard()
            }
            .padding(16)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
    }

    private var headerBlock: some View {
        PaneCard {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Spacer()

                    Text("PixelCrusher")
                        .font(.title2.weight(.semibold))

                    Text("v1")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .overlay(
                            Capsule().strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 0.8)
                        )

                    Spacer()
                }

                Text("Drop PNG/JPG/SVG/GIF files to trim, crop, and optimize using ImageOptim-style external tools.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var queuePanel: some View {
        PaneCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Active Queue")
                            .font(.headline)
                        Text("Completed \(model.completedCount)/\(model.totalCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if model.isQueueRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                ProgressView(value: model.overallProgress)
                    .progressViewStyle(.linear)
                    .opacity(model.totalCount > 0 ? 1 : 0.45)

                HStack(alignment: .firstTextBaseline) {
                    Label(model.activeItemName ?? "Waiting for files", systemImage: model.isQueueRunning ? "gearshape.2.fill" : "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Text(queuePercentText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button("Cancel queued") {
                        model.cancelQueuedJobs()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.pendingCount == 0)

                    Button("Cancel all") {
                        model.cancelAllJobs()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(!model.isQueueRunning && model.pendingCount == 0)
                }
            }
        }
    }

    private var resultsPanel: some View {
        PaneCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent Results")
                        .font(.headline)

                    Spacer()

                    Button("Reveal Output Folder") {
                        model.openLatestOutputFolder()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!layoutDescriptor.showsRevealOutputFolderAction)
                }

                if model.results.isEmpty {
                    Text("Processed files will appear here with output location and size delta badges.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(model.results.reversed())) { result in
                            resultRow(for: result)
                        }
                    }
                }
            }
        }
    }

    private func resultRow(for result: ProcessingResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            stateIcon(for: result)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(result.inputURL.lastPathComponent)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    statusBadge(for: result)

                    if let delta = sizeDeltaBadge(for: result) {
                        Text(delta.text)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(delta.color.opacity(0.18), in: Capsule())
                            .foregroundStyle(delta.color)
                    }

                    Spacer(minLength: 0)
                }

                Text(result.outputURL?.path ?? result.inputURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(result.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let warning = result.warning {
                    Text("⚠︎ \(warning)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            if result.canOpenFolder {
                Button("Reveal") {
                    model.openOutputFolder(for: result)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func statusBadge(for result: ProcessingResult) -> some View {
        Text(result.state.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(stateColor(for: result).opacity(0.16), in: Capsule())
            .foregroundStyle(stateColor(for: result))
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

    private func sectionVisible(_ id: LeftPaneSectionID) -> Bool {
        layoutDescriptor.section(id)?.isVisible ?? false
    }

    private func optionsGroupVisible(_ id: OptionsGroupID) -> Bool {
        layoutDescriptor.optionsGroup(id)?.isVisible ?? false
    }

    private var generalOptionsGroup: some View {
        PaneCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("General")
                    .font(.headline)

                Toggle("Auto-trim empty space (PNG/SVG)", isOn: $model.autoTrimTransparentBorders)
                    .toggleStyle(.switch)

                Toggle("Overwrite original files", isOn: $model.overwriteOriginal)
                    .toggleStyle(.switch)
            }
        }
    }

    private var dimensionsOptionsGroup: some View {
        PaneCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Dimensions")
                    .font(.headline)

                Toggle("Crop by explicit size", isOn: $model.fixedCropEnabled)
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Width")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("1024", text: $model.fixedCropWidth)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 98)
                            .multilineTextAlignment(.trailing)
                            .disabled(!model.fixedCropEnabled)
                    }

                    HStack {
                        Text("Height")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("1024", text: $model.fixedCropHeight)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 98)
                            .multilineTextAlignment(.trailing)
                            .disabled(!model.fixedCropEnabled)
                    }

                    HStack {
                        Text("Anchor")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Anchor", selection: $model.cropAnchor) {
                            Text("Center").tag(CropAnchor.center)
                            Text("Top Left").tag(CropAnchor.topLeft)
                            Text("Top Right").tag(CropAnchor.topRight)
                            Text("Bottom Left").tag(CropAnchor.bottomLeft)
                            Text("Bottom Right").tag(CropAnchor.bottomRight)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                        .disabled(!model.fixedCropEnabled)
                    }
                }
            }
        }
    }

    private var optimizerOptionsGroup: some View {
        PaneCard {
            VStack(alignment: .leading, spacing: 14) {
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

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.toolStatuses, id: \.tool.rawValue) { status in
                        HStack(spacing: 6) {
                            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(status.isAvailable ? .green : .secondary)
                                .font(.caption)
                            Text(status.tool.displayName)
                                .font(.caption)
                            Spacer(minLength: 0)
                            if let path = status.resolvedPath {
                                Text("\(sourceLabel(for: status.source)): \((path as NSString).lastPathComponent)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("missing")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("JPEG quality")
                        Spacer()
                        Text("\(Int(model.jpegQualityPercent.rounded()))%")
                            .font(.system(.body, design: .monospaced))
                    }
                    Slider(value: $model.jpegQualityPercent, in: 1...100, step: 1)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("PNG lossy (pngquant)", isOn: $model.pngLossyEnabled)
                        .toggleStyle(.switch)

                    HStack {
                        Text("PNG quality min")
                        Spacer()
                        Text("\(Int(model.pngLossyQualityMin.rounded()))")
                            .font(.system(.body, design: .monospaced))
                    }
                    Slider(value: $model.pngLossyQualityMin, in: 0...100, step: 1)
                        .disabled(!model.pngLossyEnabled)

                    HStack {
                        Text("PNG quality max")
                        Spacer()
                        Text("\(Int(model.pngLossyQualityMax.rounded()))")
                            .font(.system(.body, design: .monospaced))
                    }
                    Slider(value: $model.pngLossyQualityMax, in: 0...100, step: 1)
                        .disabled(!model.pngLossyEnabled)

                    HStack {
                        Text("pngquant speed")
                        Spacer()
                        Text("\(Int(model.pngQuantSpeed.rounded()))")
                            .font(.system(.body, design: .monospaced))
                    }
                    Slider(value: $model.pngQuantSpeed, in: 1...11, step: 1)
                        .disabled(!model.pngLossyEnabled)

                    Toggle("PNG lossless pass (pngcrush)", isOn: $model.pngUsePNGCrush)
                        .toggleStyle(.switch)
                    Toggle("PNG zopfli pass (zopflipng)", isOn: $model.pngUseZopfli)
                        .toggleStyle(.switch)
                    Toggle("PNGOUT pass (optional)", isOn: $model.pngUsePNGOUT)
                        .toggleStyle(.switch)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("SVG multipass (SVGO)", isOn: $model.svgMultipass)
                        .toggleStyle(.switch)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("GIF optimize level")
                        Spacer()
                        Text("\(Int(model.gifOptimizationLevel.rounded()))")
                            .font(.system(.body, design: .monospaced))
                    }
                    Slider(value: $model.gifOptimizationLevel, in: 1...3, step: 1)

                    HStack {
                        Text("GIF lossy")
                        Spacer()
                        Text("\(Int(model.gifLossyLevel.rounded()))")
                            .font(.system(.body, design: .monospaced))
                    }
                    Slider(value: $model.gifLossyLevel, in: 0...200, step: 1)
                }
            }
        }
    }

    private var footerStatusRow: some View {
        HStack(spacing: 10) {
            Label("External CLI stack", systemImage: "terminal")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.1)))

            Text(readinessText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(model.bundledDiagnosticsLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(model.isQueueRunning ? "Queue running" : "Ready")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func stateIcon(for result: ProcessingResult) -> some View {
        Group {
            switch result.state {
            case .queued:
                Image(systemName: "clock.badge")
            case .preparing, .optimizing, .saving:
                ProgressView()
            case .done:
                Image(systemName: "checkmark.circle.fill")
            case .failed:
                Image(systemName: "xmark.octagon.fill")
            }
        }
        .foregroundStyle(stateColor(for: result))
    }

    private func stateColor(for result: ProcessingResult) -> Color {
        switch result.state {
        case .queued:
            return .secondary
        case .preparing, .optimizing, .saving:
            return .accentColor
        case .done:
            return .green
        case .failed:
            return .red
        }
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

    private var dropZone: some View {
        PaneCard {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.6, dash: [8]))
                    .foregroundStyle(model.isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.9))
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(model.isDropTargeted ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.03))
                    )

                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(model.isDropTargeted ? Color.accentColor : Color.primary)

                    Text("Drop PNG/JPG/SVG/GIF files here")
                        .font(.headline)

                    Text("Files are queued and processed in order. Tool availability controls each optimization pipeline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
            }
            .frame(height: 190)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted) { providers in
            model.handleDrop(providers: providers)
        }
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
