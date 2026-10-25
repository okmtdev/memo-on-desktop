import AppKit
import Combine
import SwiftUI

@MainActor
final class WindowPresentation: ObservableObject {
    static let shared = WindowPresentation()

    @Published var alwaysOnTop: Bool {
        didSet {
            defaults.set(alwaysOnTop, forKey: storageKey)
            apply()
        }
    }
    private let defaults: UserDefaults
    private let storageKey = "memo-on-desktop.window.alwaysOnTop"
    private weak var mainWindow: NSWindow?

    init(defaults: UserDefaults = UserDefaults(suiteName: "MemoOnDesktop") ?? .standard) {
        self.defaults = defaults
        alwaysOnTop = defaults.bool(forKey: storageKey)
    }

    func attach(_ window: NSWindow) {
        mainWindow = window
        apply()
    }

    private func apply() {
        guard let window = mainWindow else { return }
        // Change only stacking order: preserve the window's size, position and focus.
        window.level = alwaysOnTop ? .floating : .normal
        window.hidesOnDeactivate = false
        if alwaysOnTop && window.isVisible { window.orderFrontRegardless() }
    }
}

/// Register the actual main window, including after closing/reopening it.
/// Settings and recurring-task windows never become pinning targets.
struct MainWindowRegistration: NSViewRepresentable {
    let presentation: WindowPresentation

    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView()
        view.presentation = presentation
        return view
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {
        nsView.presentation = presentation
        if let window = nsView.window { presentation.attach(window) }
    }

    final class RegistrationView: NSView {
        var presentation: WindowPresentation?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { presentation?.attach(window) }
        }
    }
}
