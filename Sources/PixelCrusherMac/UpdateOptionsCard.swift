import SwiftUI
import AppKit
import PixelCrusherMacCore

@MainActor
final class UpdateCheckViewModel: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var latestVersion: String?
    @Published private(set) var releaseNotes: String?
    @Published private(set) var downloadURL: URL?

    private let currentVersionProvider: () -> String

    init(
        currentVersionProvider: @escaping () -> String = {
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        }
    ) {
        self.currentVersionProvider = currentVersionProvider
    }

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        statusMessage = nil

        Task {
            defer { isChecking = false }

            do {
                let currentVersion = currentVersionProvider()
                let checker = GitHubReleaseUpdateChecker(owner: "lubomirmolin", repo: "pixelcrusher")
                let result = try await checker.checkForUpdate(currentVersionString: currentVersion, platform: .macOS)

                if result.isUpdateAvailable {
                    latestVersion = result.latestVersion.description
                    releaseNotes = result.release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
                    downloadURL = result.downloadURL
                    statusMessage = "Update available: \(result.latestVersion.description) (current \(result.currentVersion.description))"
                } else {
                    latestVersion = nil
                    releaseNotes = nil
                    downloadURL = nil
                    statusMessage = "You're up to date (\(result.currentVersion.description))."
                }
            } catch {
                latestVersion = nil
                releaseNotes = nil
                downloadURL = nil
                statusMessage = "Update check failed: \(error.localizedDescription)"
            }
        }
    }

    func openDownload() {
        guard let downloadURL else { return }
        NSWorkspace.shared.open(downloadURL)
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
                .disabled(model.isChecking)
            }

            Text("Manual check only. No background auto-update.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

            if model.downloadURL != nil {
                Button("Open Download") {
                    model.openDownload()
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
