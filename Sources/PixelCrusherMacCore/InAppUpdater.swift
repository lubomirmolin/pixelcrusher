import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum InAppUpdaterState: Equatable, Sendable {
    case idle
    case checking
    case updateAvailable(latestVersion: String)
    case upToDate(currentVersion: String)
    case downloading(progress: Double?)
    case installing
    case relaunching
    case failed(reason: String)
}

public enum InAppUpdaterEvent: Sendable {
    case startChecking
    case setUpdateAvailable(latestVersion: String)
    case setUpToDate(currentVersion: String)
    case setDownloadProgress(Double?)
    case startInstalling
    case setRelaunching
    case fail(String)
    case reset
}

public struct InAppUpdaterStateMachine: Sendable {
    public private(set) var state: InAppUpdaterState = .idle

    public init() {}

    public mutating func apply(_ event: InAppUpdaterEvent) {
        switch event {
        case .startChecking:
            state = .checking
        case .setUpdateAvailable(let latestVersion):
            state = .updateAvailable(latestVersion: latestVersion)
        case .setUpToDate(let currentVersion):
            state = .upToDate(currentVersion: currentVersion)
        case .setDownloadProgress(let progress):
            state = .downloading(progress: progress)
        case .startInstalling:
            state = .installing
        case .setRelaunching:
            state = .relaunching
        case .fail(let reason):
            state = .failed(reason: reason)
        case .reset:
            state = .idle
        }
    }
}

public enum UpdateAssetKind: String, Sendable {
    case zip
    case dmg
    case pkg
    case unsupported

    public static func infer(from assetName: String) -> UpdateAssetKind {
        let lowered = assetName.lowercased()
        if lowered.hasSuffix(".zip") { return .zip }
        if lowered.hasSuffix(".dmg") { return .dmg }
        if lowered.hasSuffix(".pkg") { return .pkg }
        return .unsupported
    }
}

public struct UpdateRepositoryConfiguration: Sendable {
    public let owner: String
    public let repo: String
    public let appName: String
    public let bundleIdentifier: String
    public let releasesPageURL: URL
    public let authToken: String?

    public init(
        owner: String,
        repo: String,
        appName: String,
        bundleIdentifier: String,
        releasesPageURL: URL,
        authToken: String? = nil
    ) {
        self.owner = owner
        self.repo = repo
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.releasesPageURL = releasesPageURL
        self.authToken = authToken?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct InAppUpdaterInstallPlanner: Sendable {
    public init() {}

    public func targetApplicationURL(currentAppBundleURL: URL, appName: String) -> URL {
        let standardized = currentAppBundleURL.standardizedFileURL
        if standardized.path.hasPrefix("/Applications/"), standardized.pathExtension.lowercased() == "app" {
            return standardized
        }

        return URL(fileURLWithPath: "/Applications/\(appName).app", isDirectory: true)
    }

    public func preferredInstallableAsset(from release: GitHubRelease) -> GitHubReleaseAsset? {
        release.preferredAsset(for: .macOS)
    }
}

public struct UpdaterSwapPlan: Equatable, Sendable {
    public let targetAppURL: URL
    public let stagingAppURL: URL
    public let backupAppURL: URL

    public init(targetAppURL: URL, stagingAppURL: URL, backupAppURL: URL) {
        self.targetAppURL = targetAppURL
        self.stagingAppURL = stagingAppURL
        self.backupAppURL = backupAppURL
    }
}

public struct UpdaterHelperConfiguration: Sendable {
    public let waitingForPID: Int32
    public let assetURL: URL
    public let assetKind: UpdateAssetKind
    public let targetAppURL: URL
    public let expectedBundleIdentifier: String
    public let appName: String

    public init(
        waitingForPID: Int32,
        assetURL: URL,
        assetKind: UpdateAssetKind,
        targetAppURL: URL,
        expectedBundleIdentifier: String,
        appName: String
    ) {
        self.waitingForPID = waitingForPID
        self.assetURL = assetURL
        self.assetKind = assetKind
        self.targetAppURL = targetAppURL
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.appName = appName
    }
}

public struct UpdaterHelperInvocation: Sendable, Equatable {
    public let executableURL: URL
    public let arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }
}

public enum UpdaterHelperBuilder {
    public static func arguments(for config: UpdaterHelperConfiguration) -> [String] {
        [
            "--pid", String(config.waitingForPID),
            "--asset", config.assetURL.path,
            "--asset-kind", config.assetKind.rawValue,
            "--target-app", config.targetAppURL.path,
            "--bundle-id", config.expectedBundleIdentifier,
            "--app-name", config.appName
        ]
    }

    public static func scriptContents() -> String {
        #"""
#!/bin/bash
set -euo pipefail

PID=""
ASSET_PATH=""
ASSET_KIND=""
TARGET_APP=""
EXPECTED_BUNDLE_ID=""
APP_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid)
      PID="$2"
      shift 2
      ;;
    --asset)
      ASSET_PATH="$2"
      shift 2
      ;;
    --asset-kind)
      ASSET_KIND="$2"
      shift 2
      ;;
    --target-app)
      TARGET_APP="$2"
      shift 2
      ;;
    --bundle-id)
      EXPECTED_BUNDLE_ID="$2"
      shift 2
      ;;
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$PID" || -z "$ASSET_PATH" || -z "$ASSET_KIND" || -z "$TARGET_APP" || -z "$EXPECTED_BUNDLE_ID" || -z "$APP_NAME" ]]; then
  echo "Missing required updater arguments" >&2
  exit 2
fi

TARGET_PARENT="$(dirname "$TARGET_APP")"
if [[ ! -w "$TARGET_PARENT" ]]; then
  echo "No write permission to $TARGET_PARENT. Move PixelCrusher to ~/Applications or update manually." >&2
  exit 3
fi

for _ in {1..900}; do
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  sleep 0.2
done

if kill -0 "$PID" 2>/dev/null; then
  echo "Timed out waiting for app process $PID to exit" >&2
  exit 4
fi

WORK_DIR="$(mktemp -d /tmp/pixelcrusher-updater.XXXXXX)"
MOUNT_POINT=""
SOURCE_ROOT=""
SOURCE_APP=""
STAGING_APP="$TARGET_PARENT/.${APP_NAME}.incoming.$$"
BACKUP_APP="$TARGET_PARENT/.${APP_NAME}.backup.$$"

cleanup() {
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}

rollback_install() {
  if [[ -d "$BACKUP_APP" && ! -e "$TARGET_APP" ]]; then
    mv "$BACKUP_APP" "$TARGET_APP" || true
  fi
}

fail() {
  local message="$1"
  rollback_install
  echo "$message" >&2
  cleanup
  exit 5
}

case "$ASSET_KIND" in
  zip)
    SOURCE_ROOT="$WORK_DIR/unpacked"
    mkdir -p "$SOURCE_ROOT"
    ditto -x -k "$ASSET_PATH" "$SOURCE_ROOT" || fail "Failed to extract ZIP update payload"
    ;;
  dmg)
    SOURCE_ROOT="$WORK_DIR/mounted"
    attach_output="$(hdiutil attach "$ASSET_PATH" -nobrowse -readonly 2>/dev/null)" || fail "Failed to mount DMG update payload"
    MOUNT_POINT="$(echo "$attach_output" | sed -n 's|^.*\t||p' | tail -n 1)"
    if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
      fail "Mounted DMG has no mount point"
    fi
    SOURCE_ROOT="$MOUNT_POINT"
    ;;
  *)
    fail "Unsupported update asset format: $ASSET_KIND"
    ;;
esac

SOURCE_APP="$(find "$SOURCE_ROOT" -maxdepth 4 -type d -name '*.app' | head -n 1)"
if [[ -z "$SOURCE_APP" || ! -d "$SOURCE_APP" ]]; then
  fail "Update payload did not contain an app bundle"
fi

ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$ACTUAL_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  fail "Bundle identifier mismatch: expected $EXPECTED_BUNDLE_ID but found $ACTUAL_BUNDLE_ID"
fi

rm -rf "$STAGING_APP" "$BACKUP_APP"

ditto "$SOURCE_APP" "$STAGING_APP" || fail "Failed to stage updated app bundle"

if [[ -e "$TARGET_APP" ]]; then
  mv "$TARGET_APP" "$BACKUP_APP" || fail "Failed to backup existing app bundle"
fi

if ! mv "$STAGING_APP" "$TARGET_APP"; then
  fail "Failed to move updated app bundle into /Applications"
fi

rm -rf "$BACKUP_APP"
xattr -dr com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1 || true
open "$TARGET_APP" >/dev/null 2>&1 || fail "Updated app installed but relaunch failed"

cleanup
exit 0
"""#
    }

    public static func buildInvocation(
        config: UpdaterHelperConfiguration,
        fileManager: FileManager = .default
    ) throws -> UpdaterHelperInvocation {
        let scriptDirectory = fileManager.temporaryDirectory.appendingPathComponent("pixelcrusher-updater", isDirectory: true)
        try fileManager.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)

        let scriptURL = scriptDirectory
            .appendingPathComponent("run-update-\(UUID().uuidString)")
            .appendingPathExtension("sh")

        try scriptContents().write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        return UpdaterHelperInvocation(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptURL.path] + arguments(for: config)
        )
    }
}

public enum InAppUpdaterInstallProgress: Equatable, Sendable {
    case downloading(Double?)
    case installing
    case relaunching
}

public enum InAppUpdaterError: LocalizedError {
    case noUpdateAvailable
    case missingInstallableAsset
    case unsupportedAsset(name: String)
    case untrustedAssetURL(URL)
    case downloadFailed(String)
    case digestMismatch(expected: String, actual: String)
    case destinationNotWritable(path: String)
    case helperLaunchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noUpdateAvailable:
            return "No newer release is available."
        case .missingInstallableAsset:
            return "Latest release has no installable macOS asset (expected .zip or .dmg)."
        case .unsupportedAsset(let name):
            return "Updater does not support this release asset format: \(name)."
        case .untrustedAssetURL(let url):
            return "Refusing to download update from untrusted URL: \(url.absoluteString)"
        case .downloadFailed(let message):
            return "Failed to download update asset: \(message)"
        case .digestMismatch(let expected, let actual):
            return "Downloaded update checksum mismatch (expected \(expected), got \(actual))."
        case .destinationNotWritable(let path):
            return "Cannot write to \(path). Move PixelCrusher to ~/Applications or update manually."
        case .helperLaunchFailed(let message):
            return "Failed to launch updater helper: \(message)"
        }
    }
}

public struct GitHubInAppUpdater: Sendable {
    public let configuration: UpdateRepositoryConfiguration

    private let checker: GitHubReleaseUpdateChecker
    private let planner: InAppUpdaterInstallPlanner
    private let session: URLSession

    public init(
        configuration: UpdateRepositoryConfiguration,
        checker: GitHubReleaseUpdateChecker? = nil,
        planner: InAppUpdaterInstallPlanner = InAppUpdaterInstallPlanner(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
        self.planner = planner

        if let checker {
            self.checker = checker
        } else {
            let client = GitHubReleaseClient(session: session, authToken: configuration.authToken)
            self.checker = GitHubReleaseUpdateChecker(owner: configuration.owner, repo: configuration.repo, client: client)
        }
    }

    public func checkForUpdates(currentVersion: String) async throws -> UpdateCheckResult {
        try await checker.checkForUpdate(currentVersionString: currentVersion, platform: .macOS)
    }

    @discardableResult
    public func prepareAndLaunchInstall(
        from result: UpdateCheckResult,
        currentAppBundleURL: URL,
        waitingForPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        progress: (@Sendable (InAppUpdaterInstallProgress) -> Void)? = nil
    ) async throws -> URL {
        guard result.isUpdateAvailable else {
            throw InAppUpdaterError.noUpdateAvailable
        }

        guard let asset = planner.preferredInstallableAsset(from: result.release) else {
            throw InAppUpdaterError.missingInstallableAsset
        }

        let assetKind = UpdateAssetKind.infer(from: asset.name)
        guard assetKind == .zip || assetKind == .dmg else {
            throw InAppUpdaterError.unsupportedAsset(name: asset.name)
        }

        guard Self.isTrustedReleaseAssetURL(asset.browserDownloadURL, owner: configuration.owner, repo: configuration.repo) else {
            throw InAppUpdaterError.untrustedAssetURL(asset.browserDownloadURL)
        }

        let targetAppURL = planner.targetApplicationURL(currentAppBundleURL: currentAppBundleURL, appName: configuration.appName)
        try ensureWritableDestination(targetAppURL: targetAppURL)

        progress?(.downloading(0))
        let downloadedAssetURL = try await downloadAsset(asset: asset) { fraction in
            progress?(.downloading(fraction))
        }

        try verifyDigestIfPresent(asset: asset, downloadedAssetURL: downloadedAssetURL)

        progress?(.installing)

        let helperConfig = UpdaterHelperConfiguration(
            waitingForPID: waitingForPID,
            assetURL: downloadedAssetURL,
            assetKind: assetKind,
            targetAppURL: targetAppURL,
            expectedBundleIdentifier: configuration.bundleIdentifier,
            appName: configuration.appName
        )

        let invocation = try UpdaterHelperBuilder.buildInvocation(config: helperConfig, fileManager: .default)
        try launchHelper(invocation)

        progress?(.relaunching)
        return targetAppURL
    }

    private static func isTrustedReleaseAssetURL(_ url: URL, owner: String, repo: String) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }

        if host == "github.com" {
            return url.path.contains("/\(owner)/\(repo)/releases/download/")
        }

        if host == "objects.githubusercontent.com" || host == "github-releases.githubusercontent.com" {
            return true
        }

        return false
    }

    private func ensureWritableDestination(targetAppURL: URL) throws {
        let parent = targetAppURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw InAppUpdaterError.destinationNotWritable(path: parent.path)
        }
    }

    private func launchHelper(_ invocation: UpdaterHelperInvocation) throws {
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments

        do {
            try process.run()
        } catch {
            throw InAppUpdaterError.helperLaunchFailed(error.localizedDescription)
        }
    }

    private func downloadAsset(
        asset: GitHubReleaseAsset,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("PixelCrusher-InAppUpdater", forHTTPHeaderField: "User-Agent")
        if let token = configuration.authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw InAppUpdaterError.downloadFailed("Invalid HTTP response")
            }

            guard (200..<300).contains(http.statusCode) else {
                throw InAppUpdaterError.downloadFailed("HTTP \(http.statusCode)")
            }

            if let responseURL = http.url,
               !Self.isTrustedReleaseAssetURL(responseURL, owner: configuration.owner, repo: configuration.repo) {
                throw InAppUpdaterError.untrustedAssetURL(responseURL)
            }

            let fileManager = FileManager.default
            let destinationDir = fileManager.temporaryDirectory
                .appendingPathComponent("pixelcrusher-updater")
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)

            let destinationURL = destinationDir.appendingPathComponent(asset.name)
            fileManager.createFile(atPath: destinationURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: destinationURL)
            defer {
                try? output.close()
            }

            let expectedLength = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            var receivedBytes: Int64 = 0
            var buffer = Data()
            var iterator = bytes.makeAsyncIterator()

            while let byte = try await iterator.next() {
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try output.write(contentsOf: buffer)
                    receivedBytes += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if let expectedLength {
                        progress(min(1, Double(receivedBytes) / Double(expectedLength)))
                    } else {
                        progress(nil)
                    }
                }
            }

            if !buffer.isEmpty {
                try output.write(contentsOf: buffer)
                receivedBytes += Int64(buffer.count)
            }

            if let expectedLength {
                progress(min(1, Double(receivedBytes) / Double(expectedLength)))
            } else {
                progress(1)
            }

            return destinationURL
        } catch let error as InAppUpdaterError {
            throw error
        } catch {
            throw InAppUpdaterError.downloadFailed(error.localizedDescription)
        }
    }

    private func verifyDigestIfPresent(asset: GitHubReleaseAsset, downloadedAssetURL: URL) throws {
        guard let digest = asset.digest?.trimmingCharacters(in: .whitespacesAndNewlines),
              digest.lowercased().hasPrefix("sha256:") else {
            return
        }

        let expected = String(digest.dropFirst("sha256:".count)).lowercased()
        let data = try Data(contentsOf: downloadedAssetURL)
        let actual = SHA256.hash(data: data).hexString

        guard actual == expected else {
            throw InAppUpdaterError.digestMismatch(expected: expected, actual: actual)
        }
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
