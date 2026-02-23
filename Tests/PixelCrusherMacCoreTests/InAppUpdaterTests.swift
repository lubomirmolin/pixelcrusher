import Testing
import Foundation
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
}
