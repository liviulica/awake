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
        awake.turnOn(for: nil)
        await m.start(duration: 3600)
        c.stateChanged()
        XCTAssertEqual(awake.state, .off, "Awake mode folds into lid mode")
        XCTAssertTrue(a.isHeld, "lid open: the screen stays on")
        h.clamshell.closed = true
        await m.lidClosedClock()
        c.stateChanged()
        XCTAssertFalse(a.isHeld, "lid closed: the display may sleep")
        _ = await m.end(reason: .user)
        c.stateChanged()
        XCTAssertFalse(a.isHeld)
        XCTAssertEqual(awake.state, .off, "ending the lid session does not bring Awake mode back")
    }
}
