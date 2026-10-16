import AppKit
import XCTest
@testable import Insomnia

/// The AppKit header built in a test: nothing is shown on screen.
@MainActor
final class ModeHeaderViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheViewShowsTheModelAndReportsClicks() {
        var tabs: [ModeHeader.Tab] = []
        var chips: [ModeHeader.ChipAction] = []
        let screen = ModeHeader.model(mode: .screen, awakeEndsAt: nil, screenChosen: nil, lidRemaining: nil, lidPaused: false, lidChosen: nil, now: now)
        let v = ModeHeaderView(model: screen, onTab: { tabs.append($0) }, onChip: { chips.append($0) })
        XCTAssertEqual(v.segments.segmentCount, 3)
        XCTAssertEqual(v.segments.selectedSegment, ModeHeader.Tab.screen.rawValue)
        XCTAssertEqual(v.chipButtons.map(\.title), ["\u{221E}", "1 h", "2 h", "4 h", "Custom\u{2026}"])
        XCTAssertEqual(v.chipButtons.map { $0.state == .on }, [true, false, false, false, false])
        XCTAssertEqual(v.chipButtons.first?.accessibilityLabel(), "Until I turn it off")
        XCTAssertEqual(v.captionLabel.stringValue, "Until you turn it off")

        v.segments.selectedSegment = ModeHeader.Tab.lid.rawValue
        _ = v.segments.sendAction(v.segments.action, to: v.segments.target)
        XCTAssertEqual(tabs, [.lid])
        XCTAssertEqual(v.segments.selectedSegment, ModeHeader.Tab.screen.rawValue, "the view waits for the real mode")
        v.chipButtons[2].performClick(nil)
        XCTAssertEqual(chips, [.screenFor(7200)])
        XCTAssertEqual(v.chipButtons[2].state, .off, "a chip's state follows the model, not the click")

        let off = ModeHeader.model(mode: .off, awakeEndsAt: nil, screenChosen: nil, lidRemaining: nil, lidPaused: false, lidChosen: nil, now: now)
        v.update(off)
        XCTAssertEqual(v.segments.selectedSegment, 0)
        XCTAssertTrue(v.chipButtons.allSatisfy(\.isHidden) || v.chipButtons.isEmpty)
        XCTAssertEqual(v.explanationLabel.stringValue, "The Mac sleeps as usual.")
        XCTAssertTrue(v.captionLabel.isHidden, "Off has no status line")
        XCTAssertGreaterThanOrEqual(v.frame.width, 260)
    }

    func testUpdateRebuildsTheChipsForAnotherMode() {
        let screen = ModeHeader.model(mode: .screen, awakeEndsAt: nil, screenChosen: nil, lidRemaining: nil, lidPaused: false, lidChosen: nil, now: now)
        let v = ModeHeaderView(model: screen, onTab: { _ in }, onChip: { _ in })
        let lid = ModeHeader.model(mode: .lid, awakeEndsAt: nil, screenChosen: nil, lidRemaining: 3600, lidPaused: false, lidChosen: 3600, now: now)
        v.update(lid)
        XCTAssertEqual(v.segments.selectedSegment, ModeHeader.Tab.lid.rawValue)
        XCTAssertEqual(v.chipButtons.filter { !$0.isHidden }.map(\.title), ["1 h", "2 h", "4 h", "8 h", "12 h", "Custom\u{2026}"])
        XCTAssertEqual(v.chipButtons.first?.state, .on)
        XCTAssertEqual(v.captionLabel.stringValue, "1:00 of closed-lid time left")
    }

    func testTheSetupButtonAndTheTooltips() {
        var setups = 0
        let lid = ModeHeader.model(mode: .lid, awakeEndsAt: nil, screenChosen: nil, lidRemaining: 3600, lidPaused: false, lidChosen: nil, hotspotConfigured: false, now: now)
        let v = ModeHeaderView(model: lid, onTab: { _ in }, onChip: { _ in }, onSetupHotspot: { setups += 1 })
        XCTAssertFalse(v.setupButton.isHidden)
        XCTAssertEqual(v.setupButton.title, "Set up hotspot failover\u{2026}")
        v.setupButton.performClick(nil)
        XCTAssertEqual(setups, 1)
        let configured = ModeHeader.model(mode: .lid, awakeEndsAt: nil, screenChosen: nil, lidRemaining: 3600, lidPaused: false, lidChosen: nil, hotspotConfigured: true, now: now)
        v.update(configured)
        XCTAssertTrue(v.setupButton.isHidden)
        for tab in ModeHeader.Tab.allCases {
            XCTAssertEqual(v.segments.toolTip(forSegment: tab.rawValue), ModeHeader.explanation(for: tab, lidKeepsScreenOn: true))
        }
    }

    /// Final review: the Lid explanation needs three lines at the header's
    /// width; it must not be cut before "too." or "usual.".
    func testTheLidExplanationIsNotCutOff() {
        for keep in [true, false] {
            let lid = ModeHeader.model(mode: .lid, awakeEndsAt: nil, screenChosen: nil, lidRemaining: 60, lidPaused: false, lidChosen: nil, lidKeepsScreenOn: keep, now: now)
            let v = ModeHeaderView(model: lid, onTab: { _ in }, onChip: { _ in })
            let unlimited = NSTextField(wrappingLabelWithString: lid.explanation)
            unlimited.font = v.explanationLabel.font
            unlimited.maximumNumberOfLines = 0
            unlimited.preferredMaxLayoutWidth = v.explanationLabel.preferredMaxLayoutWidth
            XCTAssertEqual(v.explanationLabel.fittingSize.height, unlimited.fittingSize.height, accuracy: 0.5, "keep \(keep)")
        }
    }
}
