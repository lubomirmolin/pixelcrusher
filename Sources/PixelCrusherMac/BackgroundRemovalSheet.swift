import SwiftUI
import AppKit
import PixelCrusherMacCore

struct BackgroundRemovalSheet: View {
    let sourceURL: URL
    let modelStatuses: [BackgroundRemovalModelStatus]
    @Binding var selectedModel: BackgroundRemovalModelVariant
    let isRunning: Bool
    let progressMessage: String?
    let errorMessage: String?
    let onCancel: () -> Void
    let onDownloadModel: (BackgroundRemovalModelVariant) -> Void
    let onQuickRemove: () -> Void
    let onFocusedRemove: (CGRect) -> Void

    @State private var previewImage: NSImage?
    @State private var sourceSize: CGSize?
    @State private var focusRect: CGRect = .zero
    @State private var useFocusRect = false
    @State private var didLoadImage = false

    private var resolvedSourceSize: CGSize {
        if let sourceSize,
           sourceSize.width > 0,
           sourceSize.height > 0 {
            return sourceSize
        }
        return CGSize(width: 1024, height: 1024)
    }

    private var resolvedFocusRect: CGRect {
        focusRect == .zero ? defaultFocusRect(for: resolvedSourceSize) : focusRect
    }

    private var selectedStatus: BackgroundRemovalModelStatus? {
        modelStatuses.first(where: { $0.model == selectedModel })
    }

    private var canRunSelectedModel: Bool {
        guard let selectedStatus else {
            return false
        }
        return selectedStatus.isInstalled && selectedStatus.suitability.isAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            modelSelector

            SubjectFocusCanvas(
                image: previewImage,
                sourceSize: resolvedSourceSize,
                focusRect: resolvedFocusRect,
                isEnabled: useFocusRect && !isRunning,
                onFocusRectChange: { focusRect = $0 }
            )
            .frame(height: 360)

            statusBlock

            Toggle("Focus on a selected subject", isOn: $useFocusRect)
                .disabled(isRunning)

            footer
        }
        .padding(18)
        .frame(width: 780)
        .onAppear(perform: loadImageIfNeeded)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Remove Background")
                    .font(.title3.weight(.semibold))

                Text(sourceURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let selectedStatus {
                    Text(modelStatusLine(for: selectedStatus))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Reset Focus") {
                focusRect = defaultFocusRect(for: resolvedSourceSize)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRunning || !useFocusRect)
        }
    }

    private var modelSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model")
                .font(.headline)

            HStack(alignment: .top, spacing: 10) {
                ForEach(modelStatuses, id: \.model) { status in
                    modelCard(for: status)
                }
            }
        }
    }

    private func modelCard(for status: BackgroundRemovalModelStatus) -> some View {
        let isSelected = status.model == selectedModel
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.model.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(status.model.shortLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                if isSelected {
                    Text("Selected")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }

            Text(status.model.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(modelStatusLine(for: status))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(status.suitability.message)
                .font(.caption2)
                .foregroundStyle(status.suitability.isAvailable ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(isSelected ? "Using" : "Select") {
                    selectedModel = status.model
                }
                .buttonStyle(.bordered)
                .disabled(isRunning || isSelected)

                if status.isInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Button("Download") {
                        selectedModel = status.model
                        onDownloadModel(status.model)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning || !status.suitability.isAvailable)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRunning else {
                return
            }
            selectedModel = status.model
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let selectedStatus {
                Text(selectedStatus.suitability.message)
                    .font(.footnote)
                    .foregroundStyle(selectedStatus.suitability.isAvailable ? Color.secondary : Color.red)
            }

            if let progressMessage, !progressMessage.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if let selectedStatus, !selectedStatus.isInstalled {
                Text("Download the selected model before running removal.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(useFocusRect ? "Everything outside the focus box will be cleared before compositing the alpha result." : "Quick remove runs RMBG on the full processed image.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") {
                onCancel()
            }
            .disabled(isRunning)

            Button("Quick Remove") {
                onQuickRemove()
            }
            .buttonStyle(.bordered)
            .disabled(isRunning || !canRunSelectedModel)

            Button("Remove Focused Subject") {
                onFocusedRemove(resolvedFocusRect)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning || !useFocusRect || !canRunSelectedModel)
        }
    }

    private func modelStatusLine(for status: BackgroundRemovalModelStatus) -> String {
        if status.isInstalled,
           let installedBytes = status.installedBytes {
            return "Installed · \(Self.byteCountFormatter.string(fromByteCount: installedBytes))"
        }

        return "Download · \(Self.byteCountFormatter.string(fromByteCount: status.downloadBytes))"
    }

    private func loadImageIfNeeded() {
        guard !didLoadImage else {
            return
        }

        didLoadImage = true
        sourceSize = PixelCrusherImageLoader.orientedPixelSize(from: sourceURL)
        previewImage = PixelCrusherImageLoader.orientedNSImage(from: sourceURL)
        focusRect = defaultFocusRect(for: resolvedSourceSize)
    }

    private func defaultFocusRect(for sourceSize: CGSize) -> CGRect {
        let insetX = sourceSize.width * 0.15
        let insetY = sourceSize.height * 0.15
        return CGRect(
            x: insetX,
            y: insetY,
            width: max(1, sourceSize.width - insetX * 2.0),
            height: max(1, sourceSize.height - insetY * 2.0)
        )
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.isAdaptive = true
        return formatter
    }()
}

private struct SubjectFocusCanvas: View {
    let image: NSImage?
    let sourceSize: CGSize
    let focusRect: CGRect
    let isEnabled: Bool
    let onFocusRectChange: (CGRect) -> Void

    @State private var moveStartRect: CGRect?
    @State private var resizeSession: FocusResizeSession?

    var body: some View {
        GeometryReader { proxy in
            let containerRect = CGRect(origin: .zero, size: proxy.size)
            let imageRect = fittedRect(for: sourceSize, in: containerRect.insetBy(dx: 10, dy: 10))
            let focusRectInView = mapImageRectToView(focusRect, imageRect: imageRect, sourceSize: sourceSize)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)
                }

                FocusOutsideMask(imageRect: imageRect, focusRect: focusRectInView)
                    .fill(.black.opacity(isEnabled ? 0.46 : 0.18), style: FillStyle(eoFill: true))

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .path(in: focusRectInView)
                    .stroke(.white, lineWidth: 2)

                Rectangle()
                    .fill(.clear)
                    .frame(width: focusRectInView.width, height: focusRectInView.height)
                    .position(x: focusRectInView.midX, y: focusRectInView.midY)
                    .contentShape(Rectangle())
                    .gesture(isEnabled ? focusMoveGesture(imageRect: imageRect) : nil)

                ForEach(FocusCornerHandle.allCases, id: \.self) { handle in
                    Circle()
                        .fill(isEnabled ? Color.white : Color.white.opacity(0.6))
                        .frame(width: 12, height: 12)
                        .position(handle.point(in: focusRectInView))
                        .gesture(isEnabled ? resizeGesture(handle: handle, imageRect: imageRect) : nil)
                }
            }
        }
    }

    private func resizeGesture(handle: FocusCornerHandle, imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = imagePoint(for: value.location, imageRect: imageRect, sourceSize: sourceSize)
                if resizeSession == nil {
                    resizeSession = FocusResizeSession(startRect: focusRect, handle: handle)
                }

                guard let resizeSession else {
                    return
                }

                let fixed = handle.oppositePoint(in: resizeSession.startRect)
                let signX = handle.signX
                let signY = handle.signY
                let movingX = fixed.x + (signX * abs(point.x - fixed.x))
                let movingY = fixed.y + (signY * abs(point.y - fixed.y))

                let nextRect = clampRect(
                    CGRect(
                        x: min(fixed.x, movingX),
                        y: min(fixed.y, movingY),
                        width: abs(movingX - fixed.x),
                        height: abs(movingY - fixed.y)
                    ),
                    in: sourceSize
                )
                onFocusRectChange(nextRect)
            }
            .onEnded { _ in
                resizeSession = nil
            }
    }

    private func focusMoveGesture(imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if moveStartRect == nil {
                    moveStartRect = focusRect
                }

                guard let moveStartRect else {
                    return
                }

                let dx = (value.translation.width / imageRect.width) * sourceSize.width
                let dy = (value.translation.height / imageRect.height) * sourceSize.height
                let nextRect = clampRect(
                    moveStartRect.offsetBy(dx: dx, dy: dy),
                    in: sourceSize
                )
                onFocusRectChange(nextRect)
            }
            .onEnded { _ in
                moveStartRect = nil
            }
    }
}

private struct FocusOutsideMask: Shape {
    let imageRect: CGRect
    let focusRect: CGRect

    func path(in _: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: imageRect, cornerSize: CGSize(width: 8, height: 8))
        path.addRoundedRect(in: focusRect, cornerSize: CGSize(width: 6, height: 6))
        return path
    }
}

private enum FocusCornerHandle: CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var signX: CGFloat {
        switch self {
        case .topLeft, .bottomLeft:
            return -1
        case .topRight, .bottomRight:
            return 1
        }
    }

    var signY: CGFloat {
        switch self {
        case .topLeft, .topRight:
            return -1
        case .bottomLeft, .bottomRight:
            return 1
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:
            return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:
            return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:
            return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight:
            return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    func oppositePoint(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:
            return CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight:
            return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft:
            return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight:
            return CGPoint(x: rect.minX, y: rect.minY)
        }
    }
}

private struct FocusResizeSession {
    let startRect: CGRect
    let handle: FocusCornerHandle
}

private func fittedRect(for size: CGSize, in bounds: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
        return bounds
    }

    let scale = min(bounds.width / size.width, bounds.height / size.height)
    let fittedSize = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(
        x: bounds.midX - fittedSize.width / 2,
        y: bounds.midY - fittedSize.height / 2,
        width: fittedSize.width,
        height: fittedSize.height
    )
}

private func mapImageRectToView(_ rect: CGRect, imageRect: CGRect, sourceSize: CGSize) -> CGRect {
    guard sourceSize.width > 0, sourceSize.height > 0 else {
        return imageRect
    }

    let scaleX = imageRect.width / sourceSize.width
    let scaleY = imageRect.height / sourceSize.height
    return CGRect(
        x: imageRect.minX + rect.minX * scaleX,
        y: imageRect.minY + rect.minY * scaleY,
        width: rect.width * scaleX,
        height: rect.height * scaleY
    )
}

private func imagePoint(for viewPoint: CGPoint, imageRect: CGRect, sourceSize: CGSize) -> CGPoint {
    guard imageRect.width > 0, imageRect.height > 0 else {
        return .zero
    }

    let relativeX = min(max(viewPoint.x - imageRect.minX, 0), imageRect.width)
    let relativeY = min(max(viewPoint.y - imageRect.minY, 0), imageRect.height)
    return CGPoint(
        x: (relativeX / imageRect.width) * sourceSize.width,
        y: (relativeY / imageRect.height) * sourceSize.height
    )
}

private func clampRect(_ rect: CGRect, in sourceSize: CGSize) -> CGRect {
    let minimumEdge: CGFloat = 8
    let width = min(max(rect.width, minimumEdge), sourceSize.width)
    let height = min(max(rect.height, minimumEdge), sourceSize.height)
    let x = min(max(rect.origin.x, 0), max(0, sourceSize.width - width))
    let y = min(max(rect.origin.y, 0), max(0, sourceSize.height - height))
    return CGRect(x: x, y: y, width: width, height: height)
}
