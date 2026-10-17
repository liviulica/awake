import AppKit
import Foundation
import Observation

/// Where a release build runs from that it must not (spec 2026-10-17
/// "Launch"): straight from the DMG, or from a copy macOS translocated.
/// The recovery agent pins the bundle's path and Sparkle replaces the
/// bundle in place, so neither works from there.
enum InstallLocation {
    static func problem(bundlePath: String, onReadOnlyVolume: Bool) -> String? {
        guard bundlePath.contains("/AppTranslocation/") || onReadOnlyVolume else { return nil }
        return "Drag Ember into your Applications folder, then open it from there. It can't keep your Mac awake safely or update itself from where it is now."
    }

    static func isOnReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }
}

/// The copy install.sh put in ~/Applications, left behind once a release
/// build runs from elsewhere (spec 2026-10-17 "Moving from an install.sh
/// install").
enum LegacyInstall {
    /// The old bundle to offer to trash: `~/Applications/Ember.app` when it
    /// exists, is Ember (by bundle identifier) and is not the running one.
    static func oldCopy(running: URL, home: URL, bundleIdentifier: (URL) -> String?) -> URL? {
        let old = home.appendingPathComponent("Applications/Ember.app", isDirectory: true)
        // Compared as paths: a bundle URL may or may not end in a slash.
        guard old.standardizedFileURL.resolvingSymlinksInPath().path != running.standardizedFileURL.resolvingSymlinksInPath().path else { return nil }
        guard bundleIdentifier(old) == Paths.bundleIdentifier else { return nil }
        return old
    }

    static func bundleIdentifier(of url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }
}

/// What a release build does at launch and keeps up to date afterwards:
/// the helper's registration and its restore rule, the updater, the old
/// install. Nothing of it runs in a source build (`ReleaseSignature`).
@MainActor
@Observable
final class ReleaseSetup {
    @ObservationIgnored let helper: any PrivilegedHelping
    @ObservationIgnored let updater: Updater?
    private(set) var helperState: HelperState

    init(helper: any PrivilegedHelping, updater: Updater?) {
        self.helper = helper
        self.updater = updater
        helperState = helper.state
    }

    /// The approval line shows until the helper is enabled.
    var helperNeedsApproval: Bool {
        switch helperState {
        case .enabled, .unavailable: return false
        case .notRegistered, .requiresApproval, .notFound: return true
        }
    }

    var updateHeldBack: Bool { updater?.gate.isHolding ?? false }

    /// The launch steps after the location check: offer to trash the old
    /// copy, register the helper or refresh its rule, start the updater.
    func launch(manager: SessionManager) {
        offerToTrashOldCopy()
        refreshHelper(registerIfNeeded: true)
        updater?.start()
        Task { await manager.rearmRecoveryAgentIfInstalled() }
    }

    /// Reads the helper's state again (the menu calls this when it opens).
    /// Newly enabled: has it write the restore rule.
    func refreshHelper(registerIfNeeded: Bool = false) {
        var state = helper.state
        if registerIfNeeded, state == .notRegistered {
            do {
                try helper.register()
                Log.info("helper registered; waiting for approval in System Settings > General > Login Items")
            } catch {
                Log.error("could not register the helper: \(error.localizedDescription)")
            }
            state = helper.state
        }
        let was = helperState
        helperState = state
        if state != was || registerIfNeeded { Log.info("helper: \(state)") }
        if state == .enabled, was != .enabled || registerIfNeeded {
            Task {
                do {
                    let r = try await helper.installRestoreRule()
                    if r.status == 0 { Log.info("helper: \(r.message)") } else { Log.error("helper could not write the restore rule: status \(r.status) \(r.message)") }
                } catch {
                    Log.error("could not ask the helper for the restore rule: \(error.localizedDescription)")
                }
            }
        }
    }

    func openApproval() {
        helper.openApprovalSettings()
    }

    /// True when the app may go on; false after telling the person to move
    /// it (the caller quits).
    static func checkLocation(bundle: URL = Bundle.main.bundleURL) -> Bool {
        guard let problem = InstallLocation.problem(bundlePath: bundle.path, onReadOnlyVolume: InstallLocation.isOnReadOnlyVolume(bundle)) else { return true }
        Log.error("refusing to run from \(bundle.path): \(problem)")
        let alert = NSAlert()
        alert.messageText = "Move Ember to Applications"
        alert.informativeText = problem
        alert.addButton(withTitle: "Quit")
        NSApp.activate()
        alert.runModal()
        return false
    }

    private func offerToTrashOldCopy() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let old = LegacyInstall.oldCopy(running: Bundle.main.bundleURL, home: home, bundleIdentifier: LegacyInstall.bundleIdentifier) else { return }
        let alert = NSAlert()
        alert.messageText = "Move the old Ember to the Trash?"
        alert.informativeText = "An older copy of Ember, installed from source, is at \(old.path). This one replaces it; keeping both would only confuse which one runs."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep It")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            Log.info("kept the old copy at \(old.path)")
            return
        }
        NSWorkspace.shared.recycle([old]) { _, error in
            if let error {
                Log.error("could not move \(old.path) to the Trash: \(error.localizedDescription)")
            } else {
                Log.info("moved the old copy at \(old.path) to the Trash")
            }
        }
    }
}
