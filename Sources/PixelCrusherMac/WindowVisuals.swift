import SwiftUI
import AppKit

struct WindowAppearanceConfigurator: NSViewRepresentable {
    let opacity: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            apply(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            apply(to: nsView.window)
        }
    }

    private func apply(to window: NSWindow?) {
        guard let window else {
            return
        }

        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = opacity
    }
}

struct WindowBlurBackdrop: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = .withinWindow
        nsView.state = .active
        nsView.isEmphasized = false
    }
}
