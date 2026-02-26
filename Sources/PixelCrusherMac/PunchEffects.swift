import SwiftUI
import AppKit
import Foundation
import ImageIO
import CoreImage
import PixelCrusherMacCore

struct PunchSession: Equatable {
    let id: UUID
    let inputURL: URL
    let cropTransform: PunchCropTransform?
}

struct ResultThumbnail: View {
    let url: URL

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.08))
            .overlay {
                if let image = PixelCrusherImageLoader.orientedNSImage(from: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                } else {
                    ZStack {
                        Color.secondary.opacity(0.15)
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 74, height: 74)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.12), lineWidth: 1)
            )
    }
}

struct PunchEffectView: View {
    let inputURL: URL
    let cropTransform: PunchCropTransform?
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
            animator = PunchAnimator(inputURL: inputURL, cropTransform: cropTransform)
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

    init(inputURL: URL, cropTransform: PunchCropTransform?) {
        self.sampler = PunchColorSampler(fileURL: inputURL, cropTransform: cropTransform)
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
            let initialImageHold: TimeInterval = 0.18
            let pixelRampDuration = max(0.001, 1.0 - initialImageHold)

            let pixelSize: CGFloat
            if elapsed <= initialImageHold {
                pixelSize = 1
            } else {
                let rampProgress = min(1, max(0, CGFloat((elapsed - initialImageHold) / pixelRampDuration)))
                let easedProgress = pow(rampProgress, 1.2)
                pixelSize = 1 + easedProgress * 7
            }

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
    private let sampleOriginX: Int
    private let sampleOriginY: Int
    private let sampleWidth: Int
    private let sampleHeight: Int
    private let rgba: [UInt8]
    var aspectRatio: CGFloat {
        guard sampleHeight > 0 else { return 1 }
        return CGFloat(sampleWidth) / CGFloat(sampleHeight)
    }

    init?(fileURL: URL, cropTransform: PunchCropTransform?) {
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

        let sampleRect = Self.resolvedSampleRect(
            imageWidth: width,
            imageHeight: height,
            cropTransform: cropTransform
        )
        self.sampleOriginX = sampleRect.origin.x
        self.sampleOriginY = sampleRect.origin.y
        self.sampleWidth = sampleRect.size.width
        self.sampleHeight = sampleRect.size.height
    }

    func color(atNormalizedX x: CGFloat, y: CGFloat) -> Color {
        let clampedX = min(max(x, 0), 1)
        let clampedY = min(max(y, 0), 1)

        let px = sampleOriginX + Int(clampedX * CGFloat(max(sampleWidth - 1, 0)))
        let py = sampleOriginY + Int(clampedY * CGFloat(max(sampleHeight - 1, 0)))
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

    private static func resolvedSampleRect(
        imageWidth: Int,
        imageHeight: Int,
        cropTransform: PunchCropTransform?
    ) -> (origin: (x: Int, y: Int), size: (width: Int, height: Int)) {
        guard let cropTransform else {
            return (
                origin: (x: 0, y: 0),
                size: (width: max(1, imageWidth), height: max(1, imageHeight))
            )
        }

        let width = min(max(1, cropTransform.width), max(1, imageWidth))
        let height = min(max(1, cropTransform.height), max(1, imageHeight))
        let maxX = max(0, imageWidth - width)
        let maxY = max(0, imageHeight - height)

        let originX: Int
        let originY: Int

        if let x = cropTransform.x, let y = cropTransform.y {
            originX = min(max(0, x), maxX)
            originY = min(max(0, y), maxY)
        } else {
            switch cropTransform.anchor {
            case .center:
                originX = maxX / 2
                originY = maxY / 2
            case .topLeft:
                originX = 0
                originY = 0
            case .topRight:
                originX = maxX
                originY = 0
            case .bottomLeft:
                originX = 0
                originY = maxY
            case .bottomRight:
                originX = maxX
                originY = maxY
            }
        }

        return (
            origin: (x: originX, y: originY),
            size: (width: width, height: height)
        )
    }
}

enum PixelCrusherImageLoader {
    static func orientedPixelSize(from url: URL) -> CGSize? {
        guard let cgImage = orientedCGImage(from: url) else {
            return nil
        }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }

    static func orientedNSImage(from url: URL) -> NSImage? {
        guard let cgImage = orientedCGImage(from: url) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func orientedCGImage(from url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
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
