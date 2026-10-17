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
    static let approve = "checkmark.shield"
    static let update = "arrow.down.circle"
    static let checkUpdates = "arrow.triangle.2.circlepath"
}

/// The right-click menu on the status item: under the header view
/// (`ModeHeaderView`), a "Mac" block,
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
            /// Open System Settings > Login Items to allow the helper.
            case approveHelper
            case checkForUpdates
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
    static let helperApprovalLine = "Lid mode needs your approval in Login Items"
    static let approveHelperTitle = "Open Login Items\u{2026}"
    static func updateHeldBackLine(_ mode: String) -> String { "Update ready: installs when \(mode) ends" }
    static let checkForUpdatesTitle = "Check for Updates\u{2026}"

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

    /// The menu below the header view. The Mac block (header, the
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
    /// `helperNeedsApproval` (release builds) adds the approval line and the
    /// item that opens Login Items, first among the warnings: lid mode
    /// cannot start until it is done. `canCheckForUpdates` (release builds)
    /// adds "Check for Updates…" above Settings, after the line about an
    /// update waiting for a mode to end (`updateHeldFor` names the mode).
    static func items(
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
        lidSimulationBuild: Bool = false,
        helperNeedsApproval: Bool = false,
        canCheckForUpdates: Bool = false,
        updateHeldFor: String? = nil
    ) -> [Item] {
        var sections: [[Item]] = []

        var block: [Item] = []
        if let held = SleepHeldLine.line(sessionActive: sessionActive, sleepHeld: sleepHeld) {
            block.append(held.isWarning ? warning(held.text) : Item(title: held.text, kind: .info, symbol: MenuSymbol.sleep))
        }
        block += mac
        if !block.isEmpty {
            sections.append([Item(title: headerTitle, kind: .header)] + block)
        }

        var warnings: [Item] = []
        if helperNeedsApproval {
            warnings.append(warning(helperApprovalLine))
            warnings.append(Item(title: approveHelperTitle, kind: .approveHelper, symbol: MenuSymbol.approve))
        }
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

        var last: [Item] = []
        if let mode = updateHeldFor {
            last.append(Item(title: updateHeldBackLine(mode), kind: .info, symbol: MenuSymbol.update))
        } else if canCheckForUpdates {
            last.append(Item(title: checkForUpdatesTitle, kind: .checkForUpdates, symbol: MenuSymbol.checkUpdates))
        }
        last.append(Item(title: settingsTitle, kind: .settings, symbol: MenuSymbol.settings))
        last.append(Item(title: quitTitle, kind: .quit))
        sections.append(last)

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
        header: NSView? = nil,
        target: AnyObject?,
        settings: Selector,
        quit: Selector,
        relaunchBrowser: Selector,
        stopWaitingForOutput: Selector,
        approveHelper: Selector? = nil,
        checkForUpdates: Selector? = nil
    ) -> NSMenu {
        let selectors = Selectors(settings: settings, quit: quit, relaunchBrowser: relaunchBrowser,
                                  stopWaitingForOutput: stopWaitingForOutput,
                                  approveHelper: approveHelper, checkForUpdates: checkForUpdates)
        let menu = build(items, target: target, selectors: selectors)
        if let header {
            let item = NSMenuItem()
            item.view = header
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(item, at: 0)
        }
        return menu
    }

    private struct Selectors {
        let settings, quit, relaunchBrowser, stopWaitingForOutput: Selector
        let approveHelper, checkForUpdates: Selector?
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
            case .approveHelper:
                entry = action(title: item.title, selector: s.approveHelper, key: "", target: target)
            case .checkForUpdates:
                entry = action(title: item.title, selector: s.checkForUpdates, key: "", target: target)
            }
            if let symbol = item.symbol {
                entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            menu.addItem(entry)
        }
        return menu
    }

    @MainActor
    private static func action(title: String, selector: Selector?, key: String, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = .command
        item.target = target
        item.isEnabled = selector != nil
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
