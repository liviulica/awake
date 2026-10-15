# One-click modes, readable menu, matching lid icon: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Left-click cycles off → screen → lid (8 h by default, a setting); the lid icon matches its siblings; the right-click menu reads in plain words with SF Symbols and section headers.

**Architecture:** All UI logic stays pure and testable: `MenuBarIcon` exposes its paths, `StatusLines` formats every status line, `StatusMenu.Item` gains a symbol and a header kind, `StatusItemController.clickAction` becomes a table over a `Mode`. AppKit is touched only in `StatusMenu.build` (symbols, section headers) and the controller's click handler. Config gets one key, `lidClickDuration`, and loses two dead ones.

**Tech Stack:** Swift 6.2, AppKit `NSMenu`/`NSStatusItem`, SF Symbols via `NSImage(systemSymbolName:)`, XCTest. Build with `swift build`, test with `scripts/test-fast.sh`.

**Spec:** `docs/superpowers/specs/2026-10-15-ember-menu-and-click-design.md`

## Global Constraints

- Branch `menu-and-click`; commit as `liviulica <826835+liviulica@users.noreply.github.com>` (repo config); every commit ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Never push to `main`.
- `swift build -c release -Xswiftc -warnings-as-errors` must stay clean.
- No em dashes in any user-facing string or doc; use "·", commas or colons.
- Config keys stay backward compatible: unknown keys in config.json are ignored, missing ones take defaults.
- Menu bar icons are 18×18 template images drawn in a 24-unit grid.
- Default click duration 8 h; choices 1, 2, 4, 8, 12, 24 h; always ≤ `Config.lidMaxDuration` (24 h).
- The `SleepHeldLine` keeps three cases; the session error, command and foreign-sleep sentences come from `SessionManager` unchanged.

## Review Focus

1. A config.json with `lidClickDuration` above 24 h or below 60 s: must clamp on load, not crash or start a 30-day session (Task 2 test).
2. A left-click in screen mode when the administrator prompt is cancelled: screen mode must remain on and no session exists (Task 5 test).
3. A left-click during a paused lid session (lid open) must end it, not start another (Task 5 test).
4. A symbol name macOS does not know must leave the item text intact with no image (Task 4 test builds the NSMenu with a bogus symbol).
5. Battery unknown (desktop) plus no Wi-Fi plus no hotspot: the Mac block must show only the temperature line, with no stray header-only block when even that is missing (Task 4 test).

---

### Task 1: The lid icon matches its siblings

**Files:**
- Modify: `Sources/Insomnia/UI/MenuBarIcon.swift`
- Test: `Tests/InsomniaTests/MenuBarIconTests.swift`

**Interfaces:**
- Produces: `MenuBarIcon.flame() -> NSBezierPath` (internal), `MenuBarIcon.lidFlame() -> NSBezierPath`, `MenuBarIcon.outlineWidth: CGFloat` (1.7), `MenuBarIcon.lidLineWidth: CGFloat` (2.6).

- [ ] **Step 1: Write the failing tests**

Replace `testPilotLightShapes` in `Tests/InsomniaTests/MenuBarIconTests.swift` and add a geometry test:

```swift
    /// The flame's round bottom is drawn below its centre (the arc goes
    /// through y 18.8). The lid icon's flame is lower and smaller, but of
    /// the same family: it keeps most of the full flame's height.
    func testPilotLightShapes() {
        let awake = Self.bitmap(MenuBarIcon.image(.awake))
        // 36 px render = 1.5 px per unit; bitmap y 0 is the top.
        XCTAssertGreaterThan(awake.colorAt(x: 18, y: 25)?.alphaComponent ?? 0, 0.5, "inside the flame's round bottom")
        XCTAssertGreaterThan(awake.colorAt(x: 18, y: 6)?.alphaComponent ?? 0, 0.3, "the full flame reaches near the top")
        let lid = Self.bitmap(MenuBarIcon.image(.lid))
        XCTAssertLessThan(lid.colorAt(x: 18, y: 4)?.alphaComponent ?? 1, 0.1, "the pilot flame sits lower than the full flame")
        XCTAssertGreaterThan(lid.colorAt(x: 18, y: 20)?.alphaComponent ?? 0, 0.5, "inside the pilot flame's body")
        XCTAssertGreaterThan(lid.colorAt(x: 18, y: 29)?.alphaComponent ?? 0, 0.5, "the closed lid line")
        let off = Self.bitmap(MenuBarIcon.image(.off))
        XCTAssertLessThan(off.colorAt(x: 18, y: 19)?.alphaComponent ?? 1, 0.2, "off is an outline: its middle is empty")
    }

    /// Spec "Menu bar icon": the lid flame keeps at least 75% of the full
    /// flame's height and the lid line is at least as thick as the outline,
    /// so the three states read as one family.
    func testLidIconHasTheMassOfItsSiblings() {
        let full = MenuBarIcon.flame().bounds
        let lid = MenuBarIcon.lidFlame().bounds
        XCTAssertGreaterThanOrEqual(lid.height, 0.75 * full.height, "lid flame \(lid.height) vs full \(full.height)")
        XCTAssertGreaterThanOrEqual(MenuBarIcon.lidLineWidth, MenuBarIcon.outlineWidth)
        XCTAssertLessThan(lid.maxY, 24 - MenuBarIcon.lidLineWidth, "the flame stays above the lid line")
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd ~/Coding/Ember && swift test --filter MenuBarIconTests 2>&1 | tail -15`
Expected: compile error, `flame` is private and `lidFlame`, `lidLineWidth`, `outlineWidth` do not exist.

- [ ] **Step 3: Implement**

In `Sources/Insomnia/UI/MenuBarIcon.swift` replace the `draw` body's `.off` and `.lid` cases and the `flame()` declaration:

```swift
    static let outlineWidth: CGFloat = 1.7
    static let lidLineWidth: CGFloat = 2.6
    /// Where the pilot flame sits: its bottom point, just above the lid line.
    private static let lidFlameBottom = NSPoint(x: 12, y: 17.2)
    private static let lidFlameScale: CGFloat = 0.78
    private static let lidLineY: CGFloat = 19.9

    /// Draws into the current context in 24-unit, y-down coordinates.
    static func draw(_ icon: MenuBarIcon) {
        NSColor.black.set()
        switch icon {
        case .off:
            stroke(flame(), width: outlineWidth)
        case .awake:
            flame().fill()
        case .lid:
            lidFlame().fill()
            line(from: NSPoint(x: 3.5, y: lidLineY), to: NSPoint(x: 20.5, y: lidLineY), width: lidLineWidth)
        }
    }

    /// The pilot flame: the flame scaled down around its bottom point and
    /// set just above the lid line. Internal so the test can measure it.
    static func lidFlame() -> NSBezierPath {
        let small = flame()
        var m = AffineTransform(translationByX: -12, byY: -18.8)
        m.append(AffineTransform(scale: lidFlameScale))
        m.append(AffineTransform(translationByX: lidFlameBottom.x, byY: lidFlameBottom.y))
        small.transform(using: m)
        return small
    }

    /// The flame, in 24-unit y-down coordinates: pointed top, round bottom
    /// through (12, 18.8). Internal so the test can measure it.
    static func flame() -> NSBezierPath {
```

(the path body is unchanged). Update the header comment's lid sentence to "lid closed is the flame, lower and a little smaller, on the closed lid: turned down, never out."

- [ ] **Step 4: Run the tests**

Run: `swift test --filter MenuBarIconTests 2>&1 | tail -15`
Expected: all MenuBarIconTests pass. If `testPilotLightShapes` fails at (18, 4) or (18, 20), the numbers are off by a unit: re-check `lidFlameBottom` and `lidFlameScale` against the spec before changing the test.

- [ ] **Step 5: Look at it**

Edit the scratch render `render.swift` (scratchpad `icons/`) case `.lidB` to the numbers above (scale 0.78, bottom 17.2, line y 19.9 width 2.6, x 3.5..20.5) and run `swift render.swift icons.png`, then open the PNG. The third and fourth glyphs should now be identical and sit with the mass of the second.

- [ ] **Step 6: Commit**

```bash
git add Sources/Insomnia/UI/MenuBarIcon.swift Tests/InsomniaTests/MenuBarIconTests.swift
git commit -m "Lid icon: the pilot flame has the mass of its siblings

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `lidClickDuration` in Config; the dead preset keys go

**Files:**
- Modify: `Sources/Insomnia/Model/Config.swift`
- Modify: `Sources/Insomnia/UI/StatusSource.swift` (remove `chipLabel`)
- Test: `Tests/InsomniaTests/ConfigTests.swift`

**Interfaces:**
- Produces: `Config.lidClickDuration: TimeInterval` (default `8 * 3600`), `Config.lidClickChoices: [TimeInterval]` = 1, 2, 4, 8, 12, 24 h, `Config.clampedLidClickDuration(_:) -> TimeInterval`.
- Removes: `Config.presets`, `Config.defaultPreset`, `Config.defaultPresets`, `chipLabel(for:)`.

- [ ] **Step 1: Write the failing tests**

In `Tests/InsomniaTests/ConfigTests.swift`, in `testDefaults` delete the two `c.presets` lines and add:

```swift
        XCTAssertEqual(c.lidClickDuration, 8 * 3600)
        XCTAssertEqual(Config.lidClickChoices, [3600, 7200, 14400, 28800, 43200, 86400])
```

In `testRoundTrip` replace `c.presets = [60]` with `c.lidClickDuration = 2 * 3600`.

Add after `testRoundTrip`:

```swift
    /// The click duration loads clamped: a config.json edited by hand to a
    /// 30-day click never starts a 30-day session, and a value under a
    /// minute never starts a session that ends at once.
    func testLidClickDurationIsClampedOnLoad() throws {
        let big = try Store.makeDecoder().decode(Config.self, from: Data(#"{"lidClickDuration": 2592000}"#.utf8))
        XCTAssertEqual(big.lidClickDuration, Config.lidMaxDuration)
        let tiny = try Store.makeDecoder().decode(Config.self, from: Data(#"{"lidClickDuration": 5}"#.utf8))
        XCTAssertEqual(tiny.lidClickDuration, SessionMath.minimumDuration)
        let missing = try Store.makeDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(missing.lidClickDuration, 8 * 3600)
    }
```

In `testAnInsomniaEraConfigWithDroppedKeysLoads` add, after the existing assertions, a check that the dropped preset keys are not written back:

```swift
        let saved = String(decoding: try Store.makeEncoder().encode(c), as: UTF8.self)
        XCTAssertFalse(saved.contains("\"presets\""), "deprecated key written back")
        XCTAssertFalse(saved.contains("\"defaultPreset\""), "deprecated key written back")
        XCTAssertEqual(c.lidClickDuration, 8 * 3600, "an Insomnia-era config gets the 8 h click")
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --filter ConfigTests 2>&1 | tail -15`
Expected: compile errors on `lidClickDuration` and `lidClickChoices`.

- [ ] **Step 3: Implement**

In `Sources/Insomnia/Model/Config.swift`:

Replace lines 7–13 (the `presets` and `defaultPreset` properties and their comments) with:

```swift
    // Session
    /// Closed-lid time a left-click in screen mode starts a lid session
    /// with (spec 2026-10-15 "The click duration"). One of `lidClickChoices`;
    /// loads clamped to [`SessionMath.minimumDuration`, `lidMaxDuration`].
    var lidClickDuration: TimeInterval = 8 * 3600
```

Add after `static let lidMaxDuration`:

```swift
    /// What Settings offers for the click duration: 1, 2, 4, 8, 12 and 24 h.
    static let lidClickChoices: [TimeInterval] = [1, 2, 4, 8, 12, 24].map { $0 * 3600 }

    static func clampedLidClickDuration(_ value: TimeInterval) -> TimeInterval {
        min(max(value, SessionMath.minimumDuration), lidMaxDuration)
    }
```

Delete `static let defaultPresets` (lines 90–99 and its comment).

In `init(from:)` replace the `presets` and `defaultPreset` lines with:

```swift
        lidClickDuration = Config.clampedLidClickDuration(
            try c.decodeIfPresent(TimeInterval.self, forKey: .lidClickDuration) ?? d.lidClickDuration)
```

In `Sources/Insomnia/UI/StatusSource.swift` delete the `chipLabel(for:)` function and its comment (the last six lines of the file).

- [ ] **Step 4: Run the tests and the build**

Run: `swift test --filter ConfigTests 2>&1 | tail -15 && swift build 2>&1 | grep -E "error|warning" | head`
Expected: ConfigTests pass; no other file referenced `presets` (grep confirmed before the plan), so the build is clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/Insomnia/Model/Config.swift Sources/Insomnia/UI/StatusSource.swift Tests/InsomniaTests/ConfigTests.swift
git commit -m "Config: lidClickDuration (8 h); the unused preset keys go

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Status lines in plain words

**Files:**
- Modify: `Sources/Insomnia/UI/StatusSource.swift` (`StatusLines`, `SleepHeldLine`, `WiFiStatusName`)
- Test: `Tests/InsomniaTests/MenuBarTests.swift` (`StatusMenuControlTests.testThermalLine`, `StatusMenuTests.testSleepHeldLine`, `testMachineLine`, `testActionsLine`, `testThrottleWarning`)
- Test: `Tests/InsomniaTests/LidActionsTests.swift:2050`

**Interfaces:**
- Produces (all `static`, on `StatusLines`):
  - `thermal(_ state: ProcessInfo.ThermalState) -> String` → "Temperature normal" / "warm" / "hot" / "critical" / "unknown"
  - `battery(percent: Int?, isCharging: Bool) -> String?` → "Battery 68%, charging" / "Battery 68%" / nil
  - `batterySymbol(percent: Int?, isCharging: Bool) -> String?` → "battery.100percent.bolt" when charging, else "battery.0percent" / "25percent" / "50percent" / "75percent" / "100percent" by nearest quarter, nil when unknown
  - `wifi(ssid: String?, locationAuthorized: Bool, lastGap: TimeInterval?) -> String?` → "Wi-Fi: Home" / "Wi-Fi on · name needs Location access" / nil; " · last outage 12 s" appended when `lastGap > 0`
  - `hotspot(ssid: String) -> String?` → "Hotspot failover: iPhone" / nil when empty
  - `whileClosed(frozenCount: Int, muted: Bool, lowPower: Bool) -> String?` → "While closed: 2 apps frozen · audio muted · Low Power Mode" with only the parts that apply; nil when none
  - `throttleWarning(_ browser: String) -> String` → "Arc pauses hidden tabs; agents in it may stall"
- `SleepHeldLine.line(sessionActive:sleepHeld:)` texts: "Sleep off while the lid is closed" (status), "Sleep is not off: this session is not keeping the Mac awake" (warning), "Sleep is still off with no session running" (warning).
- `WiFiStatusName.redacted: String` = the existing "on (name hidden until Location is allowed)".
- Removes: `StatusLines.machine(...)`, `StatusLines.actions(...)`, `StatusLines.throttleWarning([String])`.

- [ ] **Step 1: Write the failing tests**

In `Tests/InsomniaTests/MenuBarTests.swift` replace `testThermalLine`, `testSleepHeldLine`, `testMachineLine`, `testActionsLine` and `testThrottleWarning` with:

```swift
    func testThermalLine() {
        XCTAssertEqual(StatusLines.thermal(.nominal), "Temperature normal")
        XCTAssertEqual(StatusLines.thermal(.fair), "Temperature warm")
        XCTAssertEqual(StatusLines.thermal(.serious), "Temperature hot")
        XCTAssertEqual(StatusLines.thermal(.critical), "Temperature critical")
    }
```

```swift
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
```

In `Tests/InsomniaTests/LidActionsTests.swift` line 2050 replace with:

```swift
        XCTAssertNil(StatusLines.whileClosed(frozenCount: m.effectiveState.frozenPids.count, muted: false, lowPower: false))
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --filter 'StatusMenuTests|StatusMenuControlTests' 2>&1 | tail -15`
Expected: compile errors (`battery`, `wifi`, `hotspot`, `whileClosed` missing; `throttleWarning` takes an array).

- [ ] **Step 3: Implement**

In `Sources/Insomnia/UI/StatusSource.swift` replace the whole `enum StatusLines { ... }` with:

```swift
/// Pure formatting for the menu's "Mac" block (spec 2026-10-15 "The menu"),
/// kept out of the views so it can be tested. A nil line is left out.
enum StatusLines {
    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Temperature normal"
        case .fair: "Temperature warm"
        case .serious: "Temperature hot"
        case .critical: "Temperature critical"
        @unknown default: "Temperature unknown"
        }
    }

    /// "Battery 68%, charging"; nil on a Mac with no battery.
    static func battery(percent: Int?, isCharging: Bool) -> String? {
        guard let percent else { return nil }
        return isCharging ? "Battery \(percent)%, charging" : "Battery \(percent)%"
    }

    /// The SF Symbol for the battery line: the bolt while charging, else
    /// the nearest quarter.
    static func batterySymbol(percent: Int?, isCharging: Bool) -> String? {
        guard let percent else { return nil }
        if isCharging { return "battery.100percent.bolt" }
        let quarter = Int((Double(percent) / 25).rounded()) * 25
        return "battery.\(min(max(quarter, 0), 100))percent"
    }

    /// "Wi-Fi: Home", with " · last outage 12 s" after an outage this
    /// session. macOS hides the name until Location is allowed: say so.
    /// Nothing known and Location allowed: no line.
    static func wifi(ssid: String?, locationAuthorized: Bool, lastGap: TimeInterval?) -> String? {
        guard let shown = WiFiStatusName.display(ssid: ssid, locationAuthorized: locationAuthorized) else { return nil }
        var line = shown == WiFiStatusName.redacted ? "Wi-Fi on \u{00B7} name needs Location access" : "Wi-Fi: \(shown)"
        if let gap = lastGap, gap > 0 {
            line += " \u{00B7} last outage \(Int(gap.rounded())) s"
        }
        return line
    }

    /// "Hotspot failover: iPhone"; nil when no hotspot is configured.
    static func hotspot(ssid: String) -> String? {
        let name = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : "Hotspot failover: \(name)"
    }

    /// What the lid close changed and has not undone yet; nil when nothing.
    static func whileClosed(frozenCount: Int, muted: Bool, lowPower: Bool) -> String? {
        var parts: [String] = []
        if frozenCount > 0 {
            parts.append(frozenCount == 1 ? "1 app frozen" : "\(frozenCount) apps frozen")
        }
        if muted { parts.append("audio muted") }
        if lowPower { parts.append("Low Power Mode") }
        return parts.isEmpty ? nil : "While closed: " + parts.joined(separator: " \u{00B7} ")
    }

    /// One warning per browser running without the occlusion flags.
    static func throttleWarning(_ browser: String) -> String {
        "\(browser) pauses hidden tabs; agents in it may stall"
    }
}
```

Replace the three `Line(text:...)` strings in `SleepHeldLine.line` with the texts in the test above (same cases, same `isWarning`). Update its doc comment's last sentence to: "The texts are plain; the journal caveat lives in the spec."

In `WiFiStatusName` add `static let redacted = "on (name hidden until Location is allowed)"` and return `redacted` in place of the literal.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter 'StatusMenuTests|StatusMenuControlTests|IntegrationWiringTests/testWiFiStatusNameExplainsLocationRedaction' 2>&1 | tail -15`
Expected: the new line tests pass; `testMenuListsStatusThenSettingsAndQuit` and the control tests still fail (they move to Task 4). Confirm the failures are only in tests that call `StatusMenu.items`/`controlItems` or assert old titles.

- [ ] **Step 5: Commit (tests for Task 4 are red; that is expected and the next commit fixes them, so commit only this file set)**

```bash
git add Sources/Insomnia/UI/StatusSource.swift Tests/InsomniaTests/MenuBarTests.swift Tests/InsomniaTests/LidActionsTests.swift
git commit -m "Menu: status lines in plain words (battery, Wi-Fi, hotspot, while closed)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: The menu: symbols, headers, sections, wording

**Files:**
- Modify: `Sources/Insomnia/UI/StatusMenu.swift`
- Test: `Tests/InsomniaTests/MenuBarTests.swift` (`StatusMenuControlTests`, `StatusMenuTests`)
- Test: `Tests/InsomniaTests/StatusMenuWarningTests.swift`

**Interfaces:**
- `StatusMenu.Item` gains `symbol: String?` (init `Item(title:kind:symbol: = nil)`) and `Kind.header`.
- `enum MenuSymbol` with `static let` names: `flame = "flame"`, `lid = "laptopcomputer"`, `add = "plus"`, `end = "stop.fill"`, `settings = "gearshape"`, `sleep = "moon.zzz"`, `thermal = "thermometer.medium"`, `wifi = "wifi"`, `hotspot = "personalhotspot"`, `closed = "pause.circle"`, `warning = "exclamationmark.triangle"`, `relaunch = "arrow.clockwise"`, `stopWaiting = "speaker.slash"`.
- `StatusMenu.controlItems(awakeOn:awakeEndsAt:lidRemaining:lidPaused:clickDuration:now:) -> [Item]`
- `StatusMenu.lidDurations: [TimeInterval]` = 1, 2, 4, 8, 12 h.
- `StatusMenu.macLines(battery:batterySymbol:thermal:wifi:hotspot:whileClosed:) -> [Item]` (each `String?`, nil dropped; `batterySymbol: String?`).
- `StatusMenu.items(controls:mac:sessionActive:sleepHeld:throttledBrowsers:relaunchProblems:hotspotWarning:error:commandRunning:foreignSleep:outputsWaiting:lidSimulationBuild:) -> [Item]` (no more `thermal`, `machine`, `actions`).
- `StatusMenu.headerTitle = "Mac"`.
- `StatusMenu.menu(...)` unchanged signature.

Layout produced by `items`:
1. `controls`, then a separator if any.
2. If the sleep line or any `mac` line exists: `Item(title: "Mac", kind: .header)`, then the sleep line (info with `MenuSymbol.sleep`, or warning with `MenuSymbol.warning`), then `mac`.
3. Warnings, each with `MenuSymbol.warning` and its action right after: per throttled browser the throttle line then `Relaunch <name> without throttling…` (`.relaunchBrowser`, symbol `relaunch`); `relaunchProblems`; `hotspotWarning`; the lid-simulation marker; `commandRunning`; `error`; `foreignSleep`; per waiting output its line then `Stop waiting for <label>` (symbol `stopWaiting`). A separator before this section when it is non-empty and something precedes it.
4. Separator (if anything precedes), `Settings…` (symbol `settings`), `Quit Ember`.
Warning titles have any leading "⚠" and whitespace stripped (`HotspotPasswordProblem.menuLine` and `LidSimulationBuild.marker` carry none or one).

- [ ] **Step 1: Write the failing tests**

In `Tests/InsomniaTests/MenuBarTests.swift` replace the body of `StatusMenuControlTests` (keep `now`) with:

```swift
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
```

Add to `StatusMenu.Item` (for the test's `controls[1].children`) nothing: instead in the test use a helper at the bottom of the file:

```swift
private extension StatusMenu.Item {
    var children: [StatusMenu.Item] {
        if case let .submenu(items) = kind { return items }
        return []
    }
}
```

In `StatusMenuTests` replace `testMenuListsStatusThenSettingsAndQuit`, `testIdleMenuIsJustSettingsAndQuitWithNoLeadingSeparator`, `testMenuShowsTheLastErrorAsAWarning`, `testMenuShowsTheHotspotPasswordProblemAsAWarning` and `testEveryThrottledBrowserGetsItsOwnRelaunchItem` with:

```swift
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
```

In `Tests/InsomniaTests/StatusMenuWarningTests.swift`: delete every `machine: nil, actions: nil,` argument pair, drop the `"\u{26A0} "` prefix from every expected title, and in `testTheRelaunchProblemsFollowTheBrowserLines` replace the `throttle` line and the expected list with:

```swift
        XCTAssertEqual(items.map(\.title).filter { $0.contains("Arc") || $0.contains("Chrome") || $0.contains("restore") }, [
            StatusLines.throttleWarning("Arc"),
            "Relaunch Arc without throttling\u{2026}",
            problem,
            other,
            "restore failed",
        ])
```

and `closed.filter { $0.kind == .warning }.map(\.title), [problem]`. In `testTheRelaunchEntryCarriesTheBundleIDAndName` the title becomes `"Relaunch Arc without throttling\u{2026}"`. In `testEachWaitingOutputHasALineAndAStopWaitingItem` the expected items become:

```swift
            StatusMenu.Item(title: "USB Headset is still muted from a lid close; Ember restores it when it reconnects", kind: .warning, symbol: MenuSymbol.warning),
            StatusMenu.Item(title: "Stop waiting for USB Headset", kind: .stopWaitingForOutput(headset), symbol: MenuSymbol.stopWaiting),
            StatusMenu.Item(title: "70-8C-F2:output is still muted from a lid close; Ember restores it when it reconnects", kind: .warning, symbol: MenuSymbol.warning),
            StatusMenu.Item(title: "Stop waiting for 70-8C-F2:output", kind: .stopWaitingForOutput(unnamed), symbol: MenuSymbol.stopWaiting),
```

with `sessionActive: true, sleepHeld: true` kept where they were and the `[.header, .info, .separator, ...]` prefix expected where a session is active (those tests pass `sessionActive: false, sleepHeld: false`, so no header there). Walk each assertion and update the `kind` lists: the rule is header+sleep line only when `SleepHeldLine.line` is non-nil.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --filter 'StatusMenu|MenuBarTests' 2>&1 | tail -20`
Expected: compile errors (`symbol`, `.header`, `macLines`, `clickDuration`, `MenuSymbol`).

- [ ] **Step 3: Implement**

Rewrite `Sources/Insomnia/UI/StatusMenu.swift` from the top through `build`:

```swift
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
    /// adds the marker of a build with the simulate-lid watcher compiled in;
    /// `relaunchProblems` say why browser relaunches did not happen;
    /// `outputsWaiting` are outputs still muted from a lid close.
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
```

Keep `menu(...)` and `Selectors` as they are. In `build`, replace the `.info, .warning` case and add `.header`, and attach symbols to every item at the end of the loop body. Replace the loop with:

```swift
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
```

Delete the now unused `lineFont` line in `build`. Note `NSMenuItem.sectionHeader(title:)` is macOS 14+; the package targets macOS 26 (`Package.swift` platforms), so no availability check.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter 'StatusMenu|MenuBarTests' 2>&1 | tail -20`
Expected: every StatusMenu*, StatusMenuControlTests and StatusMenuTests test passes. `StatusItemControllerLogicTests` still fails on `clickAction` (Task 5). The build of `StatusItemController.swift` breaks on `controlItems`/`items` labels: fix the call sites minimally in this task by passing `clickDuration: manager.config.lidClickDuration` and `mac: []`, so the package compiles; Task 5 wires the real lines.

- [ ] **Step 5: Commit**

```bash
git add Sources/Insomnia/UI/StatusMenu.swift Sources/Insomnia/UI/StatusItemController.swift Tests/InsomniaTests/MenuBarTests.swift Tests/InsomniaTests/StatusMenuWarningTests.swift
git commit -m "Menu: symbols, a Mac section, warnings with their action, plain wording

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: The click cycle and the menu wiring

**Files:**
- Modify: `Sources/Insomnia/UI/StatusItemController.swift`
- Test: `Tests/InsomniaTests/MenuBarTests.swift` (`StatusItemControllerLogicTests`)

**Interfaces:**
- `StatusItemController.Mode: Equatable { off, screen, lid }`
- `StatusItemController.ClickAction: Equatable { turnOnScreen, startLid, endLid, showMenu }`
- `static func mode(lidActive: Bool, awake: AwakeController.State) -> Mode`
- `static func clickAction(isRightClick: Bool, controlHeld: Bool, mode: Mode) -> ClickAction`
- `func handle(_ action: ClickAction) async` (internal; the button handler wraps it in a Task; `.showMenu` is handled synchronously in the button handler, `handle` ignores it)
- `func startLidSession(_ duration: TimeInterval) async` (shared by the click and the menu)

- [ ] **Step 1: Write the failing tests**

In `StatusItemControllerLogicTests` replace `testLeftClickTogglesExceptDuringALidSession` with:

```swift
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

    /// Review focus 2: a start that does not take (the prompt cancelled,
    /// here the sudo refused) leaves screen mode on and no session.
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
        XCTAssertNotNil(m.lastError, "the menu says why")
        XCTAssertEqual(awake.state, .on(until: nil), "screen mode is untouched")
        XCTAssertTrue(a.isHeld)
    }
```

`h.guardFake.cancelDisable = true` makes `disablesleep 1` answer like a cancelled administrator prompt (`TestSupport.swift`, used by `RecoverySafetyTests`).

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --filter StatusItemControllerLogicTests 2>&1 | tail -15`
Expected: compile errors (`mode`, `Mode`, `handle`, new `clickAction` labels).

- [ ] **Step 3: Implement**

In `Sources/Insomnia/UI/StatusItemController.swift`:

Replace `ClickAction` and `clickAction` with:

```swift
    /// Which of the three states the item is in (spec 2026-10-15 "Left-click").
    enum Mode: Equatable {
        case off, screen, lid
    }

    /// What a click on the item does.
    enum ClickAction: Equatable {
        case turnOnScreen
        case startLid
        case endLid
        case showMenu
    }

    /// A lid session wins over screen mode (which is folded into it).
    static func mode(lidActive: Bool, awake: AwakeController.State) -> Mode {
        if lidActive { return .lid }
        return awake == .off ? .off : .screen
    }

    /// Right-click and ctrl-click open the menu. A plain left click walks
    /// off → screen → lid → off. The third step ends a session with one
    /// click; the spec records that the owner accepted this.
    static func clickAction(isRightClick: Bool, controlHeld: Bool, mode: Mode) -> ClickAction {
        if isRightClick || controlHeld { return .showMenu }
        switch mode {
        case .off: return .turnOnScreen
        case .screen: return .startLid
        case .lid: return .endLid
        }
    }
```

Update the class doc comment's second sentence to "left-click cycles off → screen → lid → off, right-click opens the menu".

Replace `buttonClicked` with:

```swift
    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
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
        case .startLid:
            await startLidSession(manager.config.lidClickDuration)
        case .endLid:
            _ = await manager.end(reason: .user)
            refresh()
        case .showMenu:
            break
        }
    }

    /// Starts a lid session, capped at 24 hours of closed-lid time
    /// (`Config.lidMaxDuration`). Shared by the click and the menu.
    func startLidSession(_ duration: TimeInterval) async {
        await manager.start(duration: min(duration, Config.lidMaxDuration))
        refresh()
    }
```

Replace `menuStartLid`'s body with:

```swift
        let chosen = (sender.representedObject as? NSNumber)?.doubleValue ?? customDuration()
        guard let chosen else { return }
        Task { @MainActor in await startLidSession(chosen) }
```

In `showMenu` delete the comment sentence about watts and keep the two refresh calls and the `recheckForeignSleep` task. Replace `menuItems` with:

```swift
    static func menuItems(manager: SessionManager, status: any StatusSource, awake: AwakeController, now: Date) -> [StatusMenu.Item] {
        let locationAuthorized = (status as? LiveStatusSource)?.locationPermission.isAuthorized ?? true
        return StatusMenu.items(
            controls: StatusMenu.controlItems(
                awakeOn: awake.isOn,
                awakeEndsAt: awake.endsAt,
                lidRemaining: manager.session?.closedLidRemaining(at: now),
                lidPaused: manager.session?.isPaused ?? false,
                clickDuration: manager.config.lidClickDuration,
                now: now
            ),
            mac: StatusMenu.macLines(
                battery: StatusLines.battery(percent: status.batteryPercent, isCharging: status.isCharging),
                batterySymbol: StatusLines.batterySymbol(percent: status.batteryPercent, isCharging: status.isCharging),
                thermal: StatusLines.thermal(ProcessInfo.processInfo.thermalState),
                wifi: StatusLines.wifi(ssid: status.wifiSSID, locationAuthorized: locationAuthorized, lastGap: status.lastGap),
                hotspot: StatusLines.hotspot(ssid: manager.config.hotspotSSID),
                whileClosed: StatusLines.whileClosed(
                    frozenCount: status.frozenCount,
                    muted: !manager.state.savedAudioOutputs.isEmpty,
                    lowPower: manager.state.lowPowerSetByUs
                )
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
```

Check `manager.state` is readable here (`private(set) var state: RuntimeState` in `SessionManager`: yes) and that `savedAudioOutputs` and `lowPowerSetByUs` are its property names (`RuntimeState.swift:120,125`).

- [ ] **Step 4: Run the tests and the whole fast suite**

Run: `swift test --filter 'StatusItemControllerLogicTests|StatusMenu|MenuBarTests|MenuBarIconTests|ConfigTests' 2>&1 | tail -15 && scripts/test-fast.sh 2>&1 | tail -5`
Expected: all pass. If `IntegrationWiringTests` or `LidActionsTests` reference `menuItems`/`clickAction` with old labels, fix those call sites the same way.

- [ ] **Step 5: Commit**

```bash
git add Sources/Insomnia/UI/StatusItemController.swift Tests/InsomniaTests/MenuBarTests.swift
git commit -m "Left-click cycles off, screen, lid (8 h by default)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Settings: the Modes section

**Files:**
- Modify: `Sources/Insomnia/UI/SettingsView.swift`

- [ ] **Step 1: Add the section**

In `body`'s `Form` put `modesSection` first (before `lidSection`). Add, before `private var lidSection`:

```swift
    // MARK: Modes

    private var modesSection: some View {
        Section("Modes") {
            Text("Click the menu bar icon to cycle: off, screen awake, lid closed, off.")
                .foregroundStyle(.secondary)
            Picker("Lid mode on click", selection: bind(\.lidClickDuration)) {
                ForEach(Config.lidClickChoices, id: \.self) { choice in
                    Text(StatusMenu.durationTitle(choice)).tag(choice)
                }
            }
        }
    }
```

If the stored value is not one of the choices (a hand-edited config.json), SwiftUI's Picker shows no selection; that is acceptable, and choosing any value writes a valid one. No test: the binding helper is generic and tested through the other sections' behaviour; verify by hand in Step 2.

- [ ] **Step 2: Build and look**

Run: `swift build 2>&1 | grep -E "error|warning" ; echo built`
Expected: nothing before "built". Then `swift run Insomnia` is not how the app runs (it needs the bundle); instead continue to Task 8 and check the window after the install there.

- [ ] **Step 3: Commit**

```bash
git add Sources/Insomnia/UI/SettingsView.swift
git commit -m "Settings: Modes section with the lid-on-click duration

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Documentation

**Files:**
- Modify: `README.md` ("Using it", lines 72–89)
- Modify: `docs/superpowers/specs/2026-10-14-awake-design.md` (lines 44 and 48)

- [ ] **Step 1: README**

Replace the table's lid row and the two bullet groups with:

```markdown
| Flame on a thick line (the closed lid) | Lid mode. The remaining time always shows beside it. |

- **Left-click** cycles through the modes: off, screen mode ("until I turn it
  off"), lid mode (8 hours by default; the administrator prompt appears),
  then off again. The third click ends a running lid session, so use the
  menu's **End now** when you want to be deliberate.
- **Right-click** (or ctrl-click) opens the menu:
  - **Keep screen awake**, and **Keep screen awake for** (until I turn it
    off, 1, 2 or 4 hours).
  - **Lid closed for 8 hours** (one click; the length is a setting) and
    **Lid closed for** (1, 2, 4, 8 or 12 hours, or Custom).
  - During a lid session: the time left, **Add 1 hour** and **End now**.
  - A **Mac** block: battery, temperature, Wi-Fi and hotspot failover, and
    what the lid close changed while it is still in effect.
  - Warnings only when something needs a decision (a browser that pauses
    hidden tabs, an output still muted, a recovery problem), each followed
    by the item that resolves it.
  - **Settings…** and **Quit Ember**.
```

Add to the Settings paragraph (after "Low Power Mode when the Mac gets seriously hot…", find the sentence that lists Settings and append): "The length of the one-click lid mode is under Settings → Modes (1 to 24 hours)."

- [ ] **Step 2: The 2026-10-14 spec**

At the top of "### Menu bar icon" and "### Interaction" add the line:

```markdown
> Superseded on 2026-10-15 by `2026-10-15-ember-menu-and-click-design.md` (lid icon size, the click cycle, the menu).
```

- [ ] **Step 3: Commit**

```bash
git add README.md docs/superpowers/specs/2026-10-14-awake-design.md
git commit -m "docs: the click cycle and the new menu

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Full verification and a real look

- [ ] **Step 1: Release build with warnings as errors**

Run: `swift build -c release -Xswiftc -warnings-as-errors 2>&1 | tail -3`
Expected: `Compiling` lines then `Build complete!`. Any warning fails the build; fix it.

- [ ] **Step 2: Fast suite, smoke, gate, shellcheck**

Run: `scripts/test-fast.sh 2>&1 | tail -3 && scripts/smoke-test.sh 2>&1 | tail -3 && scripts/check-lid-simulation-gate.sh 2>&1 | tail -2 && shellcheck scripts/*.sh && echo ok`
Expected: `Executed N tests, with 0 failures` (N ≈ 980), the smoke test's PASS line, the gate's OK line, `ok`.

- [ ] **Step 3: Install and look (asks for the administrator password once)**

Run: `./scripts/install.sh && open ~/Applications/Ember.app`
Then: right-click the icon and compare with the spec's two layouts; left-click three times (screen → lid with the prompt → off); open Settings and check the Modes section. Record anything off as a follow-up in the atelier work item, not as a GitHub issue.

- [ ] **Step 4: Update the atelier page**

In `~/Coding/atelier/projects/ember.md` "Current state" add one line: "2026-10-15: branch `menu-and-click` (one-click cycle, 8 h setting, readable menu, lid icon) built and installed; awaiting review." Commit in atelier.
