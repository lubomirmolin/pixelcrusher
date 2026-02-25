import Foundation
import PixelCrusherMacCore

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
