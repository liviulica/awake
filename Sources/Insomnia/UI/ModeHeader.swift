import Foundation

/// The top of the menu (spec 2026-10-16 "The menu's top"): Off | Screen |
/// Lid tabs that mirror the mode the Mac is really in, quick-time chips for
/// that mode, and a caption. Pure, so the rules are tested without AppKit;
/// `ModeHeaderView` draws it.
enum ModeHeader {
    enum Tab: Int, CaseIterable, Equatable {
        case off, screen, lid
    }

    enum ChipAction: Equatable {
        /// Screen mode for this long; nil is "until I turn it off".
        case screenFor(TimeInterval?)
        case screenCustom
        /// Set the lid session's closed-lid time left to this.
        case lidRemaining(TimeInterval)
        case lidCustom
    }

    struct Chip: Equatable {
        let title: String
        let accessibilityLabel: String
        let action: ChipAction
        let isSelected: Bool
    }

    struct Model: Equatable {
        let selected: Tab
        let chips: [Chip]
        /// The status line ("2:00 left"); empty when there is none.
        let caption: String
        /// What the selected mode does (spec 2026-10-16 explanations).
        let explanation: String
        /// The Lid tab offers "Set up hotspot failover…".
        let showsHotspotSetup: Bool
        /// For the segments' tooltips, which explain every tab.
        let lidKeepsScreenOn: Bool
    }

    /// What each mode does, under the tabs and as each segment's tooltip.
    static func explanation(for tab: Tab, lidKeepsScreenOn: Bool) -> String {
        switch tab {
        case .off: "The Mac sleeps as usual."
        case .screen: "Keeps the Mac and its screen awake. Closing the lid still puts it to sleep."
        case .lid: lidKeepsScreenOn
            ? "Keeps the Mac running with the lid closed. While the lid is open, the screen stays on too."
            : "Keeps the Mac running with the lid closed. While the lid is open, the screen sleeps as usual."
        }
    }

    /// What a tab click does from the mode the Mac is in.
    enum Transition: Equatable {
        case none
        case turnOffScreen
        case endLid
        case turnOnScreen
        case endLidThenTurnOnScreen
        case startLid
    }

    static let tabTitles = ["Off", "Screen", "Lid"]
    static let screenChips: [TimeInterval?] = [nil, 3600, 7200, 14400]
    static let lidChips: [TimeInterval] = [3600, 7200, 14400, 28800, 43200]

    static func tab(for mode: StatusItemController.Mode) -> Tab {
        switch mode {
        case .off: .off
        case .screen: .screen
        case .lid: .lid
        }
    }

    /// The spec's "Tabs" table.
    static func transition(from mode: StatusItemController.Mode, to tab: Tab) -> Transition {
        switch (mode, tab) {
        case (.off, .off), (.screen, .screen), (.lid, .lid): .none
        case (.off, .screen): .turnOnScreen
        case (.off, .lid), (.screen, .lid): .startLid
        case (.screen, .off): .turnOffScreen
        case (.lid, .off): .endLid
        case (.lid, .screen): .endLidThenTurnOnScreen
        }
    }

    /// `screenChosen` and `lidChosen` are the lengths last picked for the
    /// running mode (nil when none was picked); a length that is no chip
    /// highlights Custom. `lidStarting` is a Lid tab start still running:
    /// the Lid tab is selected at once, with no chips yet, and the caption
    /// says the start is under way.
    static func model(mode: StatusItemController.Mode, awakeEndsAt: Date?, screenChosen: TimeInterval?,
                      lidRemaining: TimeInterval?, lidPaused: Bool, lidChosen: TimeInterval?,
                      lidStarting: Bool = false, lidKeepsScreenOn: Bool = true, hotspotConfigured: Bool = true,
                      now: Date) -> Model {
        let base = coreModel(mode: mode, awakeEndsAt: awakeEndsAt, screenChosen: screenChosen, lidRemaining: lidRemaining,
                             lidPaused: lidPaused, lidChosen: lidChosen, lidStarting: lidStarting, now: now)
        return Model(selected: base.selected, chips: base.chips, caption: base.caption,
                     explanation: explanation(for: base.selected, lidKeepsScreenOn: lidKeepsScreenOn),
                     showsHotspotSetup: mode == .lid && !hotspotConfigured,
                     lidKeepsScreenOn: lidKeepsScreenOn)
    }

    private struct Core {
        let selected: Tab
        let chips: [Chip]
        let caption: String
    }

    private static func coreModel(mode: StatusItemController.Mode, awakeEndsAt: Date?, screenChosen: TimeInterval?,
                                  lidRemaining: TimeInterval?, lidPaused: Bool, lidChosen: TimeInterval?,
                                  lidStarting: Bool, now: Date) -> Core {
        // The Lid tab answers the click at once; a failed start snaps back.
        if lidStarting, mode != .lid {
            return Core(selected: .lid, chips: [], caption: startingCaption)
        }
        switch mode {
        case .off:
            return Core(selected: .off, chips: [], caption: "")
        case .screen:
            let timed = awakeEndsAt != nil
            let custom = timed && screenChosen != nil && !screenChips.contains(screenChosen)
            var chips = screenChips.map { length in
                Chip(title: length.map(hoursTitle) ?? "\u{221E}",
                     accessibilityLabel: length.map { StatusMenu.durationTitle($0) } ?? "Until I turn it off",
                     action: .screenFor(length),
                     isSelected: timed ? (length != nil && length == screenChosen) : length == nil)
            }
            chips.append(Chip(title: "Custom\u{2026}", accessibilityLabel: "Custom duration", action: .screenCustom, isSelected: custom))
            let caption = awakeEndsAt.map { "\(Countdown.short($0.timeIntervalSince(now))) left" } ?? "Until you turn it off"
            return Core(selected: .screen, chips: chips, caption: caption)
        case .lid:
            let custom = lidChosen.map { !lidChips.contains($0) } ?? false
            var chips = lidChips.map { length in
                Chip(title: hoursTitle(length), accessibilityLabel: StatusMenu.durationTitle(length),
                     action: .lidRemaining(length), isSelected: length == lidChosen)
            }
            chips.append(Chip(title: "Custom\u{2026}", accessibilityLabel: "Custom duration", action: .lidCustom, isSelected: custom))
            var caption = "\(Countdown.short(lidRemaining ?? 0)) of closed-lid time left"
            if lidPaused { caption += " \u{00B7} lid open, clock paused" }
            return Core(selected: .lid, chips: chips, caption: caption)
        }
    }

    static let startingCaption = "Starting lid mode\u{2026}"

    private static func hoursTitle(_ seconds: TimeInterval) -> String {
        "\(Int(seconds / 3600)) h"
    }
}
