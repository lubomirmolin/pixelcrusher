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
    @State private var cropDraftAnchor: CropAnchor = .center

    @State private var resizeDraftWidth = ""
    @State private var resizeDraftHeight = ""
    @State private var resizeDraftLock = true

    @State private var dismissedProcessedItemIDs: Set<UUID> = []
    @State private var punchSession: PunchSession?
    @State private var playedPunchIDs: Set<UUID> = []
    @State private var dropValidationState: DropValidationState = .idle

    private var isEmptyState: Bool {
        processedItems.isEmpty && punchSession == nil && !model.isQueueRunning
    }

    private var showBottomHint: Bool {
        !processedItems.isEmpty || punchSession != nil || model.isQueueRunning
    }

    private var processedItems: [ProcessingResult] {
        model.results
            .filter { ($0.state == .done || $0.state == .failed) && !dismissedProcessedItemIDs.contains($0.id) }
            .sorted { lhs, rhs in
                lhs.enqueuedOrder < rhs.enqueuedOrder
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
                    model.fixedCropWidth = cropDraftWidth
                    model.fixedCropHeight = cropDraftHeight
                    model.cropAnchor = cropDraftAnchor
                    if let width = Int(cropDraftWidth),
                       let height = Int(cropDraftHeight),
                       width > 0,
                       height > 0 {
                        model.fixedCropEnabled = true
                    } else {
                        model.fixedCropEnabled = false
                    }
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
                    applyResizeDraft(for: result)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private func applyResizeDraft(for result: ProcessingResult) {
        var width = Int(resizeDraftWidth)
        var height = Int(resizeDraftHeight)

        if resizeDraftLock,
           let sourceSize = PixelCrusherImageLoader.orientedPixelSize(from: result.inputURL) {
            if width == nil, let knownHeight = height, knownHeight > 0 {
                let computedWidth = max(1, Int((CGFloat(knownHeight) * sourceSize.width / sourceSize.height).rounded()))
                width = computedWidth
                resizeDraftWidth = String(computedWidth)
            } else if height == nil, let knownWidth = width, knownWidth > 0 {
                let computedHeight = max(1, Int((CGFloat(knownWidth) * sourceSize.height / sourceSize.width).rounded()))
                height = computedHeight
                resizeDraftHeight = String(computedHeight)
            }
        }

        guard let width, let height, width > 0, height > 0 else {
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
