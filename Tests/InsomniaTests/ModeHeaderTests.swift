import XCTest
@testable import Insomnia

/// The menu's Off | Screen | Lid header as a pure model (spec 2026-10-16
/// "The menu's top"). The AppKit view is in ModeHeaderViewTests.
final class ModeHeaderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTabsMirrorTheMode() {
        XCTAssertEqual(ModeHeader.tabTitles, ["Off", "Screen", "Lid"])
        XCTAssertEqual(ModeHeader.tab(for: .off), .off)
        XCTAssertEqual(ModeHeader.tab(for: .screen), .screen)
        XCTAssertEqual(ModeHeader.tab(for: .lid), .lid)
    }

    /// Spec "Tabs" table, every cell.
    func testTransitions() {
        XCTAssertEqual(ModeHeader.transition(from: .off, to: .off), .none)
        XCTAssertEqual(ModeHeader.transition(from: .off, to: .screen), .turnOnScreen)
        XCTAssertEqual(ModeHeader.transition(from: .off, to: .lid), .startLid)
        XCTAssertEqual(ModeHeader.transition(from: .screen, to: .off), .turnOffScreen)
        XCTAssertEqual(ModeHeader.transition(from: .screen, to: .screen), .none)
        XCTAssertEqual(ModeHeader.transition(from: .screen, to: .lid), .startLid)
        XCTAssertEqual(ModeHeader.transition(from: .lid, to: .off), .endLid)
        XCTAssertEqual(ModeHeader.transition(from: .lid, to: .screen), .endLidThenTurnOnScreen)
        XCTAssertEqual(ModeHeader.transition(from: .lid, to: .lid), .none)
    }

    /// The Lid tab answers the click at once (spec 2026-10-16 revisions):
    /// while the start runs it is selected, with no chips yet and a caption
    /// that says the start is under way. A failed start snaps it back.
    func testAPendingLidStartSelectsTheLidTab() {
        for mode in [StatusItemController.Mode.off, .screen] {
            let m = ModeHeader.model(mode: mode, awakeEndsAt: nil, screenChosen: nil, lidRemaining: nil, lidPaused: false, lidChosen: nil, lidStarting: true, now: now)
            XCTAssertEqual(m.selected, .lid, "\(mode)")
            XCTAssertTrue(m.chips.isEmpty, "\(mode)")
            XCTAssertEqual(m.caption, "Starting lid mode\u{2026}", "\(mode)")
        }
    }

    func testExplanations() {
        XCTAssertEqual(ModeHeader.explanation(for: .off, lidKeepsScreenOn: true), "The Mac sleeps as usual.")
        XCTAssertEqual(ModeHeader.explanation(for: .screen, lidKeepsScreenOn: true), "Keeps the Mac and its screen awake. Closing the lid still puts it to sleep.")
        XCTAssertEqual(ModeHeader.explanation(for: .lid, lidKeepsScreenOn: true), "Keeps the Mac running with the lid closed. While the lid is open, the screen stays on too.")
        XCTAssertEqual(ModeHeader.explanation(for: .lid, lidKeepsScreenOn: false), "Keeps the Mac running with the lid closed. While the lid is open, the screen sleeps as usual.")
    }

    func testTheModelCarriesTheExplanationAndTheStatus() {
        let lid = ModeHeader.model(mode: .lid, awakeEndsAt: nil, screenChosen: nil, lidRemaining: 3600, lidPaused: false, lidChosen: nil, lidKeepsScreenOn: false, now: now)
        XCTAssertTrue(lid.explanation.hasSuffix("the screen sleeps as usual."))
        XCTAssertEqual(lid.caption, "1:00 of closed-lid time left")
        XCTAssertFalse(lid.lidKeepsScreenOn)
        let starting = ModeHeader.model(mode: .off, awakeEndsAt: nil, screenChosen: nil, lidRemaining: nil, lidPaused: false, lidChosen: nil, lidStarting: true, now: now)
        XCTAssertEqual(starting.explanation, ModeHeader.explanation(for: .lid, lidKeepsScreenOn: true))
        let screen = ModeHeader.model(mode: .screen, awakeEndsAt: nil, screenChosen: nil, lidRemaining: nil, lidPaused: false, lidChosen: nil, now: now)
        XCTAssertEqual(screen.explanation, ModeHeader.explanation(for: .screen, lidKeepsScreenOn: true))
    }

    func testTheSetupButtonShowsOnlyForLidWithoutAHotspot() {
        func shows(_ mode: StatusItemController.Mode, _ configured: Bool) -> Bool {
            ModeHeader.model(mode: mode, awakeEndsAt: nil, screenChosen: nil, lidRemaining: 60, lidPaused: false, lidChosen: nil, hotspotConfigured: configured, now: now).showsHotspotSetup
        }
        XCTAssertTrue(shows(.lid, false))
        XCTAssertFalse(shows(.lid, true))
        XCTAssertFalse(shows(.screen, false))
        XCTAssertFalse(shows(.off, false))
    }

    func testOffHasNoChips() {
        let m = ModeHeader.model(mode: .off, awakeEndsAt: nil, screenChosen: nil, lidRemaining: nil, lidPaused: false, lidChosen: nil, now: now)
        XCTAssertEqual(m.selected, .off)
        XCTAssertTrue(m.chips.isEmpty)
        XCTAssertEqual(m.explanation, "The Mac sleeps as usual.")
        XCTAssertEqual(m.caption, "", "Off has no status line")
    }

    func testScreenChipsAndHighlight() {
        let untimed = ModeHeader.model(mode: .screen, awakeEndsAt: nil, screenChosen: nil, lidRemaining: nil, lidPaused: false, lidChosen: nil, now: now)
        XCTAssertEqual(untimed.chips.map(\.title), ["\u{221E}", "1 h", "2 h", "4 h", "Custom\u{2026}"])
        XCTAssertEqual(untimed.chips.map(\.accessibilityLabel), ["Until I turn it off", "1 hour", "2 hours", "4 hours", "Custom duration"])
        XCTAssertEqual(untimed.chips.map(\.action), [.screenFor(nil), .screenFor(3600), .screenFor(7200), .screenFor(14400), .screenCustom])
        XCTAssertEqual(untimed.chips.map(\.isSelected), [true, false, false, false, false])
        XCTAssertEqual(untimed.caption, "Until you turn it off")

        let timed = ModeHeader.model(mode: .screen, awakeEndsAt: now.addingTimeInterval(7200), screenChosen: 7200, lidRemaining: nil, lidPaused: false, lidChosen: nil, now: now)
        XCTAssertEqual(timed.chips.map(\.isSelected), [false, false, true, false, false])
        XCTAssertEqual(timed.caption, "2:00 left")

        let customTimed = ModeHeader.model(mode: .screen, awakeEndsAt: now.addingTimeInterval(5400), screenChosen: 5400, lidRemaining: nil, lidPaused: false, lidChosen: nil, now: now)
        XCTAssertEqual(customTimed.chips.map(\.isSelected), [false, false, false, false, true], "a custom length highlights Custom")
    }

    func testLidChipsCaptionAndHighlight() {
        let m = ModeHeader.model(mode: .lid, awakeEndsAt: nil, screenChosen: nil, lidRemaining: 7 * 3600 + 720, lidPaused: true, lidChosen: 8 * 3600, now: now)
        XCTAssertEqual(m.selected, .lid)
        XCTAssertEqual(m.chips.map(\.title), ["1 h", "2 h", "4 h", "8 h", "12 h", "Custom\u{2026}"])
        XCTAssertEqual(m.chips.map(\.action), [.lidRemaining(3600), .lidRemaining(7200), .lidRemaining(14400), .lidRemaining(28800), .lidRemaining(43200), .lidCustom])
        XCTAssertEqual(m.chips.map(\.isSelected), [false, false, false, true, false, false])
        XCTAssertEqual(m.caption, "7:12 of closed-lid time left \u{00B7} lid open, clock paused")
        let running = ModeHeader.model(mode: .lid, awakeEndsAt: nil, screenChosen: nil, lidRemaining: 3600, lidPaused: false, lidChosen: nil, now: now)
        XCTAssertEqual(running.caption, "1:00 of closed-lid time left")
        XCTAssertFalse(running.chips.contains(where: \.isSelected))
    }
}
