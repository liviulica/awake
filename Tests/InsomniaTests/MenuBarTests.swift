import AppKit
import XCTest
@testable import Insomnia

final class CountdownTests: XCTestCase {
    func testShortFormat() {
        XCTAssertEqual(Countdown.short(102 * 60), "1:42")
        XCTAssertEqual(Countdown.short(5 * 60), "0:05")
        XCTAssertEqual(Countdown.short(61), "0:02", "minutes round up so 0:00 only shows at the end")
        XCTAssertEqual(Countdown.short(-30), "0:00")
        XCTAssertEqual(Countdown.short(24 * 3600), "24:00")
    }
}

final class StatusMenuControlTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testIdleControls() {
        let items = StatusMenu.controlItems(awakeOn: false, awakeEndsAt: nil, lidRemaining: nil, lidPaused: false, now: now)
        XCTAssertEqual(items.map(\.title), ["Keep awake", "Keep awake for", "Keep awake with lid closed"])
        XCTAssertEqual(items[0].kind, .toggleAwake(isOn: false))
        guard case let .submenu(awake) = items[1].kind, case let .submenu(lid) = items[2].kind else {
            return XCTFail("expected two submenus")
        }
        XCTAssertEqual(awake.map(\.title), ["Until I turn it off", "1 hour", "2 hours", "4 hours"])
        XCTAssertEqual(awake.map(\.kind), [.awakeFor(nil), .awakeFor(3600), .awakeFor(7200), .awakeFor(14400)])
        XCTAssertEqual(lid.map(\.title), ["1 hour", "2 hours", "4 hours", "8 hours", "Custom\u{2026}"])
        XCTAssertEqual(lid.last?.kind, .startLid(nil))
    }

    func testTimedAwakeShowsTimeLeft() {
        let items = StatusMenu.controlItems(awakeOn: true, awakeEndsAt: now.addingTimeInterval(3600), lidRemaining: nil, lidPaused: false, now: now)
        XCTAssertEqual(items[0].title, "Keep awake \u{00B7} 1:00 left")
        XCTAssertEqual(items[0].kind, .toggleAwake(isOn: true))
    }

    func testLidSessionControls() {
        let items = StatusMenu.controlItems(awakeOn: false, awakeEndsAt: nil, lidRemaining: 102 * 60, lidPaused: false, now: now)
        XCTAssertEqual(items.map(\.title), ["Lid closed mode \u{00B7} 1:42 left", "Add 1 hour", "End now"])
        XCTAssertEqual(items.map(\.kind), [.info, .extendLid(3600), .endLid])
    }

    func testPausedLidSessionSaysTheClockWaitsForTheLid() {
        let items = StatusMenu.controlItems(awakeOn: false, awakeEndsAt: nil, lidRemaining: 102 * 60, lidPaused: true, now: now)
        XCTAssertEqual(items[0].title, "Lid closed mode \u{00B7} 1:42 left \u{00B7} paused while the lid is open")
    }

    func testControlsComeFirstThenASeparatorThenStatus() {
        let controls = StatusMenu.controlItems(awakeOn: false, awakeEndsAt: nil, lidRemaining: nil, lidPaused: false, now: now)
        let items = StatusMenu.items(controls: controls, thermal: "Temperature: normal", sessionActive: false, sleepHeld: false,
                                     machine: "Lid: open", actions: nil, throttledBrowsers: [], error: nil)
        XCTAssertEqual(items.prefix(4).map(\.kind).last, .separator)
        XCTAssertEqual(items[4].title, "Lid: open")
        XCTAssertEqual(items[5].title, "Temperature: normal")
        XCTAssertEqual(items.suffix(2).map(\.kind), [.settings, .quit])
    }

    func testThermalLine() {
        XCTAssertEqual(StatusLines.thermal(.nominal), "Temperature: normal")
        XCTAssertEqual(StatusLines.thermal(.fair), "Temperature: warm")
        XCTAssertEqual(StatusLines.thermal(.serious), "Temperature: hot")
        XCTAssertEqual(StatusLines.thermal(.critical), "Temperature: critical")
    }

    @MainActor
    func testMenuBuildsSubmenusWithLiveItems() {
        let controls = StatusMenu.controlItems(awakeOn: false, awakeEndsAt: nil, lidRemaining: nil, lidPaused: false, now: now)
        let s = #selector(NSObject.description)
        let menu = StatusMenu.menu(StatusMenu.items(controls: controls, sessionActive: false, sleepHeld: false, machine: nil,
                                                    actions: nil, throttledBrowsers: [], error: nil),
                                   target: nil, settings: s, quit: s, relaunchBrowser: s, stopWaitingForOutput: s,
                                   toggleAwake: s, awakeFor: s, startLid: s, extendLid: s, endLid: s)
        let lid = menu.items[2]
        XCTAssertEqual(lid.title, "Keep awake with lid closed")
        XCTAssertEqual(lid.submenu?.items.count, 5)
        XCTAssertEqual(lid.submenu?.items.first?.representedObject as? NSNumber, NSNumber(value: 3600.0))
        XCTAssertNil(lid.submenu?.items.last?.representedObject, "Custom… carries no duration")
        XCTAssertTrue(lid.submenu?.items.allSatisfy(\.isEnabled) ?? false)
    }
}

@MainActor
final class StatusItemControllerLogicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPresentation() {
        XCTAssertEqual(StatusItemController.presentation(lidRemaining: nil, awake: .off, now: now), .init(icon: .off, title: ""))
        XCTAssertEqual(StatusItemController.presentation(lidRemaining: nil, awake: .on(until: nil), now: now), .init(icon: .awake, title: ""))
        XCTAssertEqual(StatusItemController.presentation(lidRemaining: nil, awake: .on(until: now.addingTimeInterval(5400)), now: now),
                       .init(icon: .awake, title: "1:30"))
        XCTAssertEqual(StatusItemController.presentation(lidRemaining: 7200, awake: .off, now: now),
                       .init(icon: .lid, title: "2:00"))
    }

    func testLeftClickTogglesExceptDuringALidSession() {
        XCTAssertEqual(StatusItemController.clickAction(isRightClick: false, controlHeld: false, lidActive: false), .toggleAwake)
        XCTAssertEqual(StatusItemController.clickAction(isRightClick: true, controlHeld: false, lidActive: false), .showMenu)
        XCTAssertEqual(StatusItemController.clickAction(isRightClick: false, controlHeld: true, lidActive: false), .showMenu)
        XCTAssertEqual(StatusItemController.clickAction(isRightClick: false, controlHeld: false, lidActive: true), .showMenu)
    }

    func testLidSessionFoldsAwakeModeInAndLeavesNothingHeld() async {
        let h = Harness()
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        let a = FakeAwakeAssertion()
        let awake = AwakeController(assertion: a, clock: { h.clock.now })
        let c = StatusItemController(manager: m, status: PlaceholderStatus(), awake: awake, showSettings: {})
        defer { c.stop() }
        awake.turnOn(for: nil)
        await m.start(duration: 3600)
        c.stateChanged()
        XCTAssertEqual(awake.state, .off, "screen mode folds into lid mode")
        XCTAssertTrue(a.isHeld, "lid open: the screen stays on")
        h.clamshell.closed = true
        await m.lidClosedClock()
        c.stateChanged()
        XCTAssertFalse(a.isHeld, "lid closed: the display may sleep")
        _ = await m.end(reason: .user)
        c.stateChanged()
        XCTAssertFalse(a.isHeld)
        XCTAssertEqual(awake.state, .off, "ending the lid session does not bring screen mode back")
    }

    /// "Custom…" with text that is not a duration says so instead of doing
    /// nothing; a readable one is returned; a cancel is silent.
    func testAnUnreadableCustomDurationShowsANotice() {
        let h = Harness()
        defer { h.home.destroy() }
        let m = h.makeManager()
        let typed = Locked<String?>("soon")
        let notices = Locked<[String]>([])
        let c = StatusItemController(manager: m, status: PlaceholderStatus(), awake: AwakeController(assertion: FakeAwakeAssertion()),
                                     showSettings: {}, askDurationText: { typed.value }, showNotice: { notices.value.append($0) })
        defer { c.stop() }
        XCTAssertNil(c.customDuration())
        XCTAssertEqual(notices.value, ["Couldn't read that duration. Try 90m, 3h or 1h30m."])
        typed.value = "1h30m"
        XCTAssertEqual(c.customDuration(), 5400)
        typed.value = nil
        XCTAssertNil(c.customDuration())
        XCTAssertEqual(notices.value.count, 1, "a cancel says nothing")
    }

    /// The real path, with no hand-driven `stateChanged()`: the session
    /// change reaches the controller through observation, which holds the
    /// screen while the lid is open.
    func testObservationHoldsTheScreenWhenALidSessionStartsWithTheLidOpen() async {
        let h = Harness()
        defer { h.home.destroy() }
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        let a = FakeAwakeAssertion()
        let awake = AwakeController(assertion: a, clock: { h.clock.now })
        let c = StatusItemController(manager: m, status: PlaceholderStatus(), awake: awake, showSettings: {})
        defer { c.stop() }
        XCTAssertFalse(a.isHeld)
        await m.start(duration: 3600)
        await pollUntil("observation never delivered the lid session to screen mode") { a.isHeld }
        XCTAssertTrue(awake.lidHoldActive)
    }
}

/// The menu's status block, the relaunch flow and the status-source
/// placeholder (moved here from Insomnia's UIStatusTests when the pill UI
/// and its tests went).
final class StatusMenuTests: XCTestCase {
    private static let chrome = ThrottledBrowser(bundleId: "com.google.Chrome", name: "Chrome")
    private static let arc = ThrottledBrowser(bundleId: "company.thebrowser.Browser", name: "Arc")

    func testSleepHeldLine() {
        XCTAssertEqual(
            SleepHeldLine.line(sessionActive: true, sleepHeld: true),
            SleepHeldLine.Line(text: "Sleep held per journal \u{2014} not verified live", isWarning: false)
        )
        XCTAssertEqual(
            SleepHeldLine.line(sessionActive: true, sleepHeld: false),
            SleepHeldLine.Line(text: "Sleep is not held \u{2014} this session is not keeping the Mac awake", isWarning: true)
        )
        XCTAssertEqual(
            SleepHeldLine.line(sessionActive: false, sleepHeld: true),
            SleepHeldLine.Line(text: "Sleep still held with no session", isWarning: true)
        )
        XCTAssertNil(SleepHeldLine.line(sessionActive: false, sleepHeld: false))
    }

    @MainActor
    func testPlaceholderReportsNothing() {
        let s = PlaceholderStatus()
        XCTAssertFalse(s.lidClosed)
        XCTAssertNil(s.batteryPercent)
        XCTAssertFalse(s.isCharging)
        XCTAssertNil(s.wifiSSID)
        XCTAssertNil(s.lastGap)
        XCTAssertEqual(s.frozenCount, 0)
        XCTAssertTrue(s.throttledBrowsers.isEmpty)
        XCTAssertNil(s.hotspotPasswordReport)
        XCTAssertNil(s.instantWatts())
        s.refreshInstant()
        s.refreshOnDemand()
        s.relaunchUnthrottled(ThrottledBrowser(bundleId: "com.google.Chrome", name: "Chrome"))
    }

    func testMachineLine() {
        XCTAssertEqual(
            StatusLines.machine(lidClosed: true, watts: 4.12, wifiSSID: "iPhone", batteryPercent: nil, isCharging: false),
            "Lid: closed \u{00B7} 4.1 W \u{00B7} Wi-Fi: iPhone"
        )
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: nil, wifiSSID: nil, batteryPercent: nil, isCharging: false),
            "Lid: open"
        )
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: nil, wifiSSID: "", batteryPercent: 82, isCharging: true),
            "Lid: open \u{00B7} 82% charging"
        )
    }

    func testActionsLine() {
        XCTAssertNil(StatusLines.actions(frozenCount: 0, lastGap: nil))
        XCTAssertEqual(StatusLines.actions(frozenCount: 3, lastGap: nil), "3 apps frozen")
        XCTAssertEqual(StatusLines.actions(frozenCount: 1, lastGap: 12.4), "1 app frozen \u{00B7} last gap 12s")
        XCTAssertNil(StatusLines.actions(frozenCount: 0, lastGap: 0))
    }

    func testThrottleWarning() {
        XCTAssertNil(StatusLines.throttleWarning([]))
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome"]), "\u{26A0} Chrome is throttled")
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome", "Arc"]), "\u{26A0} Chrome and Arc are throttled")
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome", "Arc", "Chromium"]), "\u{26A0} Chrome, Arc, and Chromium are throttled")
    }

    func testMenuListsStatusThenSettingsAndQuit() {
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            machine: "Lid: closed \u{00B7} 82%",
            actions: "3 apps frozen",
            throttledBrowsers: [Self.chrome],
            error: nil
        )
        XCTAssertEqual(items, [
            StatusMenu.Item(title: "Sleep held per journal \u{2014} not verified live", kind: .info),
            StatusMenu.Item(title: "Lid: closed \u{00B7} 82%", kind: .info),
            StatusMenu.Item(title: "3 apps frozen", kind: .info),
            StatusMenu.Item(title: "\u{26A0} Chrome is throttled", kind: .warning),
            StatusMenu.Item(title: "Relaunch Chrome unthrottled", kind: .relaunchBrowser(Self.chrome)),
            StatusMenu.Item(title: "", kind: .separator),
            StatusMenu.Item(title: StatusMenu.settingsTitle, kind: .settings),
            StatusMenu.Item(title: StatusMenu.quitTitle, kind: .quit),
        ])
    }

    func testIdleMenuIsJustSettingsAndQuitWithNoLeadingSeparator() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
            actions: nil,
            throttledBrowsers: [],
            error: ""
        )
        XCTAssertEqual(items, [
            StatusMenu.Item(title: StatusMenu.settingsTitle, kind: .settings),
            StatusMenu.Item(title: StatusMenu.quitTitle, kind: .quit),
        ])
        XCTAssertFalse(items.contains { $0.kind == .separator })
    }

    func testMenuShowsTheLastErrorAsAWarning() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
            actions: nil,
            throttledBrowsers: [],
            error: "sudo: a password is required"
        )
        XCTAssertEqual(items.first, StatusMenu.Item(title: "\u{26A0} sudo: a password is required", kind: .warning))
        XCTAssertEqual(items.map(\.kind), [.warning, .separator, .settings, .quit])
    }

    /// A hotspot join skipped for want of a password is a warning line in
    /// the menu, between the browser items and the session error, so the
    /// failure is never silent.
    func testMenuShowsTheHotspotPasswordProblemAsAWarning() {
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            machine: nil,
            actions: nil,
            throttledBrowsers: [Self.chrome],
            hotspotWarning: HotspotPasswordProblem.unreadable.menuLine,
            error: "sudo: a password is required"
        )
        XCTAssertEqual(
            items.map(\.kind),
            [.info, .warning, .relaunchBrowser(Self.chrome), .warning, .warning, .separator, .settings, .quit]
        )
        XCTAssertEqual(items[3], StatusMenu.Item(
            title: "\u{26A0} Hotspot password unreadable by this build: enter it again in Settings",
            kind: .warning
        ))
        XCTAssertEqual(
            StatusMenu.items(sessionActive: false, sleepHeld: false, machine: nil, actions: nil, throttledBrowsers: [], hotspotWarning: nil, error: nil).map(\.kind),
            [.settings, .quit]
        )
    }

    /// Each problem has a menu line, a sentence for the notification, and a
    /// Settings notice except for a missing item, where the empty field is
    /// the notice.
    func testHotspotPasswordProblemCopy() {
        XCTAssertEqual(HotspotPasswordProblem.missing.menuLine, "\u{26A0} Hotspot password not saved: enter it in Settings")
        XCTAssertNil(HotspotPasswordProblem.missing.settingsNotice)
        XCTAssertTrue(HotspotPasswordProblem.unreadable.settingsNotice?.contains("Enter it again and save") ?? false)
        XCTAssertTrue(HotspotPasswordProblem.unreadable.explanation.hasSuffix("Enter it again in Settings."))
        XCTAssertEqual(HotspotPasswordProblem.error("keychain: boom").menuLine, "\u{26A0} Hotspot password unreadable: keychain: boom")
        XCTAssertEqual(HotspotPasswordProblem.error("keychain: boom").settingsNotice, "The saved password can't be read: keychain: boom")
        XCTAssertEqual(KeychainError(status: errSecAuthFailed).problem, .unreadable)
        XCTAssertEqual(KeychainError(status: errSecInteractionNotAllowed).problem, .unreadable)
        XCTAssertEqual(KeychainError(status: errSecInvalidOwnerEdit).problem, .unreadable)
        XCTAssertEqual(KeychainError(status: errSecParam).problem, .error("keychain: One or more parameters passed to a function were not valid."))
    }

    /// The relaunch item asks first, since the browser is quit and its
    /// windows come back only through its own session restore. Cancel
    /// hands nothing on; confirming hands on the bundle id and name the
    /// item carried, even when a scan emptied the list during the alert.
    @MainActor
    func testRelaunchAsksBeforeQuittingAndCancelDoesNothing() {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let source = RecordingStatusSource()
        source.throttledBrowsers = [Self.chrome, Self.arc]
        let asked = Locked<[String]>([])
        let answer = Locked(false)
        let controller = StatusItemController(
            manager: h.makeManager(),
            status: source,
            awake: AwakeController(assertion: FakeAwakeAssertion()),
            showSettings: {},
            confirmRelaunch: { name in
                asked.value.append(name)
                source.throttledBrowsers = []
                return answer.value
            }
        )
        defer { controller.stop() }

        controller.relaunchBrowser(Self.chrome)
        XCTAssertEqual(asked.value, ["Chrome"])
        XCTAssertEqual(source.relaunched, [])

        answer.value = true
        controller.relaunchBrowser(Self.arc)
        XCTAssertEqual(asked.value, ["Chrome", "Arc"])
        XCTAssertEqual(source.relaunched, [Self.arc])
    }

    /// The prompt names the browser, says the windows depend on the
    /// browser's own startup setting, and gives the 10 s rule.
    func testRelaunchPromptCopy() {
        let prompt = RelaunchPrompt(browser: "Chrome")
        XCTAssertEqual(prompt.title, "Quit and relaunch Chrome?")
        XCTAssertEqual(
            prompt.message,
            "Ember quits Chrome and opens it again with the two flags that stop it throttling hidden windows. Your windows and tabs come back only if Chrome is set to reopen them on startup. If Chrome has not quit after 10 s, nothing is relaunched."
        )
        XCTAssertEqual(RelaunchPrompt.confirmTitle, "Quit and relaunch")
        XCTAssertEqual(RelaunchPrompt.cancelTitle, "Cancel")
    }

    /// Greptile caught this as a regression: replacing the popover with a
    /// menu left the throttle warning with no way to act on it.
    func testEveryThrottledBrowserGetsItsOwnRelaunchItem() {
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            machine: nil,
            actions: nil,
            throttledBrowsers: [Self.chrome, Self.arc],
            error: nil
        )
        XCTAssertEqual(items.filter { $0.kind == .relaunchBrowser(Self.chrome) }.count, 1)
        XCTAssertEqual(items.filter { $0.kind == .relaunchBrowser(Self.arc) }.count, 1)
        XCTAssertEqual(
            items.map(\.kind),
            [.info, .warning, .relaunchBrowser(Self.chrome), .relaunchBrowser(Self.arc), .separator, .settings, .quit]
        )
    }
}

/// A status source that records relaunch requests and reports nothing else.
@MainActor
@Observable
final class RecordingStatusSource: StatusSource {
    var lidClosed = false
    var batteryPercent: Int? = nil
    var isCharging = false
    var wifiSSID: String? = nil
    var lastGap: TimeInterval? = nil
    var frozenCount = 0
    var throttledBrowsers: [ThrottledBrowser] = []
    var relaunchProblems: [String] = []
    var hotspotPasswordReport: HotspotPasswordReport? = nil
    private(set) var relaunched: [ThrottledBrowser] = []

    func refreshOnDemand() {}
    func refreshInstant() {}
    func instantWatts() -> Double? { nil }
    func relaunchUnthrottled(_ browser: ThrottledBrowser) { relaunched.append(browser) }
}
