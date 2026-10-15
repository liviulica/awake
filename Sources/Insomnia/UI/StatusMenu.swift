import AppKit

/// SF Symbol names on the menu's lines (spec 2026-10-15 "The menu"). A name
/// this macOS lacks gives a nil image, and the line shows without one.
enum MenuSymbol {
    static let flame = "flame"
    static let lid = "laptopcomputer"
    static let add = "plus"
    static let end = "stop.fill"
    static let settings = "gearshape"
    static let sleep = "moon.zzz"
    static let thermal = "thermometer.medium"
    static let wifi = "wifi"
    static let hotspot = "personalhotspot"
    static let closed = "pause.circle"
    static let warning = "exclamationmark.triangle"
    static let relaunch = "arrow.clockwise"
    static let stopWaiting = "speaker.slash"
}

/// The right-click menu on the status item: the controls, a "Mac" block,
/// warnings that need a decision (each followed by its action), then
/// Settings and Quit, which live here and nowhere else.
///
/// The item list is pure so the ordering and the omission rules can be
/// tested without a menu bar; `menu(_:target:settings:quit:...)` is the only
/// part that touches AppKit.
enum StatusMenu {
    struct Item: Equatable {
        enum Kind: Equatable {
            case info
            case warning
            /// A section header ("Mac").
            case header
            case separator
            case settings
            case quit
            /// Relaunch this browser with the occlusion flags. Carries the
            /// bundle id and name, so the item still names the same browser
            /// after a scan replaces the list.
            case relaunchBrowser(ThrottledBrowser)
            /// Drop the saved volume of this output device: it is not
            /// connected, and Ember stops waiting for it. Carries the
            /// save the item was built for, its save ID included, so a
            /// later one is not dropped.
            case stopWaitingForOutput(SavedAudioOutput)
            /// Screen mode on or off.
            case toggleAwake(isOn: Bool)
            /// Turn screen mode on for this long; nil is "until I turn it off".
            case awakeFor(TimeInterval?)
            /// Start a lid session for this long; nil asks for a custom duration.
            case startLid(TimeInterval?)
            case extendLid(TimeInterval)
            case endLid
            case submenu([Item])
        }

        let title: String
        let kind: Kind
        /// SF Symbol shown before the title; nil for none.
        let symbol: String?

        init(title: String, kind: Kind, symbol: String? = nil) {
            self.title = title
            self.kind = kind
            self.symbol = symbol
        }
    }

    static let settingsTitle = "Settings\u{2026}"
    static let quitTitle = "Quit Ember"
    static let headerTitle = "Mac"

    static let awakeDurations: [TimeInterval?] = [nil, 3600, 7200, 14400]
    static let lidDurations: [TimeInterval] = [3600, 7200, 14400, 28800, 43200]

    /// The controls above the Mac block (spec "Interaction"). During a lid
    /// session only its own controls show: screen mode is part of it then.
    /// `lidRemaining` is the closed-lid time left (`Session.closedLidRemaining`);
    /// `clickDuration` is `Config.lidClickDuration`, the one-click item's length.
    static func controlItems(awakeOn: Bool, awakeEndsAt: Date?, lidRemaining: TimeInterval?, lidPaused: Bool,
                             clickDuration: TimeInterval, now: Date) -> [Item] {
        if let lid = lidRemaining {
            let left = "Lid mode \u{00B7} \(Countdown.short(lid)) left"
            return [
                Item(title: lidPaused ? left + " \u{00B7} lid open, clock paused" : left, kind: .info, symbol: MenuSymbol.lid),
                Item(title: "Add 1 hour", kind: .extendLid(3600), symbol: MenuSymbol.add),
                Item(title: "End now", kind: .endLid, symbol: MenuSymbol.end),
            ]
        }
        var toggle = "Keep screen awake"
        if awakeOn, let end = awakeEndsAt {
            toggle += " \u{00B7} \(Countdown.short(end.timeIntervalSince(now))) left"
        }
        let awake = awakeDurations.map { Item(title: durationTitle($0), kind: .awakeFor($0)) }
        let lid = lidDurations.map { Item(title: durationTitle($0), kind: .startLid($0)) }
            + [Item(title: "Custom\u{2026}", kind: .startLid(nil))]
        return [
            Item(title: toggle, kind: .toggleAwake(isOn: awakeOn), symbol: MenuSymbol.flame),
            Item(title: "Keep screen awake for", kind: .submenu(awake), symbol: MenuSymbol.flame),
            Item(title: "Lid closed for \(durationTitle(clickDuration))", kind: .startLid(clickDuration), symbol: MenuSymbol.lid),
            Item(title: "Lid closed for", kind: .submenu(lid), symbol: MenuSymbol.lid),
        ]
    }

    static func durationTitle(_ duration: TimeInterval?) -> String {
        guard let duration else { return "Until I turn it off" }
        let hours = Int(duration / 3600)
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    /// The "Mac" block's lines, in order, from `StatusLines`; nil lines are
    /// left out. `batterySymbol` is `StatusLines.batterySymbol`.
    static func macLines(battery: String?, batterySymbol: String?, thermal: String?, wifi: String?, hotspot: String?, whileClosed: String?) -> [Item] {
        var out: [Item] = []
        if let battery = present(battery) { out.append(Item(title: battery, kind: .info, symbol: batterySymbol)) }
        if let thermal = present(thermal) { out.append(Item(title: thermal, kind: .info, symbol: MenuSymbol.thermal)) }
        if let wifi = present(wifi) { out.append(Item(title: wifi, kind: .info, symbol: MenuSymbol.wifi)) }
        if let hotspot = present(hotspot) { out.append(Item(title: hotspot, kind: .info, symbol: MenuSymbol.hotspot)) }
        if let closed = present(whileClosed) { out.append(Item(title: closed, kind: .info, symbol: MenuSymbol.closed)) }
        return out
    }

    /// The whole menu. `controls` first; then the Mac block (header, the
    /// sleep line, `mac`), shown only when it has a line; then the warnings
    /// that need a decision, each followed by its action; then Settings…
    /// and Quit. A separator appears only between non-empty sections, so
    /// the menu never opens with a stray rule.
    /// `hotspotWarning` is the line about a hotspot password the failover
    /// could not use (`HotspotPasswordProblem.menuLine`); `lidSimulationBuild`
    /// adds the marker of a build with the simulate-lid watcher compiled in
    /// (`LidSimulationBuild`), so such a build is never mistaken for a normal
    /// one; `relaunchProblems` say why browser relaunches did not happen, one
    /// line per browser; `outputsWaiting` are output devices still muted
    /// from a lid close because they were not connected to get their volume
    /// back; each gets a line and an item to stop waiting for it.
    static func items(
        controls: [Item] = [],
        mac: [Item] = [],
        sessionActive: Bool,
        sleepHeld: Bool,
        throttledBrowsers: [ThrottledBrowser],
        relaunchProblems: [String] = [],
        hotspotWarning: String? = nil,
        error: String?,
        commandRunning: String? = nil,
        foreignSleep: String? = nil,
        outputsWaiting: [SavedAudioOutput] = [],
        lidSimulationBuild: Bool = false
    ) -> [Item] {
        var sections: [[Item]] = [controls]

        var block: [Item] = []
        if let held = SleepHeldLine.line(sessionActive: sessionActive, sleepHeld: sleepHeld) {
            block.append(held.isWarning ? warning(held.text) : Item(title: held.text, kind: .info, symbol: MenuSymbol.sleep))
        }
        block += mac
        if !block.isEmpty {
            sections.append([Item(title: headerTitle, kind: .header)] + block)
        }

        var warnings: [Item] = []
        for browser in throttledBrowsers {
            // The warning alone is a dead end; each browser's relaunch is
            // the next item.
            warnings.append(warning(StatusLines.throttleWarning(browser.name)))
            warnings.append(Item(title: "Relaunch \(browser.name) without throttling\u{2026}", kind: .relaunchBrowser(browser), symbol: MenuSymbol.relaunch))
        }
        warnings += relaunchProblems.compactMap(present).map(warning)
        if let hotspot = present(hotspotWarning) { warnings.append(warning(hotspot)) }
        if lidSimulationBuild { warnings.append(warning(LidSimulationBuild.marker)) }
        // The sudo pmset left running comes before the session error: it
        // holds every change and quit until it exits, and the line goes
        // away then.
        if let command = present(commandRunning) { warnings.append(warning(command)) }
        if let error = present(error) { warnings.append(warning(error)) }
        // Its own line, after the error: a restore that failed and a bit
        // someone else set can both be true of the same reconcile.
        if let foreignSleep = present(foreignSleep) { warnings.append(warning(foreignSleep)) }
        for waiting in outputsWaiting {
            warnings.append(warning(SessionManager.stillMutedLine(waiting)))
            warnings.append(Item(title: "Stop waiting for \(waiting.label)", kind: .stopWaitingForOutput(waiting), symbol: MenuSymbol.stopWaiting))
        }
        sections.append(warnings)

        sections.append([
            Item(title: settingsTitle, kind: .settings, symbol: MenuSymbol.settings),
            Item(title: quitTitle, kind: .quit),
        ])

        var out: [Item] = []
        for section in sections where !section.isEmpty {
            if !out.isEmpty { out.append(Item(title: "", kind: .separator)) }
            out += section
        }
        return out
    }

    /// A warning line. The "⚠" some sentences carry is dropped: the symbol
    /// says it.
    private static func warning(_ text: String) -> Item {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("\u{26A0}") {
            t = String(t.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Item(title: t, kind: .warning, symbol: MenuSymbol.warning)
    }

    private static func present(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Build the AppKit menu. Status lines are disabled items in the menu's
    /// own font; warnings are orange. `autoenablesItems` is off so the
    /// disabled lines stay disabled and the actions stay live without
    /// validation. Each line's symbol becomes its image; a name this macOS
    /// lacks gives nil, and the line shows without one.
    @MainActor
    static func menu(
        _ items: [Item],
        target: AnyObject?,
        settings: Selector,
        quit: Selector,
        relaunchBrowser: Selector,
        stopWaitingForOutput: Selector,
        toggleAwake: Selector? = nil,
        awakeFor: Selector? = nil,
        startLid: Selector? = nil,
        extendLid: Selector? = nil,
        endLid: Selector? = nil
    ) -> NSMenu {
        let selectors = Selectors(settings: settings, quit: quit, relaunchBrowser: relaunchBrowser,
                                  stopWaitingForOutput: stopWaitingForOutput, toggleAwake: toggleAwake,
                                  awakeFor: awakeFor, startLid: startLid, extendLid: extendLid, endLid: endLid)
        return build(items, target: target, selectors: selectors)
    }

    private struct Selectors {
        let settings, quit, relaunchBrowser, stopWaitingForOutput: Selector
        let toggleAwake, awakeFor, startLid, extendLid, endLid: Selector?
    }

    @MainActor
    private static func build(_ items: [Item], target: AnyObject?, selectors s: Selectors) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            let entry: NSMenuItem
            switch item.kind {
            case .separator:
                menu.addItem(.separator())
                continue
            case .header:
                entry = NSMenuItem.sectionHeader(title: item.title)
            case .info, .warning:
                entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                entry.isEnabled = false
                if item.kind == .warning {
                    // The menu's own font; only the colour is set.
                    entry.attributedTitle = NSAttributedString(string: item.title, attributes: [.foregroundColor: NSColor.systemOrange])
                }
            case .settings:
                entry = action(title: item.title, selector: s.settings, key: ",", target: target)
            case .quit:
                entry = action(title: item.title, selector: s.quit, key: "q", target: target)
            case let .relaunchBrowser(browser):
                entry = action(title: item.title, selector: s.relaunchBrowser, key: "", target: target)
                entry.representedObject = browser
            case let .stopWaitingForOutput(waiting):
                entry = action(title: item.title, selector: s.stopWaitingForOutput, key: "", target: target)
                entry.representedObject = waiting
            case let .toggleAwake(isOn):
                entry = optionalAction(item.title, s.toggleAwake, target)
                entry.state = isOn ? .on : .off
            case let .awakeFor(duration):
                entry = optionalAction(item.title, s.awakeFor, target)
                entry.representedObject = duration.map { NSNumber(value: $0) }
            case let .startLid(duration):
                entry = optionalAction(item.title, s.startLid, target)
                entry.representedObject = duration.map { NSNumber(value: $0) }
            case let .extendLid(duration):
                entry = optionalAction(item.title, s.extendLid, target)
                entry.representedObject = NSNumber(value: duration)
            case .endLid:
                entry = optionalAction(item.title, s.endLid, target)
            case let .submenu(children):
                entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                entry.submenu = build(children, target: target, selectors: s)
            }
            if let symbol = item.symbol {
                entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            menu.addItem(entry)
        }
        return menu
    }

    /// An action item, disabled when the caller wired no selector for it.
    @MainActor
    private static func optionalAction(_ title: String, _ selector: Selector?, _ target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = target
        item.isEnabled = selector != nil
        return item
    }

    @MainActor
    private static func action(title: String, selector: Selector, key: String, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = .command
        item.target = target
        item.isEnabled = true
        return item
    }
}

/// What the menu asks before "Relaunch <browser> without throttling…" quits
/// anything. Pure so the copy is testable; the controller shows it as an
/// NSAlert.
struct RelaunchPrompt: Equatable {
    static let confirmTitle = "Quit and relaunch"
    static let cancelTitle = "Cancel"

    let title: String
    let message: String

    init(browser name: String) {
        title = "Quit and relaunch \(name)?"
        message = "Ember quits \(name) and opens it again with the two flags that stop it throttling hidden windows. Your windows and tabs come back only if \(name) is set to reopen them on startup. If \(name) has not quit after \(Int(BrowserThrottle.quitTimeout)) s, nothing is relaunched."
    }
}
