import AppKit
import Sparkle

/// Holds an update's relaunch while Ember is keeping the Mac awake, and
/// lets it go once nothing is (spec 2026-10-17 "Updater"). Quitting ends a
/// lid session and screen mode, so an update must never quit for them.
@MainActor
final class RelaunchGate {
    private var pending: (() -> Void)?

    /// True while an installed update waits for the session to end.
    var isHolding: Bool { pending != nil }

    /// Sparkle asks before relaunching: true holds `install` until
    /// `update(busy: false)`; false lets the relaunch go now.
    func shouldPostpone(busy: Bool, install: @escaping () -> Void) -> Bool {
        guard busy else { return false }
        pending = install
        return true
    }

    /// Runs the held relaunch, once, when Ember is no longer busy.
    func update(busy: Bool) {
        guard !busy, let install = pending else { return }
        pending = nil
        install()
    }
}

/// Sparkle's standard updater, in a release build only. Checks daily on its
/// own (SUEnableAutomaticChecks), from the feed in Info.plist (SUFeedURL),
/// and accepts only updates signed with the key in SUPublicEDKey.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    let gate = RelaunchGate()
    /// True while a lid session or screen mode is on.
    private let isBusy: @MainActor () -> Bool
    /// Called when an update starts or stops waiting, so the menu can say so.
    var onHoldChange: (@MainActor () -> Void)?
    private var controller: SPUStandardUpdaterController!

    init(isBusy: @escaping @MainActor () -> Bool) {
        self.isBusy = isBusy
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    func start() {
        controller.startUpdater()
        Log.info("updater started (automatic checks \(automaticallyChecks ? "on" : "off"))")
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Call when a lid session or screen mode starts or ends.
    func busyChanged() {
        let held = gate.isHolding
        gate.update(busy: isBusy())
        if held != gate.isHolding { onHoldChange?() }
    }

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        nonisolated(unsafe) let install = installHandler
        return MainActor.assumeIsolated {
            let held = gate.shouldPostpone(busy: isBusy(), install: install)
            if held {
                Log.info("update \(version) is ready; it installs when the lid session or screen mode ends")
                onHoldChange?()
            }
            return held
        }
    }
}
