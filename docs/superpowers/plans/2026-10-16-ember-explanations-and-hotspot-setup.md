# Mode explanations, lid screen toggle, guided hotspot setup: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each mode explains itself under the tabs; a setting decides whether lid mode keeps the screen on while the lid is open; a three-step window sets up hotspot failover, reachable from the Lid tab and Settings.

**Architecture:** Pure models carry every rule (`ModeHeader` explanations and status, `StatusLines.wifi`, `HotspotSetup` steps) and are tested without AppKit; thin AppKit/SwiftUI views draw them. `AwakeController` reads the screen setting through an injected closure. The setup window copies `SettingsWindow`'s pattern; a `WiFiScanning` protocol wraps CoreWLAN so the model is tested with a fake.

**Tech Stack:** Swift 6.2, AppKit, SwiftUI (setup view), CoreWLAN, CoreLocation (existing `LocationPermission`), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-16-ember-explanations-and-hotspot-setup-design.md`

## Global Constraints

- Branch `explanations-and-hotspot-setup`; commits as `liviulica <826835+liviulica@users.noreply.github.com>`, trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Merge locally only, on the owner's yes.
- `swift build -c release -Xswiftc -warnings-as-errors`, `scripts/test-fast.sh`, `scripts/smoke-test.sh`, `scripts/check-lid-simulation-gate.sh`, `shellcheck scripts/*.sh` stay green.
- No em dashes in user-facing text. Explanation strings exactly as the spec's table.
- `lidKeepsScreenOn` default `true`; a missing key decodes as `true`.
- Saving in the setup window writes `hotspotSSID` before the password (the keychain store keys the password by the configured SSID).

## Review Focus

1. Turning `lidKeepsScreenOn` off during a running, paused lid session releases the screen assertion at once, and back on holds it again (Task 1 test).
2. Screen mode on its own is unaffected by the setting (Task 1 test).
3. Setup Save when the keychain write fails: the SSID was already written; the step stays on Password with the error, and a retry saves (Task 4 test pins that the SSID is not rolled back and the retry works).
4. A scan that throws, or returns no names (Location denied): step 2 still allows a typed name (Task 4 test).
5. Reopening the window after a completed setup starts at step 1 with the saved SSID filled in (Task 4 test).

---

### Task 1: `lidKeepsScreenOn` and the screen hold

**Files:** `Sources/Insomnia/Model/Config.swift`, `Sources/Insomnia/Core/AwakeController.swift`, `Sources/Insomnia/InsomniaApp.swift`, `Sources/Insomnia/UI/SettingsView.swift`; tests `Tests/InsomniaTests/ConfigTests.swift`, `Tests/InsomniaTests/AwakeControllerTests.swift` (find the existing file with `grep -ln "AwakeController(" Tests/InsomniaTests/*.swift`; add to the one testing `lidSessionChanged`).

**Interfaces:**
- `Config.lidKeepsScreenOn: Bool = true` (decoded with `decodeIfPresent ?? true`).
- `AwakeController.keepsScreenOnWhileLidOpen: @MainActor () -> Bool` (`@ObservationIgnored var`, default `{ true }`); `AwakeController.settingsChanged()` re-runs `syncLidHold()`.
- `SettingsView` init gains `lidScreenSettingChanged: @escaping @MainActor () -> Void = {}`.

- [ ] **Step 1: Failing tests.** `ConfigTests`: in `testDefaults` add `XCTAssertTrue(c.lidKeepsScreenOn)`; new test decoding `{}` gives `true`, `{"lidKeepsScreenOn": false}` gives `false`, round-trip with `false`. AwakeController tests (use the file's existing assertion fake and clock helpers):

```swift
    func testWithTheScreenSettingOffALidSessionHoldsNoScreen() {
        let a = FakeAwakeAssertion()
        let c = AwakeController(assertion: a)
        var keep = false
        c.keepsScreenOnWhileLidOpen = { keep }
        c.lidSessionChanged(active: true, lidOpen: true)
        XCTAssertFalse(a.isHeld, "lid open, setting off: the display follows its own timer")
        keep = true
        c.settingsChanged()
        XCTAssertTrue(a.isHeld, "back on: held at once")
        keep = false
        c.settingsChanged()
        XCTAssertFalse(a.isHeld, "off again: released at once")
    }

    func testTheScreenSettingLeavesScreenModeAlone() {
        let a = FakeAwakeAssertion()
        let c = AwakeController(assertion: a)
        c.keepsScreenOnWhileLidOpen = { false }
        c.turnOn(for: nil)
        XCTAssertTrue(a.isHeld)
        c.settingsChanged()
        XCTAssertTrue(a.isHeld, "screen mode is not a lid session")
    }
```

- [ ] **Step 2: Run, fail** (`swift test --filter 'ConfigTests|AwakeController'`).
- [ ] **Step 3: Implement.** Config key with doc comment ("Lid mode keeps the screen on while the lid is open; off leaves the display to its idle timer during a lid session; spec 2026-10-16 explanations"). `AwakeController`: the var, `settingsChanged()`, and in `syncLidHold` `let want = lidSessionActive && sessionLidOpen && !lidClosedByEvent && keepsScreenOnWhileLidOpen()`. `InsomniaApp`: after `manager` exists in `init`, `awake.keepsScreenOnWhileLidOpen = { [manager] in manager.config.lidKeepsScreenOn }`; pass `lidScreenSettingChanged: { [awake] in awake.settingsChanged() }` into `SettingsView`. `SettingsView.modesSection`: after the picker, `Toggle("Lid mode keeps the screen on while the lid is open", isOn: Binding(get: { manager.config.lidKeepsScreenOn }, set: { manager.config.lidKeepsScreenOn = $0; save(); lidScreenSettingChanged() }))`.
- [ ] **Step 4: Run, pass; `swift build`.** **Step 5: Commit** "Setting: lid mode keeps the screen on while the lid is open (default on)".

---

### Task 2: Explanations and status in the header; the setup button

**Files:** `Sources/Insomnia/UI/ModeHeader.swift`, `Sources/Insomnia/UI/ModeHeaderView.swift`, `Sources/Insomnia/UI/StatusItemController.swift`; tests `ModeHeaderTests.swift`, `ModeHeaderViewTests.swift`, `MenuBarTests.swift`.

**Interfaces:**
- `ModeHeader.Model` gains `explanation: String`, `showsHotspotSetup: Bool`; `caption` keeps its name and is the status line (empty string when none).
- `ModeHeader.explanation(for tab: Tab, lidKeepsScreenOn: Bool) -> String`.
- `ModeHeader.model(..., lidStarting:, lidKeepsScreenOn: Bool = true, hotspotConfigured: Bool = true, now:)`.
- `ModeHeaderView.init(model:onTab:onChip:onSetupHotspot: @escaping @MainActor () -> Void = {})`; internal `explanationLabel: NSTextField`, `setupButton: NSButton`.
- `StatusItemController.init(..., showHotspotSetup: (@MainActor () -> Void)? = nil, ...)` (after `showSettings`).

- [ ] **Step 1: Failing tests.** `ModeHeaderTests`:

```swift
    func testExplanations() {
        XCTAssertEqual(ModeHeader.explanation(for: .off, lidKeepsScreenOn: true), "The Mac sleeps as usual.")
        XCTAssertEqual(ModeHeader.explanation(for: .screen, lidKeepsScreenOn: true), "Keeps the Mac and its screen awake. Closing the lid still puts it to sleep.")
        XCTAssertEqual(ModeHeader.explanation(for: .lid, lidKeepsScreenOn: true), "Keeps the Mac running with the lid closed. While the lid is open, the screen stays on too.")
        XCTAssertEqual(ModeHeader.explanation(for: .lid, lidKeepsScreenOn: false), "Keeps the Mac running with the lid closed. While the lid is open, the screen sleeps as usual.")
    }

    func testTheModelCarriesTheExplanationAndTheStatus() {
        let off = ModeHeader.model(mode: .off, awakeEndsAt: nil, screenChosen: nil, lidRemaining: nil, lidPaused: false, lidChosen: nil, now: now)
        XCTAssertEqual(off.explanation, "The Mac sleeps as usual.")
        XCTAssertEqual(off.caption, "", "Off has no status line")
        let lid = ModeHeader.model(mode: .lid, awakeEndsAt: nil, screenChosen: nil, lidRemaining: 3600, lidPaused: false, lidChosen: nil, lidKeepsScreenOn: false, now: now)
        XCTAssertTrue(lid.explanation.hasSuffix("the screen sleeps as usual."))
        XCTAssertEqual(lid.caption, "1:00 of closed-lid time left")
        let starting = ModeHeader.model(mode: .off, awakeEndsAt: nil, screenChosen: nil, lidRemaining: nil, lidPaused: false, lidChosen: nil, lidStarting: true, now: now)
        XCTAssertEqual(starting.explanation, ModeHeader.explanation(for: .lid, lidKeepsScreenOn: true))
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
```

Update `testOffHasNoChips` (Off caption is now `""`; explanation carries the sentence). `ModeHeaderViewTests`: the off update asserts `explanationLabel.stringValue == "The Mac sleeps as usual."` and `captionLabel.isHidden`; a new test builds the view with a Lid model without a hotspot, asserts `setupButton.isHidden == false`, `performClick` calls the handler, and an update with a configured hotspot hides it; segments' tooltips equal `ModeHeader.explanation(for:lidKeepsScreenOn:)`. `MenuBarTests` (`ModeHeaderControllerTests`): `c.headerModel(now:)` during a lid session with `manager.config.hotspotSSID = ""` has `showsHotspotSetup == true`.

- [ ] **Step 2: Run, fail.**
- [ ] **Step 3: Implement.** `ModeHeader`: the explanation function (the spec's table), the two new model fields; Off caption `""`; starting state explanation = Lid's. `ModeHeaderView`: an `explanationLabel` (regular small system font, `.labelColor`, wraps: `maximumNumberOfLines = 2`, `preferredMaxLayoutWidth = minimumWidth - 28`) above `captionLabel` (hidden when empty); a borderless `setupButton` "Set up hotspot failover…" (`bezelStyle = .inline`, `controlSize = .small`), hidden unless `showsHotspotSetup`; its click calls `enclosingMenuItem?.menu?.cancelTracking()` then `onSetupHotspot()`; segments' `setToolTip(ModeHeader.explanation(for:lidKeepsScreenOn:), forSegment:)` updated on each `apply()` (the model carries `lidKeepsScreenOn` for that: add `lidKeepsScreenOn: Bool` to `Model`). `StatusItemController`: `headerModel` passes `lidKeepsScreenOn: manager.config.lidKeepsScreenOn`, `hotspotConfigured: !HotspotSSID.normalized(manager.config.hotspotSSID).isEmpty`; `showMenu` passes `onSetupHotspot: { [weak self] in Self.presentOutsideTracking { self?.showHotspotSetup() } }`; store `showHotspotSetup` (default no-op).
- [ ] **Step 4: Run, pass.** **Step 5: Commit** "Menu: each mode explains itself; Lid offers hotspot setup when none is configured".

---

### Task 3: The Wi-Fi line's Location hint only with a hotspot

**Files:** `Sources/Insomnia/UI/StatusSource.swift`, `Sources/Insomnia/UI/StatusItemController.swift`; test `MenuBarTests.swift` (`testWiFiLine`).

- [ ] **Step 1: Failing test.** Replace `testWiFiLine` with calls that pass `hotspotConfigured:`; add:

```swift
        XCTAssertEqual(StatusLines.wifi(ssid: nil, locationAuthorized: false, lastGap: nil, hotspotConfigured: false), "Wi-Fi on")
        XCTAssertEqual(StatusLines.wifi(ssid: nil, locationAuthorized: false, lastGap: nil, hotspotConfigured: true), "Wi-Fi on \u{00B7} name needs Location access")
        XCTAssertEqual(StatusLines.wifi(ssid: "Home", locationAuthorized: true, lastGap: nil, hotspotConfigured: false), "Wi-Fi: Home")
```

- [ ] **Step 2: Run, fail.** **Step 3: Implement** the parameter (no default, so every caller decides); `menuItems` passes `hotspotConfigured: !HotspotSSID.normalized(manager.config.hotspotSSID).isEmpty`. **Step 4: pass. Step 5: Commit** "Menu: the Location hint on the Wi-Fi line only once a hotspot is set up".

---

### Task 4: The setup model (pure) and the scanner

**Files:** Create `Sources/Insomnia/UI/HotspotSetup.swift`, `Sources/Insomnia/System/WiFiScanner.swift`; test `Tests/InsomniaTests/HotspotSetupTests.swift`.

**Interfaces:**

```swift
struct ScannedNetworks: Equatable, Sendable { let names: [String]; let current: String? }
protocol WiFiScanning: Sendable { func scan() async throws -> ScannedNetworks }
struct CoreWLANScanner: WiFiScanning   // CWWiFiClient.shared().interface(); scanForNetworks(withSSID: nil); names de-duplicated, sorted case-insensitively, empty names dropped; current = interface.ssid()

@MainActor @Observable
final class HotspotSetup {
    enum Step: Int, CaseIterable { case wifiNames, hotspot, password, done }
    private(set) var step: Step
    var typedName: String            // the field; picking a network sets it
    private(set) var networks: ScannedNetworks?
    private(set) var scanError: String?
    private(set) var scanning: Bool
    var password: String
    var hasNoPassword: Bool
    var alsoInScreenMode: Bool
    private(set) var saveError: String?
    private(set) var saving: Bool
    init(config: Config, scanner: any WiFiScanning, secrets: any HotspotSecretStore,
         saveConfig: @escaping @MainActor (Config) throws -> Void, passwordStored: @escaping @MainActor (HotspotStoreOutcome) -> Void)
    var chosenName: String { get }   // HotspotSSID.normalized(typedName)
    var canContinue: Bool { get }
    func next() async                // wifiNames→hotspot (and starts a scan), hotspot→password, password→save→done
    func back()
    func rescan() async
    func pick(_ name: String)
}
```

- [ ] **Step 1: Failing tests** (`HotspotSetupTests`, `@MainActor`, with a `FakeScanner` returning a set `ScannedNetworks` or throwing, and `InMemoryHotspotSecretStore`; `saveConfig` captures the config):
  - starts at `.wifiNames` with `typedName` = the config's SSID and `alsoInScreenMode` = `awakeHotspotFailover`;
  - `next()` from `.wifiNames` goes to `.hotspot` and scans; names come back de-duplicated and sorted when the fake returns `["b", "A", "b", ""]` with current `"b"` (the scanner normalises; test `CoreWLANScanner.normalised(_:)` as a static pure helper: `["b","A","b",""]` → `["A","b"]`);
  - a throwing scan sets `scanError`, leaves `networks` nil, and a typed name still enables Continue (Review Focus 4);
  - `canContinue` on `.hotspot` is false for `""` and `"  "`, true after `pick("iPhone")` (which sets `typedName`);
  - on `.password`, `canContinue` is false with an empty password unless `hasNoPassword`;
  - `next()` on `.password` saves: the captured config has `hotspotSSID == "iPhone"` and `awakeHotspotFailover` as chosen, the store holds the password, step is `.done`, `passwordStored` got `.stored`;
  - a store that throws (a test double whose `save` throws) leaves step `.password`, sets `saveError`, the captured config still has the SSID (Review Focus 3), and a second `next()` with a working store reaches `.done`;
  - `hasNoPassword` saves through `delete()` (the store's password is nil afterwards);
  - `back()` from `.password` returns to `.hotspot` with `typedName` kept;
  - a new `HotspotSetup` built from the saved config starts at `.wifiNames` with that SSID typed (Review Focus 5).
- [ ] **Step 2: Run, fail.**
- [ ] **Step 3: Implement.** Save order: copy config, set `hotspotSSID = chosenName`, `awakeHotspotFailover = alsoInScreenMode`, call `saveConfig`, then `SettingsView.storePassword(hasNoPassword ? "" : password, in: secrets)` (reuse; it maps empty to `delete()`), then `passwordStored(outcome)`; on `.failed(notice)` set `saveError = notice`, stay. A `saveConfig` throw sets `saveError` and stays. The scanner: `CoreWLANScanner.scan()` runs `scanForNetworks(withSSID: nil)` in a `Task.detached`; a missing interface throws a readable error ("No Wi-Fi interface"); `normalised` as described.
- [ ] **Step 4: Run, pass.** **Step 5: Commit** "Hotspot setup: the step model and a CoreWLAN scanner".

---

### Task 5: The setup window, and wiring it in

**Files:** Create `Sources/Insomnia/UI/HotspotSetupView.swift`, `Sources/Insomnia/UI/HotspotSetupWindow.swift`; modify `Sources/Insomnia/InsomniaApp.swift`, `Sources/Insomnia/UI/SettingsView.swift`.

**Interfaces:** `HotspotSetupWindow(make: @escaping @MainActor () -> HotspotSetup, locationPermission: LocationPermission)` with `show()`; each `show()` builds a fresh `HotspotSetup` (so it starts at step 1 with current values) and a fresh `NSHostingController(rootView: HotspotSetupView(...))`. `SettingsView` gains `showHotspotSetup: @escaping @MainActor () -> Void = {}`.

- [ ] **Step 1: Test.** A `@MainActor` test builds `HotspotSetupView(setup:locationPermission:onDone:)` inside an `NSHostingController` for each `Step` (drive the model with the fakes from Task 4) and asserts `view.fittingSize.width > 300`, so every step at least lays out. Run: fails (no type).
- [ ] **Step 2: Implement the view.** A `VStack(alignment: .leading, spacing: 12)`, fixed width 420, padding 20. Header "Set up hotspot failover", trailing "Step N of 3" (hidden on done). Bodies per the spec's text for each step:
  - wifiNames: the explanation, a status line from `locationPermission.statusDescription`, "Allow" (`.notDetermined` → `requestWhenInUse()`) or "Open Location Services" (`.denied`);
  - hotspot: the iPhone instruction; the Mac line "On this Mac: System Settings → Wi-Fi → Ask to join hotspots: Automatically" with "Open Wi-Fi Settings" (`NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wi-Fi-Settings.extension")!)`); a `List` of `networks.names` (selection drives `pick`, current marked "(current)"), "Rescan" with a `ProgressView` while `scanning`, `scanError` in orange; "Not listed? Type its name:" `TextField` bound to `typedName`;
  - password: the line, `SecureField` (disabled when `hasNoPassword`), `Toggle("This hotspot has no password")`, `Toggle("Also use it in screen mode")`, `saveError` in orange;
  - done: the summary with the chosen name.
  Footer: Back (hidden on wifiNames and done), Continue / Save (on password) / Done (on done, calls `onDone`), disabled unless `canContinue` or while `saving`. Buttons run `Task { await setup.next() }`.
- [ ] **Step 3: Implement the window** like `SettingsWindow` (title "Hotspot Failover Setup", `.titled, .closable`, not released when closed; `show()` activates the app, replaces the content with a fresh view and setup, centers when not visible, makes key). `onDone` closes the window.
- [ ] **Step 4: Wire.** `InsomniaApp`: build the window with `make: { [manager, secrets] in HotspotSetup(config: manager.config, scanner: CoreWLANScanner(), secrets: secrets, saveConfig: { c in manager.config = c; try manager.store.saveConfig(c) }, passwordStored: { outcome in SettingsView.passwordStored(outcome, configuredSSID: manager.config.hotspotSSID, services: manager.services) }) }`; pass `showHotspotSetup: { [weak setup] in setup?.show() }` to `StatusItemController` and `SettingsView`. `SettingsView.networkSection`: first row `Button("Set up\u{2026}") { showHotspotSetup() }` with the caption "A guided setup: Location, your iPhone's hotspot, its password."
- [ ] **Step 5:** `swift build`, run the Step 1 test and `swift test --filter 'HotspotSetup|ModeHeader|Settings'`; commit "Hotspot setup window, from the Lid tab and Settings".

---

### Task 6: README

- [ ] README "iPhone hotspot failover": lead with "Right-click the menu bar icon, choose Lid, then Set up hotspot failover… (or Settings → Network failover → Set up…). The window walks you through Location access, your iPhone's Personal Hotspot screen, and the password." Keep the existing explanation of how failover behaves. "Using it": mention each mode's explanation line and the Settings → Modes toggle "Lid mode keeps the screen on while the lid is open". Commit "docs: guided hotspot setup, explanations, the lid screen toggle".

---

### Task 7: Verify, review, ship

- [ ] Full verification (release build, fast suite, smoke, gate, shellcheck).
- [ ] Final review: a fresh reviewer (most capable model) with this plan's Review Focus, plus `codex-companion.mjs review --wait --base main --scope branch`. One fix pass, each fix RED→GREEN.
- [ ] Push, open the PR, wait for CI; merge locally on the owner's yes; the owner installs and walks the setup with their iPhone.
