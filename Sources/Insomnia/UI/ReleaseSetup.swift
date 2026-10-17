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

    /// The mode an installed update waits for, for the menu; nil when none waits.
    var updateHeldFor: String? { updater?.gate.heldFor }

    /// The launch steps after the location check: offer to trash the old
    /// copy, register the helper or refresh its rule, start the updater, and
    /// start Lid mode again when an update restarted Ember out of it.
    func launch(manager: SessionManager) {
        offerToTrashOldCopy()
        refreshHelper(registerIfNeeded: true)
        updater?.start()
        let resume = ResumeAfterUpdate.take(from: manager.paths.resumeAfterUpdateFile)
        Task {
            await manager.rearmRecoveryAgentIfInstalled()
            if let resume {
                Log.info("starting Lid mode again after the update with \(Int(resume))s of closed-lid time")
                await manager.start(duration: resume)
                if manager.session == nil {
                    // The menu shows why (the start's own error).
                    Log.error("Lid mode could not be started again after the update")
                }
            }
        }
    }

    /// Reads the helper's state again (the menu calls this when it opens).
    /// Newly enabled: has it write the restore rule.
    func refreshHelper(registerIfNeeded: Bool = false) {
        var state = helper.state
        // A daemon that was never registered reads notFound, not
        // notRegistered (macOS 26, seen on the first 0.2.0 install).
        if registerIfNeeded, state == .notRegistered || state == .notFound {
            do {
                try helper.register()
                Log.info("helper registered; waiting for approval in System Settings > General > Login Items")
            } catch {
                // register() fails with "Operation not permitted" when the
                // helper is registered but waits for the person's approval.
                if helper.state == .requiresApproval {
                    Log.info("helper registered; waiting for approval in System Settings > General > Login Items")
                } else {
                    Log.error("could not register the helper: \(error.localizedDescription)")
                }
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

    /// Opens Login Items, then looks again every 2 s for 3 minutes, so the
    /// approval takes effect without waiting for the menu to open.
    func openApproval() {
        helper.openApprovalSettings()
        approvalWatch?.cancel()
        approvalWatch = Task { [weak self] in
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.refreshHelper()
                if self.helperState == .enabled { return }
            }
        }
    }

    @ObservationIgnored private var approvalWatch: Task<Void, Never>?

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
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Paths.bundleIdentifier
                && $0.bundleURL?.resolvingSymlinksInPath().path == old.resolvingSymlinksInPath().path
        }
        let alert = NSAlert()
        alert.messageText = "Move the old Ember to the Trash?"
        alert.informativeText = "An older copy of Ember, installed from source, is at \(old.path). This one replaces it; keeping both would only confuse which one runs."
            + (running.isEmpty ? "" : " It is running now: it is quit first, which ends its session.")
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep It")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            Log.info("kept the old copy at \(old.path)")
            return
        }
        Task { @MainActor in
            // Asked to quit, as its own Quit item would: it ends its session
            // and may refuse while recovery is pending.
            for app in running { app.terminate() }
            for _ in 0..<150 where running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if running.contains(where: { !$0.isTerminated }) {
                Log.error("the old copy at \(old.path) is still running after 15 s; not moving it to the Trash")
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
}
