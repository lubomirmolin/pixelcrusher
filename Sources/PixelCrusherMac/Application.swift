import SwiftUI
import AppKit
import Foundation

struct PixelCrusherDesktopApp: App {
    @NSApplicationDelegateAdaptor(PixelCrusherAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Pixel Crusher", id: "pixelcrusher-main-window") {
            ContentView()
        }
        .windowResizability(.automatic)
    }
}

final class PixelCrusherAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        handleOpen(paths: [filename])
        return true
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        handleOpen(paths: filenames)
        application.reply(toOpenOrPrint: .success)
    }

    private func handleOpen(paths: [String]) {
        let urls = paths
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }

        guard !urls.isEmpty else {
            return
        }

        DispatchQueue.main.async {
            ExternalOpenFilesCoordinator.shared.enqueue(urls)

            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
