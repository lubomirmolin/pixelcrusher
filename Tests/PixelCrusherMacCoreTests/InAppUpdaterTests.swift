import Testing
import Foundation
import CryptoKit
@testable import PixelCrusherMacCore

struct InAppUpdaterTests {
    @Test("Updater state machine transitions through check/download/install flow")
    func stateMachineFlow() {
        var machine = InAppUpdaterStateMachine()

        machine.apply(.startChecking)
        #expect(machine.state == .checking)

        machine.apply(.setUpdateAvailable(latestVersion: "1.3.0"))
        #expect(machine.state == .updateAvailable(latestVersion: "1.3.0"))

        machine.apply(.setDownloadProgress(0.42))
        #expect(machine.state == .downloading(progress: 0.42))

        machine.apply(.startInstalling)
        #expect(machine.state == .installing)

        machine.apply(.setRelaunching)
        #expect(machine.state == .relaunching)
    }

    @Test("Install planner targets /Applications when app is not already there")
    func plannerUsesApplicationsPathFallback() {
        let planner = InAppUpdaterInstallPlanner()
        let current = URL(fileURLWithPath: "/Users/dev/Downloads/PixelCrusher.app", isDirectory: true)

        let target = planner.targetApplicationURL(currentAppBundleURL: current, appName: "PixelCrusher")
        #expect(target.path == "/Applications/PixelCrusher.app")
    }

    @Test("Helper invocation includes deterministic argument contract")
    func helperArgsContract() {
        let config = UpdaterHelperConfiguration(
            waitingForPID: 4321,
            assetURL: URL(fileURLWithPath: "/tmp/PixelCrusher.zip"),
            assetKind: .zip,
            targetAppURL: URL(fileURLWithPath: "/Applications/PixelCrusher.app", isDirectory: true),
            expectedBundleIdentifier: "com.lubo.pixelcrusher",
            appName: "PixelCrusher"
        )

        let args = UpdaterHelperBuilder.arguments(for: config)
        #expect(args.contains("--pid"))
        #expect(args.contains("4321"))
        #expect(args.contains("--asset"))
        #expect(args.contains("/tmp/PixelCrusher.zip"))
        #expect(args.contains("--target-app"))
        #expect(args.contains("/Applications/PixelCrusher.app"))
        #expect(args.contains("--bundle-id"))
        #expect(args.contains("com.lubo.pixelcrusher"))
    }

    @Test("Helper script includes rollback path for failed swap")
    func helperScriptContainsRollback() {
        let script = UpdaterHelperBuilder.scriptContents()

        #expect(script.contains("rollback_install"))
        #expect(script.contains("mv \"$BACKUP_APP\" \"$TARGET_APP\" || true"))
        #expect(script.contains("mv \"$TARGET_APP\" \"$BACKUP_APP\""))
    }

    @Test("Prepare install rejects non-newer release results")
    func prepareInstallRejectsEqualVersionResult() async {
        let release = GitHubRelease(
            tagName: "v0.1.2",
            name: "PixelCrusher 0.1.2",
            body: nil,
            htmlURL: URL(string: "https://github.com/lubomirmolin/pixelcrusher/releases/tag/v0.1.2")!,
            assets: []
        )

        let result = UpdateCheckResult(
            currentVersion: SemanticVersion(parsing: "0.1.2")!,
            latestVersion: SemanticVersion(parsing: "0.1.2")!,
            release: release,
            preferredAsset: nil,
            downloadURL: nil
        )

        let updater = makeUpdater(session: .shared)

        var thrownError: InAppUpdaterError?
        do {
            _ = try await updater.prepareAndLaunchInstall(
                from: result,
                currentAppBundleURL: URL(fileURLWithPath: "/Applications/PixelCrusher.app", isDirectory: true)
            )
        } catch let error as InAppUpdaterError {
            thrownError = error
        } catch {
            #expect(Bool(false))
        }

        guard let thrownError else {
            #expect(Bool(false))
            return
        }

        if case .noUpdateAvailable = thrownError {
            #expect(Bool(true))
        } else {
            #expect(Bool(false))
        }
    }

    @Test("Digest verification succeeds when metadata checksum matches download")
    func digestVerificationSuccess() async throws {
        let payload = Data("pixelcrusher".utf8)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-digest-success-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let downloadedAsset = tempDir.appendingPathComponent("PixelCrusher.zip")
        try payload.write(to: downloadedAsset)

        let updater = makeUpdater(session: .shared)
        let asset = GitHubReleaseAsset(
            name: "PixelCrusher.zip",
            browserDownloadURL: URL(string: "https://github.com/lubomirmolin/pixelcrusher/releases/download/v0.1.2/PixelCrusher.zip")!,
            contentType: "application/zip",
            digest: "sha256:\(digest)"
        )

        try await updater.verifyDownloadedAssetDigest(asset: asset, downloadedAssetURL: downloadedAsset)
    }

    @Test("Digest verification fails on checksum mismatch")
    func digestVerificationMismatch() async throws {
        let payload = Data("pixelcrusher".utf8)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-digest-mismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let downloadedAsset = tempDir.appendingPathComponent("PixelCrusher.zip")
        try payload.write(to: downloadedAsset)

        let updater = makeUpdater(session: .shared)
        let asset = GitHubReleaseAsset(
            name: "PixelCrusher.zip",
            browserDownloadURL: URL(string: "https://github.com/lubomirmolin/pixelcrusher/releases/download/v0.1.2/PixelCrusher.zip")!,
            contentType: "application/zip",
            digest: "sha256:\(String(repeating: "0", count: 64))"
        )

        var thrownError: InAppUpdaterError?
        do {
            try await updater.verifyDownloadedAssetDigest(asset: asset, downloadedAssetURL: downloadedAsset)
        } catch let error as InAppUpdaterError {
            thrownError = error
        } catch {
            #expect(Bool(false))
        }

        guard let thrownError else {
            #expect(Bool(false))
            return
        }

        if case .digestMismatch = thrownError {
            #expect(Bool(true))
        } else {
            #expect(Bool(false))
        }
    }

    @Test("Digest verification fails when no metadata or companion checksum exists")
    func digestVerificationMissingHashPolicy() async throws {
        let payload = Data("pixelcrusher".utf8)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelcrusher-digest-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let downloadedAsset = tempDir.appendingPathComponent("PixelCrusher.zip")
        try payload.write(to: downloadedAsset)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Always404URLProtocol.self]
        let session = URLSession(configuration: config)

        let updater = makeUpdater(session: session)
        let asset = GitHubReleaseAsset(
            name: "PixelCrusher.zip",
            browserDownloadURL: URL(string: "https://github.com/lubomirmolin/pixelcrusher/releases/download/v0.1.2/PixelCrusher.zip")!,
            contentType: "application/zip",
            digest: nil
        )

        var thrownError: InAppUpdaterError?
        do {
            try await updater.verifyDownloadedAssetDigest(asset: asset, downloadedAssetURL: downloadedAsset)
        } catch let error as InAppUpdaterError {
            thrownError = error
        } catch {
            #expect(Bool(false))
        }

        guard let thrownError else {
            #expect(Bool(false))
            return
        }

        if case .missingDigest(let assetName) = thrownError {
            #expect(assetName == "PixelCrusher.zip")
        } else {
            #expect(Bool(false))
        }
    }

    private func makeUpdater(session: URLSession) -> GitHubInAppUpdater {
        let configuration = UpdateRepositoryConfiguration(
            owner: "lubomirmolin",
            repo: "pixelcrusher",
            appName: "PixelCrusher",
            bundleIdentifier: "com.lubo.pixelcrusher",
            releasesPageURL: URL(string: "https://github.com/lubomirmolin/pixelcrusher/releases")!,
            authToken: nil
        )

        return GitHubInAppUpdater(configuration: configuration, session: session)
    }
}

private final class Always404URLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
