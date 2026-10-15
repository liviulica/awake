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
        let items = StatusMenu.controlItems(awakeOn: false, awakeEndsAt: nil, lidRemaining: nil, lidPaused: false, clickDuration: 8 * 3600, now: now)
        XCTAssertEqual(items.map(\.title), ["Keep screen awake", "Keep screen awake for", "Lid closed for 8 hours", "Lid closed for"])
        XCTAssertEqual(items[0].kind, .toggleAwake(isOn: false))
        XCTAssertEqual(items[0].symbol, MenuSymbol.flame)
        XCTAssertEqual(items[2].kind, .startLid(8 * 3600))
        XCTAssertEqual(items[2].symbol, MenuSymbol.lid)
        guard case let .submenu(awake) = items[1].kind, case let .submenu(lid) = items[3].kind else {
            return XCTFail("expected two submenus")
        }
        XCTAssertEqual(awake.map(\.title), ["Until I turn it off", "1 hour", "2 hours", "4 hours"])
        XCTAssertEqual(awake.map(\.kind), [.awakeFor(nil), .awakeFor(3600), .awakeFor(7200), .awakeFor(14400)])
        XCTAssertEqual(lid.map(\.title), ["1 hour", "2 hours", "4 hours", "8 hours", "12 hours", "Custom\u{2026}"])
        XCTAssertEqual(lid.last?.kind, .startLid(nil))
    }

    func testTheOneClickLidItemReadsTheSetting() {
        let items = StatusMenu.controlItems(awakeOn: false, awakeEndsAt: nil, lidRemaining: nil, lidPaused: false, clickDuration: 2 * 3600, now: now)
        XCTAssertEqual(items[2].title, "Lid closed for 2 hours")
        XCTAssertEqual(items[2].kind, .startLid(7200))
    }

    func testTimedAwakeShowsTimeLeft() {
        let items = StatusMenu.controlItems(awakeOn: true, awakeEndsAt: now.addingTimeInterval(3600), lidRemaining: nil, lidPaused: false, clickDuration: 8 * 3600, now: now)
        XCTAssertEqual(items[0].title, "Keep screen awake \u{00B7} 1:00 left")
        XCTAssertEqual(items[0].kind, .toggleAwake(isOn: true))
    }

    func testLidSessionControls() {
        let items = StatusMenu.controlItems(awakeOn: false, awakeEndsAt: nil, lidRemaining: 102 * 60, lidPaused: false, clickDuration: 8 * 3600, now: now)
        XCTAssertEqual(items.map(\.title), ["Lid mode \u{00B7} 1:42 left", "Add 1 hour", "End now"])
        XCTAssertEqual(items.map(\.kind), [.info, .extendLid(3600), .endLid])
        XCTAssertEqual(items.map(\.symbol), [MenuSymbol.lid, MenuSymbol.add, MenuSymbol.end])
    }

    func testPausedLidSessionSaysTheClockWaitsForTheLid() {
        let items = StatusMenu.controlItems(awakeOn: false, awakeEndsAt: nil, lidRemaining: 102 * 60, lidPaused: true, clickDuration: 8 * 3600, now: now)
        XCTAssertEqual(items[0].title, "Lid mode \u{00B7} 1:42 left \u{00B7} lid open, clock paused")
    }

    func testControlsThenMacBlockThenSettings() {
        let controls = StatusMenu.controlItems(awakeOn: false, awakeEndsAt: nil, lidRemaining: nil, lidPaused: false, clickDuration: 8 * 3600, now: now)
        let mac = StatusMenu.macLines(battery: "Battery 68%, charging", batterySymbol: "battery.100percent.bolt",
                                      thermal: "Temperature normal", wifi: nil, hotspot: nil, whileClosed: nil)
        let items = StatusMenu.items(controls: controls, mac: mac, sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: nil)
        XCTAssertEqual(items.map(\.kind), [
            .toggleAwake(isOn: false), .submenu(controls[1].children), .startLid(8 * 3600), .submenu(controls[3].children),
            .separator, .header, .info, .info, .separator, .settings, .quit,
        ])
        XCTAssertEqual(items[5].title, StatusMenu.headerTitle)
        XCTAssertEqual(items[6], StatusMenu.Item(title: "Battery 68%, charging", kind: .info, symbol: "battery.100percent.bolt"))
        XCTAssertEqual(items[7], StatusMenu.Item(title: "Temperature normal", kind: .info, symbol: MenuSymbol.thermal))
        XCTAssertEqual(items.last?.title, StatusMenu.quitTitle)
        XCTAssertEqual(items[items.count - 2].symbol, MenuSymbol.settings)
    }

    /// Review focus 5: a desktop with nothing known shows only the
    /// temperature, and a block with no lines shows no header either.
    func testMacBlockDropsUnknownLinesAndItsHeaderWhenEmpty() {
        let mac = StatusMenu.macLines(battery: nil, batterySymbol: nil, thermal: "Temperature normal", wifi: nil, hotspot: nil, whileClosed: nil)
        XCTAssertEqual(mac.map(\.title), ["Temperature normal"])
        let items = StatusMenu.items(controls: [], mac: [], sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: nil)
        XCTAssertEqual(items.map(\.kind), [.settings, .quit])
    }

    func testThermalLine() {
        XCTAssertEqual(StatusLines.thermal(.nominal), "Temperature normal")
        XCTAssertEqual(StatusLines.thermal(.fair), "Temperature warm")
        XCTAssertEqual(StatusLines.thermal(.serious), "Temperature hot")
        XCTAssertEqual(StatusLines.thermal(.critical), "Temperature critical")
    }

    @MainActor
    func testMenuBuildsSubmenusHeadersAndSymbols() {
        let controls = StatusMenu.controlItems(awakeOn: false, awakeEndsAt: nil, lidRemaining: nil, lidPaused: false, clickDuration: 8 * 3600, now: now)
        let mac = StatusMenu.macLines(battery: "Battery 68%", batterySymbol: "battery.75percent", thermal: "Temperature normal",
                                      wifi: "Wi-Fi: Home", hotspot: nil, whileClosed: nil)
        let s = #selector(NSObject.description)
        let menu = StatusMenu.menu(StatusMenu.items(controls: controls, mac: mac, sessionActive: false, sleepHeld: false,
                                                    throttledBrowsers: [], error: nil),
                                   target: nil, settings: s, quit: s, relaunchBrowser: s, stopWaitingForOutput: s,
                                   toggleAwake: s, awakeFor: s, startLid: s, extendLid: s, endLid: s)
        let lid = menu.items[3]
        XCTAssertEqual(lid.title, "Lid closed for")
        XCTAssertEqual(lid.submenu?.items.count, 6)
        XCTAssertEqual(lid.submenu?.items.first?.representedObject as? NSNumber, NSNumber(value: 3600.0))
        XCTAssertNil(lid.submenu?.items.last?.representedObject, "Custom… carries no duration")
        XCTAssertTrue(lid.submenu?.items.allSatisfy(\.isEnabled) ?? false)
        XCTAssertEqual(menu.items[2].representedObject as? NSNumber, NSNumber(value: 28800.0), "the one-click item carries 8 h")
        XCTAssertTrue(menu.items[5].isSectionHeader, "the Mac header is a section header")
        XCTAssertNotNil(menu.items[0].image, "symbols are attached")
        XCTAssertNil(menu.items[6].attributedTitle, "status lines use the menu's own font, no small text")
        XCTAssertFalse(menu.items[6].isEnabled)
    }

    /// Review focus 4: a symbol macOS does not have leaves the item's text
    /// alone and attaches no image.
    @MainActor
    func testAnUnknownSymbolIsNoImage() {
        let s = #selector(NSObject.description)
        let items = [StatusMenu.Item(title: "Temperature normal", kind: .info, symbol: "no.such.symbol.ember")]
        let menu = StatusMenu.menu(items, target: nil, settings: s, quit: s, relaunchBrowser: s, stopWaitingForOutput: s)
        XCTAssertEqual(menu.items.first?.title, "Temperature normal")
        XCTAssertNil(menu.items.first?.image)
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

    func testModeFromSessionAndScreenState() {
        XCTAssertEqual(StatusItemController.mode(lidActive: false, awake: .off), .off)
        XCTAssertEqual(StatusItemController.mode(lidActive: false, awake: .on(until: nil)), .screen)
        XCTAssertEqual(StatusItemController.mode(lidActive: false, awake: .on(until: now)), .screen)
        XCTAssertEqual(StatusItemController.mode(lidActive: true, awake: .off), .lid)
        XCTAssertEqual(StatusItemController.mode(lidActive: true, awake: .on(until: nil)), .lid, "a lid session wins")
    }

    /// Spec "Left-click": off → screen → lid → off; right-click and
    /// ctrl-click open the menu in every state.
    func testLeftClickCyclesAndModifiedClicksOpenTheMenu() {
        XCTAssertEqual(StatusItemController.clickAction(isRightClick: false, controlHeld: false, mode: .off), .turnOnScreen)
        XCTAssertEqual(StatusItemController.clickAction(isRightClick: false, controlHeld: false, mode: .screen), .startLid)
        XCTAssertEqual(StatusItemController.clickAction(isRightClick: false, controlHeld: false, mode: .lid), .endLid)
        for mode in [StatusItemController.Mode.off, .screen, .lid] {
            XCTAssertEqual(StatusItemController.clickAction(isRightClick: true, controlHeld: false, mode: mode), .showMenu, "\(mode)")
            XCTAssertEqual(StatusItemController.clickAction(isRightClick: false, controlHeld: true, mode: mode), .showMenu, "\(mode)")
        }
    }

    /// The cycle against a real manager: a click from screen mode starts a
    /// lid session of the configured length and folds screen mode in; a
    /// click during it (lid open, so the session is paused: review focus
    /// 3) ends it and leaves nothing held.
    func testClickCycleStartsAnEightHourSessionAndEndsIt() async {
        let h = Harness()
        defer { h.home.destroy() }
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        let a = FakeAwakeAssertion()
        let awake = AwakeController(assertion: a, clock: { h.clock.now })
        let c = StatusItemController(manager: m, status: PlaceholderStatus(), awake: awake, showSettings: {})
        defer { c.stop() }

        await c.handle(.turnOnScreen)
        XCTAssertEqual(awake.state, .on(until: nil))
        XCTAssertTrue(a.isHeld)

        await c.handle(.startLid)
        c.stateChanged()
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.session?.isPaused, true, "lid open: the closed-lid clock waits")
        XCTAssertEqual(m.session?.closedLidRemaining(at: h.clock.now) ?? 0, 8 * 3600, accuracy: 1)
        XCTAssertEqual(awake.state, .off, "screen mode folds into lid mode")
        XCTAssertTrue(a.isHeld, "lid open: the screen stays on")

        await c.handle(.endLid)
        c.stateChanged()
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(awake.state, .off)
        XCTAssertFalse(a.isHeld)
    }

    /// A double-click is one step of the cycle; right-click is never a
    /// repeat.
    func testTheSecondMouseUpOfADoubleClickIsIgnored() {
        XCTAssertFalse(StatusItemController.isRepeatClick(clickCount: 1, isRightClick: false))
        XCTAssertTrue(StatusItemController.isRepeatClick(clickCount: 2, isRightClick: false))
        XCTAssertTrue(StatusItemController.isRepeatClick(clickCount: 3, isRightClick: false))
        XCTAssertFalse(StatusItemController.isRepeatClick(clickCount: 2, isRightClick: true))
    }

    /// A second start while the first waits on the administrator prompt
    /// returns at once instead of queuing behind it, so a cancel of the
    /// first prompt can never bring up a second one. The gate holds the
    /// first start inside `disablesleep 1`, where the prompt would be.
    func testAStartDuringThePromptIsIgnored() async {
        let h = Harness()
        defer { h.home.destroy() }
        h.clamshell.closed = false
        let gate = AsyncGate()
        h.guardFake.sleepGate = gate
        let m = h.makeManager(closedLidClock: true)
        let awake = AwakeController(assertion: FakeAwakeAssertion(), clock: { h.clock.now })
        let c = StatusItemController(manager: m, status: PlaceholderStatus(), awake: awake, showSettings: {})
        defer { c.stop() }

        let first = Task { await c.startLidSession(8 * 3600) }
        await gate.waitUntilStarted()
        XCTAssertTrue(c.lidStartInFlight)
        await c.startLidSession(8 * 3600)
        XCTAssertFalse(m.isActive, "the second start returned while the first still waits on the prompt")
        await gate.open()
        await first.value

        XCTAssertFalse(c.lidStartInFlight)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, 1, "one prompt: \(h.guardFake.calls)")
    }

    /// Review focus 2: a start that does not take (the administrator prompt
    /// cancelled) leaves screen mode on and no session. A cancel is the
    /// person's own choice, so the manager logs it and shows no error.
    func testACancelledLidStartLeavesScreenModeOn() async {
        let h = Harness()
        defer { h.home.destroy() }
        h.clamshell.closed = false
        h.guardFake.cancelDisable = true
        let m = h.makeManager(closedLidClock: true)
        let a = FakeAwakeAssertion()
        let awake = AwakeController(assertion: a, clock: { h.clock.now })
        let c = StatusItemController(manager: m, status: PlaceholderStatus(), awake: awake, showSettings: {})
        defer { c.stop() }
        await c.handle(.turnOnScreen)
        await c.handle(.startLid)
        c.stateChanged()
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(awake.state, .on(until: nil), "screen mode is untouched")
        XCTAssertTrue(a.isHeld)
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
            SleepHeldLine.Line(text: "Sleep off while the lid is closed", isWarning: false)
        )
        XCTAssertEqual(
            SleepHeldLine.line(sessionActive: true, sleepHeld: false),
            SleepHeldLine.Line(text: "Sleep is not off: this session is not keeping the Mac awake", isWarning: true)
        )
        XCTAssertEqual(
            SleepHeldLine.line(sessionActive: false, sleepHeld: true),
            SleepHeldLine.Line(text: "Sleep is still off with no session running", isWarning: true)
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

    func testBatteryLine() {
        XCTAssertEqual(StatusLines.battery(percent: 68, isCharging: true), "Battery 68%, charging")
        XCTAssertEqual(StatusLines.battery(percent: 68, isCharging: false), "Battery 68%")
        XCTAssertNil(StatusLines.battery(percent: nil, isCharging: true), "a desktop has no battery line")
        XCTAssertEqual(StatusLines.batterySymbol(percent: 68, isCharging: true), "battery.100percent.bolt")
        XCTAssertEqual(StatusLines.batterySymbol(percent: 68, isCharging: false), "battery.75percent")
        XCTAssertEqual(StatusLines.batterySymbol(percent: 12, isCharging: false), "battery.0percent")
        XCTAssertEqual(StatusLines.batterySymbol(percent: 13, isCharging: false), "battery.25percent")
        XCTAssertEqual(StatusLines.batterySymbol(percent: 100, isCharging: false), "battery.100percent")
        XCTAssertNil(StatusLines.batterySymbol(percent: nil, isCharging: false))
    }

    func testWiFiLine() {
        XCTAssertEqual(StatusLines.wifi(ssid: "Home", locationAuthorized: true, lastGap: nil), "Wi-Fi: Home")
        XCTAssertEqual(StatusLines.wifi(ssid: "Home", locationAuthorized: true, lastGap: 12.4), "Wi-Fi: Home \u{00B7} last outage 12 s")
        XCTAssertEqual(StatusLines.wifi(ssid: nil, locationAuthorized: false, lastGap: nil), "Wi-Fi on \u{00B7} name needs Location access")
        XCTAssertNil(StatusLines.wifi(ssid: nil, locationAuthorized: true, lastGap: 30), "nothing known: no line, even after an outage")
        XCTAssertEqual(StatusLines.wifi(ssid: "", locationAuthorized: false, lastGap: 0), "Wi-Fi on \u{00B7} name needs Location access")
    }

    func testHotspotAndWhileClosedLines() {
        XCTAssertEqual(StatusLines.hotspot(ssid: "iPhone"), "Hotspot failover: iPhone")
        XCTAssertNil(StatusLines.hotspot(ssid: ""))
        XCTAssertNil(StatusLines.whileClosed(frozenCount: 0, muted: false, lowPower: false))
        XCTAssertEqual(StatusLines.whileClosed(frozenCount: 1, muted: false, lowPower: false), "While closed: 1 app frozen")
        XCTAssertEqual(
            StatusLines.whileClosed(frozenCount: 2, muted: true, lowPower: true),
            "While closed: 2 apps frozen \u{00B7} audio muted \u{00B7} Low Power Mode"
        )
        XCTAssertEqual(StatusLines.whileClosed(frozenCount: 0, muted: true, lowPower: false), "While closed: audio muted")
    }

    func testThrottleWarning() {
        XCTAssertEqual(StatusLines.throttleWarning("Arc"), "Arc pauses hidden tabs; agents in it may stall")
    }

    func testMenuListsSleepLineMacBlockWarningsThenSettingsAndQuit() {
        let mac = StatusMenu.macLines(battery: "Battery 82%", batterySymbol: "battery.75percent", thermal: nil, wifi: nil, hotspot: nil,
                                      whileClosed: "While closed: 3 apps frozen")
        let items = StatusMenu.items(controls: [], mac: mac, sessionActive: true, sleepHeld: true, throttledBrowsers: [Self.chrome], error: nil)
        XCTAssertEqual(items, [
            StatusMenu.Item(title: StatusMenu.headerTitle, kind: .header),
            StatusMenu.Item(title: "Sleep off while the lid is closed", kind: .info, symbol: MenuSymbol.sleep),
            StatusMenu.Item(title: "Battery 82%", kind: .info, symbol: "battery.75percent"),
            StatusMenu.Item(title: "While closed: 3 apps frozen", kind: .info, symbol: MenuSymbol.closed),
            StatusMenu.Item(title: "", kind: .separator),
            StatusMenu.Item(title: "Chrome pauses hidden tabs; agents in it may stall", kind: .warning, symbol: MenuSymbol.warning),
            StatusMenu.Item(title: "Relaunch Chrome without throttling\u{2026}", kind: .relaunchBrowser(Self.chrome), symbol: MenuSymbol.relaunch),
            StatusMenu.Item(title: "", kind: .separator),
            StatusMenu.Item(title: StatusMenu.settingsTitle, kind: .settings, symbol: MenuSymbol.settings),
            StatusMenu.Item(title: StatusMenu.quitTitle, kind: .quit),
        ])
    }

    func testIdleMenuIsJustSettingsAndQuitWithNoLeadingSeparator() {
        let items = StatusMenu.items(sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: "")
        XCTAssertEqual(items.map(\.kind), [.settings, .quit])
        XCTAssertFalse(items.contains { $0.kind == .separator })
    }

    func testMenuShowsTheLastErrorAsAWarning() {
        let items = StatusMenu.items(sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: "sudo: a password is required")
        XCTAssertEqual(items.first, StatusMenu.Item(title: "sudo: a password is required", kind: .warning, symbol: MenuSymbol.warning))
        XCTAssertEqual(items.map(\.kind), [.warning, .separator, .settings, .quit])
    }

    /// The sleep warning stays in the Mac block, first: it is about the Mac.
    func testASleepWarningLeadsTheMacBlock() {
        let items = StatusMenu.items(sessionActive: true, sleepHeld: false, throttledBrowsers: [], error: nil)
        XCTAssertEqual(items.map(\.kind), [.header, .warning, .separator, .settings, .quit])
        XCTAssertEqual(items[1], StatusMenu.Item(title: "Sleep is not off: this session is not keeping the Mac awake", kind: .warning, symbol: MenuSymbol.warning))
    }

    /// A hotspot join skipped for want of a password is a warning line in
    /// the menu, between the browser items and the session error, so the
    /// failure is never silent. The "⚠" the line carries is dropped: the
    /// symbol says it.
    func testMenuShowsTheHotspotPasswordProblemAsAWarning() {
        let items = StatusMenu.items(sessionActive: true, sleepHeld: true, throttledBrowsers: [Self.chrome],
                                     hotspotWarning: HotspotPasswordProblem.unreadable.menuLine, error: "sudo: a password is required")
        XCTAssertEqual(
            items.map(\.kind),
            [.header, .info, .separator, .warning, .relaunchBrowser(Self.chrome), .warning, .warning, .separator, .settings, .quit]
        )
        XCTAssertEqual(items[5], StatusMenu.Item(
            title: "Hotspot password unreadable by this build: enter it again in Settings", kind: .warning, symbol: MenuSymbol.warning
        ))
        XCTAssertEqual(StatusMenu.items(sessionActive: false, sleepHeld: false, throttledBrowsers: [], hotspotWarning: nil, error: nil).map(\.kind), [.settings, .quit])
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
    func testEveryThrottledBrowserGetsItsOwnWarningAndRelaunchItem() {
        let items = StatusMenu.items(sessionActive: true, sleepHeld: true, throttledBrowsers: [Self.chrome, Self.arc], error: nil)
        XCTAssertEqual(items.filter { $0.kind == .relaunchBrowser(Self.chrome) }.count, 1)
        XCTAssertEqual(items.filter { $0.kind == .relaunchBrowser(Self.arc) }.count, 1)
        XCTAssertEqual(
            items.map(\.kind),
            [.header, .info, .separator, .warning, .relaunchBrowser(Self.chrome), .warning, .relaunchBrowser(Self.arc), .separator, .settings, .quit]
        )
        XCTAssertEqual(items[5].title, "Arc pauses hidden tabs; agents in it may stall")
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

private extension StatusMenu.Item {
    var children: [StatusMenu.Item] {
        if case let .submenu(items) = kind { return items }
        return []
    }
}
