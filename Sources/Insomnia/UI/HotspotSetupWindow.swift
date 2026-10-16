import AppKit
import SwiftUI

/// The hotspot setup window, held by AppKit like `SettingsWindow`. Each
/// `show()` starts a fresh setup at step 1 with the current values.
@MainActor
final class HotspotSetupWindow {
    private var window: NSWindow?
    private let make: @MainActor () -> HotspotSetup
    private let locationPermission: LocationPermission

    init(make: @escaping @MainActor () -> HotspotSetup, locationPermission: LocationPermission) {
        self.make = make
        self.locationPermission = locationPermission
    }

    func show() {
        let view = HotspotSetupView(setup: make(), locationPermission: locationPermission) { [weak self] in
            self?.window?.close()
        }
        let host = NSHostingController(rootView: view)
        let window = window ?? Self.newWindow()
        self.window = window
        window.contentViewController = host
        window.setContentSize(host.view.fittingSize)
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    private static func newWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Hotspot Failover Setup"
        // Reopened from the menu or Settings: keep the window object.
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        return window
    }
}
