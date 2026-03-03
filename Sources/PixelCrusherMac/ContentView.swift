import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PixelCrusherMacCore

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
    @State private var cropDraftX = ""
    @State private var cropDraftY = ""

    @State private var resizeDraftWidth = ""
    @State private var resizeDraftHeight = ""
    @State private var resizeDraftLock = true

    @State private var dismissedProcessedItemIDs: Set<UUID> = []
    @State private var punchSession: PunchSession?
    @State private var playedPunchIDs: Set<UUID> = []
    @State private var activeFolderSession: FolderDropSession?
    @State private var activeFolderPunch: FolderDropSession?
    @State private var expandedFolderIDs: Set<UUID> = []
    @State private var dropValidationState: DropValidationState = .idle

    private var isEmptyState: Bool {
        visibleProcessedItems.isEmpty && folderSessionFiles.isEmpty && activeFolderPunch == nil && !model.isQueueRunning
    }

    private var showBottomHint: Bool {
        !visibleProcessedItems.isEmpty || !folderSessionFiles.isEmpty || activeFolderSession != nil || activeFolderPunch != nil || model.isQueueRunning
    }

    private var processedItems: [ProcessingResult] {
        model.results
            .filter { ($0.state == .done || $0.state == .failed) && !dismissedProcessedItemIDs.contains($0.id) }
            .sorted { lhs, rhs in
                lhs.enqueuedOrder < rhs.enqueuedOrder
            }
    }

    private var activeFolderSessionFiles: [ProcessingResult] {
        guard let folderSession = activeFolderSession else {
            return []
        }

        return model.results
            .filter { isFile($0.inputURL, inside: folderSession.folderURL) }
            .sorted { lhs, rhs in
                lhs.enqueuedOrder < rhs.enqueuedOrder
            }
    }

    private var folderSessionFiles: [ProcessingResult] {
        guard activeFolderSession != nil else {
            return []
        }

        return activeFolderSessionFiles.filter { !dismissedProcessedItemIDs.contains($0.id) }
    }

    private var visibleProcessedItems: [ProcessingResult] {
        guard let folderSession = activeFolderSession else {
            return processedItems
        }

        return processedItems.filter { !isFile($0.inputURL, inside: folderSession.folderURL) }
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
        .onDrop(
            of: [UTType.fileURL.identifier],
            delegate: FileDropDelegate(
                model: model,
                validationState: $dropValidationState
            )
        )
        .onAppear {
            applyProfile(profile)
            consumeExternalOpenFiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pixelCrusherOpenFiles)) { notification in
            _ = notification
            consumeExternalOpenFiles()
        }
        .onChange(of: model.activeItemID) { _ in
            syncPunchSession()
        }
        .onChange(of: model.results.count) { _ in
            syncPunchSession()
        }
        .onChange(of: model.latestFolderDropSession) { _ in
            syncFolderSession()
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
                VStack(spacing: 0) {
                    processedListHeader

                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 14) {
                                if !visibleProcessedItems.isEmpty {
                                    ForEach(visibleProcessedItems) { result in
                                        resultRow(for: result)
                                    }
                                }

                                if let folderSession = activeFolderSession {
                                    folderSection(for: folderSession)
                                }

                                if let active = punchSession {
                                    punchSection(for: active)
                                } else if model.isQueueRunning {
                                    idleProcessingSection
                                }

                                if visibleProcessedItems.isEmpty
                                    && !model.isQueueRunning
                                    && punchSession == nil
                                    && activeFolderSession == nil {
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
                        .onChange(of: model.completedCount) { _ in
                            scrollToProcessingBottom(proxy)
                        }
                        .onChange(of: punchSession?.id) { _ in
                            scrollToProcessingBottom(proxy)
                        }
                    }
                }
                .background(Color(nsColor: colorScheme == .dark
                    ? NSColor(calibratedWhite: 0.07, alpha: 0.82)
                    : NSColor(calibratedWhite: 0.92, alpha: 0.82)
                ))
            }
        }
    }

    private var processedListHeader: some View {
        HStack {
            Text("Processed images")
                .font(.headline.weight(.semibold))
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.9) : Color.primary)

            Spacer()

            Button("Clear") {
                clearProcessedItems()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(processedItems.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Color(nsColor: colorScheme == .dark
                ? NSColor(calibratedWhite: 0.13, alpha: 0.9)
                : NSColor(calibratedWhite: 0.95, alpha: 0.9)
            )
        )
        .overlay(alignment: .bottom) {
            Divider().opacity(0.55)
        }
    }

    private func scrollToProcessingBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(processingScrollBottomID, anchor: .bottom)
            }
        }
    }

    private func consumeExternalOpenFiles() {
        let urls = ExternalOpenFilesCoordinator.shared.drain()
        guard !urls.isEmpty else {
            return
        }
        model.enqueueExternal(urls: urls)
    }

    private func clearProcessedItems() {
        let idsToDismiss = model.results
            .filter { $0.state == .done || $0.state == .failed }
            .map(\.id)

        dismissedProcessedItemIDs.formUnion(idsToDismiss)
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
        return VStack(spacing: 10) {
            PunchEffectView(inputURL: session.inputURL, cropTransform: session.cropTransform) {
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

    private func folderSection(for session: FolderDropSession) -> some View {
        let isExpanded = expandedFolderIDs.contains(session.id)
        let items = folderSessionFiles(for: session)
        let isPunching = activeFolderPunch?.id == session.id

        return VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    toggleFolderExpansion(session.id)
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 12, weight: .semibold))

                        Image(systemName: "folder.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.orange)

                        Text(session.folderURL.lastPathComponent)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.88) : Color.primary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Text("\(items.count) files")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }

            if isPunching {
                FolderPunchAnimation(folderName: session.folderURL.lastPathComponent)
                    .frame(maxWidth: 300)
                    .padding(.bottom, 2)
            } else if isExpanded {
                if items.isEmpty {
                    Text("Preparing files…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                } else {
                    VStack(spacing: 10) {
                        ForEach(items) { result in
                            folderFileRow(for: result)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: colorScheme == .dark
                    ? NSColor(calibratedWhite: 0.12, alpha: 0.92)
                    : NSColor(calibratedWhite: 0.98, alpha: 0.95)
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.14), lineWidth: 1)
        )
    }

    private func folderFileRow(for result: ProcessingResult) -> some View {
        let previewURL = processingSourceURL(for: result)
        let isTerminal = result.state.isTerminal
        let progress = progress(for: result.state)

        return VStack(spacing: 7) {
            HStack(alignment: .center, spacing: 14) {
                ResultThumbnail(url: previewURL)

                VStack(alignment: .leading, spacing: 7) {
                    Text(result.inputURL.lastPathComponent)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.86) : Color.primary)
                        .lineLimit(1)

                    if isTerminal {
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
                    } else {
                        Text(result.statusText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if isTerminal {
                    Text(resolutionText(for: result))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.65) : .secondary)
                        .frame(minWidth: 110, alignment: .trailing)
                } else {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }

                if isTerminal {
                    HStack(spacing: 8) {
                        actionGlyphButton(symbol: "crop", help: "Crop image") {
                            cropTarget = result
                            cropDraftWidth = ""
                            cropDraftHeight = ""
                            cropDraftX = "0"
                            cropDraftY = "0"
                        }

                        actionGlyphButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Resize image") {
                            resizeTarget = result
                            resizeDraftWidth = model.fixedResizeWidth
                            resizeDraftHeight = model.fixedResizeHeight
                            resizeDraftLock = true
                        }
                    }
                }

                Image(systemName: result.state == .done ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(result.state == .done ? Color.green.opacity(0.92) : Color.orange)
                    .font(.system(size: 24, weight: .medium))
                    .frame(width: 24)
            }

            if !isTerminal {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(result.state == .failed ? .red : .accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: colorScheme == .dark
                    ? NSColor(calibratedWhite: 0.17, alpha: 0.9)
                    : NSColor(calibratedWhite: 1.0, alpha: 0.98)
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.1 : 0.08), lineWidth: 1)
        )
    }

    private func resultRow(for result: ProcessingResult) -> some View {
        let previewURL = processingSourceURL(for: result)

        return HStack(alignment: .center, spacing: 14) {
            ResultThumbnail(url: previewURL)

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

            Text(resolutionText(for: result))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.65) : .secondary)
                .frame(minWidth: 110, alignment: .trailing)

            HStack(spacing: 8) {
                actionGlyphButton(symbol: "crop", help: "Crop image") {
                    cropTarget = result
                    cropDraftWidth = ""
                    cropDraftHeight = ""
                    cropDraftX = "0"
                    cropDraftY = "0"
                }

                actionGlyphButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Resize image") {
                    resizeTarget = result
                    resizeDraftWidth = model.fixedResizeWidth
                    resizeDraftHeight = model.fixedResizeHeight
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

    private func toggleFolderExpansion(_ folderID: UUID) {
        if expandedFolderIDs.contains(folderID) {
            expandedFolderIDs.remove(folderID)
        } else {
            expandedFolderIDs.insert(folderID)
        }
    }

    private func folderSessionFiles(for session: FolderDropSession) -> [ProcessingResult] {
        return activeFolderSessionFiles.filter { result in
            !dismissedProcessedItemIDs.contains(result.id) &&
            isFile(result.inputURL, inside: session.folderURL)
        }
    }

    private func isFile(_ fileURL: URL, inside folderURL: URL) -> Bool {
        let folderPath = folderURL.standardized.path
        let filePath = fileURL.standardized.path

        if folderPath.isEmpty {
            return false
        }

        if filePath == folderPath {
            return false
        }

        let folderPrefix = folderPath.hasSuffix("/") ? folderPath : "\(folderPath)/"
        return filePath.hasPrefix(folderPrefix)
    }

    private func progress(for state: ProcessingItemState) -> Double {
        switch state {
        case .queued:
            return 0.05
        case .preparing:
            return 0.28
        case .optimizing:
            return 0.67
        case .saving:
            return 0.92
        case .done:
            return 1.0
        case .failed:
            return 1.0
        }
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
        let isUnsupported = dropValidationState == .unsupported
        let tintColor = isUnsupported ? Color.red : Color.accentColor
        let title = isUnsupported ? "Unsupported format" : "Drop to crush"

        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [10]))
            .foregroundStyle(tintColor.opacity(0.8))
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tintColor.opacity(isUnsupported ? 0.2 : 0.15))
            )
            .overlay(
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: isUnsupported ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                        Text(title)
                            .fontWeight(.semibold)
                    }
                    if isUnsupported {
                        Text("Supported: \(AppViewModel.supportedFormatsLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.headline)
                .foregroundStyle(tintColor)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
            )
            .padding(30)
            .allowsHitTesting(false)
    }

    private func applyProfile(_ profile: CompressionProfile) {
        model.applyCompressionProfile(profile)
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

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else {
            return "—"
        }

        return Self.byteCountFormatter.string(fromByteCount: bytes)
    }

    private func resolutionText(for result: ProcessingResult) -> String {
        let url = processingSourceURL(for: result)
        guard let size = PixelCrusherImageLoader.orientedPixelSize(from: url) else {
            return "—"
        }
        return "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }

    private func processingSourceURL(for result: ProcessingResult) -> URL {
        result.outputURL ?? result.inputURL
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

        punchSession = PunchSession(
            id: activeID,
            inputURL: processingSourceURL(for: result),
            cropTransform: model.punchCropTransform(for: activeID)
        )
    }

    private func syncFolderSession() {
        guard let folderSession = model.consumeLatestFolderDropSession() else {
            return
        }

        activeFolderSession = folderSession
        expandedFolderIDs.insert(folderSession.id)
        activeFolderPunch = folderSession

        let folderPunchSessionID = folderSession.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            guard activeFolderPunch?.id == folderPunchSessionID else {
                return
            }
            activeFolderPunch = nil
        }
    }

    private func cropSheet(for result: ProcessingResult) -> some View {
        let sourceURL = processingSourceURL(for: result)

        return CropEditorSheet(
            sourceURL: sourceURL,
            widthText: $cropDraftWidth,
            heightText: $cropDraftHeight,
            xText: $cropDraftX,
            yText: $cropDraftY,
            onCancel: {
                cropTarget = nil
            },
            onApply: {
                if let width = Int(cropDraftWidth),
                   let height = Int(cropDraftHeight),
                   width > 0,
                   height > 0 {
                    model.enqueueCroppedImage(
                        sourceURL: sourceURL,
                        width: width,
                        height: height,
                        x: Int(cropDraftX) ?? 0,
                        y: Int(cropDraftY) ?? 0
                    )
                }
                cropTarget = nil
            }
        )
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
                    applyResizeDraft(for: result)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private func applyResizeDraft(for result: ProcessingResult) {
        let parsedWidth = Int(resizeDraftWidth)
        let parsedHeight = Int(resizeDraftHeight)

        let resolved = AspectRatioResize.resolve(
            width: parsedWidth,
            height: parsedHeight,
            lockAspectRatio: resizeDraftLock,
            sourceSize: PixelCrusherImageLoader.orientedPixelSize(from: processingSourceURL(for: result))
        )

        if parsedWidth == nil, let computedWidth = resolved.width {
            resizeDraftWidth = String(computedWidth)
        }

        if parsedHeight == nil, let computedHeight = resolved.height {
            resizeDraftHeight = String(computedHeight)
        }

        guard let width = resolved.width,
              let height = resolved.height,
              width > 0,
              height > 0 else {
            model.fixedResizeEnabled = false
            resizeTarget = nil
            return
        }

        model.fixedResizeWidth = String(width)
        model.fixedResizeHeight = String(height)
        model.fixedResizeEnabled = true
        resizeTarget = nil
    }
}
