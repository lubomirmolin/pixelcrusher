import Foundation

public enum BundledToolingVerifier {
    public static func bundledToolsDirectory(inAppBundle appBundleURL: URL) -> URL {
        appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("BundledTools", isDirectory: true)
    }

    public static func missingRequiredTools(inAppBundle appBundleURL: URL) -> [OptimizerTool] {
        missingRequiredTools(inBundledToolsDirectory: bundledToolsDirectory(inAppBundle: appBundleURL))
    }

    public static func missingRequiredTools(inBundledToolsDirectory bundledToolsDirectory: URL) -> [OptimizerTool] {
        let fileManager = FileManager.default

        return OptimizerTool.requiredBundledTools.filter { tool in
            let path = bundledToolsDirectory
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent(tool.preferredExecutableNames[0])
                .path
            return !fileManager.isExecutableFile(atPath: path)
        }
    }
}
