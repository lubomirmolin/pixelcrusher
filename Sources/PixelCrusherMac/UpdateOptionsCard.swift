import SwiftUI
import AppKit
import PixelCrusherMacCore

struct UpdateRepositorySettings {
    let owner: String
    let repo: String
    let bundleIdentifier: String
    let appName: String

    var releasesPageURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases")!
    }

    static func fromBundle(_ bundle: Bundle) -> UpdateRepositorySettings {
        let defaults = UpdateRepositorySettings(
            owner: "lubomirmolin",
            repo: "pixelcrusher",
            bundleIdentifier: "com.lubo.pixelcrusher",
            appName: "PixelCrusher"
        )

        func value(for key: String) -> String? {
            guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else {
                return nil
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return UpdateRepositorySettings(
            owner: value(for: "PixelCrusherGitHubOwner") ?? defaults.owner,
            repo: value(for: "PixelCrusherGitHubRepo") ?? defaults.repo,
            bundleIdentifier: value(for: "PixelCrusherBundleIdentifier") ?? defaults.bundleIdentifier,
            appName: value(for: "PixelCrusherAppName") ?? defaults.appName
        )
    }
}

@MainActor
final class UpdateCheckViewModel: ObservableObject {
    @Published private(set) var state: InAppUpdaterState = .idle
    @Published private(set) var latestVersion: String?
    @Published private(set) var releaseNotes: String?

    private let repository: UpdateRepositorySettings
    private let currentVersionProvider: () -> String
    private var latestCheckResult: UpdateCheckResult?
    private var stateMachine = InAppUpdaterStateMachine()

    init(
        repository: UpdateRepositorySettings = .fromBundle(.main),
        currentVersionProvider: @escaping () -> String = {
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        }
    ) {
        self.repository = repository
        self.currentVersionProvider = currentVersionProvider
    }

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    var isInstalling: Bool {
        switch state {
        case .downloading, .installing, .relaunching:
            return true
        default:
            return false
        }
    }

    var canInstall: Bool {
        if case .updateAvailable = state {
            return latestCheckResult?.isUpdateAvailable == true
                && latestCheckResult?.preferredAsset != nil
        }
        return false
    }

    var stateMessage: String {
        switch state {
        case .idle:
            return "Manual update checks only."
        case .checking:
            return "Checking GitHub releases…"
        case .updateAvailable(let latestVersion):
            return "Update available: \(latestVersion)."
        case .upToDate(let currentVersion):
            return "You're up to date (\(currentVersion))."
        case .downloading(let progress):
            if let progress {
                return "Downloading update: \(Int((progress * 100).rounded()))%"
            }
            return "Downloading update…"
        case .installing:
            return "Preparing installation…"
        case .relaunching:
            return "Installing and relaunching PixelCrusher…"
        case .failed(let reason):
            return reason
        }
    }

    var showOpenReleasesFallback: Bool {
        if case .failed = state { return true }
        if case .updateAvailable = state {
            return latestCheckResult?.preferredAsset == nil
        }
        return false
    }

    func checkForUpdates() {
        guard !isChecking, !isInstalling else { return }
        transition(.startChecking)

        Task {
            do {
                let updater = makeUpdater()
                let result = try await updater.checkForUpdates(currentVersion: currentVersionProvider())

                if result.isUpdateAvailable {
                    latestCheckResult = result
                    latestVersion = result.latestVersion.description
                    releaseNotes = result.release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
                    transition(.setUpdateAvailable(latestVersion: result.latestVersion.description))
                } else {
                    latestCheckResult = nil
                    latestVersion = nil
                    releaseNotes = nil
                    transition(.setUpToDate(currentVersion: result.currentVersion.description))
                }
            } catch {
                latestCheckResult = nil
                latestVersion = nil
                releaseNotes = nil
                transition(.fail(checkErrorMessage(for: error)))
            }
        }
    }

    func installUpdate() {
        guard !isInstalling,
              let latestCheckResult,
              latestCheckResult.isUpdateAvailable else {
            return
        }

        Task {
            do {
                let updater = makeUpdater()
                _ = try await updater.prepareAndLaunchInstall(
                    from: latestCheckResult,
                    currentAppBundleURL: Bundle.main.bundleURL
                ) { [weak self] stage in
                    Task { @MainActor [weak self] in
                        self?.consumeInstallProgress(stage)
                    }
                }

                transition(.setRelaunching)
                NSApplication.shared.terminate(nil)
            } catch {
                transition(.fail(error.localizedDescription))
            }
        }
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(repository.releasesPageURL)
    }

    private func consumeInstallProgress(_ stage: InAppUpdaterInstallProgress) {
        switch stage {
        case .downloading(let fraction):
            transition(.setDownloadProgress(fraction))
        case .installing:
            transition(.startInstalling)
        case .relaunching:
            transition(.setRelaunching)
        }
    }

    private func transition(_ event: InAppUpdaterEvent) {
        stateMachine.apply(event)
        state = stateMachine.state
    }

    private func makeUpdater() -> GitHubInAppUpdater {
        let authToken = GitHubTokenResolver.resolve()
        let configuration = UpdateRepositoryConfiguration(
            owner: repository.owner,
            repo: repository.repo,
            appName: repository.appName,
            bundleIdentifier: repository.bundleIdentifier,
            releasesPageURL: repository.releasesPageURL,
            authToken: authToken
        )

        return GitHubInAppUpdater(configuration: configuration)
    }

    private func checkErrorMessage(for error: Error) -> String {
        switch error {
        case GitHubReleaseClientError.notFoundLatestRelease:
            return "Could not access latest release (404). The repository may be private or there may be no published release yet. You can still open the Releases page directly."
        case GitHubReleaseClientError.unauthorizedOrForbidden:
            return "GitHub denied access to releases. For private repos set PIXELCRUSHER_GITHUB_TOKEN or defaults key PixelCrusherGitHubToken."
        default:
            return "Update check failed: \(error.localizedDescription)"
        }
    }
}

struct UpdateOptionsCard: View {
    @StateObject private var model = UpdateCheckViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Updates")
                    .font(.headline)
                Spacer()
                Button(model.isChecking ? "Checking…" : "Check for Updates") {
                    model.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isChecking || model.isInstalling)
            }

            Text("User-initiated updater only. No background auto-update daemon.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(model.stateMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let latestVersion = model.latestVersion {
                Text("Latest release: \(latestVersion)")
                    .font(.subheadline.weight(.semibold))
            }

            if let notes = model.releaseNotes, !notes.isEmpty {
                ScrollView {
                    Text(notes)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.35))
                )
            }

            if model.canInstall {
                Button("Download & Install Update") {
                    model.installUpdate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isInstalling)
            }

            if model.showOpenReleasesFallback {
                Button("Open Releases Page") {
                    model.openReleasesPage()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.52))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}
