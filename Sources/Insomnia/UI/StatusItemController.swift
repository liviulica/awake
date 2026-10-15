import AppKit
import Observation

/// The menu bar item (spec 2026-10-15 "Left-click"): a fixed template icon,
/// a countdown when something is timed, left-click turns screen mode on and
/// off (during a lid session it opens the menu), right-click (or ctrl-click)
/// opens the menu. A plain
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

    /// Which of the three states the item is in (spec 2026-10-15 "Left-click").
    enum Mode: Equatable {
        case off, screen, lid
    }

    /// Runs `body` once the menu's tracking has ended: a run-loop block in
    /// the default mode, which an open menu's tracking mode does not run.
    /// Not a main-queue block: a modal alert started inside one holds every
    /// other main-queue job (the lease renewal, the deadline, the timers)
    /// until it closes, because the main queue does not nest.
    static func presentOutsideTracking(_ body: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated(body) }
    }

    /// Which Custom… prompt to show.
    enum DurationPrompt: Equatable {
        case screen, lid
    }

    /// What a click on the item does.
    enum ClickAction: Equatable {
        case turnOnScreen
        case turnOffScreen
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
    private let askDurationText: @MainActor (DurationPrompt) -> String?
    /// Tells the person something with a plain alert. Injected for tests.
    private let showNotice: @MainActor (String) -> Void
    /// What the countdown reads the time from; tests inject a fake clock.
    private let clock: @Sendable () -> Date
    private let statusItem: NSStatusItem
    /// Redraws the countdown while one is shown. It reads whole minutes,
    /// so every 30 s keeps it at most half a minute behind.
    private var tick: Timer?
    /// True while a lid start waits on the administrator prompt. The
    /// session does not exist until the password is accepted, so without
    /// this a second click (or the menu's start) would queue another start,
    /// and a cancel would bring the prompt straight back.
    private(set) var lidStartInFlight = false
    /// The length last picked for screen mode or the lid session from a
    /// chip (nil when none was), so the header highlights it. Forgotten
    /// when the Mac leaves that mode.
    private(set) var screenChosen: TimeInterval?
    private(set) var lidChosen: TimeInterval?
    private var lastMode: Mode = .off
    /// The header of the menu that is open now, refreshed in place.
    private weak var openHeader: ModeHeaderView?

    init(
        manager: SessionManager,
        status: any StatusSource,
        awake: AwakeController,
        showSettings: @escaping () -> Void,
        confirmRelaunch: (@MainActor (String) -> Bool)? = nil,
        askDurationText: (@MainActor (DurationPrompt) -> String?)? = nil,
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

    /// A lid session wins over screen mode (which is folded into it).
    static func mode(lidActive: Bool, awake: AwakeController.State) -> Mode {
        if lidActive { return .lid }
        return awake == .off ? .off : .screen
    }

    /// Right-click and ctrl-click open the menu. A plain left click toggles
    /// screen mode; during a lid session it opens the menu, so a stray click
    /// never ends a session (spec 2026-10-16 "Left-click").
    static func clickAction(isRightClick: Bool, controlHeld: Bool, mode: Mode) -> ClickAction {
        if isRightClick || controlHeld { return .showMenu }
        switch mode {
        case .off: return .turnOnScreen
        case .screen: return .turnOffScreen
        case .lid: return .showMenu
        }
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
        // Every change ends in a refresh, so this is where leaving a mode
        // is noticed and the length picked for it forgotten.
        let mode = Self.mode(lidActive: manager.isActive, awake: awake.state)
        if mode != lastMode {
            if lastMode == .screen { screenChosen = nil }
            if lastMode == .lid { lidChosen = nil }
            lastMode = mode
        }
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
        openHeader?.update(headerModel(now: now))
    }

    // MARK: Header

    /// The open menu's header, from the real state.
    func headerModel(now: Date) -> ModeHeader.Model {
        ModeHeader.model(
            mode: Self.mode(lidActive: manager.isActive, awake: awake.state),
            awakeEndsAt: awake.endsAt,
            screenChosen: screenChosen,
            lidRemaining: manager.session?.closedLidRemaining(at: now),
            lidPaused: manager.session?.isPaused ?? false,
            lidChosen: lidChosen,
            lidStarting: lidStartInFlight,
            now: now
        )
    }

    /// A tab click (spec 2026-10-16 "Tabs").
    func applyTab(_ tab: ModeHeader.Tab) async {
        // A newer choice than a Lid start still waiting wins: ending through
        // the manager bumps its end ticket, so the pending start rolls back.
        if lidStartInFlight, tab != .lid {
            _ = await manager.end(reason: .user)
        }
        switch ModeHeader.transition(from: Self.mode(lidActive: manager.isActive, awake: awake.state), to: tab) {
        case .none:
            break
        case .turnOnScreen:
            screenChosen = nil
            awake.turnOn(for: nil)
        case .turnOffScreen:
            awake.turnOff(reason: "user")
        case .startLid:
            let length = manager.config.lidClickDuration
            await startLidSession(length)
            if manager.isActive { lidChosen = length }
        case .endLid:
            _ = await manager.end(reason: .user)
        case .endLidThenTurnOnScreen:
            _ = await manager.end(reason: .user)
            if !manager.isActive {
                stateChanged()
                screenChosen = nil
                awake.turnOn(for: nil)
            }
        }
        refresh()
    }

    /// A chip click. A chip for a mode the Mac has left meanwhile (the menu
    /// stayed open across a timer end) does nothing.
    func applyChip(_ action: ModeHeader.ChipAction) async {
        let mode = Self.mode(lidActive: manager.isActive, awake: awake.state)
        switch action {
        case let .screenFor(length):
            guard mode == .screen else { return }
            awake.turnOn(for: length)
            screenChosen = length
        case let .lidRemaining(length):
            guard mode == .lid else { return }
            await manager.setRemaining(min(length, Config.lidMaxDuration))
            lidChosen = length
        case .screenCustom, .lidCustom:
            let kind: DurationPrompt = action == .screenCustom ? .screen : .lid
            // Once the menu has closed, and outside any main-queue job.
            Self.presentOutsideTracking { [weak self] in
                guard let self, let length = self.customDuration(kind) else { return }
                Task { @MainActor in
                    await self.applyChip(kind == .screen ? .screenFor(length) : .lidRemaining(min(length, Config.lidMaxDuration)))
                }
            }
            return
        }
        refresh()
    }

    // MARK: Clicks

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // A double-click is one click: the second mouse-up of a pair would
        // otherwise toggle screen mode straight back.
        if Self.isRepeatClick(clickCount: event?.clickCount ?? 1, isRightClick: event?.type == .rightMouseUp) { return }
        let action = Self.clickAction(
            isRightClick: event?.type == .rightMouseUp,
            controlHeld: event?.modifierFlags.contains(.control) ?? false,
            mode: Self.mode(lidActive: manager.isActive, awake: awake.state)
        )
        if action == .showMenu {
            showMenu()
            return
        }
        Task { @MainActor in await handle(action) }
    }

    /// The click's effect, apart from the menu. Internal so tests drive the
    /// cycle without a menu bar.
    func handle(_ action: ClickAction) async {
        switch action {
        case .turnOnScreen:
            awake.turnOn(for: nil)
            refresh()
        case .turnOffScreen:
            awake.turnOff(reason: "user")
            refresh()
        case .showMenu:
            break
        }
    }

    /// Starts a lid session, capped at 24 hours of closed-lid time
    /// (`Config.lidMaxDuration`). Shared by the click and the menu. A start
    /// already waiting on the prompt makes this one a no-op.
    func startLidSession(_ duration: TimeInterval) async {
        guard !lidStartInFlight else {
            Log.info("lid mode start ignored: one is already waiting on the administrator prompt")
            return
        }
        lidStartInFlight = true
        refresh()
        await manager.start(duration: min(duration, Config.lidMaxDuration))
        lidStartInFlight = false
        refresh()
    }

    /// The second and later mouse-ups of a multi-click on the left button.
    static func isRepeatClick(clickCount: Int, isRightClick: Bool) -> Bool {
        !isRightClick && clickCount > 1
    }

    /// Not assigned to `statusItem.menu`, which would swallow the left click
    /// that toggles screen mode.
    private func showMenu() {
        guard let button = statusItem.button else { return }
        // The lid and the battery are read right here, so the menu opens on
        // what the machine is doing now. The SSID and the throttled browser
        // list are whatever the last scan found: both have to be awaited,
        // and an open NSMenu blocks the main actor, so there is no moment at
        // which they could be filled into a menu that is already up. Kick
        // that scan off anyway, for the next opening.
        status.refreshInstant()
        status.refreshOnDemand()
        // Same for the foreign-sleep line: re-read the bit now, and let the
        // next opening drop the line if sleep is enabled again.
        Task { await manager.recheckForeignSleep() }
        let header = ModeHeaderView(
            model: headerModel(now: clock()),
            onTab: { [weak self] tab in Task { @MainActor in await self?.applyTab(tab) } },
            onChip: { [weak self] chip in Task { @MainActor in await self?.applyChip(chip) } }
        )
        openHeader = header
        let menu = StatusMenu.menu(
            Self.menuItems(manager: manager, status: status, awake: awake, now: clock()),
            header: header,
            target: self,
            settings: #selector(menuOpenSettings),
            quit: #selector(menuQuit),
            relaunchBrowser: #selector(menuRelaunchBrowser(_:)),
            stopWaitingForOutput: #selector(menuStopWaitingForOutput(_:))
        )
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        openHeader = nil
    }

    /// The menu's lines from what the session, screen mode and the status
    /// source report now. Static, so a test can check them without a status item.
    static func menuItems(manager: SessionManager, status: any StatusSource, awake: AwakeController, now: Date) -> [StatusMenu.Item] {
        let locationAuthorized = (status as? LiveStatusSource)?.locationPermission.isAuthorized ?? true
        return StatusMenu.items(
            mac: StatusMenu.macLines(
                battery: StatusLines.battery(percent: status.batteryPercent, isCharging: status.isCharging),
                batterySymbol: StatusLines.batterySymbol(percent: status.batteryPercent, isCharging: status.isCharging),
                thermal: StatusLines.thermal(ProcessInfo.processInfo.thermalState),
                wifi: StatusLines.wifi(ssid: status.wifiSSID, locationAuthorized: locationAuthorized, lastGap: status.lastGap),
                hotspot: StatusLines.hotspot(ssid: manager.config.hotspotSSID),
                // Only during a session: outputs still waiting for a device
                // outlive it and have their own warning and fix item.
                whileClosed: manager.isActive ? StatusLines.whileClosed(
                    frozenCount: status.frozenCount,
                    muted: !manager.state.savedAudioOutputs.isEmpty,
                    lowPower: manager.state.lowPowerSetByUs
                ) : nil
            ),
            sessionActive: manager.isActive,
            sleepHeld: manager.state.sleepDisabledByUs,
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
    /// `startLidSession` caps it at 24 hours. Internal so tests drive it.
    func customDuration(_ kind: DurationPrompt) -> TimeInterval? {
        guard let text = askDurationText(kind) else { return nil }
        guard let seconds = DurationParser.seconds(from: text) else {
            Log.info("custom \(kind == .lid ? "lid" : "screen") duration not understood: \(text.count) characters")
            showNotice(Self.unreadableDurationNotice)
            return nil
        }
        return seconds
    }

    /// A modal alert, so the field has the keyboard only while the person is
    /// typing in it.
    private static func askCustomDurationText(_ kind: DurationPrompt) -> String? {
        let alert = NSAlert()
        switch kind {
        case .screen:
            alert.messageText = "Keep the screen awake for how long?"
            alert.informativeText = "For example 90m, 3h or 1h30m."
        case .lid:
            alert.messageText = "Keep awake with the lid closed for how long?"
            alert.informativeText = "For example 90m, 3h or 1h30m. The most is 24 hours."
        }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "3h"
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
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
