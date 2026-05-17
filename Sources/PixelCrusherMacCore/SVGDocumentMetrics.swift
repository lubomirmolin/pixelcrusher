import Foundation
import CoreGraphics

public enum SVGDocumentMetrics {
    private static let widthPattern = try! NSRegularExpression(pattern: #"(?i)\bwidth\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"#)
    private static let heightPattern = try! NSRegularExpression(pattern: #"(?i)\bheight\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"#)
    private static let viewBoxPattern = try! NSRegularExpression(pattern: #"(?i)\bviewBox\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"#)

    public static func canvasSize(from url: URL) -> CGSize? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return canvasSize(from: data)
    }

    public static func canvasSize(from data: Data) -> CGSize? {
        guard let openingTag = svgOpeningTag(in: data) else {
            return nil
        }

        let widthValue = attributeValue(in: openingTag, regex: widthPattern)
        let heightValue = attributeValue(in: openingTag, regex: heightPattern)
        let viewBox = parseViewBox(attributeValue(in: openingTag, regex: viewBoxPattern))

        let parsedWidth = parseLength(widthValue)
        let parsedHeight = parseLength(heightValue)

        if let parsedWidth, let parsedHeight, parsedWidth > 0, parsedHeight > 0 {
            return CGSize(width: parsedWidth, height: parsedHeight)
        }

        if let viewBox {
            if let parsedWidth, parsedWidth > 0, viewBox.width > 0, viewBox.height > 0 {
                return CGSize(width: parsedWidth, height: parsedWidth * (viewBox.height / viewBox.width))
            }

            if let parsedHeight, parsedHeight > 0, viewBox.width > 0, viewBox.height > 0 {
                return CGSize(width: parsedHeight * (viewBox.width / viewBox.height), height: parsedHeight)
            }

            if viewBox.width > 0, viewBox.height > 0 {
                return CGSize(width: viewBox.width, height: viewBox.height)
            }
        }

        return nil
    }

    private static func svgOpeningTag(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        guard let svgStart = text.range(of: "<svg", options: [.caseInsensitive]) else {
            return nil
        }

        guard let tagEnd = text[svgStart.lowerBound...].firstIndex(of: ">") else {
            return nil
        }

        return String(text[svgStart.lowerBound...tagEnd])
    }

    private static func attributeValue(in openingTag: String, regex: NSRegularExpression) -> String? {
        let nsrange = NSRange(openingTag.startIndex..<openingTag.endIndex, in: openingTag)
        guard let match = regex.firstMatch(in: openingTag, options: [], range: nsrange) else {
            return nil
        }

        for index in 1..<match.numberOfRanges {
            let capture = match.range(at: index)
            guard capture.location != NSNotFound,
                  let range = Range(capture, in: openingTag) else {
                continue
            }
            return String(openingTag[range])
        }

        return nil
    }

    private static func parseLength(_ raw: String?) -> CGFloat? {
        guard var raw else {
            return nil
        }

        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.hasSuffix("%") else {
            return nil
        }

        let scanner = Scanner(string: raw)
        scanner.charactersToBeSkipped = .whitespacesAndNewlines
        guard let value = scanner.scanDouble() else {
            return nil
        }

        let unit = raw[scanner.currentIndex...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scale: CGFloat
        switch unit {
        case "", "px":
            scale = 1
        case "pt":
            scale = 96.0 / 72.0
        case "pc":
            scale = 16.0
        case "mm":
            scale = 96.0 / 25.4
        case "cm":
            scale = 96.0 / 2.54
        case "in":
            scale = 96.0
        default:
            return nil
        }

        let resolved = CGFloat(value) * scale
        return resolved.isFinite && resolved > 0 ? resolved : nil
    }

    private static func parseViewBox(_ raw: String?) -> CGRect? {
        guard let raw else {
            return nil
        }

        let parts = raw
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .compactMap { Double($0) }

        guard parts.count == 4,
              parts[2] > 0,
              parts[3] > 0 else {
            return nil
        }

        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}
