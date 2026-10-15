import AppKit
import Observation

/// The menu bar item (spec "Interaction"): a fixed template icon, a
/// countdown when something is timed, left-click toggles screen mode,
/// right-click (or any click during a lid session) opens the menu. A plain
/// NSStatusItem with no hosted view and no key window: nothing here takes
/// the keyboard, and the item's width changes only when the countdown
/// appears or goes, or gains or loses a digit (crossing 10:00).
@MainActor
final class StatusItemController: NSObject {
    /// What the item shows: the icon and the countdown next to it (empty
    /// when nothing is timed). Pure so tests check it without a menu bar.
    struct Presentation: Equatable {
        let icon: MenuBarIcon
        let title: String
    }

    /// What a click on the item does.
    enum ClickAction: Equatable {
        case toggleAwake
        case showMenu
    }

    /// Autosave name so macOS remembers where the user drags the item.
    static let autosaveName = "ember.status"

    let manager: SessionManager
    let status: any StatusSource
    let awake: AwakeController
    let reminder = ReminderScheduler()
    /// Opens the settings window. Injected because the window is owned by the
    /// app delegate, which outlives any one status item.
    private let showSettings: () -> Void
    /// Asks before a browser is quit for a relaunch; true means go ahead.
    /// Injected so tests never see the NSAlert.
    private let confirmRelaunch: @MainActor (String) -> Bool
    /// The "Custom…" prompt: the text typed, or nil when cancelled.
    /// Injected so tests never see the NSAlert.
    private let askDurationText: @MainActor () -> String?
    /// Tells the person something with a plain alert. Injected for tests.
    private let showNotice: @MainActor (String) -> Void
    /// What the countdown reads the time from; tests inject a fake clock.
    private let clock: @Sendable () -> Date
    private let statusItem: NSStatusItem
    /// Redraws the countdown while one is shown. It reads whole minutes,
    /// so every 30 s keeps it at most half a minute behind.
    private var tick: Timer?

    init(
        manager: SessionManager,
        status: any StatusSource,
        awake: AwakeController,
        showSettings: @escaping () -> Void,
        confirmRelaunch: (@MainActor (String) -> Bool)? = nil,
        askDurationText: (@MainActor () -> String?)? = nil,
        showNotice: (@MainActor (String) -> Void)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.manager = manager
        self.status = status
        self.awake = awake
        self.showSettings = showSettings
        self.confirmRelaunch = confirmRelaunch ?? Self.askBeforeRelaunch
        self.askDurationText = askDurationText ?? Self.askCustomDurationText
        self.showNotice = showNotice ?? Self.showAlert
        self.clock = clock
        Self.seedPreferredPositionIfNeeded()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.autosaveName
        statusItem.behavior = [.terminationOnRemoval]
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        observe()
        // A lid close drops the screen hold before the close actions ask
        // the display to sleep (AwakeController.lidEvent).
        manager.services?.onLidEvent = { [weak awake] closed in awake?.lidEvent(closed: closed) }
        // A session already on file at launch gets its lid hold and its
        // reminder now, not at its next change.
        stateChanged()
    }

    /// New status items are appended at the left of the existing group. On a
    /// crowded menu bar (notch Macs) that lands in the hidden overflow, so the
    /// item exists but is never seen. Seed a position near the right end the
    /// first time only; after that macOS keeps whatever the user drags to.
    static func seedPreferredPositionIfNeeded(defaults: UserDefaults = .standard) {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(40, forKey: key)
    }

    /// A lid session wins over screen mode (which is off during one anyway):
    /// the robot and the closed-lid time left. Screen mode shows its time
    /// left only when it was given a duration.
    static func presentation(lidRemaining: TimeInterval?, awake: AwakeController.State, now: Date) -> Presentation {
        if let lid = lidRemaining {
            return Presentation(icon: .lid, title: Countdown.short(lid))
        }
        switch awake {
        case .off:
            return Presentation(icon: .off, title: "")
        case let .on(until):
            return Presentation(icon: .awake, title: until.map { Countdown.short($0.timeIntervalSince(now)) } ?? "")
        }
    }

    /// Right-click and ctrl-click open the menu. During a lid session a left
    /// click opens it too: toggling there would do nothing (screen mode is
    /// part of the session), and the spec wants nothing destructive on a
    /// stray click.
    static func clickAction(isRightClick: Bool, controlHeld: Bool, lidActive: Bool) -> ClickAction {
        isRightClick || controlHeld || lidActive ? .showMenu : .toggleAwake
    }

    /// Takes the item off the menu bar and stops the countdown tick. The
    /// app never calls it (the item lives as long as the app); tests do, so
    /// no repeating timer or stray item outlives them.
    func stop() {
        tick?.invalidate()
        tick = nil
        manager.services?.onLidEvent = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: State

    /// Sessions can start, pause or end without the UI (reconcile at launch,
    /// the lid, the deadline, the battery floor), and screen mode can end on
    /// its own timer. Keep the item, the lid hold and the reminder in step.
    private func observe() {
        withObservationTracking {
            _ = manager.session
            _ = awake.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.stateChanged()
                self.observe()
            }
        }
    }

    /// Internal so tests can run it without waiting for observation.
    func stateChanged() {
        // A paused session is a lid session with the lid open (Task 6b).
        awake.lidSessionChanged(active: manager.isActive, lidOpen: manager.session?.isPaused ?? false)
        // "5 minutes left" only while the closed-lid clock runs: a paused
        // session's endsAt is a lease, not the end.
        reminder.sync(endsAt: manager.session?.isPaused == false ? manager.session?.endsAt : nil)
        refresh()
    }

    private func refresh() {
        let now = clock()
        let p = Self.presentation(lidRemaining: manager.session?.closedLidRemaining(at: now), awake: awake.state, now: now)
        if let button = statusItem.button {
            button.image = MenuBarIcon.image(p.icon)
            button.title = p.title
        }
        if p.title.isEmpty {
            tick?.invalidate()
            tick = nil
        } else if tick == nil {
            let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            tick = t
        }
    }

    // MARK: Clicks

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let action = Self.clickAction(
            isRightClick: event?.type == .rightMouseUp,
            controlHeld: event?.modifierFlags.contains(.control) ?? false,
            lidActive: manager.isActive
        )
        switch action {
        case .toggleAwake:
            awake.toggle()
            refresh()
        case .showMenu:
            showMenu()
        }
    }

    /// Not assigned to `statusItem.menu`, which would swallow the left click
    /// that toggles screen mode.
    private func showMenu() {
        guard let button = statusItem.button else { return }
        // The lid, the battery and the watts are read right here, so the menu
        // opens on what the machine is doing now. The SSID and the throttled
        // browser list are whatever the last scan found: both have to be
        // awaited, and an open NSMenu blocks the main actor, so there is no
        // moment at which they could be filled into a menu that is already up.
        // Kick that scan off anyway, for the next opening.
        status.refreshInstant()
        status.refreshOnDemand()
        // Same for the foreign-sleep line: re-read the bit now, and let the
        // next opening drop the line if sleep is enabled again.
        Task { await manager.recheckForeignSleep() }
        let menu = StatusMenu.menu(
            Self.menuItems(manager: manager, status: status, awake: awake, now: clock()),
            target: self,
            settings: #selector(menuOpenSettings),
            quit: #selector(menuQuit),
            relaunchBrowser: #selector(menuRelaunchBrowser(_:)),
            stopWaitingForOutput: #selector(menuStopWaitingForOutput(_:)),
            toggleAwake: #selector(menuToggleAwake(_:)),
            awakeFor: #selector(menuAwakeFor(_:)),
            startLid: #selector(menuStartLid(_:)),
            extendLid: #selector(menuExtendLid(_:)),
            endLid: #selector(menuEndLid(_:))
        )
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    /// The menu's lines from what the session, screen mode and the status
    /// source report now. Static, so a test can check them without a status item.
    static func menuItems(manager: SessionManager, status: any StatusSource, awake: AwakeController, now: Date) -> [StatusMenu.Item] {
        StatusMenu.items(
            controls: StatusMenu.controlItems(
                awakeOn: awake.isOn,
                awakeEndsAt: awake.endsAt,
                lidRemaining: manager.session?.closedLidRemaining(at: now),
                lidPaused: manager.session?.isPaused ?? false,
                now: now
            ),
            thermal: StatusLines.thermal(ProcessInfo.processInfo.thermalState),
            sessionActive: manager.isActive,
            sleepHeld: manager.state.sleepDisabledByUs,
            machine: StatusLines.machine(
                lidClosed: status.lidClosed,
                watts: status.instantWatts(),
                wifiSSID: WiFiStatusName.display(
                    ssid: status.wifiSSID,
                    locationAuthorized: (status as? LiveStatusSource)?.locationPermission.isAuthorized ?? true
                ),
                batteryPercent: status.batteryPercent,
                isCharging: status.isCharging
            ),
            actions: StatusLines.actions(frozenCount: status.frozenCount, lastGap: status.lastGap),
            throttledBrowsers: status.throttledBrowsers,
            relaunchProblems: status.relaunchProblems,
            // A report about an SSID edited away since is not shown.
            hotspotWarning: status.hotspotPasswordReport?.problem(for: manager.config.hotspotSSID)?.menuLine,
            error: awake.lastError ?? manager.lastError,
            commandRunning: manager.commandWarning,
            foreignSleep: manager.foreignSleepWarning,
            outputsWaiting: manager.outputsWaitingForRestore,
            lidSimulationBuild: LidSimulationBuild.isCompiledIn
        )
    }

    // MARK: Menu actions

    @objc private func menuToggleAwake(_ sender: NSMenuItem) {
        awake.toggle()
        refresh()
    }

    /// No represented duration is "until I turn it off".
    @objc private func menuAwakeFor(_ sender: NSMenuItem) {
        awake.turnOn(for: (sender.representedObject as? NSNumber)?.doubleValue)
        refresh()
    }

    /// No represented duration is "Custom…". Capped at 24 hours of
    /// closed-lid time (`Config.lidMaxDuration`).
    @objc private func menuStartLid(_ sender: NSMenuItem) {
        let chosen = (sender.representedObject as? NSNumber)?.doubleValue ?? customDuration()
        guard let chosen else { return }
        let duration = min(chosen, Config.lidMaxDuration)
        Task { @MainActor in
            await manager.start(duration: duration)
            refresh()
        }
    }

    @objc private func menuExtendLid(_ sender: NSMenuItem) {
        let extra = (sender.representedObject as? NSNumber)?.doubleValue ?? 3600
        Task { @MainActor in
            await manager.extend(by: extra)
            refresh()
        }
    }

    @objc private func menuEndLid(_ sender: NSMenuItem) {
        Task { @MainActor in
            _ = await manager.end(reason: .user)
            refresh()
        }
    }

    @objc private func menuOpenSettings() { showSettings() }

    @objc private func menuQuit() { NSApplication.shared.terminate(nil) }

    @objc private func menuStopWaitingForOutput(_ sender: NSMenuItem) {
        guard let waiting = sender.representedObject as? SavedAudioOutput else { return }
        Task { await manager.stopWaitingForOutput(waiting) }
    }

    @objc private func menuRelaunchBrowser(_ sender: NSMenuItem) {
        guard let browser = sender.representedObject as? ThrottledBrowser else { return }
        relaunchBrowser(browser)
    }

    /// The relaunch item: ask first, since the browser is quit and its
    /// windows come back only through its own session restore. Cancel does
    /// nothing. Confirming hands on the bundle id and name the item
    /// carried; a scan that replaced the browser list while the alert was
    /// up does not change them.
    func relaunchBrowser(_ browser: ThrottledBrowser) {
        guard confirmRelaunch(browser.name) else { return }
        status.relaunchUnthrottled(browser)
    }

    private static func askBeforeRelaunch(_ name: String) -> Bool {
        let prompt = RelaunchPrompt(browser: name)
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: RelaunchPrompt.confirmTitle)
        alert.addButton(withTitle: RelaunchPrompt.cancelTitle)
        // A menu bar app has no window to carry the alert; bring the app
        // forward so the alert is not behind whatever is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static let unreadableDurationNotice = "Couldn't read that duration. Try 90m, 3h or 1h30m."

    /// "Custom…": a duration typed as "90", "1h30m" or "2h" (DurationParser).
    /// Nil when cancelled, or when unreadable, which the person is told;
    /// `menuStartLid` caps it at 24 hours. Internal so tests drive it.
    func customDuration() -> TimeInterval? {
        guard let text = askDurationText() else { return nil }
        guard let seconds = DurationParser.seconds(from: text) else {
            Log.info("custom lid duration not understood: \(text.count) characters")
            showNotice(Self.unreadableDurationNotice)
            return nil
        }
        return seconds
    }

    /// A modal alert, so the field has the keyboard only while the person is
    /// typing in it.
    private static func askCustomDurationText() -> String? {
        let alert = NSAlert()
        alert.messageText = "Keep awake with the lid closed for how long?"
        alert.informativeText = "For example 90m, 3h or 1h30m. The most is 24 hours."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "3h"
        alert.accessoryView = field
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private static func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
