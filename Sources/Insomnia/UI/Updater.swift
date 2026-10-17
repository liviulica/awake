import AppKit
import Sparkle

/// When an update may restart Ember (spec 2026-10-17 "Updater", revised
/// with the owner after the 0.2.1 test). Restarting quits, and quitting ends
/// whatever Ember is doing, so:
/// - nothing on: restart now;
/// - Lid mode with the lid open (its clock paused): restart now and start
///   Lid mode again afterwards with the same closed-lid time left;
/// - Screen mode, or Lid mode with the lid closed (its clock running): wait
///   until that ends.
enum UpdateMoment: Equatable {
    case now
    case nowRestoringLid(remaining: TimeInterval)
    /// The mode that holds the restart, as the menu names it.
    case wait(mode: String)

    static func of(screenOn: Bool, lidActive: Bool, lidPaused: Bool, lidRemaining: TimeInterval) -> UpdateMoment {
        if screenOn { return .wait(mode: "Screen mode") }
        if lidActive { return lidPaused ? .nowRestoringLid(remaining: lidRemaining) : .wait(mode: "Lid mode") }
        return .now
    }

    var waitingFor: String? {
        if case let .wait(mode) = self { return mode }
        return nil
    }
}

/// Holds an update's restart while `UpdateMoment` says wait, and lets it go,
/// once, when it no longer does.
@MainActor
final class RelaunchGate {
    private var pending: (() -> Void)?
    /// The mode it waited for when it was held, for the menu.
    private(set) var heldFor: String?

    /// True while an installed update waits for a mode to end.
    var isHolding: Bool { pending != nil }

    /// Holds `install` when `moment` says wait and returns true; returns
    /// false (the caller lets the restart go) otherwise.
    func shouldHold(_ moment: UpdateMoment, install: @escaping () -> Void) -> Bool {
        guard let mode = moment.waitingFor else { return false }
        pending = install
        heldFor = mode
        return true
    }

    /// Runs the held install, once, when `moment` no longer says wait.
    /// Returns true when it ran.
    @discardableResult
    func update(_ moment: UpdateMoment) -> Bool {
        guard moment.waitingFor == nil, let install = pending else { return false }
        pending = nil
        heldFor = nil
        install()
        return true
    }
}

/// Sparkle's standard updater, in a release build only. Checks daily
/// (SUEnableAutomaticChecks), downloads and installs on its own
/// (SUAutomaticallyUpdate, the "Install updates automatically" switch), from
/// the feed in Info.plist (SUFeedURL), and accepts only updates signed with
/// the key in SUPublicEDKey. Every restart goes through `UpdateMoment`.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    let gate = RelaunchGate()
    /// What Ember is doing now, as an `UpdateMoment`.
    private let moment: @MainActor () -> UpdateMoment
    /// Records that Lid mode is to start again after the restart, with this
    /// much closed-lid time.
    private let restoreLid: @MainActor (TimeInterval) -> Void
    /// Asks whether to turn `mode` off so the update installs now; true to
    /// turn it off. Injected so tests never see the alert.
    private let askTurnOff: @MainActor (String) -> Bool
    /// Turns Screen mode off.
    private let turnOffScreen: @MainActor () -> Void
    private var controller: SPUStandardUpdaterController!

    init(
        moment: @escaping @MainActor () -> UpdateMoment,
        restoreLid: @escaping @MainActor (TimeInterval) -> Void,
        turnOffScreen: @escaping @MainActor () -> Void,
        askTurnOff: (@MainActor (String) -> Bool)? = nil,
        startController: Bool = true
    ) {
        self.moment = moment
        self.restoreLid = restoreLid
        self.turnOffScreen = turnOffScreen
        self.askTurnOff = askTurnOff ?? Self.askTurnOffAlert
        super.init()
        if startController {
            controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        }
    }

    func start() {
        controller.startUpdater()
        Log.info("updater started (automatic checks \(automaticallyChecks ? "on" : "off"), automatic install \(automaticallyInstalls ? "on" : "off"))")
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyInstalls: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// Call when Screen mode or Lid mode starts, ends, pauses or runs.
    func busyChanged() {
        let now = moment()
        guard gate.isHolding, now.waitingFor == nil else { return }
        prepare(now)
        gate.update(now)
    }

    /// Before a restart the moment allows: a paused Lid mode is recorded so
    /// the new version starts it again.
    private func prepare(_ now: UpdateMoment) {
        if case let .nowRestoringLid(remaining) = now {
            restoreLid(remaining)
        }
    }

    // MARK: Decisions (internal so tests drive them without Sparkle)

    /// The person chose Install and Relaunch. True holds the restart.
    func decideRelaunch(version: String, install: @escaping () -> Void) -> Bool {
        let now = moment()
        guard gate.shouldHold(now, install: install) else {
            prepare(now)
            return false
        }
        let mode = now.waitingFor ?? "Lid mode"
        Log.info("update \(version) is ready; it installs when \(mode) ends")
        // Only Screen mode can be turned off from here: with the lid closed
        // in Lid mode nobody is at the Mac to answer.
        if mode == "Screen mode" {
            StatusItemController.presentOutsideTracking { [weak self] in
                guard let self, self.gate.isHolding, self.askTurnOff(mode) else { return }
                self.turnOffScreen()
                self.busyChanged()
            }
        }
        return true
    }

    /// An update downloaded on its own is ready. Installs and restarts now
    /// when the moment allows, else when it does. Always handled here, so
    /// Sparkle never waits for a quit that a menu bar app may not see for days.
    func decideAutomaticInstall(version: String, install: @escaping () -> Void) -> Bool {
        let now = moment()
        if gate.shouldHold(now, install: install) {
            Log.info("update \(version) downloaded; it installs when \(now.waitingFor ?? "Lid mode") ends")
        } else {
            Log.info("update \(version) downloaded; installing and restarting now")
            prepare(now)
            install()
        }
        return true
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        nonisolated(unsafe) let install = installHandler
        return MainActor.assumeIsolated { decideRelaunch(version: version, install: install) }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        nonisolated(unsafe) let install = immediateInstallHandler
        return MainActor.assumeIsolated { decideAutomaticInstall(version: version, install: install) }
    }

    private static func askTurnOffAlert(_ mode: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Update Ember now?"
        alert.informativeText = "The update installs when \(mode) ends. Turn it off now and update? Ember restarts in a second."
        alert.addButton(withTitle: "Turn Off and Update")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Lid mode to start again after an update restarted Ember with the lid
/// open (`UpdateMoment.nowRestoringLid`). Written just before the restart,
/// read and removed by the next launch; ignored when older than `maxAge`, so
/// a restart that did not happen never starts Lid mode out of the blue later.
struct ResumeAfterUpdate: Codable, Equatable {
    static let maxAge: TimeInterval = 10 * 60
    /// Shorter than this is not worth starting again.
    static let minimumRemaining: TimeInterval = 60

    var remaining: TimeInterval
    var savedAt: Date

    static func save(remaining: TimeInterval, at url: URL, now: Date = Date()) {
        do {
            let data = try JSONEncoder().encode(ResumeAfterUpdate(remaining: remaining, savedAt: now))
            try data.write(to: url, options: .atomic)
            Log.info("Lid mode starts again after the update with \(Int(remaining))s of closed-lid time")
        } catch {
            Log.error("could not record Lid mode for after the update: \(error.localizedDescription)")
        }
    }

    /// Reads and removes the record; returns the closed-lid time to start
    /// Lid mode with, or nil.
    static func take(from url: URL, now: Date = Date()) -> TimeInterval? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard let record = try? JSONDecoder().decode(ResumeAfterUpdate.self, from: data) else { return nil }
        let age = now.timeIntervalSince(record.savedAt)
        guard age >= 0, age <= maxAge, record.remaining >= minimumRemaining else { return nil }
        return record.remaining
    }
}
