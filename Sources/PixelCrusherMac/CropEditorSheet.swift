import SwiftUI
import AppKit
import PixelCrusherMacCore

struct CropEditorSheet: View {
    let result: ProcessingResult
    @Binding var widthText: String
    @Binding var heightText: String
    @Binding var xText: String
    @Binding var yText: String
    let onCancel: () -> Void
    let onApply: () -> Void

    @State private var previewImage: NSImage?
    @State private var sourceSize: CGSize?
    @State private var selectedPreset: CropAspectPreset = .free
    @State private var didLoadImage = false

    private var resolvedSourceSize: CGSize {
        if let sourceSize,
           sourceSize.width > 0,
           sourceSize.height > 0 {
            return sourceSize
        }

        let fallbackWidth = max(1, Int(widthText) ?? 1024)
        let fallbackHeight = max(1, Int(heightText) ?? 1024)
        return CGSize(width: fallbackWidth, height: fallbackHeight)
    }

    private var currentCropRect: CGRect {
        normalizedCropRect(
            sourceSize: resolvedSourceSize,
            widthText: widthText,
            heightText: heightText,
            xText: xText,
            yText: yText
        )
    }

    private var sourceLabel: String {
        let source = resolvedSourceSize
        return "\(Int(source.width)) × \(Int(source.height))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            CropPreviewCanvas(
                image: previewImage,
                sourceSize: resolvedSourceSize,
                cropRect: currentCropRect,
                lockedAspectRatio: selectedPreset.ratio(for: resolvedSourceSize),
                onCropRectChange: updateCropRect
            )
            .frame(height: 360)

            aspectPresetStrip

            settingsRow

            footer
        }
        .padding(18)
        .frame(width: 720)
        .onAppear(perform: loadImageIfNeeded)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Crop image")
                    .font(.title3.weight(.semibold))

                Text(result.inputURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Source: \(sourceLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Reset") {
                selectedPreset = .free
                let source = resolvedSourceSize
                updateCropRect(CGRect(origin: .zero, size: source))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var aspectPresetStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aspect ratio")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CropAspectPreset.allCases) { preset in
                        Button(preset.label) {
                            selectedPreset = preset
                            guard let ratio = preset.ratio(for: resolvedSourceSize) else {
                                return
                            }

                            let size = maxCropSize(for: ratio, within: resolvedSourceSize)
                            let x = (resolvedSourceSize.width - size.width) / 2.0
                            let y = (resolvedSourceSize.height - size.height) / 2.0
                            updateCropRect(CGRect(x: x, y: y, width: size.width, height: size.height))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(selectedPreset == preset ? .accentColor : nil)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private var settingsRow: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Dimensions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    TextField("Width", text: $widthText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)

                    Text("×")
                        .foregroundStyle(.secondary)

                    TextField("Height", text: $heightText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
            }

            Divider()
                .frame(height: 62)

            VStack(alignment: .leading, spacing: 8) {
                Text("Position")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    TextField("X", text: $xText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)

                    TextField("Y", text: $yText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
            }

            Spacer(minLength: 0)
        }

    }

    private var footer: some View {
        HStack {
            Text("Drag inside the crop box to move. Drag any corner handle to resize.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") {
                onCancel()
            }

            Button("Apply Crop") {
                let normalized = currentCropRect
                updateCropRect(normalized)
                onApply()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func loadImageIfNeeded() {
        guard !didLoadImage else {
            return
        }

        didLoadImage = true
        sourceSize = PixelCrusherImageLoader.orientedPixelSize(from: result.inputURL)
        previewImage = PixelCrusherImageLoader.orientedNSImage(from: result.inputURL)

        let normalized = currentCropRect
        updateCropRect(normalized)
        selectedPreset = CropAspectPreset.bestMatch(for: normalized.size, sourceSize: resolvedSourceSize)
    }

    private func updateCropRect(_ rect: CGRect) {
        let normalized = normalizedCropRect(
            sourceSize: resolvedSourceSize,
            widthText: String(Int(rect.width.rounded())),
            heightText: String(Int(rect.height.rounded())),
            xText: String(Int(rect.origin.x.rounded())),
            yText: String(Int(rect.origin.y.rounded()))
        )

        widthText = String(Int(normalized.width))
        heightText = String(Int(normalized.height))
        xText = String(Int(normalized.origin.x))
        yText = String(Int(normalized.origin.y))
    }
}

private struct CropPreviewCanvas: View {
    let image: NSImage?
    let sourceSize: CGSize
    let cropRect: CGRect
    let lockedAspectRatio: CGFloat?
    let onCropRectChange: (CGRect) -> Void

    @State private var moveStartRect: CGRect?
    @State private var resizeSession: CropResizeSession?
    @State private var resizeAxis: CropResizeAxis?

    var body: some View {
        GeometryReader { proxy in
            let containerRect = CGRect(origin: .zero, size: proxy.size)
            let imageRect = fittedRect(for: sourceSize, in: containerRect.insetBy(dx: 10, dy: 10))
            let cropRectInView = mapImageRectToView(cropRect, imageRect: imageRect, sourceSize: sourceSize)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                        .frame(width: imageRect.width, height: imageRect.height)
                        .overlay {
                            Label("Preview unavailable", systemImage: "photo")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .position(x: imageRect.midX, y: imageRect.midY)
                }

                CropOutsideMask(imageRect: imageRect, cropRect: cropRectInView)
                    .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))

                CropRuleOfThirds(rect: cropRectInView)
                    .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .path(in: cropRectInView)
                    .stroke(.white, lineWidth: 2)
                    .shadow(color: .black.opacity(0.35), radius: 1.5)

                Rectangle()
                    .fill(.clear)
                    .frame(width: cropRectInView.width, height: cropRectInView.height)
                    .position(x: cropRectInView.midX, y: cropRectInView.midY)
                    .contentShape(Rectangle())
                    .gesture(cropMoveGesture(imageRect: imageRect))

                ForEach(CropCornerHandle.allCases, id: \.self) { handle in
                    cropHandle(handle: handle, cropRectInView: cropRectInView, imageRect: imageRect)
                }
            }
        }
    }

    private func cropHandle(handle: CropCornerHandle, cropRectInView: CGRect, imageRect: CGRect) -> some View {
        let handlePoint = handle.point(in: cropRectInView)

        return Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .overlay {
                Circle()
                    .stroke(Color.black.opacity(0.3), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
            .position(handlePoint)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let point = imagePoint(for: value.location, imageRect: imageRect, sourceSize: sourceSize)
                        if resizeSession == nil {
                            resizeSession = CropResizeSession(startRect: cropRect, handle: handle)
                            resizeAxis = nil
                        }

                        if lockedAspectRatio != nil,
                           resizeAxis == nil {
                            let horizontal = abs(value.translation.width)
                            let vertical = abs(value.translation.height)
                            resizeAxis = horizontal >= vertical ? .horizontal : .vertical
                        }

                        guard let session = resizeSession else {
                            return
                        }

                        let nextRect = resizedRect(
                            from: session,
                            pointer: point,
                            lockedAspectRatio: lockedAspectRatio,
                            axis: resizeAxis
                        )
                        onCropRectChange(nextRect)
                    }
                    .onEnded { _ in
                        resizeSession = nil
                        resizeAxis = nil
                    }
            )
    }

    private func cropMoveGesture(imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard imageRect.width > 0, imageRect.height > 0 else {
                    return
                }

                let startRect: CGRect
                if let moveStartRect {
                    startRect = moveStartRect
                } else {
                    startRect = cropRect
                    moveStartRect = cropRect
                }

                let dx = value.translation.width * (sourceSize.width / imageRect.width)
                let dy = value.translation.height * (sourceSize.height / imageRect.height)

                let maxX = max(0, sourceSize.width - startRect.width)
                let maxY = max(0, sourceSize.height - startRect.height)

                let nextX = min(max(0, startRect.minX + dx), maxX)
                let nextY = min(max(0, startRect.minY + dy), maxY)

                onCropRectChange(CGRect(x: nextX, y: nextY, width: startRect.width, height: startRect.height))
            }
            .onEnded { _ in
                moveStartRect = nil
            }
    }

    private func resizedRect(
        from session: CropResizeSession,
        pointer: CGPoint,
        lockedAspectRatio: CGFloat?,
        axis: CropResizeAxis?
    ) -> CGRect {
        let fixed = session.handle.oppositePoint(in: session.startRect)
        let signX = session.handle.signX
        let signY = session.handle.signY

        let maxWidth = signX > 0 ? (sourceSize.width - fixed.x) : fixed.x
        let maxHeight = signY > 0 ? (sourceSize.height - fixed.y) : fixed.y

        var width = min(max(1, abs(pointer.x - fixed.x)), maxWidth)
        var height = min(max(1, abs(pointer.y - fixed.y)), maxHeight)

        if let ratio = lockedAspectRatio,
           ratio > 0 {
            switch axis {
            case .horizontal:
                height = width / ratio
            case .vertical:
                width = height * ratio
            case nil:
                height = width / ratio
            }

            if width > maxWidth {
                width = maxWidth
                height = width / ratio
            }

            if height > maxHeight {
                height = maxHeight
                width = height * ratio
            }

            width = min(max(1, width), maxWidth)
            height = min(max(1, height), maxHeight)
        }

        let movingX = fixed.x + (signX * width)
        let movingY = fixed.y + (signY * height)

        let nextRect = CGRect(
            x: min(fixed.x, movingX),
            y: min(fixed.y, movingY),
            width: abs(movingX - fixed.x),
            height: abs(movingY - fixed.y)
        )

        return clampRect(nextRect, in: sourceSize)
    }

    private func clampRect(_ rect: CGRect, in sourceSize: CGSize) -> CGRect {
        let width = min(max(1, rect.width), sourceSize.width)
        let height = min(max(1, rect.height), sourceSize.height)
        let maxX = max(0, sourceSize.width - width)
        let maxY = max(0, sourceSize.height - height)

        let x = min(max(0, rect.minX), maxX)
        let y = min(max(0, rect.minY), maxY)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func imagePoint(for location: CGPoint, imageRect: CGRect, sourceSize: CGSize) -> CGPoint {
        let x = ((location.x - imageRect.minX) / imageRect.width) * sourceSize.width
        let y = ((location.y - imageRect.minY) / imageRect.height) * sourceSize.height
        return CGPoint(
            x: min(max(0, x), sourceSize.width),
            y: min(max(0, y), sourceSize.height)
        )
    }

    private func fittedRect(for sourceSize: CGSize, in bounds: CGRect) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return .zero
        }

        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        let width = sourceSize.width * scale
        let height = sourceSize.height * scale

        return CGRect(
            x: bounds.midX - (width / 2.0),
            y: bounds.midY - (height / 2.0),
            width: width,
            height: height
        )
    }

    private func mapImageRectToView(_ imageCropRect: CGRect, imageRect: CGRect, sourceSize: CGSize) -> CGRect {
        let scaleX = imageRect.width / sourceSize.width
        let scaleY = imageRect.height / sourceSize.height

        return CGRect(
            x: imageRect.minX + (imageCropRect.minX * scaleX),
            y: imageRect.minY + (imageCropRect.minY * scaleY),
            width: imageCropRect.width * scaleX,
            height: imageCropRect.height * scaleY
        )
    }
}

private enum CropCornerHandle: CaseIterable {
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

private struct CropResizeSession {
    let startRect: CGRect
    let handle: CropCornerHandle
}

private enum CropResizeAxis {
    case horizontal
    case vertical
}

private struct CropOutsideMask: Shape {
    let imageRect: CGRect
    let cropRect: CGRect

    func path(in _: CGRect) -> Path {
        var path = Path()
        path.addRect(imageRect)
        path.addRoundedRect(in: cropRect, cornerSize: CGSize(width: 6, height: 6))
        return path
    }
}

private struct CropRuleOfThirds: Shape {
    let rect: CGRect

    func path(in _: CGRect) -> Path {
        guard rect.width > 2, rect.height > 2 else {
            return Path()
        }

        var path = Path()

        let thirdX = rect.width / 3.0
        let thirdY = rect.height / 3.0

        path.move(to: CGPoint(x: rect.minX + thirdX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + thirdX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX + (thirdX * 2.0), y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + (thirdX * 2.0), y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + thirdY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + thirdY))
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + (thirdY * 2.0)))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + (thirdY * 2.0)))

        return path
    }
}

private enum CropAspectPreset: String, CaseIterable, Identifiable {
    case free
    case original
    case square
    case fourByThree
    case threeByTwo
    case sixteenByNine
    case nineBySixteen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free:
            return "Free"
        case .original:
            return "Original"
        case .square:
            return "1:1"
        case .fourByThree:
            return "4:3"
        case .threeByTwo:
            return "3:2"
        case .sixteenByNine:
            return "16:9"
        case .nineBySixteen:
            return "9:16"
        }
    }

    func ratio(for sourceSize: CGSize) -> CGFloat? {
        switch self {
        case .free:
            return nil
        case .original:
            guard sourceSize.width > 0, sourceSize.height > 0 else {
                return nil
            }
            return sourceSize.width / sourceSize.height
        case .square:
            return 1.0
        case .fourByThree:
            return 4.0 / 3.0
        case .threeByTwo:
            return 3.0 / 2.0
        case .sixteenByNine:
            return 16.0 / 9.0
        case .nineBySixteen:
            return 9.0 / 16.0
        }
    }

    static func bestMatch(for cropSize: CGSize, sourceSize: CGSize) -> CropAspectPreset {
        guard cropSize.width > 0, cropSize.height > 0 else {
            return .free
        }

        let cropRatio = cropSize.width / cropSize.height
        let tolerance: CGFloat = 0.02

        let ranked: [CropAspectPreset] = [.original, .square, .fourByThree, .threeByTwo, .sixteenByNine, .nineBySixteen]
        for preset in ranked {
            guard let ratio = preset.ratio(for: sourceSize) else {
                continue
            }
            if abs((cropRatio / ratio) - 1.0) <= tolerance {
                return preset
            }
        }

        return .free
    }
}

private func normalizedCropRect(
    sourceSize: CGSize,
    widthText: String,
    heightText: String,
    xText: String,
    yText: String
) -> CGRect {
    let sourceW = max(1, Int(sourceSize.width.rounded()))
    let sourceH = max(1, Int(sourceSize.height.rounded()))

    let width = min(max(1, Int(widthText) ?? sourceW), sourceW)
    let height = min(max(1, Int(heightText) ?? sourceH), sourceH)

    let maxX = max(0, sourceW - width)
    let maxY = max(0, sourceH - height)

    let x = min(max(0, Int(xText) ?? 0), maxX)
    let y = min(max(0, Int(yText) ?? 0), maxY)

    return CGRect(x: x, y: y, width: width, height: height)
}

private func maxCropSize(for ratio: CGFloat, within sourceSize: CGSize) -> CGSize {
    guard ratio > 0, sourceSize.width > 0, sourceSize.height > 0 else {
        return sourceSize
    }

    let sourceRatio = sourceSize.width / sourceSize.height

    if sourceRatio > ratio {
        let height = sourceSize.height
        return CGSize(width: height * ratio, height: height)
    }

    let width = sourceSize.width
    return CGSize(width: width, height: width / ratio)
}
