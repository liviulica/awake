# Awake Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Insomnia fork in `~/Coding/Awake` into Awake phase 1: a Caffeine-style Awake mode on left-click, a password-to-start lid mode capped at 24h, a plain NSMenu, a robot lid icon, faster crash recovery, and hotspot failover that checks the internet and switches back.

**Architecture:** Keep Insomnia's session machinery (`SessionManager`, the recovery journal, `backstop.sh`, `LidActions`) and change it at its seams: a new `AwakeController` owns an IOKit assertion outside the journal; `StatusItemController` is rewritten around a plain `NSStatusItem` + the existing `StatusMenu` builder; `PmsetSleepGuard` turns sleep off through an `AdminCommandRunning` seam (osascript administrator prompt); `backstop.sh` gains an app-absence rule; `NetworkFailover` gains a reachability probe and a switch-back loop. The Swift module, target and folder names stay `Insomnia`.

**Tech Stack:** Swift 6.2 (language mode 6, strict concurrency), SwiftPM, AppKit + SwiftUI (Settings only), IOKit power management, CoreWLAN, Network.framework, URLSession (new, probe only), bash 3.2 scripts, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-14-awake-design.md`

## Global Constraints

- macOS 26 or later, Apple Silicon; `Package.swift` stays `swift-tools-version: 6.2`, `.macOS(.v26)`, `.swiftLanguageMode(.v6)`.
- `swift build -c release -Xswiftc -warnings-as-errors` must pass after every task.
- No new package dependencies.
- Scripts run under macOS `/bin/bash` 3.2: no empty-array expansion under `set -u`, no `mapfile`, no `${var,,}`. Every script stays ShellCheck clean (`shellcheck --shell=bash scripts/*.sh`).
- Script tests swap tools by patching `NAME=` constant lines (`ScriptFixture.patch`, `Tests/InsomniaTests/RecoveryScriptTests.swift:6514`): every new external tool or path a script uses must be a single `NAME=` line the fixture can patch.
- User-visible name: **Awake**. Bundle id `app.chargingpixels.awake`. Executable `Awake`. App Support `~/Library/Application Support/Awake`, Logs `~/Library/Logs/Awake/awake.log`, LaunchAgent label `app.chargingpixels.awake.recovery`, sudoers `/etc/sudoers.d/awake`, keychain service `awake-hotspot`, env override `AWAKE_HOME`, app bundle `~/Applications/Awake.app`, status item autosave `awake.status`.
- Lid sessions: max 24h (`Config.lidMaxDuration = 24 * 3600`). Awake mode durations: until turned off, 1h, 2h, 4h. Lid durations: 1h, 2h, 4h, 8h, Custom.
- Sudoers grants exactly: `pmset -a disablesleep 0`, `pmset -b lowpowermode 1`, `pmset -b lowpowermode 0`. Never `disablesleep 1`.
- The only network request the app makes is `GET http://captive.apple.com/hotspot-detect.html`, only while hotspot failover is running.
- Comment style: match the surrounding code (Insomnia documents every type and non-obvious decision with `///`).
- Commit after every task, on branch `phase-1`, with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Fast tests: `scripts/test-fast.sh` (Task 17). Until it exists: `swift test --skip 'RecoveryScriptTests|AgentModeExitInANewBootTests|AppEncodedJournalScriptTests|PackagingTests|LidSimulationGateScriptTests|ResumeFrozenCommandTests'`. Script-driven test classes are run on their own with `--filter` in the tasks that touch scripts.
- The full suite has known timing-flaky tests under load (spec, Open questions 1). A failure in `PowerMonitorTests`, `UIStatusTests` or `RecoveryScriptTests` timing cases is re-run alone with `--filter` before it is treated as real.

## Decisions this plan makes inside the spec

Each is called out again in the task that implements it.

1. **Executable renamed to `Awake`** (not only the display name): `install.sh`/`uninstall.sh` find the app with `pgrep -x <executable>`, and keeping `Insomnia` would match a running Insomnia.
2. **Relaunch during a lid session never prompts.** Reconcile keeps a valid session only if `SleepDisabled` still reads 1; otherwise it ends the session with a notification. (Insomnia re-ran `disablesleep 1` at launch, which would now raise the password prompt at login.)
3. **Lid mode includes screen mode (progression off → screen → lid; spec revision 2026-10-14).** During a lid session the Awake assertion is held while the lid is open and released while it is closed (a held display assertion would stop `LidActions` from sleeping the panel, `DisplayPower.swift:23`). Starting a lid session folds a running Awake mode into it; ending the lid session leaves everything off.
4. **A cancelled password prompt** ends the start with a new `EndReason.startCancelled`: no notification, no error line.
5. **osascript gets 300 s** (a person typing a password), not the 20 s pmset limit.
6. **`Config.maxDuration` is clamped to 24h on load** and the Settings session section (pill presets) is removed. Extensions keep Insomnia's rule: never past `now + 24h`.
7. **"Network recovered" notification stays** for outages of 90 s or more, without the tmux text; `nudgeThreshold` becomes a constant.
8. **`dockerFrozen` stays in the journal** so recovery of an Insomnia-era journal still clears it; only the rule that sets it goes.
9. **App icon (Finder, notifications) stays the eye** in phase 1.
10. **Backstop app check:** `pgrep -x Awake`; a pgrep timeout counts as "running" (never end a session on a guess).
11. **Closed-lid clock (spec revision 2026-10-14).** The lid timer counts only closed-lid time; a paused session keeps `pausedRemaining` plus a 5-minute `endsAt` lease renewed every minute (Task 6b). `SessionManager(closedLidClock:)` defaults to `true`; the test `Harness` defaults to `false` so Insomnia's existing tests keep their wall-clock meaning.

## Review Focus

1. **A password prompt left open until it times out (300 s)** must fail the start cleanly ("Session not started" with a readable reason), never leave sleep disabled, and never count as a cancel. Test: Task 11, `testAdminTimeoutFailsTheStartAndRestoresSleep`.
2. **Relaunching the app during a lid session while sleep is still disabled** must keep the session with no prompt. Test: Task 11, `testReconcileKeepsSessionWithoutPromptWhenSleepStillDisabled`.
3. **The app crashing with the lid closed** must have sleep restored by the backstop within about 3 minutes, and a briefly restarted app must reset the clock. Tests: Task 13.
4. **Awake mode on, then a lid session starts, the lid closes and opens, and the session ends** must hold the screen only while the lid is open, and leave the Mac with normal sleep and nothing held at the end (Awake mode not silently re-enabled). Tests: Task 7 `testLidSessionHoldsOnlyWhileTheLidIsOpen`, Task 10 `testLidSessionFoldsAwakeModeInAndLeavesNothingHeld`.
6. **The lid opened for hours during a lid session** must never end it by the clock, and an app crash while paused must still restore sleep within about 5 minutes. Tests: Task 6b `testAPausedSessionIsNeverEndedByTheClock`, and the lease is what Task 13's backstop reads.
5. **Wi-Fi connected but no internet (captive portal, ISP down)** must move to the hotspot, and must not switch back to a home network that still has no internet. Tests: Task 14 `testProbeFailuresStartAnOutage`, Task 15 `testSwitchBackRejoinsHotspotWhenHomeHasNoInternet`.

---

## File Structure

Created:
- `Sources/Insomnia/System/AwakeAssertion.swift`: `AwakeAsserting` protocol, `IOPMAwakeAssertion`, `AwakeAssertionError`.
- `Sources/Insomnia/Core/AwakeController.swift`: Awake mode state, timer, lid hand-off.
- `Sources/Insomnia/UI/MenuBarIcon.swift`: the three template icons, drawn in code.
- `Sources/Insomnia/UI/Countdown.swift`: `h:mm` formatting for the menu bar and menu.
- `Sources/Insomnia/UI/DurationParser.swift`: moved out of `DurationInput.swift`.
- `Sources/Insomnia/Core/AdminPrompt.swift`: `AdminCommandRunning`, `OsascriptAdminRunner`, `AdminPromptCancelledError`.
- `Sources/Insomnia/System/ReachabilityProbe.swift`: `ReachabilityProbing`, `CaptivePortalProbe`, `ReachabilityTracker`.
- `scripts/test-fast.sh`, `.github/workflows/ci.yml` (replaced).
- Tests: `AwakeControllerTests.swift`, `MenuBarIconTests.swift`, `MenuBarTests.swift`, `AdminPromptTests.swift`, `ReachabilityTests.swift`, `DurationParserTests.swift`.

Rewritten: `Sources/Insomnia/UI/StatusItemController.swift`.

Deleted: `TmuxNudge.swift`, `DockerRule.swift`, `StatusRootView.swift`, `MenuBarModel.swift`, `DurationInput.swift`, `PillView.swift`, `HoldToEndButton.swift`, `Motion.swift`, `EyeMark.swift`, `KeyCatcherPanel.swift`, `StatusWidthWriter.swift`, `.github/workflows/merge-gate.yml`, `.github/workflows/release.yml`, `.github/scripts/merge-gate*`, `.greptile/`, `skills/`, and the tests of those.

Kept although UI: `StatusMenu.swift`, `StatusSource.swift`, `LiveStatusSource.swift`, `ReminderScheduler.swift`, `SettingsWindow.swift`, `SettingsView.swift`, `AppIconArtwork.swift`, `BrandPalette.swift`, `EyeMarkGeometry.swift`, `EyeLensGeometry.swift` (the last four draw the app icon).

---

### Task 1: Branch and adopt the closed-lid sleep fix (Insomnia PR #61)

**Files:** merge only (10 files from PR #61: `Sources/Insomnia/System/ClosedLidSleep.swift`, `SessionManager.swift`, `InsomniaApp.swift`, `LidObserver.swift`, tests, docs).

**Interfaces:**
- Produces: `EndReason.sleepsAClosedLid`, `ClosedLidSleeping`, `IOKitClosedLidSleep`, `SessionManager.closedLidSleepOwed`.

- [ ] **Step 1: Create the branch and fetch the PR**

```bash
cd ~/Coding/Awake
git switch -c phase-1 main
git fetch upstream pull/61/head:pr-61
```

- [ ] **Step 2: Merge it**

```bash
git -c user.name=liviulica -c user.email=826835+liviulica@users.noreply.github.com merge --no-ff --no-edit pr-61
```
Expected: auto-merge of `README.md`, `docs/*.md`, no conflicts (verified 2026-10-14 against `b6a7499`).

- [ ] **Step 3: Run the PR's tests**

Run: `swift test --filter ClosedLidSleepTests`
Expected: 18 tests pass.

- [ ] **Step 4: Build warnings-clean**

Run: `swift build -c release -Xswiftc -warnings-as-errors`
Expected: `Build complete!`

- [ ] **Step 5: Push the branch** (the merge commit is the commit for this task)

```bash
git push -u origin phase-1
```

---

### Task 2: Rename the user-visible identity to Awake

Decision 1 applies: the executable becomes `Awake`.

**Files:**
- Modify: `Sources/Insomnia/Store/Paths.swift:19-21,42,51-54,94`
- Modify: `Resources/Info.plist:8,10,14,16,32,34`
- Modify: `scripts/build-app.sh:67,71`
- Modify: `scripts/install.sh` (constants `:74,87-93,100`, pgrep `:431-438,520`, staging names `:445,604-605`, sudoers comment `:393`, `AGENT_PROGRAM` `:855`, `:1130`), `scripts/uninstall.sh` (`:93-110,226,803,816,993-999,1017`), `scripts/backstop.sh` (`:189-190,207-217`), `scripts/simulate-lid.sh:25`
- Modify: `Sources/Insomnia/Core/LaunchdBackstop.swift:62`, `Sources/Insomnia/System/NetworkFailover.swift:125,185,210,485,487`, `Sources/Insomnia/Core/Log.swift:28,38`, `Sources/Insomnia/Core/SleepGuard.swift:24`, `Sources/Insomnia/System/DisplayPower.swift:221`, `Sources/Insomnia/UI/ReminderScheduler.swift:65`, `Sources/Insomnia/UI/StatusMenu.swift:33,191`, `Sources/Insomnia/UI/SettingsWindow.swift:36`, `Sources/Insomnia/UI/SettingsView.swift:200,275,282,311`, `Sources/Insomnia/Model/Config.swift:213`, `Sources/Insomnia/Core/LidActions.swift:448`, `Sources/Insomnia/Core/ResumeFrozenCommand.swift:97`, user-facing strings in `Sources/Insomnia/Core/SessionManager.swift` (about 30, lines 789-3187)
- Modify: `Tests/InsomniaTestHome/InsomniaTestHome.c:16,42`
- Test: `StoreTests.swift:544-551`, `LaunchdBackstopTests.swift`, `RecoveryScriptTests.swift` (fixture `:6391-6480` and assertions), `PackagingTests.swift:130,201,373-475`, `ConfigTests.swift:254,257,378,403,448`, `OwnerOnlyTests.swift`, `LogPrivacyTests.swift:51-52`, `AutomationSafetyTests.swift:441,473`, `LidActionsTests.swift:184,1186`, `TestIsolationTests.swift:55`, `ResumeFrozenCommandTests.swift:281,446`

**Interfaces:**
- Produces: `Paths.environmentKey == "AWAKE_HOME"`, `Paths.backstopLabel == "app.chargingpixels.awake.recovery"`, `Paths.bundleIdentifier == "app.chargingpixels.awake"`, `Paths.logFile` ends in `awake.log`, `KeychainStore.service == "awake-hotspot"`, `StatusMenu.quitTitle == "Quit Awake"`.

- [ ] **Step 1: Update the identity pins in the tests first**

In `Tests/InsomniaTests/StoreTests.swift` around line 544, change the environment-override test to the new values:

```swift
        let p = Paths.resolve(environment: ["AWAKE_HOME": "/tmp/x"], home: URL(fileURLWithPath: "/Users/u"))
        XCTAssertEqual(p.logFile.path, "/tmp/x/Logs/awake.log")
        XCTAssertEqual(p.backstopPlist.lastPathComponent, "app.chargingpixels.awake.recovery.plist")
```
and the default-layout assertion to `"/Library/Application Support/Awake/session.json"`. (Keep the surrounding code; only the literals change. If the helper is not named `Paths.resolve`, keep whatever it calls.)

Then run: `grep -rln 'INSOMNIA_HOME\|com\.insomnia\.backstop\|com\.kgarg\.insomnia\|insomnia\.log\|"insomnia: \|Quit Insomnia\|Logs/Insomnia\|Support/Insomnia\|insomnia-hotspot\|MacOS/Insomnia\|Insomnia\.app' Tests/`
For every hit, replace the literal with its Awake value from Global Constraints (`"insomnia: "` → `"awake: "`, `Contents/MacOS/Insomnia` → `Contents/MacOS/Awake`, `Insomnia.app` → `Awake.app`, `.Insomnia.app.previous` → `.Awake.app.previous`). Do not rename Swift types, the module, `InsomniaTests`, or `InsomniaResumeFrozenVersion`.

- [ ] **Step 2: Run the pinned tests to see them fail**

Run: `swift test --filter 'StoreTests|LaunchdBackstopTests|TestIsolationTests'`
Expected: FAIL on the new literals.

- [ ] **Step 3: Change the Swift identity constants**

`Sources/Insomnia/Store/Paths.swift`:
```swift
    static let environmentKey = "AWAKE_HOME"
    static let backstopLabel = "app.chargingpixels.awake.recovery"
    static let bundleIdentifier = "app.chargingpixels.awake"
```
and the path literals: `"Awake.app"` (`:42`), `"Application Support/Awake"` (`:51`), `"Logs/Awake"` (`:52`), `"Applications/Awake.app"` (`:54`), `"awake.log"` (`:94`). Update the doc comments at `:3-17` to say Awake.

`Sources/Insomnia/Core/LaunchdBackstop.swift:62`, replace both log paths and the reinstall text:
```swift
    static let agentProgram = #"r="$(/usr/bin/codesign --verify --strict "-R=$1" "$2" 2>&1)" && exec /bin/bash "$2/Contents/Resources/backstop.sh"; mkdir -p "$HOME/Library/Logs/Awake"; printf "%s [error] backstop agent: %s does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Awake (scripts/install.sh). codesign: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$(printf %s "$r" | tr "\n" " ")" >> "$HOME/Library/Logs/Awake/awake.log"; exit 1"#
```
`scripts/install.sh:855` `AGENT_PROGRAM=` must be the same string byte for byte (`LaunchdBackstopTests:239-243` compares them).

`NetworkFailover.swift`: `:485` `static let service = "awake-hotspot"`, `:487` `accessDescriptor = "Awake hotspot password"`, `:125` queue label `"app.chargingpixels.awake.keychain"`, and "Insomnia" → "Awake" in the texts at `:185,210`.

`Log.swift:28` prefix `"awake: "`, `:38` `"awake.log: "`. `SleepGuard.swift:24` `/etc/sudoers.d/awake`. `DisplayPower.swift:221` `"Awake lid open"`. `ReminderScheduler.swift:65` `"awake.reminder"`. `StatusMenu.swift:33` `static let quitTitle = "Quit Awake"`, and `:191` "Insomnia quits" → "Awake quits". `SettingsWindow.swift:36` `"Awake Settings"`.

Every remaining user-facing "Insomnia" string in `SessionManager.swift`, `SettingsView.swift`, `Config.swift:213`, `LidActions.swift:448`, `ResumeFrozenCommand.swift:97`: replace the word with "Awake". Find them with `grep -n '"[^"]*Insomnia[^"]*"' Sources/Insomnia -r`; change string literals only, never identifiers.

- [ ] **Step 4: Change Info.plist and build-app.sh**

`Resources/Info.plist`: `CFBundleExecutable` `Awake`, `CFBundleIdentifier` `app.chargingpixels.awake`, `CFBundleName` and `CFBundleDisplayName` `Awake`, and "Insomnia" → "Awake" in both `NSLocation*UsageDescription` strings. Keep `InsomniaResumeFrozenVersion` as is.

`scripts/build-app.sh`: `:67` `APP="$OUTPUT/Awake.app"`; `:71` copy the SwiftPM binary (still `.build/.../Insomnia`, `:63`) to `"$APP/Contents/MacOS/Awake"`.

- [ ] **Step 5: Change the scripts**

`scripts/install.sh`: `BUNDLE_ID=app.chargingpixels.awake`, `APP="$APP_DIR/Awake.app"`, `APP_SUPPORT="$HOME/Library/Application Support/Awake"`, `LOG_DIR="$HOME/Library/Logs/Awake"`, `LABEL=app.chargingpixels.awake.recovery`, `SUDOERS=/etc/sudoers.d/awake`, the previous/staging names `.Awake.app.previous` / `.Awake.app.staging.`, `pgrep -x Awake` (both places), the `INSOMNIA_HOME` refusal at `:40-42` becomes `AWAKE_HOME` with the same text but naming Awake, the sudoers comment `# Installed by Awake install.sh.`, and the log path at `:1130`.

`scripts/uninstall.sh`: the same constants (`:93-110`), the basename check `"Awake.app"` (`:226`), `pgrep -x Awake` (`:803`), the osascript bundle id (`:816`), previous/staging names (`:993-999`), log names (`:1017`).

`scripts/backstop.sh`:
```bash
INSOMNIA_BIN="${HOME:-}/Applications/Awake.app/Contents/MacOS/Awake"
INSOMNIA_INFO="${HOME:-}/Applications/Awake.app/Contents/Info.plist"
```
(the variable names stay: the fixture patches them by name), and:
```bash
if [[ -n "${AWAKE_HOME:-}" ]]; then
  APP_SUPPORT="$AWAKE_HOME"
  LOG_DIR="$AWAKE_HOME/Logs"
else
  APP_SUPPORT="$HOME/Library/Application Support/Awake"
  LOG_DIR="$HOME/Library/Logs/Awake"
fi
```
and `LOG="$LOG_DIR/awake.log"`. `scripts/simulate-lid.sh:25` `${AWAKE_HOME:-$HOME/Library/Application Support/Awake}`.

In `RecoveryScriptTests.swift:6470`, the fixture's `replaceOnce` anchor becomes `if [[ -n "${AWAKE_HOME:-}" ]]; then`, and the environment it passes (`:6587-6640`) uses `AWAKE_HOME`.

`Tests/InsomniaTestHome/InsomniaTestHome.c:16` `kKey = "AWAKE_HOME"`, `:42` temp prefix `awake-test-home`.

- [ ] **Step 6: Run the tests**

Run: `swift build --build-tests && swift test --filter 'StoreTests|LaunchdBackstopTests|TestIsolationTests|ConfigTests|OwnerOnlyTests|LogPrivacyTests'`
Expected: PASS.
Run: `swift test --filter 'RecoveryScriptTests|PackagingTests'` (slow, about 15 min)
Expected: PASS (re-run a timing failure alone before treating it as real).
Run: `grep -rn 'Insomnia' scripts/*.sh Resources/Info.plist | grep -v 'INSOMNIA_BIN\|INSOMNIA_INFO\|InsomniaResumeFrozenVersion\|\.build/'`
Expected: no user-visible "Insomnia" left (comments may still credit Insomnia).

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "Identity: Awake, app.chargingpixels.awake, executable Awake

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Installer refuses while Insomnia is installed

**Files:**
- Modify: `scripts/install.sh` (new constants near `:87-100`; new check before step 2 at `:386`)
- Test: `Tests/InsomniaTests/RecoveryScriptTests.swift` (fixture `writeInstallCopies` around `:6420-6471`; new test next to the other install tests)

**Interfaces:**
- Produces: install.sh constants `INSOMNIA_SUDOERS`, `INSOMNIA_PLIST`, `INSOMNIA_APP` (patchable).

- [ ] **Step 1: Teach the fixture the new constants**

In `ScriptFixture.writeInstallCopies`, add to the install patch map (same form as the existing `APP`/`SUDOERS` entries):
```swift
            "INSOMNIA_SUDOERS": root.appendingPathComponent("etc/sudoers.d/insomnia").path,
            "INSOMNIA_PLIST": root.appendingPathComponent("home/Library/LaunchAgents/com.insomnia.backstop.plist").path,
            "INSOMNIA_APP": root.appendingPathComponent("Applications/Insomnia.app").path,
```

- [ ] **Step 2: Write the failing test**

Add to the install tests in `RecoveryScriptTests.swift` (mirror the setup of the nearest existing install test, e.g. the one asserting `fx.exists(fx.sudoers)`):
```swift
    func testInstallRefusesWhileInsomniaIsInstalled() throws {
        let insomnia = fx.root.appendingPathComponent("Applications/Insomnia.app")
        try FileManager.default.createDirectory(at: insomnia, withIntermediateDirectories: true)

        let r = try fx.run(fx.install, [])

        XCTAssertEqual(r.status, 1, r.stdout + r.stderr)
        XCTAssertTrue(r.stderr.contains("Insomnia is installed"), r.stderr)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo") }, "\(fx.calls())")
        XCTAssertFalse(fx.exists(fx.sudoers))
    }
```

- [ ] **Step 3: Run it to verify it fails**

Run: `swift test --filter RecoveryScriptTests/testInstallRefusesWhileInsomniaIsInstalled`
Expected: FAIL (status is not 1, or sudo is called).

- [ ] **Step 4: Implement the check**

In `scripts/install.sh`, next to the other path constants:
```bash
# Insomnia drives the same SleepDisabled bit; the two must not be installed
# together (spec "Coexistence").
INSOMNIA_SUDOERS=/etc/sudoers.d/insomnia
INSOMNIA_PLIST="$HOME/Library/LaunchAgents/com.insomnia.backstop.plist"
INSOMNIA_APP="$HOME/Applications/Insomnia.app"
```
Immediately before `# 2. sudoers ----` (`:386`):
```bash
# 1b. Insomnia ---------------------------------------------------------------
#    Refused before the password prompt, so nothing is changed.
insomnia_found=""
for path in "$INSOMNIA_SUDOERS" "$INSOMNIA_PLIST" "$INSOMNIA_APP"; do
  if [[ -e "$path" ]]; then insomnia_found="$insomnia_found $path"; fi
done
if [[ -n "$insomnia_found" ]]; then
  echo "Insomnia is installed (found:$insomnia_found). Awake and Insomnia both control this Mac's sleep setting and cannot be installed together. Uninstall Insomnia first (scripts/uninstall.sh in your Insomnia checkout), then run this installer again. Nothing was changed." >&2
  exit 1
fi
```

- [ ] **Step 5: Run the test and the install tests**

Run: `swift test --filter RecoveryScriptTests/testInstall`
Expected: PASS. Run `shellcheck --shell=bash scripts/install.sh`: no findings.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "install: refuse while Insomnia is installed

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Remove the tmux nudge

Decision 7 applies.

**Files:**
- Delete: `Sources/Insomnia/System/TmuxNudge.swift`
- Modify: `Sources/Insomnia/Model/Config.swift:63-71,163-165`, `Sources/Insomnia/System/NetworkFailover.swift:749,780,806,816,1076-1091`, `Sources/Insomnia/UI/SettingsView.swift:17,279-307,315-320,471-476`
- Modify tests: `AutomationSafetyTests.swift` (delete `TmuxNudgeTests` `:257`, `TmuxLiveRunnerTests` `:322`, `TmuxTargetResolutionTests` `:613`; rewrite `NetworkFailoverCancellationTests` `:85` without `nudge:`), `FailoverMachineTests.swift:79-82,111-200`, `ConfigTests.swift:20,39-40,46-53,333`, `OwnerOnlyTests.swift:356`, `LogPrivacyTests.swift:6,18,52`

**Interfaces:**
- Produces: `NetworkFailover.recoveredNoticeThreshold: TimeInterval = 90`; `NetworkFailover.init` without `nudge:`.

- [ ] **Step 1: Write the failing test for the recovered notice**

In `FailoverMachineTests.swift`, inside `NetworkFailoverDriverTests`, replace the nudge tests (`:111-200`) with:
```swift
    func testLongOutageRecoveryNotifiesWithoutTmuxText() async throws {
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: notifier, clock: clock)
        await n.simulate(satisfied: false)
        clock.advance(NetworkFailover.recoveredNoticeThreshold)
        await n.simulate(satisfied: true)
        let post = try XCTUnwrap(notifier.posts.last)
        XCTAssertEqual(post.title, "Network recovered")
        XCTAssertFalse(post.body.contains("tmux"), post.body)
    }

    func testShortOutageRecoveryDoesNotNotify() async {
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: notifier, clock: clock)
        await n.simulate(satisfied: false)
        clock.advance(NetworkFailover.recoveredNoticeThreshold - 1)
        await n.simulate(satisfied: true)
        XCTAssertFalse(notifier.posts.contains { $0.title == "Network recovered" })
    }
```
Delete `testRecoveryBelowThresholdNoNudge` (`:79-82`). Remove the `nudge:` argument from the `driver(...)` helper (`:433`).

- [ ] **Step 2: Run to verify it fails**

Run: `swift build --build-tests`
Expected: compile error, `recoveredNoticeThreshold` does not exist.

- [ ] **Step 3: Remove the nudge from the driver**

In `NetworkFailover.swift`: delete `private let nudge: TmuxNudge` (`:780`), the `nudge:` init parameter (`:806`) and its assignment (`:816`); change the doc comment at `:749` to "…CoreWLAN for the join, handoffs.log and a notification on recovery…". Add next to `networksetup`:
```swift
    /// Outages at least this long post "Network recovered" when they end.
    static let recoveredNoticeThreshold: TimeInterval = 90
```
Replace `recovered(start:gap:)` with:
```swift
    private func recovered(start: Date, gap: TimeInterval) async {
        let epoch = self.epoch
        let end = clock()
        lastGap = gap
        let line = FailoverMachine.logLine(start: start, end: end, gap: gap)
        appendHandoff(line)
        Log.info("wifi path satisfied after \(FailoverMachine.humanGap(gap))")
        // A stopped driver must not write into the next session's status.
        guard self.epoch == epoch else { return }
        if gap >= Self.recoveredNoticeThreshold {
            notifier.post(
                title: "Network recovered",
                body: "The network was down for \(FailoverMachine.humanGap(gap)). Check that your agents picked up where they left off."
            )
        }
        onRecovered?(gap)
    }
```

- [ ] **Step 4: Remove the Config keys and Settings rows**

`Config.swift`: delete `nudgeThreshold`, `tmuxTargets`, `tmuxNudgePressesEnter` (`:63-71`) and their three `decodeIfPresent` lines (`:163-165`). Old config files keep loading: unknown keys are ignored.
`SettingsView.swift`: delete `@State private var newTmuxTarget` (`:17`), the tmux rows (`:279-307`), `nudgeSeconds` (`:315-320`) and `addTmuxTarget()` (`:471-476`).
Delete `Sources/Insomnia/System/TmuxNudge.swift`.

- [ ] **Step 5: Fix the remaining test references**

Delete `TmuxNudgeTests`, `TmuxLiveRunnerTests`, `TmuxTargetResolutionTests` from `AutomationSafetyTests.swift`. In `NetworkFailoverCancellationTests` (`:85`), drop the `nudge:` and `targets:` parameters from `makeDriver` and delete the test methods whose only assertion is about nudged panes. Remove the tmux keys from `ConfigTests.swift` (`:20,39-40,46-53,333`) and the `nudge:` argument at `OwnerOnlyTests.swift:356`. In `LogPrivacyTests.swift`, drop the tmux-specific strings (`:6,18,52`).

- [ ] **Step 6: Run**

Run: `swift build --build-tests && swift test --filter 'FailoverMachineTests|NetworkFailoverDriverTests|NetworkFailoverCancellationTests|ConfigTests|OwnerOnlyTests|LogPrivacyTests'`
Expected: PASS. Run `grep -rni 'tmux\|nudge' Sources/`: no hits.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "Remove the tmux nudge; keep the recovered notice at 90 s

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Remove the Docker rule (keep the journal field)

Decision 8 applies.

**Files:**
- Delete: `Sources/Insomnia/System/DockerRule.swift`
- Modify: `Config.swift:24-28,149`; `LidActions.swift:17,36,44,100-125,152,365-444`; `AppServices.swift:18,59,124,147,452`; `StatusSource.swift:16,47,78-86`; `LiveStatusSource.swift:20`; `StatusItemController.swift:680` (this file is rewritten in Task 10; here only drop the argument); `SettingsView.swift:186-187,200`; `Freezer.swift:53` (the `applyDenylist: false` variant, only DockerRule used it)
- Keep unchanged: `RuntimeState.dockerFrozen` and its coding, `SessionManager` `owedEdits.freeze.docker` handling, `backstop.sh`/`uninstall.sh` `dockerFrozen` logic, `Freezer`'s Docker hard-deny (`:252-257`).
- Tests: delete `DockerRuleSecondCheckTests` and `DockerRuleEndpointTests` (`AutomationSafetyTests.swift:719,771`), the Docker tests in `LidActionsTests.swift:1734-2070` and the helper parts at `:31-47,2518,2568`; drop the `docker:` arguments where `LidActions`/`AppServices` are built (`PrivateDisplayGuardTests.swift:234,630,1061,1236,3082`, `StillRunningCommandTests.swift:688`, `EarlierBootLowPowerClaimTests.swift:70`, `RecoveryScriptTests.swift:7567,7895`); `ConfigTests.swift:25,29,175-186,217-225`; `UIStatusTests.swift:203,228-231,1187` and `IntegrationWiringTests.swift:23,34` (`dockerPaused`); `FreezerTests.swift:57-63,196-202` only where they call the removed `applyDenylist: false` variant.

**Interfaces:**
- Produces: `LidActions.init` without `docker:`; `StatusLines.actions(frozenCount:lastGap:)` (no `dockerPaused:`); `StatusSource` without `dockerPaused`.

- [ ] **Step 1: Write the regression test that matters (old journal still recovers)**

In `RecoveryScriptTests.swift`, the existing `dockerFrozen: true` fixtures (`:106-156`) already cover backstop clearing it. Add one Swift-side test to `ReconcileTests.swift`:
```swift
    func testReconcileClearsAnInsomniaEraDockerFlag() async throws {
        var state = RuntimeState.clean
        state.dockerFrozen = true
        try h.store.saveState(state)
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertFalse(try XCTUnwrap(h.store.loadState()).dockerFrozen)
    }
```

- [ ] **Step 2: Run it (it should already pass) and keep it as the guard**

Run: `swift test --filter ReconcileTests/testReconcileClearsAnInsomniaEraDockerFlag`
Expected: PASS before and after the removal. If it fails before the removal, stop and report: the journal semantics differ from the research.

- [ ] **Step 3: Remove the rule**

Delete `DockerRule.swift`. In `LidActions.swift`, delete the `docker` property and init parameter (`:17,36,44`), the idle checks and Docker freeze (`:100-125`), and the Docker branch of `freeze(_:docker:...)` (`:365-444`): the function keeps freezing the planned apps and writes `dockerFrozen = false` never, so the journal field stays at whatever recovery leaves. In `AppServices.swift`, delete `status.dockerPaused` (`:18,452`), the `DockerRule` construction (`:59,124`) and the `docker:` argument (`:147`). Delete `Config.dockerRule` and its decode line. Delete the Settings toggle and caption (`:186-187`) and the mention at `:200`. Delete `dockerPaused` from `StatusSource`/`PlaceholderStatus`/`LiveStatusSource` and the "Docker paused" part of `StatusLines.actions`. Delete Freezer's `plan(..., applyDenylist: false)` variant if nothing else calls it (`grep -n 'applyDenylist' -r Sources`).

- [ ] **Step 4: Fix the tests listed above**

Delete the Docker-only tests; drop `docker:` arguments; remove `dockerPaused` from the recording status source.

- [ ] **Step 5: Run**

Run: `swift build -c release -Xswiftc -warnings-as-errors && swift test --filter 'LidActionsTests|ReconcileTests|FreezerTests|ConfigTests|PrivateDisplayGuardTests|StillRunningCommandTests|EarlierBootLowPowerClaimTests'`
Expected: PASS. `grep -rn 'DockerRule\|dockerRule\|dockerPaused' Sources Tests`: no hits. `grep -rn dockerFrozen Sources scripts`: still present in RuntimeState, SessionManager, backstop.sh, uninstall.sh.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Remove the Docker rule; keep dockerFrozen for old journals

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: 24-hour lid sessions, drop the pill presets from Settings

Decision 6 applies.

**Files:**
- Create: `Sources/Insomnia/UI/DurationParser.swift` (moved from `DurationInput.swift:167-end`)
- Modify: `Sources/Insomnia/Model/Config.swift` (`maxDuration` default, new `lidMaxDuration`, `normalizeMaxDuration()`), `Sources/Insomnia/Core/SessionManager.swift:590-611` (apply it on load), `Sources/Insomnia/UI/SettingsView.swift:27,98-156` (delete `sessionSection`)
- Test: `ConfigTests.swift:21`, `SessionMathTests.swift:5`, `ReconcileTests.swift:328`, new `DurationParserTests.swift` (move the parser cases out of `DurationInputTests.swift`)

**Interfaces:**
- Produces: `Config.lidMaxDuration: TimeInterval` (static, `24 * 3600`), `mutating func normalizeMaxDuration() -> String?`, `DurationParser.seconds(from:) -> TimeInterval?` (unchanged API, new file).

- [ ] **Step 1: Write the failing tests**

In `ConfigTests.swift`:
```swift
    func testMaxDurationDefaultsTo24Hours() {
        XCTAssertEqual(Config().maxDuration, 24 * 3600)
        XCTAssertEqual(Config.lidMaxDuration, 24 * 3600)
    }

    func testAnOlderThirtyDayMaxIsClampedOnLoad() {
        var c = Config()
        c.maxDuration = 30 * 24 * 3600
        XCTAssertNotNil(c.normalizeMaxDuration())
        XCTAssertEqual(c.maxDuration, 24 * 3600)
        XCTAssertNil(c.normalizeMaxDuration(), "a second pass changes nothing")
    }
```
Update `ConfigTests.swift:21`, `SessionMathTests.swift:5` and `ReconcileTests.swift:328` where they pin 30 days to `24 * 3600`.

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests`
Expected: compile error (`lidMaxDuration`, `normalizeMaxDuration` missing).

- [ ] **Step 3: Implement**

`Config.swift`:
```swift
    /// Hard ceiling on a lid session: 24 hours (spec "Interaction"). An
    /// extension never pushes the end past `now + maxDuration`.
    var maxDuration: TimeInterval = Config.lidMaxDuration

    static let lidMaxDuration: TimeInterval = 24 * 3600
```
and next to `normalizeFloors()`:
```swift
    /// Insomnia allowed 30 days; Awake allows 24 hours. A config.json an
    /// earlier build saved is brought down to the ceiling once and saved.
    mutating func normalizeMaxDuration() -> String? {
        guard maxDuration > Config.lidMaxDuration || maxDuration < SessionMath.minimumDuration else { return nil }
        let before = maxDuration
        maxDuration = Config.lidMaxDuration
        return "maxDuration \(Int(before)) s -> \(Int(maxDuration)) s"
    }
```
`SessionManager.swift`, where corrections are gathered (`:593`):
```swift
            var corrections = c.normalizeFloors().map { [$0] } ?? []
            if let max = c.normalizeMaxDuration() { corrections.append(max) }
```
Check `SessionMath.minimumDuration` is accessible (it is used by `clamp`); if it is `private`, make it `static let` internal.

- [ ] **Step 4: Move DurationParser and remove the session section**

Move `enum DurationParser` (`DurationInput.swift:167` to the end of that type) into `Sources/Insomnia/UI/DurationParser.swift` unchanged. In `SettingsView.swift`, delete `sessionSection` from the `Form` (`:27`) and its definition (`:98-156`). Move the `DurationParser` cases from `DurationInputTests.swift` into `Tests/InsomniaTests/DurationParserTests.swift` (the rest of `DurationInputTests.swift` is deleted in Task 10 with `DurationInput`).

- [ ] **Step 5: Run**

Run: `swift test --filter 'ConfigTests|SessionMathTests|ReconcileTests|DurationParserTests'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Lid sessions max 24h; move DurationParser; drop pill presets from Settings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6b: The lid timer counts closed-lid time only

Decision 11 applies. A lid session's timer runs only while the lid is closed. While the lid is open the session is **paused**: `session.json` carries `pausedRemaining` (the closed-lid seconds left) and a short **lease** for `endsAt`, renewed every minute, so the recovery agent and reconcile (which only read `endsAt`) keep treating it as valid while the app runs, and recover it within minutes if the app dies.

**Files:**
- Modify: `Sources/Insomnia/Model/Session.swift` (`pausedRemaining`, `isPaused`, `closedLidRemaining(at:)`), `Sources/Insomnia/Core/SessionMath.swift` (`pauseLease`, `newPausedSession`, `paused`, `resumed`, `leaseRenewed`, paused-aware `extended`), `Sources/Insomnia/Core/SessionManager.swift` (init flag `closedLidClock`, start, deadline callback, lease timer, `lidClosedClock()`, `lidOpenedClock()`, `renewLeaseIfPaused()`, reconcile, `refreshCountdown`, `stopTimers`), `Sources/Insomnia/Core/LidActions.swift:133,145` (call the clock hooks next to `pauseCountdown`/`resumeCountdown`), `Tests/InsomniaTests/TestSupport.swift` (`Harness.makeManager(closedLidClock: Bool = false)`)
- Test: new `Tests/InsomniaTests/ClosedLidClockTests.swift`; `StoreTests.swift` (old session.json decodes); `RecoveryScriptTests.swift` (a paused session file is valid for the backstop)

**Interfaces:**
- Produces:
  - `Session.pausedRemaining: TimeInterval?` (Codable, optional: Insomnia-era files decode with nil), `var isPaused: Bool`, `func closedLidRemaining(at now: Date) -> TimeInterval`
  - `SessionMath.pauseLease: TimeInterval = 300`, `static func newPausedSession(now:duration:maxDuration:) -> Session`, `static func paused(_:now:) -> Session`, `static func resumed(_:now:) -> Session`, `static func leaseRenewed(_:now:) -> Session`
  - `SessionManager.init(..., closedLidClock: Bool = true, ...)`; `func lidClosedClock() async`, `func lidOpenedClock() async`, `func renewLeaseIfPaused() async` (internal; LidActions and tests call them)
- Consumed later: Task 9 (`controlItems` gets `lidRemaining:` and `lidPaused:`), Task 10 (presentation and the Awake hold read `session.isPaused` / `closedLidRemaining`).

**Rules:**
- Start with the lid open (or unknown): `newPausedSession` — `pausedRemaining = clamp(duration)`, `endsAt = now + pauseLease`. Start with the lid closed: today's `newSession`.
- Lid closes: `resumed` — `endsAt = now + pausedRemaining`, `pausedRemaining = nil`; arm the deadline; stop the lease timer.
- Lid opens: `paused` — `pausedRemaining = max(0, endsAt - now)`, `endsAt = now + pauseLease`; start the lease timer (every 60 s: `leaseRenewed`, save, re-arm).
- The deadline timer, when it fires on a paused session, renews the lease instead of ending it.
- Extend while paused adds to `pausedRemaining`, capped at `maxDuration` (24 h of closed time). Extend while running keeps today's rule.
- Reconcile, for a valid session: lid closed and paused -> `resumed`; lid open and running -> `paused`; paused -> start the lease timer.
- Every write goes through `exclusive` and `store.saveSession`, like `performExtend` (arm the backstop first).
- The countdown text and the "5 minutes left" reminder use `closedLidRemaining`; the reminder is only scheduled while running (the lid is closed then, so it rarely shows; that is fine).
- `closedLidClock: false` keeps Insomnia's wall-clock behaviour exactly; `Harness.makeManager` passes `false` by default so the existing tests keep their meaning, and the new tests pass `true`. (This flag is also where a later "separate screen and lid" setting would plug in.)

- [ ] **Step 1: Write the failing tests**

`Tests/InsomniaTests/ClosedLidClockTests.swift`:
```swift
import XCTest
@testable import Insomnia

@MainActor
final class ClosedLidClockTests: XCTestCase {
    private var h: Harness!

    override func setUp() async throws {
        h = Harness()
    }

    func testStartWithTheLidOpenIsPausedWithALease() async throws {
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 3600)
        let s = try XCTUnwrap(m.session)
        XCTAssertEqual(s.pausedRemaining, 3600)
        XCTAssertEqual(s.endsAt, h.clock.now.addingTimeInterval(SessionMath.pauseLease))
        XCTAssertEqual(try h.store.loadSession(), s, "the paused state is on disk")
    }

    func testClosingTheLidStartsTheClockAndOpeningPausesIt() async throws {
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 3600)
        h.clamshell.closed = true
        await m.lidClosedClock()
        XCTAssertNil(m.session?.pausedRemaining)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(3600))
        h.clock.advance(600)
        h.clamshell.closed = false
        await m.lidOpenedClock()
        XCTAssertEqual(m.session?.pausedRemaining, 3000)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(SessionMath.pauseLease))
    }

    func testAPausedSessionIsNeverEndedByTheClock() async throws {
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 3600)
        for _ in 0..<10 {
            h.clock.advance(60)
            await m.renewLeaseIfPaused()
        }
        XCTAssertNotNil(m.session)
        XCTAssertEqual(m.session?.pausedRemaining, 3600, "open-lid time does not count")
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(SessionMath.pauseLease))
    }

    func testExtendWhilePausedAddsClosedTimeUpTo24Hours() async throws {
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 23 * 3600)
        await m.extend(by: 3600)
        XCTAssertEqual(m.session?.pausedRemaining, 24 * 3600)
        await m.extend(by: 3600)
        XCTAssertEqual(m.session?.pausedRemaining, 24 * 3600, "capped at 24 h of closed time")
    }

    func testReconcileResumesAPausedSessionWhenTheLidIsClosed() async throws {
        var s = Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(SessionMath.pauseLease))
        s.pausedRemaining = 1800
        try h.store.saveSession(s)
        var state = RuntimeState.clean
        state.sleepDisabledByUs = true
        try h.store.saveState(state)
        h.guardFake.sleepDisabled = true
        h.clamshell.closed = true
        let m = h.makeManager(closedLidClock: true)
        await m.reconcile()
        XCTAssertNil(m.session?.pausedRemaining)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(1800))
    }

    func testWallClockModeIsUnchanged() async throws {
        h.clamshell.closed = false
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertNil(m.session?.pausedRemaining)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(3600))
    }
}
```
`StoreTests.swift`: decode `{"startedAt":"2026-10-14T10:00:00Z","endsAt":"2026-10-14T12:00:00Z","extensions":[]}` and assert `pausedRemaining == nil`.
`RecoveryScriptTests.swift`: next to `testValidFutureSessionIsNoOpWithoutForce`, a session file written with an extra `"pausedRemaining": 1800` and `endsAt` 4 minutes ahead is left alone (status 0, no `sudo` call; if Task 13 has landed, set pgrep mode `0` and expect only the pgrep call).
(Task 11 changes reconcile to read `isSleepDisabled` instead of re-running `disablesleep 1`; this task lands first, so `testReconcileResumesAPausedSessionWhenTheLidIsClosed` sets `h.guardFake.sleepDisabled = true` and works either way.)

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests`
Expected: compile errors (`pausedRemaining`, `closedLidClock:`, `lidClosedClock`).

- [ ] **Step 3: Session and SessionMath**

`Session.swift`, add:
```swift
    /// Closed-lid seconds left while the lid is open (spec "Lid mode"): the
    /// timer counts only closed-lid time. nil while the clock runs. While
    /// set, `endsAt` is a short lease (`SessionMath.pauseLease`) the app
    /// renews, so recovery still finds a deadline if the app dies.
    var pausedRemaining: TimeInterval?

    var isPaused: Bool { pausedRemaining != nil }

    /// Closed-lid time left: the paused amount, or the time to `endsAt`.
    func closedLidRemaining(at now: Date) -> TimeInterval {
        pausedRemaining ?? remaining(at: now)
    }
```
and an `init` parameter `pausedRemaining: TimeInterval? = nil`. Synthesized `Codable` decodes a missing key as nil for an `Optional`; keep it synthesized.

`SessionMath.swift`, add:
```swift
    /// How far ahead a paused session's `endsAt` lease reaches. Renewed
    /// every minute while the app runs; if the app dies the session expires
    /// within this window and the recovery agent restores sleep.
    static let pauseLease: TimeInterval = 300

    static func newPausedSession(now: Date, duration: TimeInterval, maxDuration: TimeInterval) -> Session {
        Session(startedAt: now, endsAt: now.addingTimeInterval(pauseLease), pausedRemaining: clamp(duration, maxDuration: maxDuration))
    }

    /// Lid opened: stop the clock and keep what was left.
    static func paused(_ s: Session, now: Date) -> Session {
        guard !s.isPaused else { return s }
        var p = s
        p.pausedRemaining = s.remaining(at: now)
        p.endsAt = now.addingTimeInterval(pauseLease)
        return p
    }

    /// Lid closed: run the clock on what was left.
    static func resumed(_ s: Session, now: Date) -> Session {
        guard let left = s.pausedRemaining else { return s }
        var r = s
        r.pausedRemaining = nil
        r.endsAt = now.addingTimeInterval(left)
        return r
    }

    static func leaseRenewed(_ s: Session, now: Date) -> Session {
        guard s.isPaused else { return s }
        var r = s
        r.endsAt = now.addingTimeInterval(pauseLease)
        return r
    }
```
In `extended(_:by:now:maxDuration:)`, before the existing body:
```swift
        if let left = session.pausedRemaining {
            var s = session
            let newLeft = min(left + max(extra, 0), max(maxDuration, minimumDuration))
            s.extensions.append(newLeft - left)
            s.pausedRemaining = newLeft
            return s
        }
```

- [ ] **Step 4: SessionManager**

Add `@ObservationIgnored private let closedLidClock: Bool` (init parameter `closedLidClock: Bool = true`, assigned in init) and `@ObservationIgnored private var leaseTimer: Timer?`.

In `performStart`, where the session is built (`SessionMath.newSession(now:duration:maxDuration:)`, around `:1195`):
```swift
        let new = closedLidClock && clamshell() != true
            ? SessionMath.newPausedSession(now: now, duration: duration, maxDuration: config.maxDuration)
            : SessionMath.newSession(now: now, duration: duration, maxDuration: config.maxDuration)
```
and after the session is confirmed (where `armDeadline` is called), `syncLeaseTimer()`.

In `armDeadline`, the timer callback becomes:
```swift
            Task { @MainActor in
                guard let self, let s = self.session, s.isExpired(at: self.clock()) else { return }
                if s.isPaused {
                    await self.renewLeaseIfPaused()
                } else {
                    await self.end(reason: .timer)
                }
            }
```
Add:
```swift
    /// Lid closed: the closed-lid clock runs (spec "Lid mode").
    func lidClosedClock() async {
        await moveClock("lid closed") { SessionMath.resumed($0, now: $1) }
    }

    /// Lid opened: the clock pauses on what is left.
    func lidOpenedClock() async {
        await moveClock("lid opened") { SessionMath.paused($0, now: $1) }
    }

    /// Keeps a paused session's lease ahead of now. The lease timer calls it.
    func renewLeaseIfPaused() async {
        await moveClock("lease") { SessionMath.leaseRenewed($0, now: $1) }
    }

    private func moveClock(_ why: String, _ change: @escaping @MainActor (Session, Date) -> Session) async {
        guard closedLidClock, session != nil else { return }
        let ticket = endTicket
        _ = await exclusive("closed-lid clock (\(why))") {
            guard let current = self.session, self.endTicket == ticket else { return }
            let updated = change(current, self.clock())
            guard updated != current else { return }
            do {
                try await self.backstop.arm()
                try self.store.saveSession(updated)
            } catch {
                self.fail("could not update the lid timer: \(error.localizedDescription)")
                return
            }
            self.session = updated
            await self.armDeadline(updated.endsAt)
            self.syncLeaseTimer()
        }
    }

    /// A 60 s lease renewal while paused; none while the clock runs.
    private func syncLeaseTimer() {
        guard session?.isPaused == true else {
            leaseTimer?.invalidate()
            leaseTimer = nil
            return
        }
        guard leaseTimer == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.renewLeaseIfPaused() }
        }
        RunLoop.main.add(t, forMode: .common)
        leaseTimer = t
    }
```
(`exclusive`'s closure signature is `@escaping @MainActor @Sendable () async -> T`; adapt the closure if the compiler needs explicit `self` captures or a `[weak self]`.) In `stopTimers()` also invalidate and nil `leaseTimer`. In `refreshCountdown()` replace `s.remaining(at:)` with `s.closedLidRemaining(at:)`. In `performExtend` call `syncLeaseTimer()` after `armDeadline`.

Reconcile, after the session is kept as valid (after the sleep check): 
```swift
            if closedLidClock {
                let lid = clamshell()
                let now = clock()
                let adjusted = lid == true ? SessionMath.resumed(s, now: now) : (lid == false ? SessionMath.paused(s, now: now) : s)
                if adjusted != s {
                    do {
                        try store.saveSession(adjusted)
                        session = adjusted
                    } catch {
                        Log.error("reconcile: could not update the lid timer: \(error.localizedDescription)")
                    }
                }
            }
```
placed before the deadline is armed for the session, followed by `syncLeaseTimer()` after it.

`LidActions.swift`: right after `manager.pauseCountdown()` (`:133`) add `await manager.lidClosedClock()`; right after `manager.resumeCountdown()` (`:145`) add `await manager.lidOpenedClock()`.

`TestSupport.swift`: `Harness.makeManager` gains `closedLidClock: Bool = false` and passes it to `SessionManager`.

- [ ] **Step 5: Run**

Run: `swift test --filter 'ClosedLidClockTests|StoreTests|SessionMathTests|ReconcileTests|LidActionsTests|ClosedLidSleepTests'` and the new RecoveryScriptTests case by name.
Expected: PASS. Then the fast set and `swift build -c release -Xswiftc -warnings-as-errors`.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Lid timer counts closed-lid time only; paused sessions keep a renewed lease

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Awake mode (assertion + controller)

Decision 3 applies (the controller exposes `lidSessionChanged(active:lidOpen:)`; Task 10 calls it on every session change).

**Files:**
- Create: `Sources/Insomnia/System/AwakeAssertion.swift`, `Sources/Insomnia/Core/AwakeController.swift`
- Modify: `Tests/InsomniaTests/TestSupport.swift` (add `FakeAwakeAssertion`)
- Test: `Tests/InsomniaTests/AwakeControllerTests.swift`

**Interfaces:**
- Produces:
  - `protocol AwakeAsserting: Sendable { var isHeld: Bool { get }; func hold() throws; func release() }`
  - `final class IOPMAwakeAssertion: AwakeAsserting, @unchecked Sendable`
  - `@MainActor @Observable final class AwakeController` with `enum State: Equatable { case off; case on(until: Date?) }`, `private(set) var state: State`, `private(set) var lastError: String?`, `var isOn: Bool`, `var endsAt: Date?`, `@ObservationIgnored var onChange: (@MainActor (State) -> Void)?`, `init(assertion: any AwakeAsserting, clock: @escaping @Sendable () -> Date = { Date() })`, `func turnOn(for duration: TimeInterval?)`, `func turnOff(reason: String)`, `func toggle()`, `func expireIfDue()`, `private(set) var lidHoldActive: Bool`, `func lidSessionChanged(active: Bool, lidOpen: Bool)`.

- [ ] **Step 1: Add the fake**

Append to `TestSupport.swift`:
```swift
final class FakeAwakeAssertion: AwakeAsserting, @unchecked Sendable {
    private let lock = NSLock()
    private var _held = false
    private var _calls: [String] = []
    var failHold = false

    var calls: [String] { lock.withLock { _calls } }
    var isHeld: Bool { lock.withLock { _held } }

    func hold() throws {
        lock.withLock { _calls.append("hold") }
        if failHold { throw AwakeAssertionError(code: -1) }
        lock.withLock { _held = true }
    }

    func release() {
        lock.withLock {
            _calls.append("release")
            _held = false
        }
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/InsomniaTests/AwakeControllerTests.swift`:
```swift
import XCTest
@testable import Insomnia

@MainActor
final class AwakeControllerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testToggleHoldsThenReleases() {
        let a = FakeAwakeAssertion()
        let c = AwakeController(assertion: a, clock: { [t0] in t0 })
        c.toggle()
        XCTAssertEqual(c.state, .on(until: nil))
        XCTAssertTrue(a.isHeld)
        c.toggle()
        XCTAssertEqual(c.state, .off)
        XCTAssertEqual(a.calls, ["hold", "release"])
    }

    func testTimedModeEndsWhenDue() {
        let a = FakeAwakeAssertion()
        let clock = FakeClock(t0)
        let c = AwakeController(assertion: a, clock: { clock.now })
        c.turnOn(for: 3600)
        XCTAssertEqual(c.endsAt, t0.addingTimeInterval(3600))
        clock.advance(3599)
        c.expireIfDue()
        XCTAssertTrue(c.isOn)
        clock.advance(1)
        c.expireIfDue()
        XCTAssertEqual(c.state, .off)
        XCTAssertFalse(a.isHeld)
    }

    func testHoldFailureStaysOffAndSaysWhy() {
        let a = FakeAwakeAssertion()
        a.failHold = true
        let c = AwakeController(assertion: a, clock: { [t0] in t0 })
        c.turnOn(for: nil)
        XCTAssertEqual(c.state, .off)
        XCTAssertNotNil(c.lastError)
    }

    func testLidSessionFoldsAwakeModeIn() {
        let a = FakeAwakeAssertion()
        let c = AwakeController(assertion: a, clock: { [t0] in t0 })
        var seen: [AwakeController.State] = []
        c.onChange = { seen.append($0) }
        c.turnOn(for: nil)
        c.lidSessionChanged(active: true, lidOpen: true)
        XCTAssertEqual(c.state, .off, "screen mode is part of lid mode now")
        XCTAssertTrue(c.lidHoldActive)
        XCTAssertTrue(a.isHeld, "the screen stays on while the lid is open")
        XCTAssertEqual(seen, [.on(until: nil), .off])
    }

    func testLidSessionHoldsOnlyWhileTheLidIsOpen() {
        let a = FakeAwakeAssertion()
        let c = AwakeController(assertion: a, clock: { [t0] in t0 })
        c.lidSessionChanged(active: true, lidOpen: true)
        XCTAssertTrue(a.isHeld)
        c.lidSessionChanged(active: true, lidOpen: false)
        XCTAssertFalse(a.isHeld, "released so LidActions can sleep the panel")
        c.lidSessionChanged(active: true, lidOpen: true)
        XCTAssertTrue(a.isHeld)
        c.lidSessionChanged(active: false, lidOpen: true)
        XCTAssertFalse(a.isHeld, "nothing held once the lid session ends")
        XCTAssertFalse(c.lidHoldActive)
        XCTAssertEqual(c.state, .off)
    }

    func testTurningOnAgainReplacesTheDeadline() {
        let a = FakeAwakeAssertion()
        let c = AwakeController(assertion: a, clock: { [t0] in t0 })
        c.turnOn(for: 3600)
        c.turnOn(for: nil)
        XCTAssertEqual(c.state, .on(until: nil))
        XCTAssertEqual(a.calls, ["hold", "hold"], "hold is idempotent in the live assertion")
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift build --build-tests`
Expected: compile error, `AwakeController` / `AwakeAsserting` not found.

- [ ] **Step 4: Implement the assertion**

`Sources/Insomnia/System/AwakeAssertion.swift`:
```swift
import Foundation
import IOKit.pwr_mgt

/// Awake mode's hold on sleep (spec "Awake mode"): one IOPM assertion of
/// type PreventUserIdleDisplaySleep, which keeps the display and with it
/// the Mac awake while the lid is open. macOS releases an assertion when
/// its process exits, so a crash cleans up by itself: nothing is journaled.
protocol AwakeAsserting: Sendable {
    var isHeld: Bool { get }
    /// Takes the assertion; a second call while held does nothing.
    func hold() throws
    /// Releases it if held. A refused release is logged, never thrown:
    /// the process exit releases it anyway.
    func release()
}

struct AwakeAssertionError: Error, LocalizedError, Equatable {
    let code: IOReturn

    var errorDescription: String? {
        "IOPMAssertionCreateWithName returned \(String(format: "0x%08x", UInt32(bitPattern: code)))"
    }
}

final class IOPMAwakeAssertion: AwakeAsserting, @unchecked Sendable {
    /// The type string behind kIOPMAssertPreventUserIdleDisplaySleep, a
    /// CFSTR macro Swift does not import.
    static let type = "PreventUserIdleDisplaySleep" as CFString
    /// What `pmset -g assertions` shows for it.
    static let name = "Awake mode" as CFString

    private let lock = NSLock()
    private var id: IOPMAssertionID?

    var isHeld: Bool { lock.withLock { id != nil } }

    func hold() throws {
        try lock.withLock {
            guard id == nil else { return }
            var newID: IOPMAssertionID = 0
            let kr = IOPMAssertionCreateWithName(Self.type, IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.name, &newID)
            guard kr == kIOReturnSuccess else { throw AwakeAssertionError(code: kr) }
            id = newID
        }
    }

    func release() {
        lock.withLock {
            guard let current = id else { return }
            let kr = IOPMAssertionRelease(current)
            if kr != kIOReturnSuccess {
                Log.error("IOPMAssertionRelease returned \(String(format: "0x%08x", UInt32(bitPattern: kr)))")
            }
            id = nil
        }
    }
}
```

- [ ] **Step 5: Implement the controller**

`Sources/Insomnia/Core/AwakeController.swift`:
```swift
import Foundation
import Observation

/// Awake mode: the Caffeine-style hold, toggled by a left click (spec
/// "Interaction"). Independent of `SessionManager`: no journal, no root,
/// no recovery agent. Lid mode includes it (`lidSessionChanged`): during a
/// lid session the same assertion is held while the lid is open and
/// released while it is closed, because a held display assertion would
/// keep `LidActions` from sleeping the panel (`DisplayDimming.requestSleep`).
@MainActor
@Observable
final class AwakeController {
    enum State: Equatable {
        case off
        /// `until` is nil for "until I turn it off".
        case on(until: Date?)
    }

    private(set) var state: State = .off
    /// Why the last `turnOn` did not take; shown in the menu.
    private(set) var lastError: String?
    /// True while lid mode holds the screen on (lid session, lid open).
    private(set) var lidHoldActive = false

    var isOn: Bool { state != .off }
    var endsAt: Date? {
        if case let .on(until) = state { return until }
        return nil
    }

    /// Called after every state change, for the hotspot failover hookup.
    @ObservationIgnored var onChange: (@MainActor (State) -> Void)?

    @ObservationIgnored private let assertion: any AwakeAsserting
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var timer: Timer?

    init(assertion: any AwakeAsserting, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.assertion = assertion
        self.clock = clock
    }

    /// `duration` nil keeps the Mac awake until turned off.
    func turnOn(for duration: TimeInterval?) {
        do {
            try assertion.hold()
        } catch {
            lastError = "Could not keep the Mac awake: \(error.localizedDescription)"
            Log.error("awake mode: \(error.localizedDescription)")
            set(.off)
            return
        }
        lastError = nil
        let until = duration.map { clock().addingTimeInterval($0) }
        schedule(until)
        Log.info("awake mode on " + (until.map { "until \(ISO8601DateFormatter().string(from: $0))" } ?? "until turned off"))
        set(.on(until: until))
    }

    func turnOff(reason: String) {
        timer?.invalidate()
        timer = nil
        guard state != .off else { return }
        assertion.release()
        Log.info("awake mode off (\(reason))")
        set(.off)
    }

    func toggle() {
        isOn ? turnOff(reason: "user") : turnOn(for: nil)
    }

    /// The deadline timer's target; internal so tests drive it with a fake clock.
    func expireIfDue() {
        guard let endsAt, clock() >= endsAt else { return }
        turnOff(reason: "timer")
    }

    /// Screen mode inside a lid session (spec "Interaction"): a running
    /// Awake mode folds in when the session starts; the assertion is held
    /// while the lid is open and released while it is closed or once the
    /// session ends. Called on every session change; idempotent.
    func lidSessionChanged(active: Bool, lidOpen: Bool) {
        if active, state != .off {
            turnOff(reason: "folded into lid mode")
        }
        let want = active && lidOpen
        guard want != lidHoldActive else { return }
        if want {
            do {
                try assertion.hold()
                lidHoldActive = true
            } catch {
                lastError = "Could not keep the screen on: \(error.localizedDescription)"
                Log.error("lid-mode screen hold: \(error.localizedDescription)")
            }
        } else {
            assertion.release()
            lidHoldActive = false
        }
    }

    private func set(_ new: State) {
        guard new != state else { return }
        state = new
        onChange?(new)
    }

    private func schedule(_ until: Date?) {
        timer?.invalidate()
        timer = nil
        guard let until else { return }
        let t = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.expireIfDue() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
```
Note: `testTurningOnAgainReplacesTheDeadline` expects `set(.on(until: nil))` after `.on(until: deadline)`; `set` fires because the states differ.

- [ ] **Step 6: Run**

Run: `swift test --filter AwakeControllerTests`
Expected: 5 PASS.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "Awake mode: IOPM assertion and controller

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Menu bar icons

**Files:**
- Create: `Sources/Insomnia/UI/MenuBarIcon.swift`
- Test: `Tests/InsomniaTests/MenuBarIconTests.swift`

**Interfaces:**
- Produces: `enum MenuBarIcon: Equatable, CaseIterable { case off, awake, lid }`, `static let size: NSSize` (18×18), `@MainActor static func image(_ icon: MenuBarIcon) -> NSImage` (template), `static func draw(_ icon: MenuBarIcon)` (draws in a 24-unit, y-down space).

Shapes (24×24 viewBox, y down), from the approved mockup (private mockup):
- off: rounded rect x 4.2 y 4.8 w 15.6 h 11.2 r 1.6, stroke 1.7; base line 2.5→21.5 at y 19.2, stroke 1.7, round caps.
- awake: the same rect filled and stroked; same base line.
- lid (robot): head rounded rect x 6 y 7 w 12 h 8.6 r 2.6 stroke 1.7; antenna line (12, 7)→(12, 4.6) stroke 1.7; antenna dot circle (12, 3.9) r 1 fill; eyes circles (9.6, 11.3) and (14.4, 11.3) r 1.3 fill; closed lid line 2.5→21.5 at y 19.4, stroke 2.2, round caps.

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import XCTest
@testable import Insomnia

@MainActor
final class MenuBarIconTests: XCTestCase {
    func testEveryIconIsAnEighteenPointTemplate() {
        for icon in MenuBarIcon.allCases {
            let image = MenuBarIcon.image(icon)
            XCTAssertTrue(image.isTemplate, "\(icon)")
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18), "\(icon)")
            XCTAssertNotNil(image.accessibilityDescription, "\(icon)")
        }
    }

    func testIconsDrawSomethingAndDifferFromEachOther() {
        let renders = MenuBarIcon.allCases.map { Self.inkCount(MenuBarIcon.image($0)) }
        for (icon, ink) in zip(MenuBarIcon.allCases, renders) {
            XCTAssertGreaterThan(ink, 20, "\(icon) drew nothing")
        }
        XCTAssertGreaterThan(renders[1], renders[0], "awake (filled) has more ink than off (outline)")
        XCTAssertEqual(Set(MenuBarIcon.allCases.map { Self.png(MenuBarIcon.image($0)) }).count, 3)
    }

    /// Pixels with any alpha in a 36×36 render (2x).
    private static func inkCount(_ image: NSImage) -> Int {
        let rep = bitmap(image)
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                count += 1
            }
        }
        return count
    }

    private static func png(_ image: NSImage) -> Data {
        bitmap(image).representation(using: .png, properties: [:]) ?? Data()
    }

    private static func bitmap(_ image: NSImage) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests`
Expected: compile error, `MenuBarIcon` not found.

- [ ] **Step 3: Implement**

`Sources/Insomnia/UI/MenuBarIcon.swift`:
```swift
import AppKit

/// The three menu bar states (spec "Menu bar icon"), drawn in code as
/// template images so macOS tints them for light and dark bars. An outline
/// means off and a filled shape means on, as in Caffeine; lid mode is a
/// small robot on a closed lid.
enum MenuBarIcon: Equatable, CaseIterable {
    case off
    case awake
    case lid

    static let size = NSSize(width: 18, height: 18)
    /// Shapes are specified in a 24-unit square, y down, like the mockup's SVG.
    private static let units: CGFloat = 24

    @MainActor
    static func image(_ icon: MenuBarIcon) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.scale(by: rect.width / units)
            t.concat()
            draw(icon)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = switch icon {
        case .off: "Awake: off"
        case .awake: "Awake: keeping the Mac awake"
        case .lid: "Awake: running with the lid closed"
        }
        return image
    }

    /// Draws into the current context in 24-unit, y-down coordinates.
    static func draw(_ icon: MenuBarIcon) {
        NSColor.black.set()
        switch icon {
        case .off:
            stroke(NSBezierPath(roundedRect: NSRect(x: 4.2, y: 4.8, width: 15.6, height: 11.2), xRadius: 1.6, yRadius: 1.6), width: 1.7)
            line(from: NSPoint(x: 2.5, y: 19.2), to: NSPoint(x: 21.5, y: 19.2), width: 1.7)
        case .awake:
            let screen = NSBezierPath(roundedRect: NSRect(x: 4.2, y: 4.8, width: 15.6, height: 11.2), xRadius: 1.6, yRadius: 1.6)
            screen.fill()
            stroke(screen, width: 1.7)
            line(from: NSPoint(x: 2.5, y: 19.2), to: NSPoint(x: 21.5, y: 19.2), width: 1.7)
        case .lid:
            stroke(NSBezierPath(roundedRect: NSRect(x: 6, y: 7, width: 12, height: 8.6), xRadius: 2.6, yRadius: 2.6), width: 1.7)
            line(from: NSPoint(x: 12, y: 7), to: NSPoint(x: 12, y: 4.6), width: 1.7)
            dot(NSPoint(x: 12, y: 3.9), radius: 1)
            dot(NSPoint(x: 9.6, y: 11.3), radius: 1.3)
            dot(NSPoint(x: 14.4, y: 11.3), radius: 1.3)
            line(from: NSPoint(x: 2.5, y: 19.4), to: NSPoint(x: 21.5, y: 19.4), width: 2.2)
        }
    }

    private static func stroke(_ path: NSBezierPath, width: CGFloat) {
        path.lineWidth = width
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func line(from a: NSPoint, to b: NSPoint, width: CGFloat) {
        let p = NSBezierPath()
        p.move(to: a)
        p.line(to: b)
        p.lineWidth = width
        p.lineCapStyle = .round
        p.stroke()
    }

    private static func dot(_ center: NSPoint, radius: CGFloat) {
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
    }
}
```

- [ ] **Step 4: Run**

Run: `swift test --filter MenuBarIconTests`
Expected: 2 PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Menu bar icons: off, awake, robot on a closed lid

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Menu model: Awake and lid controls in StatusMenu

**Files:**
- Create: `Sources/Insomnia/UI/Countdown.swift`
- Modify: `Sources/Insomnia/UI/StatusMenu.swift` (Item.Kind cases, `controlItems`, `items(controls:thermal:...)`, `menu(...)` submenus and new selectors), `Sources/Insomnia/UI/StatusSource.swift` (`StatusLines.thermal`)
- Test: `Tests/InsomniaTests/MenuBarTests.swift`

**Interfaces:**
- Produces:
  - `enum Countdown { static func short(_ remaining: TimeInterval) -> String }` (`"1:42"`, `"0:05"`, never negative, rounds minutes up)
  - `StatusMenu.Item.Kind` new cases: `toggleAwake(isOn: Bool)`, `awakeFor(TimeInterval?)`, `startLid(TimeInterval?)` (nil = Custom…), `extendLid(TimeInterval)`, `endLid`, `submenu([Item])`
  - `static let awakeDurations: [TimeInterval?] = [nil, 3600, 7200, 14400]`, `static let lidDurations: [TimeInterval] = [3600, 7200, 14400, 28800]`
  - `static func controlItems(awakeOn: Bool, awakeEndsAt: Date?, lidRemaining: TimeInterval?, lidPaused: Bool, now: Date) -> [Item]` (`lidRemaining` is closed-lid time left, from `Session.closedLidRemaining`, Task 6b)
  - `items(controls: [Item] = [], thermal: String? = nil, …existing parameters…)`
  - `menu(_:target:settings:quit:relaunchBrowser:stopWaitingForOutput:toggleAwake:awakeFor:startLid:extendLid:endLid:)` with the five new selectors defaulting to `nil`
  - `StatusLines.thermal(_ state: ProcessInfo.ThermalState) -> String`

- [ ] **Step 1: Write the failing tests**

`Tests/InsomniaTests/MenuBarTests.swift`:
```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests`
Expected: compile errors for the new API.

- [ ] **Step 3: Implement Countdown**

`Sources/Insomnia/UI/Countdown.swift`:
```swift
import Foundation

/// The `h:mm` countdown shown next to the menu bar icon and in the menu.
/// Minutes round up, so "0:00" appears only when the time is up.
enum Countdown {
    static func short(_ remaining: TimeInterval) -> String {
        let minutes = max(0, Int((remaining / 60).rounded(.up)))
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
```

- [ ] **Step 4: Extend StatusMenu**

In `StatusMenu.Item.Kind`, add (keep the existing cases):
```swift
            /// Left-click's action from the menu: Awake mode on or off.
            case toggleAwake(isOn: Bool)
            /// Turn Awake mode on for this long; nil is "until I turn it off".
            case awakeFor(TimeInterval?)
            /// Start a lid session for this long; nil asks for a custom duration.
            case startLid(TimeInterval?)
            case extendLid(TimeInterval)
            case endLid
            case submenu([Item])
```
Add:
```swift
    static let awakeDurations: [TimeInterval?] = [nil, 3600, 7200, 14400]
    static let lidDurations: [TimeInterval] = [3600, 7200, 14400, 28800]

    /// The controls above the status block (spec "Interaction"). During a
    /// lid session only its own controls show: Awake mode is off then.
    static func controlItems(awakeOn: Bool, awakeEndsAt: Date?, lidRemaining: TimeInterval?, lidPaused: Bool, now: Date) -> [Item] {
        if let lid = lidRemaining {
            let left = "Lid closed mode \u{00B7} \(Countdown.short(lid)) left"
            return [
                Item(title: lidPaused ? left + " \u{00B7} paused while the lid is open" : left, kind: .info),
                Item(title: "Add 1 hour", kind: .extendLid(3600)),
                Item(title: "End now", kind: .endLid),
            ]
        }
        var toggle = "Keep awake"
        if awakeOn, let end = awakeEndsAt {
            toggle += " \u{00B7} \(Countdown.short(end.timeIntervalSince(now))) left"
        }
        let awake = awakeDurations.map { Item(title: durationTitle($0), kind: .awakeFor($0)) }
        let lid = lidDurations.map { Item(title: durationTitle($0), kind: .startLid($0)) }
            + [Item(title: "Custom\u{2026}", kind: .startLid(nil))]
        return [
            Item(title: toggle, kind: .toggleAwake(isOn: awakeOn)),
            Item(title: "Keep awake for", kind: .submenu(awake)),
            Item(title: "Keep awake with lid closed", kind: .submenu(lid)),
        ]
    }

    static func durationTitle(_ duration: TimeInterval?) -> String {
        guard let duration else { return "Until I turn it off" }
        let hours = Int(duration / 3600)
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }
```
Change `items(...)` to take two new leading parameters and use them:
```swift
    static func items(
        controls: [Item] = [],
        thermal: String? = nil,
        sessionActive: Bool,
        // …the existing parameters, unchanged…
    ) -> [Item] {
        var out: [Item] = controls
        if !controls.isEmpty {
            out.append(Item(title: "", kind: .separator))
        }
        let statusStart = out.count
        // existing body, appending to `out` as before; after the machine line:
        //     if let thermal = present(thermal) { out.append(Item(title: thermal, kind: .info)) }
        // and the final separator condition becomes:
        if out.count > statusStart {
            out.append(Item(title: "", kind: .separator))
        }
        out.append(Item(title: settingsTitle, kind: .settings))
        out.append(Item(title: quitTitle, kind: .quit))
        return out
    }
```
(Place the thermal line immediately after the `machine` line.)

Change `menu(...)`: add the five selectors with defaults, and move the loop into a recursive helper so submenus get the same selectors:
```swift
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
        let lineFont = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        for item in items {
            switch item.kind {
            // .separator, .info, .warning, .settings, .quit, .relaunchBrowser,
            // .stopWaitingForOutput: the existing code, reading `s.settings` etc.
            case let .toggleAwake(isOn):
                let entry = optionalAction(item.title, s.toggleAwake, target)
                entry.state = isOn ? .on : .off
                menu.addItem(entry)
            case let .awakeFor(duration):
                let entry = optionalAction(item.title, s.awakeFor, target)
                entry.representedObject = duration.map { NSNumber(value: $0) }
                menu.addItem(entry)
            case let .startLid(duration):
                let entry = optionalAction(item.title, s.startLid, target)
                entry.representedObject = duration.map { NSNumber(value: $0) }
                menu.addItem(entry)
            case let .extendLid(duration):
                let entry = optionalAction(item.title, s.extendLid, target)
                entry.representedObject = NSNumber(value: duration)
                menu.addItem(entry)
            case .endLid:
                menu.addItem(optionalAction(item.title, s.endLid, target))
            case let .submenu(children):
                let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                entry.submenu = build(children, target: target, selectors: s)
                menu.addItem(entry)
            }
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
```

In `StatusSource.swift`, add to `StatusLines`:
```swift
    /// The thermal state as the menu shows it (spec "Interaction").
    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Temperature: normal"
        case .fair: "Temperature: warm"
        case .serious: "Temperature: hot"
        case .critical: "Temperature: critical"
        @unknown default: "Temperature: unknown"
        }
    }
```

- [ ] **Step 5: Run**

Run: `swift test --filter 'CountdownTests|StatusMenuControlTests|StatusMenuWarningTests'`
Expected: PASS (existing `StatusMenuWarningTests` still pass: their calls use the defaults).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Menu model: Awake and lid controls, submenus, thermal line

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: New status item controller; delete the pill UI; wire Awake mode

Decisions 3 and 9 apply. Insomnia's "item expands by itself while typing" bug lived in the pill UI and `KeyCatcherPanel` (which takes the keyboard while the pills are open); this task deletes that whole mechanism, and the new item never takes key focus.

**Files:**
- Rewrite: `Sources/Insomnia/UI/StatusItemController.swift`
- Modify: `Sources/Insomnia/InsomniaApp.swift:18-116`
- Delete: `StatusRootView.swift`, `MenuBarModel.swift`, `DurationInput.swift`, `PillView.swift`, `HoldToEndButton.swift`, `Motion.swift`, `EyeMark.swift`, `KeyCatcherPanel.swift`, `StatusWidthWriter.swift`
- Delete tests: `UIStatusTests.swift`, `UIStartupTests.swift`, `DurationInputTests.swift`; the `Motion`/`EyeMark` parts of `BrandingTests.swift` (`:229-474`, keep the geometry and icon tests); the tests that build `StatusItemController`/`MenuBarModel` in `IntegrationWiringTests.swift:153`, `LidActionsTests.swift:1128,2472,2537`, `LidSimulationTests.swift:97` (rewrite the last to call `StatusMenu.items` directly if it only checks the simulation marker)
- Test: `Tests/InsomniaTests/MenuBarTests.swift` (add `StatusItemControllerLogicTests`)

**Interfaces:**
- Consumes: `AwakeController` (Task 7), `MenuBarIcon` (Task 8), `StatusMenu.controlItems`/`items`/`menu`, `Countdown`, `StatusLines.thermal` (Task 9), `DurationParser` (Task 6), `Config.lidMaxDuration` (Task 6), `SessionManager.start(duration:)`, `extend(by:)`, `end(reason:)`, `session`, `isActive`.
- Produces: `StatusItemController.init(manager:status:awake:showSettings:confirmRelaunch:clock:)`, `struct Presentation: Equatable { let icon: MenuBarIcon; let title: String }`, `static func presentation(lidRemaining: TimeInterval?, awake: AwakeController.State, now: Date) -> Presentation`, `enum ClickAction: Equatable { case toggleAwake, showMenu }`, `static func clickAction(isRightClick: Bool, controlHeld: Bool, lidActive: Bool) -> ClickAction`, `AppDelegate.awake: AwakeController`.

- [ ] **Step 1: Write the failing logic tests**

Append to `MenuBarTests.swift`:
```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests`
Expected: compile errors (new init, `presentation`, `clickAction`, `stateChanged`).

- [ ] **Step 3: Rewrite the controller**

Replace `Sources/Insomnia/UI/StatusItemController.swift` entirely:
```swift
import AppKit
import Observation

/// The menu bar item (spec "Interaction"): a fixed template icon, a
/// countdown when something is timed, left-click toggles Awake mode,
/// right-click (or any click during a lid session) opens the menu. A plain
/// NSStatusItem with no hosted view and no key window: nothing here takes
/// the keyboard, and the item's width changes only when the countdown
/// appears or goes.
@MainActor
final class StatusItemController: NSObject {
    struct Presentation: Equatable {
        let icon: MenuBarIcon
        let title: String
    }

    enum ClickAction: Equatable {
        case toggleAwake
        case showMenu
    }

    static let autosaveName = "awake.status"

    let manager: SessionManager
    let status: any StatusSource
    let awake: AwakeController
    let reminder = ReminderScheduler()
    private let showSettings: () -> Void
    private let confirmRelaunch: @MainActor (String) -> Bool
    private let clock: @Sendable () -> Date
    private let statusItem: NSStatusItem
    private var tick: Timer?

    init(
        manager: SessionManager,
        status: any StatusSource,
        awake: AwakeController,
        showSettings: @escaping () -> Void,
        confirmRelaunch: (@MainActor (String) -> Bool)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.manager = manager
        self.status = status
        self.awake = awake
        self.showSettings = showSettings
        self.confirmRelaunch = confirmRelaunch ?? Self.askBeforeRelaunch
        self.clock = clock
        Self.seedPreferredPositionIfNeeded()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.autosaveName
        statusItem.behavior = [.terminationOnRemoval]
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        observe()
        refresh()
    }

    /// New items land at the left of the group, which on a crowded notch
    /// bar is the hidden overflow; seed a spot near the right end once.
    static func seedPreferredPositionIfNeeded(defaults: UserDefaults = .standard) {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(40, forKey: key)
    }

    static func presentation(lidRemaining: TimeInterval?, awake: AwakeController.State, now: Date) -> Presentation {
        if let lid = lidRemaining {
            return Presentation(icon: .lid, title: Countdown.short(lid))
        }
        switch awake {
        case .off:
            return Presentation(icon: .off, title: "")
        case let .on(until):
            return Presentation(icon: .awake, title: until.map { Countdown.short($0.timeIntervalSince(now)) } ?? "")
        }
    }

    static func clickAction(isRightClick: Bool, controlHeld: Bool, lidActive: Bool) -> ClickAction {
        isRightClick || controlHeld || lidActive ? .showMenu : .toggleAwake
    }

    // MARK: State

    private func observe() {
        withObservationTracking {
            _ = manager.session
            _ = awake.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.stateChanged()
                self.observe()
            }
        }
    }

    /// Internal so tests can run it without waiting for observation.
    func stateChanged() {
        // A paused session is a lid session with the lid open (Task 6b).
        awake.lidSessionChanged(active: manager.isActive, lidOpen: manager.session?.isPaused ?? false)
        // "5 minutes left" only while the closed-lid clock runs.
        reminder.sync(endsAt: manager.session?.isPaused == false ? manager.session?.endsAt : nil)
        refresh()
    }

    private func refresh() {
        let now = clock()
        let p = Self.presentation(lidRemaining: manager.session?.closedLidRemaining(at: now), awake: awake.state, now: now)
        if let button = statusItem.button {
            button.image = MenuBarIcon.image(p.icon)
            button.title = p.title
        }
        if p.title.isEmpty {
            tick?.invalidate()
            tick = nil
        } else if tick == nil {
            let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            tick = t
        }
    }

    // MARK: Clicks

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let action = Self.clickAction(
            isRightClick: event?.type == .rightMouseUp,
            controlHeld: event?.modifierFlags.contains(.control) ?? false,
            lidActive: manager.isActive
        )
        switch action {
        case .toggleAwake:
            awake.toggle()
            refresh()
        case .showMenu:
            showMenu()
        }
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        status.refreshInstant()
        status.refreshOnDemand()
        Task { await manager.recheckForeignSleep() }
        let menu = StatusMenu.menu(
            Self.menuItems(manager: manager, status: status, awake: awake, now: clock()),
            target: self,
            settings: #selector(menuOpenSettings),
            quit: #selector(menuQuit),
            relaunchBrowser: #selector(menuRelaunchBrowser(_:)),
            stopWaitingForOutput: #selector(menuStopWaitingForOutput(_:)),
            toggleAwake: #selector(menuToggleAwake(_:)),
            awakeFor: #selector(menuAwakeFor(_:)),
            startLid: #selector(menuStartLid(_:)),
            extendLid: #selector(menuExtendLid(_:)),
            endLid: #selector(menuEndLid(_:))
        )
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    static func menuItems(manager: SessionManager, status: any StatusSource, awake: AwakeController, now: Date) -> [StatusMenu.Item] {
        StatusMenu.items(
            controls: StatusMenu.controlItems(awakeOn: awake.isOn, awakeEndsAt: awake.endsAt, lidRemaining: manager.session?.closedLidRemaining(at: now),
                                              lidPaused: manager.session?.isPaused ?? false, now: now),
            thermal: StatusLines.thermal(ProcessInfo.processInfo.thermalState),
            sessionActive: manager.isActive,
            sleepHeld: manager.state.sleepDisabledByUs,
            machine: StatusLines.machine(
                lidClosed: status.lidClosed,
                watts: status.instantWatts(),
                wifiSSID: WiFiStatusName.display(
                    ssid: status.wifiSSID,
                    locationAuthorized: (status as? LiveStatusSource)?.locationPermission.isAuthorized ?? true
                ),
                batteryPercent: status.batteryPercent,
                isCharging: status.isCharging
            ),
            actions: StatusLines.actions(frozenCount: status.frozenCount, lastGap: status.lastGap),
            throttledBrowsers: status.throttledBrowsers,
            relaunchProblems: status.relaunchProblems,
            hotspotWarning: status.hotspotPasswordReport?.problem(for: manager.config.hotspotSSID)?.menuLine,
            error: awake.lastError ?? manager.lastError,
            commandRunning: manager.commandWarning,
            foreignSleep: manager.foreignSleepWarning,
            outputsWaiting: manager.outputsWaitingForRestore,
            lidSimulationBuild: LidSimulationBuild.isCompiledIn
        )
    }

    // MARK: Menu actions

    @objc private func menuToggleAwake(_ sender: NSMenuItem) {
        awake.toggle()
        refresh()
    }

    @objc private func menuAwakeFor(_ sender: NSMenuItem) {
        awake.turnOn(for: (sender.representedObject as? NSNumber)?.doubleValue)
        refresh()
    }

    @objc private func menuStartLid(_ sender: NSMenuItem) {
        let chosen = (sender.representedObject as? NSNumber)?.doubleValue ?? askCustomDuration()
        guard let chosen else { return }
        let duration = min(chosen, Config.lidMaxDuration)
        Task { @MainActor in
            await manager.start(duration: duration)
            refresh()
        }
    }

    @objc private func menuExtendLid(_ sender: NSMenuItem) {
        let extra = (sender.representedObject as? NSNumber)?.doubleValue ?? 3600
        Task { @MainActor in
            await manager.extend(by: extra)
            refresh()
        }
    }

    @objc private func menuEndLid(_ sender: NSMenuItem) {
        Task { @MainActor in
            _ = await manager.end(reason: .user)
            refresh()
        }
    }

    @objc private func menuOpenSettings() { showSettings() }

    @objc private func menuQuit() { NSApplication.shared.terminate(nil) }

    @objc private func menuStopWaitingForOutput(_ sender: NSMenuItem) {
        guard let waiting = sender.representedObject as? SavedAudioOutput else { return }
        Task { await manager.stopWaitingForOutput(waiting) }
    }

    // Keep `menuRelaunchBrowser(_:)`, `relaunchBrowser(_:)` and
    // `askBeforeRelaunch(_:)` exactly as they are in the old file
    // (StatusItemController.swift:700-727 before this rewrite).

    /// "Custom…": a duration typed as "90", "1h30m" or "2h" (DurationParser).
    /// Nil when cancelled or unreadable; capped at 24 hours.
    private func askCustomDuration() -> TimeInterval? {
        let alert = NSAlert()
        alert.messageText = "Keep awake with the lid closed for how long?"
        alert.informativeText = "For example 90m, 3h or 1h30m. The most is 24 hours."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "3h"
        alert.accessoryView = field
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let seconds = DurationParser.seconds(from: field.stringValue) else {
            Log.info("custom lid duration not understood: \(field.stringValue.count) characters")
            return nil
        }
        return min(seconds, Config.lidMaxDuration)
    }
}
```
Copy `menuRelaunchBrowser(_:)`, `relaunchBrowser(_:)` and `askBeforeRelaunch(_:)` verbatim from the old file before deleting it (`git show HEAD:Sources/Insomnia/UI/StatusItemController.swift | sed -n 695,730p`).

- [ ] **Step 4: Wire it in the app delegate**

In `Sources/Insomnia/InsomniaApp.swift`, add the property and construct it in `init`:
```swift
    let awake = AwakeController(assertion: IOPMAwakeAssertion())
```
and replace the controller construction in `applicationDidFinishLaunching`:
```swift
        statusItem = StatusItemController(manager: manager, status: status, awake: awake) { [weak settings] in
            settings?.show()
        }
```
In `applicationShouldTerminate`, before the `Task`, release Awake mode synchronously:
```swift
        awake.turnOff(reason: "quit")
```

- [ ] **Step 5: Delete the pill UI and its tests**

```bash
git rm Sources/Insomnia/UI/{StatusRootView,MenuBarModel,DurationInput,PillView,HoldToEndButton,Motion,EyeMark,KeyCatcherPanel,StatusWidthWriter}.swift
git rm Tests/InsomniaTests/{UIStatusTests,UIStartupTests,DurationInputTests}.swift
```
Then run `swift build --build-tests 2>&1 | grep error:`. For each error in a test file that names a deleted type (`MenuBarModel`, `StatusRootView`, `Motion`, `EyeMark`, `KeyCatcherPanel`, `StatusWidthWriter`, `DurationInput`), delete that test method: it tested the deleted UI. In `BrandingTests.swift` delete the `Motion` and `EyeMark` view tests (`:229-474`) and keep the geometry and icon-artwork tests. For an error in `Sources/`, fix the reference (for example `BrandPalette` users in deleted files simply go away).

- [ ] **Step 6: Run**

Run: `swift build -c release -Xswiftc -warnings-as-errors && swift test --filter 'StatusItemControllerLogicTests|StatusMenuControlTests|MenuBarIconTests|AwakeControllerTests|BrandingTests|IntegrationWiringTests|LidSimulationTests|StatusMenuWarningTests'`
Expected: PASS.

- [ ] **Step 7: Run the app once by hand**

```bash
scripts/build-app.sh --output /tmp/awake-dev && open /tmp/awake-dev/Awake.app
```
Expected: the off icon appears; left-click fills the screen; right-click shows "Keep awake / Keep awake for ▸ / Keep awake with lid closed ▸", a separator, the status lines, Settings…, Quit Awake. `pmset -g assertions | grep "Awake mode"` shows the assertion while on and not after turning it off. Do not start a lid session (the sudoers change lands in Task 12). Quit the app.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "Menu bar: plain status item, left-click Awake mode, NSMenu; delete the pill UI

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Password to start; quiet cancel; no prompt on relaunch

Decisions 2, 4 and 5 apply.

**Files:**
- Create: `Sources/Insomnia/Core/AdminPrompt.swift`
- Modify: `Sources/Insomnia/Core/SleepGuard.swift` (doc comment `:3-4`, `PmsetSleepGuard` init and `setSleepDisabled` `:69-103`), `Sources/Insomnia/Core/SessionManager.swift` (`EndReason` `:4-22`, `sleepsAClosedLid`, start catch `:1238-1250`, reconcile `:2635-2647`, `endTitle` `:3136`, end notification `:1486`)
- Modify: `Tests/InsomniaTests/TestSupport.swift` (`FakeSleepGuard.cancelDisable`, `FakeAdminRunner`)
- Test: `Tests/InsomniaTests/AdminPromptTests.swift`; update `SleepGuardReadBackTests.swift`, `PmsetParsingTests.swift:64`, and reconcile expectations in `ReconcileTests`, `ReconcileLidGatingTests`, `UIStartupTests` (deleted already), `RecoverySafetyTests`, `StillRunningCommandTests`, `UndoClearFailureTests`, `LidActionsTests:234`

**Interfaces:**
- Produces:
  - `protocol AdminCommandRunning: Sendable { func runAsAdministrator(_ command: String, prompt: String) async throws }`
  - `struct AdminPromptCancelledError: Error, LocalizedError, Equatable`
  - `struct OsascriptAdminRunner: AdminCommandRunning` with `static let osascript`, `static let timeout: TimeInterval = 300`, `init(osascript: String = Self.osascript, timeout: TimeInterval = Self.timeout, runner: CancellableCommand = CancellableCommand())`, `static func script(command:prompt:) -> String`
  - `PmsetSleepGuard.init(..., admin: any AdminCommandRunning = OsascriptAdminRunner())`, `static let disableSleepCommand = "/usr/bin/pmset -a disablesleep 1"`, `static let adminPrompt`
  - `EndReason.startCancelled`

- [ ] **Step 1: Write the runner tests**

`Tests/InsomniaTests/AdminPromptTests.swift`:
```swift
import XCTest
@testable import Insomnia

final class AdminPromptTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("admin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func fakeOsascript(exit status: Int, stderr: String) throws -> String {
        let url = dir.appendingPathComponent("osascript")
        try TestScripts.write("#!/bin/sh\necho \"$2\" > \"\(dir.path)/args\"\necho '\(stderr)' >&2\nexit \(status)\n", to: url)
        return url.path
    }

    func testScriptIsTheConstantCommandWithAdministratorPrivileges() {
        let s = OsascriptAdminRunner.script(command: PmsetSleepGuard.disableSleepCommand, prompt: PmsetSleepGuard.adminPrompt)
        XCTAssertEqual(s, "do shell script \"/usr/bin/pmset -a disablesleep 1\" with prompt \"\(PmsetSleepGuard.adminPrompt)\" with administrator privileges")
        XCTAssertFalse(PmsetSleepGuard.adminPrompt.contains("\""))
        XCTAssertFalse(PmsetSleepGuard.adminPrompt.contains("\\"))
    }

    func testSuccess() async throws {
        let runner = OsascriptAdminRunner(osascript: try fakeOsascript(exit: 0, stderr: ""))
        try await runner.runAsAdministrator("/usr/bin/true", prompt: "p")
        let args = try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8)
        XCTAssertTrue(args.contains("with administrator privileges"), args)
    }

    func testCancelIsItsOwnError() async throws {
        let runner = OsascriptAdminRunner(osascript: try fakeOsascript(exit: 1, stderr: "0:94: execution error: User canceled. (-128)"))
        do {
            try await runner.runAsAdministrator("/usr/bin/true", prompt: "p")
            XCTFail("expected a cancel")
        } catch is AdminPromptCancelledError {
        }
    }

    func testOtherFailureIsASleepGuardError() async throws {
        let runner = OsascriptAdminRunner(osascript: try fakeOsascript(exit: 1, stderr: "execution error: something else (-1)"))
        do {
            try await runner.runAsAdministrator("/usr/bin/true", prompt: "p")
            XCTFail("expected a failure")
        } catch let e as SleepGuardError {
            XCTAssertEqual(e.status, 1)
        }
    }

    func testTimeoutIsAFailureNotACancel() async throws {
        let url = dir.appendingPathComponent("osascript")
        try TestScripts.write("#!/bin/sh\nsleep 30\n", to: url)
        let runner = OsascriptAdminRunner(osascript: url.path, timeout: 0.5)
        do {
            try await runner.runAsAdministrator("/usr/bin/true", prompt: "p")
            XCTFail("expected a timeout")
        } catch is AdminPromptCancelledError {
            XCTFail("a timeout must not read as a cancel")
        } catch {
        }
    }
}
```

- [ ] **Step 2: Write the SessionManager tests**

Add to `TestSupport.swift`, in `FakeSleepGuard`:
```swift
    /// `disablesleep 1` answers like a cancelled administrator prompt.
    var cancelDisable = false
```
and in its `setSleepDisabled`, right after `try record(...)`:
```swift
        if disabled && cancelDisable { throw AdminPromptCancelledError() }
```
Add to `RecoverySafetyTests.swift` (it already has `h` and the start-failure tests at `:282`):
```swift
    func testCancelledPromptEndsTheStartQuietly() async throws {
        h.guardFake.cancelDisable = true
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertNil(m.session)
        XCTAssertNil(m.lastError, "a cancel is the person's choice, not an error")
        XCTAssertFalse(h.notifier.posts.contains { $0.title == "Session not started" }, "\(h.notifier.posts)")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertNil(try h.store.loadSession())
    }

    func testAdminTimeoutFailsTheStartAndRestoresSleep() async throws {
        h.guardFake.throwOn = ["disablesleep 1"]
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertNil(m.session)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(h.notifier.posts.last?.title, "Session not started")
    }
```
Add to `ReconcileTests.swift`:
```swift
    func testReconcileKeepsSessionWithoutPromptWhenSleepStillDisabled() async throws {
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(3600)))
        var state = RuntimeState.clean
        state.sleepDisabledByUs = true
        try h.store.saveState(state)
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertNotNil(m.session)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"), "\(h.guardFake.calls)")
    }

    func testReconcileEndsSessionWhenSleepWasTurnedBackOn() async throws {
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(3600)))
        var state = RuntimeState.clean
        state.sleepDisabledByUs = true
        try h.store.saveState(state)
        h.guardFake.sleepDisabled = false
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertNil(m.session)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"), "never prompt at launch: \(h.guardFake.calls)")
    }
```
(If `Session`'s memberwise init needs `extensions:`, pass `extensions: []`.)

- [ ] **Step 3: Run to verify failure**

Run: `swift build --build-tests`
Expected: compile errors (`AdminPromptCancelledError`, `OsascriptAdminRunner`, `PmsetSleepGuard.disableSleepCommand`).

- [ ] **Step 4: Implement AdminPrompt.swift**

```swift
import Foundation

/// Runs one fixed command as root through the macOS administrator prompt
/// (spec "Phase 1: password to start"). Only `disablesleep 1` goes this
/// way; everything that gives sleep back stays passwordless in sudoers.
protocol AdminCommandRunning: Sendable {
    func runAsAdministrator(_ command: String, prompt: String) async throws
}

/// The person closed the administrator prompt: their choice, not a failure.
struct AdminPromptCancelledError: Error, LocalizedError, Equatable {
    var errorDescription: String? { "The administrator prompt was cancelled" }
}

struct OsascriptAdminRunner: AdminCommandRunning {
    static let osascript = "/usr/bin/osascript"
    /// Long enough to read the prompt and type a password; the 20 s pmset
    /// limit would cut a person off mid-password.
    static let timeout: TimeInterval = 300

    let osascriptPath: String
    let commandTimeout: TimeInterval
    let runner: CancellableCommand

    init(osascript: String = Self.osascript, timeout: TimeInterval = Self.timeout, runner: CancellableCommand = CancellableCommand()) {
        osascriptPath = osascript
        commandTimeout = timeout
        self.runner = runner
    }

    /// `command` and `prompt` are constants with no quotes or backslashes
    /// (AdminPromptTests pins this): nothing user-provided reaches the script.
    static func script(command: String, prompt: String) -> String {
        "do shell script \"\(command)\" with prompt \"\(prompt)\" with administrator privileges"
    }

    func runAsAdministrator(_ command: String, prompt: String) async throws {
        let result = try await runner.run(
            osascriptPath,
            ["-e", Self.script(command: command, prompt: prompt)],
            timeout: commandTimeout,
            stop: .terminateThenKill,
            holding: RecoveryLock.held
        )
        if result.status == 0 { return }
        // AppleScript's "User canceled." is error -128.
        if result.stderr.contains("(-128)") { throw AdminPromptCancelledError() }
        throw SleepGuardError(command: "osascript: \(command)", status: result.status, stderr: result.stderr)
    }
}
```

- [ ] **Step 5: Route disablesleep 1 through it**

In `SleepGuard.swift`, update the protocol doc comment to "three sudoers-allowed pmset commands, plus `disablesleep 1` through the administrator prompt (`AdminCommandRunning`)". In `PmsetSleepGuard` add:
```swift
    static let disableSleepCommand = "/usr/bin/pmset -a disablesleep 1"
    static let adminPrompt = "Awake needs your password to keep this Mac running with the lid closed."

    let admin: any AdminCommandRunning
```
add `admin: any AdminCommandRunning = OsascriptAdminRunner()` as the last init parameter and assign it. Replace the start of `setSleepDisabled`:
```swift
    func setSleepDisabled(_ disabled: Bool) async throws {
        guard disabled else {
            try await sudoPmset(["-a", "disablesleep", "0"])
            return
        }
        guard RecoveryLock.held != nil else {
            throw SleepGuardError(command: "pmset -a disablesleep 1", status: -1, stderr: "not run: no recovery transaction holds the lock")
        }
        try await admin.runAsAdministrator(Self.disableSleepCommand, prompt: Self.adminPrompt)
        // …the existing settle wait and read-back, unchanged…
    }
```
Update `SleepGuardError`'s hint (`:23-25`) to "(run scripts/install.sh to install /etc/sudoers.d/awake)".

In `SleepGuardReadBackTests.swift` (`:45-62`), pass a fake admin that runs the fake pmset directly, so the read-back is still exercised:
```swift
struct FakeAdminRunner: AdminCommandRunning {
    let pmset: String
    func runAsAdministrator(_ command: String, prompt: String) async throws {
        let args = Array(command.split(separator: " ").dropFirst().map(String.init))
        let r = try await Shell.run(pmset, args, timeout: 5)
        guard r.status == 0 else { throw SleepGuardError(command: command, status: r.status, stderr: r.stderr) }
    }
}
```
(put it in `TestSupport.swift`) and change the expectation at `:76` from `"sudo -n <pmset> -a disablesleep 1"` to the fake pmset's own log of `-a disablesleep 1`. Update `PmsetParsingTests.swift:64` if it builds the "disablesleep 1" message through sudo.

- [ ] **Step 6: SessionManager: cancel, reconcile, notification**

`EndReason` gains:
```swift
    /// The person cancelled the administrator prompt at start. Undone like
    /// `startFailed`, but with no notification and no error line.
    case startCancelled
```
In `sleepsAClosedLid` (from Task 1) add `.startCancelled` to the `false` list. In `endTitle` add `case .startCancelled: "Lid mode not started"`. At the end notification (`:1486`):
```swift
        if reason != .startCancelled {
            notifier.post(title: Self.endTitle(reason, had: had), body: endBody(reason, waiting: waiting))
        }
```
In `performStart`, insert before the generic `catch` (`:1246`):
```swift
        } catch is AdminPromptCancelledError {
            Log.info("lid mode start cancelled at the administrator prompt")
            _ = await performEnd(reason: .startCancelled)
            return
```
In `performReconcile`, replace the `do { try await sleepGuard.setSleepDisabled(true) … }` block (`:2635-2647`) with:
```swift
            // Turning sleep off needs the administrator prompt, which a
            // launch must never raise (spec "Privileges"). Keep the session
            // only while sleep is still off from before.
            let stillHeld: Bool
            do {
                stillHeld = try await sleepGuard.isSleepDisabled()
            } catch {
                Log.error("reconcile: could not read SleepDisabled: \(error.localizedDescription)")
                stillHeld = false
            }
            guard stillHeld else {
                fail("Lid closed mode ended: sleep was turned back on while Awake was not running. Start it again from the menu.")
                _ = await performEnd(reason: .recoveryUnavailable)
                return
            }
            lastError = nil
```
Make sure `performEnd`'s `switch`es over `EndReason` (search `case .startFailed`) handle `.startCancelled` like `.startFailed` (for example the `had` and incomplete paths).

- [ ] **Step 7: Update reconcile expectations in existing tests**

Run: `swift test --filter 'ReconcileTests|ReconcileLidGatingTests|RecoverySafetyTests|StillRunningCommandTests|UndoClearFailureTests|LidActionsTests'`
For each failure caused by reconcile no longer calling `disablesleep 1`: if the test means "a valid session survives a relaunch", set `h.guardFake.sleepDisabled = true` before `reconcile()` and replace `"disablesleep 1"` in the expected call list with `"pmset -g"`; if the test means "re-applying failed", rewrite it to set `h.guardFake.sleepDisabled = false` and expect the session to end with `.recoveryUnavailable`. Tests about `CommandStillRunningError` during reconcile's `disablesleep 1` no longer apply: delete them.

- [ ] **Step 8: Run**

Run: `swift build -c release -Xswiftc -warnings-as-errors && swift test --filter 'AdminPromptTests|SleepGuardReadBackTests|PmsetParsingTests|RecoverySafetyTests|ReconcileTests|ReconcileLidGatingTests|StillRunningCommandTests|UndoClearFailureTests|LidActionsTests|ClosedLidSleepTests'`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "Lid mode: administrator prompt to start, quiet cancel, no prompt on relaunch

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Sudoers keeps only the three safe commands

**Files:**
- Modify: `scripts/install.sh:4-9,260-280,391-398` and the re-check under the lock (`:535-568`), `README.md:75-88`
- Test: `RecoveryScriptTests.swift:5617,5648` and the fake sudo's `-n -l` handling (`:6557-6660`)

**Interfaces:**
- Produces: sudoers file with exactly three `NOPASSWD` lines.

- [ ] **Step 1: Write the failing test**

```swift
    func testInstallWritesExactlyTheThreeSafeCommands() throws {
        let r = try fx.run(fx.install, [])
        XCTAssertEqual(r.status, 0, r.stdout + r.stderr)
        let rule = try fx.contents(of: fx.sudoers)
        XCTAssertTrue(rule.contains("NOPASSWD: /usr/bin/pmset -a disablesleep 0"), rule)
        XCTAssertTrue(rule.contains("NOPASSWD: /usr/bin/pmset -b lowpowermode 1"), rule)
        XCTAssertTrue(rule.contains("NOPASSWD: /usr/bin/pmset -b lowpowermode 0"), rule)
        XCTAssertFalse(rule.contains("disablesleep 1"), "turning sleep off must need the password: \(rule)")
        XCTAssertFalse(fx.calls().contains("sudo -n -l /usr/bin/pmset -a disablesleep 1"), "\(fx.calls())")
    }
```
Change the assertions at `:5617` and `:5648` from `"sudo -n -l /usr/bin/pmset -a disablesleep 1"` to `"sudo -n -l /usr/bin/pmset -a disablesleep 0"` (the first check in the new chain).

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter RecoveryScriptTests/testInstallWritesExactlyTheThreeSafeCommands`
Expected: FAIL (`disablesleep 1` present).

- [ ] **Step 3: Implement**

`scripts/install.sh` heredoc:
```bash
cat > "$TMP_SUDOERS" <<SUDO
# Installed by Awake install.sh. Three commands, none of which can keep the
# Mac awake: turning sleep off asks for the administrator password each time.
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0
SUDO
```
and:
```bash
pmset_rule_effective() {
  pmset_rule_check -a disablesleep 0 \
    && pmset_rule_check -b lowpowermode 1 \
    && pmset_rule_check -b lowpowermode 0
}
```
Update the comments at `:4-9` and `:260-264` ("the three pmset commands"). `README.md:75-88`: list the three lines and say starting lid mode asks for the password.

- [ ] **Step 4: Run**

Run: `swift test --filter 'RecoveryScriptTests/testInstall'` and `shellcheck --shell=bash scripts/install.sh`
Expected: PASS, no findings.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "sudoers: only disablesleep 0 and lowpowermode 0/1

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12b: Pilot light icons (user decision 2026-10-14)

The person picked the "Pilot light" family from the icon sketches (private mockup): no laptop, one flame. Off = the flame's outline (unlit), screen on = the flame filled, lid closed = a small low flame on the closed lid ("turned down, never out"). This replaces the shapes Task 8 drew; the `MenuBarIcon` API (`.off/.awake/.lid`, `image(_:)`, `draw(_:)`, 18 pt template) does not change, so nothing else moves.

**Files:**
- Modify: `Sources/Insomnia/UI/MenuBarIcon.swift` (the three `draw` cases, the type's doc comment)
- Test: `Tests/InsomniaTests/MenuBarIconTests.swift`

**Interfaces:** unchanged (`enum MenuBarIcon: Equatable, CaseIterable { case off, awake, lid }`, `static let size`, `@MainActor static func image(_:)`, `static func draw(_:)`).

Shapes (24×24 viewBox, y down). The flame path, in SVG terms:
`M12 2.6 C13.8 6 17.4 8.6 17.4 13.4 A5.4 5.4 0 0 1 6.6 13.4 C6.6 10.6 8.2 8.8 9.6 7.6 C9.8 9.6 10.6 10.8 11.6 11.4 C11 8.6 11.3 5.4 12 2.6 Z`
(the arc is the round bottom of the flame, through (12, 18.8)).
- off: the flame, stroked 1.7, round joins, not filled.
- awake: the flame, filled.
- lid: the flame filled, scaled 0.6 about its bottom point and moved so its bottom (y 18.8) sits at y 17.4; plus the closed-lid line from (2.5, 19.4) to (21.5, 19.4), width 2.2, round caps.

- [ ] **Step 1: Write the failing test**

Add to `MenuBarIconTests`:
```swift
    /// The flame's round bottom is drawn below its centre (the arc goes
    /// through y 18.8), and the lid icon's flame is small: ink near the
    /// top only for the full flame.
    func testPilotLightShapes() {
        let awake = Self.bitmap(MenuBarIcon.image(.awake))
        // 36 px render = 1.5 px per unit; bitmap y 0 is the top.
        XCTAssertGreaterThan(awake.colorAt(x: 18, y: 25)?.alphaComponent ?? 0, 0.5, "inside the flame's round bottom")
        XCTAssertGreaterThan(awake.colorAt(x: 18, y: 6)?.alphaComponent ?? 0, 0.3, "the full flame reaches near the top")
        let lid = Self.bitmap(MenuBarIcon.image(.lid))
        XCTAssertLessThan(lid.colorAt(x: 18, y: 6)?.alphaComponent ?? 1, 0.1, "the pilot flame is low")
        XCTAssertGreaterThan(lid.colorAt(x: 18, y: 29)?.alphaComponent ?? 0, 0.5, "the closed lid line")
        let off = Self.bitmap(MenuBarIcon.image(.off))
        XCTAssertLessThan(off.colorAt(x: 18, y: 19)?.alphaComponent ?? 1, 0.2, "off is an outline: its middle is empty")
    }
```
(`bitmap(_:)` already exists in the file as a private helper; make it `static` internal-to-the-class if needed.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter MenuBarIconTests/testPilotLightShapes`
Expected: FAIL (the laptop shapes have no ink at (18, 6) for awake, and the robot head reaches y 6).

- [ ] **Step 3: Implement**

In `MenuBarIcon.swift`, replace the doc comment's description with: "The three menu bar states, drawn in code as template images: a pilot light. Off is the flame's outline (unlit); screen on is the flame filled; lid closed is a small low flame on the closed lid: turned down, never out." Then:
```swift
    /// The flame, in 24-unit y-down coordinates: pointed top, round bottom
    /// through (12, 18.8).
    private static func flame() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 12, y: 2.6))
        p.curve(to: NSPoint(x: 17.4, y: 13.4), controlPoint1: NSPoint(x: 13.8, y: 6), controlPoint2: NSPoint(x: 17.4, y: 8.6))
        // Round bottom: from the right side, down through (12, 18.8), to the left side.
        p.appendArc(withCenter: NSPoint(x: 12, y: 13.4), radius: 5.4, startAngle: 0, endAngle: 180, clockwise: false)
        p.curve(to: NSPoint(x: 9.6, y: 7.6), controlPoint1: NSPoint(x: 6.6, y: 10.6), controlPoint2: NSPoint(x: 8.2, y: 8.8))
        p.curve(to: NSPoint(x: 11.6, y: 11.4), controlPoint1: NSPoint(x: 9.8, y: 9.6), controlPoint2: NSPoint(x: 10.6, y: 10.8))
        p.curve(to: NSPoint(x: 12, y: 2.6), controlPoint1: NSPoint(x: 11, y: 8.6), controlPoint2: NSPoint(x: 11.3, y: 5.4))
        p.close()
        return p
    }
```
and the `draw` cases:
```swift
        case .off:
            stroke(flame(), width: 1.7)
        case .awake:
            flame().fill()
        case .lid:
            let small = flame()
            // Move the flame's bottom point to the origin, scale, then put
            // that point at (12, 17.4) just above the lid.
            var m = AffineTransform(translationByX: -12, byY: -18.8)
            m.append(AffineTransform(scale: 0.6))
            m.append(AffineTransform(translationByX: 12, byY: 17.4))
            small.transform(using: m)
            small.fill()
            line(from: NSPoint(x: 2.5, y: 19.4), to: NSPoint(x: 21.5, y: 19.4), width: 2.2)
```
If the arc renders upward instead of through the bottom (the test's first assertion fails), flip `clockwise:` — the y-down flipped image context is what decides it, and the test pins the result. Remove the now-unused laptop/robot helpers if nothing else uses them (`dot`, the rounded rects).

Accessibility descriptions stay as they are.

- [ ] **Step 4: Run**

Run: `swift test --filter MenuBarIconTests` and `swift build -c release -Xswiftc -warnings-as-errors`.
Expected: PASS (the existing "awake has more ink than off" and "three distinct images" tests still hold).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Menu bar icons: pilot light (unlit, lit, low flame on the closed lid)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 13: Backstop ends a session when the app has been gone for 2 minutes

Decision 10 applies.

**Files:**
- Modify: `scripts/backstop.sh` (constants near `:165-196`; the valid-session exit `:874-876`), `scripts/uninstall.sh` (`--purge` file list), `Sources/Insomnia/Store/Paths.swift` (`appAbsentMarker`), `docs/recovery.md:7-9`, backstop header comment `:29-30`
- Test: `RecoveryScriptTests.swift` (fixture patch map `:6388-6406` gains `PGREP` and `APP_ABSENT_SECONDS`; update `testValidFutureSessionIsNoOpWithoutForce` `:77-88`; new tests)

**Interfaces:**
- Produces: backstop constants `PGREP=/usr/bin/pgrep`, `APP_PROCESS_NAME=Awake`, `APP_ABSENT_SECONDS=120`; file `$APP_SUPPORT/app-absent-since` (epoch seconds, one line); `Paths.appAbsentMarker`.

- [ ] **Step 1: Teach the fixture**

In `writeScriptCopies`, add to the backstop patch map: `"PGREP": fakePgrep` (the fake already exists around `:6912-6921`; reuse its path) and `"APP_ABSENT_SECONDS": "120"` by default. Add a helper:
```swift
    /// The app-absence marker the backstop keeps between runs.
    var absentMarker: URL { home.appendingPathComponent("app-absent-since") }
```

- [ ] **Step 2: Write the failing tests**

```swift
    func testValidSessionWithAppRunningIsLeftAlone() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try fx.setMode("pgrep", "0")
        let r = try fx.run(fx.backstop, [])
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), ["pgrep -x Awake"])
        XCTAssertFalse(fx.exists(fx.absentMarker))
    }

    func testFirstRunWithoutTheAppOnlyStartsTheClock() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try fx.setMode("pgrep", "1")
        let r = try fx.run(fx.backstop, [])
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), ["pgrep -x Awake"])
        XCTAssertTrue(fx.exists(fx.absentMarker))
        XCTAssertTrue(fx.exists(fx.session), "the session is not ended on the first sighting")
    }

    func testAppGoneForTwoMinutesEndsTheSession() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try fx.setMode("pgrep", "1")
        let then = Int(Date().timeIntervalSince1970) - 121
        try "\(then)\n".write(to: fx.absentMarker, atomically: true, encoding: .utf8)
        let r = try fx.run(fx.backstop, [])
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), ["pgrep -x Awake", "sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertFalse(fx.exists(fx.absentMarker))
        XCTAssertTrue(try fx.log().contains("app not running for"), try fx.log())
    }

    func testAppSeenAgainResetsTheClock() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try "\(Int(Date().timeIntervalSince1970) - 600)\n".write(to: fx.absentMarker, atomically: true, encoding: .utf8)
        try fx.setMode("pgrep", "0")
        _ = try fx.run(fx.backstop, [])
        XCTAssertFalse(fx.exists(fx.absentMarker))
        XCTAssertTrue(fx.exists(fx.session))
    }

    func testAPgrepThatDoesNotAnswerCountsAsRunning() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try "\(Int(Date().timeIntervalSince1970) - 600)\n".write(to: fx.absentMarker, atomically: true, encoding: .utf8)
        try fx.setMode("pgrep", "hang")
        _ = try fx.run(fx.backstop, [])
        XCTAssertTrue(fx.exists(fx.session), "never end a session on a guess")
    }
```
In `testValidFutureSessionIsNoOpWithoutForce` (`:77-88`), set `try fx.setMode("pgrep", "0")` and expect `["pgrep -x Awake"]`. If the fake pgrep has no `hang` mode, add one to its script (sleep longer than `COMMAND_TIMEOUT_SECONDS`, which the fixture patches to 1).

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter 'RecoveryScriptTests/testValidSessionWithAppRunningIsLeftAlone|RecoveryScriptTests/testAppGoneForTwoMinutesEndsTheSession'`
Expected: FAIL (no pgrep call; session untouched).

- [ ] **Step 4: Implement**

`scripts/backstop.sh`, with the other tool constants:
```bash
PGREP=/usr/bin/pgrep
# A valid session whose app has not been running for this long is ended
# (spec "Recovery"): with a 24 h session, waiting for the deadline could
# leave a crashed app's Mac sleepless for a day.
APP_PROCESS_NAME=Awake
APP_ABSENT_SECONDS=120
```
after `LOCK=`:
```bash
ABSENT_MARKER="$APP_SUPPORT/app-absent-since"
```
Replace the exit at `:874-876`:
```bash
if [[ "$session_state" != valid ]]; then
  "$RM" -f "$ABSENT_MARKER"
elif (( force == 0 )); then
  app_rc=0
  run_bounded "$PGREP" -x "$APP_PROCESS_NAME" >/dev/null 2>&1 || app_rc=$?
  if (( app_rc != 1 )); then
    # Running, or pgrep did not answer: a session is never ended on a guess.
    "$RM" -f "$ABSENT_MARKER"
    exit 0
  fi
  now="$("$DATE" -u +%s)"
  since=""
  if [[ -f "$ABSENT_MARKER" ]]; then since="$(head -n 1 "$ABSENT_MARKER" 2>/dev/null || true)"; fi
  if [[ ! "$since" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$now" > "$ABSENT_MARKER"
    exit 0
  fi
  if (( now - since < APP_ABSENT_SECONDS )); then
    exit 0
  fi
  log info "app not running for $(( now - since )) s with a session valid until $ends_at; ending it"
  "$RM" -f "$ABSENT_MARKER"
  force=1
fi
```
Use the script's existing names for `rm` and the bounded runner (`run_bounded`, `$RM` or the literal it uses; check with `grep -n '^RM=\|run_bounded()' scripts/backstop.sh`; if there is no `RM=` constant, add `RM=/bin/rm` and patch it in the fixture like the others). Keep the existing `--force` path below unchanged: setting `force=1` routes this run through it.

`Paths.swift`: `var appAbsentMarker: URL { appSupport.appendingPathComponent("app-absent-since") }`. `uninstall.sh --purge`: delete `"$APP_SUPPORT/app-absent-since"` with the other owned files (the purge test at `RecoveryScriptTests:1800-1822` lists what may remain). Update the backstop header comment (`:29-30`) and `docs/recovery.md:7-9`: a valid session is left alone while the app runs, and ended after 2 minutes without it.

- [ ] **Step 5: Run**

Run: `swift test --filter RecoveryScriptTests` (slow) and `shellcheck --shell=bash scripts/backstop.sh scripts/uninstall.sh`
Expected: PASS, no findings.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "backstop: end a session after the app has been gone for 2 minutes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Failover: internet reachability probe

**Files:**
- Create: `Sources/Insomnia/System/ReachabilityProbe.swift`
- Modify: `Sources/Insomnia/System/NetworkFailover.swift` (init seam, `start`, `stop`, `process(satisfied:)`, new `probeTick()`)
- Test: `Tests/InsomniaTests/ReachabilityTests.swift`, `FailoverMachineTests.swift` (driver tests)

**Interfaces:**
- Produces:
  - `protocol ReachabilityProbing: Sendable { func isInternetReachable() async -> Bool }`
  - `struct CaptivePortalProbe: ReachabilityProbing` (`static let url = URL(string: "http://captive.apple.com/hotspot-detect.html")!`, 5 s timeout, success = HTTP 200 and body contains "Success")
  - `struct ReachabilityTracker: Equatable { static let threshold = 3; mutating func record(success: Bool) -> Bool }` (true exactly when the third consecutive failure arrives)
  - `NetworkFailover.init(..., probe: any ReachabilityProbing = CaptivePortalProbe(), ...)`, `static let probeInterval: TimeInterval = 30`, `static let probeRetryInterval: TimeInterval = 10`, `func probeTick() async`

- [ ] **Step 1: Write the failing tests**

`ReachabilityTests.swift`:
```swift
import XCTest
@testable import Insomnia

final class ReachabilityTrackerTests: XCTestCase {
    func testThirdConsecutiveFailureStartsAnOutageOnce() {
        var t = ReachabilityTracker()
        XCTAssertFalse(t.record(success: false))
        XCTAssertFalse(t.record(success: false))
        XCTAssertTrue(t.record(success: false))
        XCTAssertFalse(t.record(success: false), "only the crossing reports")
    }

    func testASuccessResetsTheCount() {
        var t = ReachabilityTracker()
        _ = t.record(success: false)
        _ = t.record(success: false)
        XCTAssertFalse(t.record(success: true))
        XCTAssertFalse(t.record(success: false))
    }
}

final class FakeProbe: ReachabilityProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool]
    init(_ results: [Bool]) { self.results = results }
    /// Pops the next scripted answer; the last one repeats.
    func isInternetReachable() async -> Bool {
        lock.withLock { results.count > 1 ? results.removeFirst() : (results.first ?? true) }
    }
}
```
In `NetworkFailoverDriverTests`, extend the `driver(...)` helper with `probe: any ReachabilityProbing = FakeProbe([true])` and pass it through, then add:
```swift
    func testProbeFailuresStartAnOutage() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: RecordingNotifier(),
                       clock: clock, probe: FakeProbe([false]))
        await n.probeTick()
        await n.probeTick()
        XCTAssertFalse(n.machine.inOutage)
        await n.probeTick()
        XCTAssertTrue(n.machine.inOutage, "Wi-Fi associated but no internet counts as an outage")
    }

    func testPathBackWithoutInternetDoesNotEndTheOutage() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: RecordingNotifier(),
                       clock: clock, probe: FakeProbe([false]))
        await n.simulate(satisfied: false)
        await n.simulate(satisfied: true)
        XCTAssertTrue(n.machine.inOutage)
    }

    func testPathBackWithInternetEndsTheOutage() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: RecordingNotifier(),
                       clock: clock, probe: FakeProbe([true]))
        await n.simulate(satisfied: false)
        await n.simulate(satisfied: true)
        XCTAssertFalse(n.machine.inOutage)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests`
Expected: compile errors.

- [ ] **Step 3: Implement the probe**

`Sources/Insomnia/System/ReachabilityProbe.swift`:
```swift
import Foundation

/// Whether the internet answers, not only whether Wi-Fi is associated
/// (spec "Hotspot failover", point 1).
protocol ReachabilityProbing: Sendable {
    func isInternetReachable() async -> Bool
}

/// Apple's captive-portal check, the one macOS itself uses. The app's only
/// network request; made only while failover runs, with no cookies, cache
/// or identifying data.
struct CaptivePortalProbe: ReachabilityProbing {
    static let url = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    static let timeout: TimeInterval = 5

    func isInternetReachable() async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: Self.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            return String(decoding: data, as: UTF8.self).contains("Success")
        } catch {
            return false
        }
    }
}

/// Counts consecutive probe failures; an outage starts on the third.
struct ReachabilityTracker: Equatable {
    static let threshold = 3
    private(set) var failures = 0

    /// True exactly when this failure is the one that crosses the threshold.
    mutating func record(success: Bool) -> Bool {
        if success {
            failures = 0
            return false
        }
        failures += 1
        return failures == Self.threshold
    }
}
```
`http` to `captive.apple.com` needs an App Transport Security exception. Add to `Resources/Info.plist`:
```xml
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSExceptionDomains</key>
		<dict>
			<key>captive.apple.com</key>
			<dict>
				<key>NSExceptionAllowsInsecureHTTPLoads</key>
				<true/>
			</dict>
		</dict>
	</dict>
```

- [ ] **Step 4: Wire it into the driver**

`NetworkFailover`: add `private let probe: any ReachabilityProbing`, `private var tracker = ReachabilityTracker()`, `private(set) var probeTimer: Timer?`, the init parameter `probe: any ReachabilityProbing = CaptivePortalProbe()` (after `hotspotJoiner`), and:
```swift
    static let probeInterval: TimeInterval = 30
    static let probeRetryInterval: TimeInterval = 10

    /// One reachability check. Three failures in a row start an outage
    /// even while Wi-Fi stays associated. Internal so tests drive it.
    func probeTick() async {
        let epoch = self.epoch
        let ok = await probe.isInternetReachable()
        guard self.epoch == epoch, !Task.isCancelled else { return }
        if tracker.record(success: ok) {
            Log.info("internet unreachable for \(ReachabilityTracker.threshold) checks with Wi-Fi up")
            await process(satisfied: false)
        }
        scheduleProbe(after: ok ? Self.probeInterval : Self.probeRetryInterval)
    }

    private func scheduleProbe(after: TimeInterval) {
        probeTimer?.invalidate()
        let epoch = self.epoch
        let t = Timer(timeInterval: after, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.epoch == epoch else { return }
                self.track { [weak self] in await self?.probeTick() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        probeTimer = t
    }
```
At the end of `start()` (after the monitor starts): `scheduleProbe(after: Self.probeInterval)`. In `stop()`: `probeTimer?.invalidate(); probeTimer = nil; tracker = ReachabilityTracker()`.
In `process(satisfied:)`, gate recovery on the internet answering:
```swift
    private func process(satisfied: Bool) async {
        guard !Task.isCancelled else { return }
        if satisfied, machine.inOutage, !(await probe.isInternetReachable()) {
            Log.info("wifi path satisfied but the internet is unreachable; still in outage")
            return
        }
        let now = clock()
        let outputs = satisfied ? machine.pathSatisfied(at: now) : machine.pathUnsatisfied(at: now)
        if outputs.isEmpty { return }
        if !satisfied { Log.info("wifi path unsatisfied") }
        await apply(outputs)
    }
```

- [ ] **Step 5: Run**

Run: `swift test --filter 'ReachabilityTrackerTests|NetworkFailoverDriverTests|NetworkFailoverCancellationTests|FailoverMachineTests'`
Expected: PASS. Existing driver tests that end an outage with `simulate(satisfied: true)` pass because the default fake probe answers `true`.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Failover: an outage also starts when the internet stops answering

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Failover: switch back to the previous Wi-Fi

**Files:**
- Modify: `Sources/Insomnia/System/HotspotJoiner.swift` (protocol + CoreWLAN), `Sources/Insomnia/System/NetworkFailover.swift` (home SSID, switch-back timer, `switchBackTick()`), `Tests/InsomniaTests/FailoverMachineTests.swift` (`RecordingHotspotJoiner` `:4-20`)
- Test: `FailoverMachineTests.swift` (`NetworkFailoverDriverTests`)

**Interfaces:**
- Produces:
  - `HotspotJoining.isVisible(ssid: String, interfaceName: String) async throws -> Bool`
  - `HotspotJoining.rejoinKnownNetwork(ssid: String, interfaceName: String) async throws -> Bool`
  - `NetworkFailover.init(..., ssidReader: (@MainActor () async -> String?)? = nil, settle: Duration = .seconds(10), ...)`, `static let switchBackInterval: TimeInterval = 60`, `private(set) var homeSSID: String?`, `func switchBackTick() async`

- [ ] **Step 1: Extend the recording joiner and write the failing tests**

`RecordingHotspotJoiner` gains:
```swift
    var visible: Set<String> = []
    var rejoined: [String] = []
    func isVisible(ssid: String, interfaceName: String) async throws -> Bool { visible.contains(ssid) }
    func rejoinKnownNetwork(ssid: String, interfaceName: String) async throws -> Bool {
        rejoined.append(ssid)
        return visible.contains(ssid)
    }
```
(match its existing locking style). Extend `driver(...)` with `ssid: String? = "Home"` passed as `ssidReader: { ssid }` and `settle: .zero`. Tests:
```swift
    func testSwitchBackRejoinsHomeWhenItIsVisibleAndOnline() async {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        let n = driver(keychain: FakeKeychainStore(), joiner: joiner, notifier: RecordingNotifier(),
                       clock: FakeClock(Date(timeIntervalSince1970: 1_800_000_000)), probe: FakeProbe([true]))
        await n.recordHomeNetwork()
        XCTAssertEqual(n.homeSSID, "Home")
        await n.switchBackTick()
        XCTAssertEqual(joiner.rejoined, ["Home"])
    }

    func testSwitchBackRejoinsHotspotWhenHomeHasNoInternet() async {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        let keychain = FakeKeychainStore()
        try? keychain.set("pw", service: KeychainStore.service, account: "Phone")
        let n = driver(keychain: keychain, joiner: joiner, notifier: RecordingNotifier(),
                       clock: FakeClock(Date(timeIntervalSince1970: 1_800_000_000)), hotspot: "Phone", probe: FakeProbe([false]))
        await n.recordHomeNetwork()
        await n.switchBackTick()
        XCTAssertEqual(joiner.rejoined, ["Home"])
        XCTAssertEqual(joiner.calls.last?.ssid, "Phone", "back to the hotspot: home has no internet")
    }

    func testNoSwitchBackWhileHomeIsOutOfRange() async {
        let joiner = RecordingHotspotJoiner()
        let n = driver(keychain: FakeKeychainStore(), joiner: joiner, notifier: RecordingNotifier(),
                       clock: FakeClock(Date(timeIntervalSince1970: 1_800_000_000)), probe: FakeProbe([true]))
        await n.recordHomeNetwork()
        await n.switchBackTick()
        XCTAssertEqual(joiner.rejoined, [])
    }

    func testTheHotspotIsNeverRecordedAsHome() async {
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: RecordingNotifier(),
                       clock: FakeClock(Date(timeIntervalSince1970: 1_800_000_000)), hotspot: "Phone", ssid: "Phone")
        await n.recordHomeNetwork()
        XCTAssertNil(n.homeSSID)
    }
```
Use the existing helper names for the keychain write (`FakeKeychainStore`'s setter) and the joiner's recorded calls; adapt `calls.last?.ssid` to however `RecordingHotspotJoiner` stores calls.

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests`
Expected: compile errors.

- [ ] **Step 3: Implement the CoreWLAN side**

`HotspotJoiner.swift`, protocol:
```swift
protocol HotspotJoining: Sendable {
    /// Returns false when the SSID-filtered scan finds no matching network.
    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool
    /// Whether an SSID-filtered scan sees the network now.
    func isVisible(ssid: String, interfaceName: String) async throws -> Bool
    /// Joins a network macOS already knows, with the password macOS stored
    /// for it. False when it is not in range.
    func rejoinKnownNetwork(ssid: String, interfaceName: String) async throws -> Bool
}
```
`CoreWLANHotspotJoiner`:
```swift
    func isVisible(ssid: String, interfaceName: String) async throws -> Bool {
        try !scan(ssid: ssid, interfaceName: interfaceName).isEmpty
    }

    func rejoinKnownNetwork(ssid: String, interfaceName: String) async throws -> Bool {
        guard let network = try scan(ssid: ssid, interfaceName: interfaceName).first,
              let interface = CWWiFiClient.shared().interface(withName: interfaceName) else { return false }
        // nil: CoreWLAN uses the credentials macOS stored for a known network.
        try interface.associate(to: network, password: nil)
        return true
    }

    private func scan(ssid: String, interfaceName: String) throws -> Set<CWNetwork> {
        guard let interface = CWWiFiClient.shared().interface(withName: interfaceName) else {
            throw HotspotJoinError.missingInterface(interfaceName)
        }
        return try interface.scanForNetworks(withSSID: ssid.data(using: .utf8))
    }
```
Hardware check, Task 18 step 3: if `associate(to:password: nil)` fails for a WPA network macOS knows, replace its body with `interface.disassociate(); return true` (macOS auto-join then picks the known network) and keep the probe-then-hotspot fallback.

- [ ] **Step 4: Implement the driver side**

`NetworkFailover`: add
```swift
    static let switchBackInterval: TimeInterval = 60
    /// The Wi-Fi the Mac was on before failover moved it to the hotspot.
    private(set) var homeSSID: String?
    private(set) var switchBackTimer: Timer?
    private let ssidReader: (@MainActor () async -> String?)?
    private let settle: Duration
```
init parameters `ssidReader: (@MainActor () async -> String?)? = nil, settle: Duration = .seconds(10)` and:
```swift
    private func readSSID() async -> String? {
        if let ssidReader { return await ssidReader() }
        return await currentSSID()
    }

    /// Remember the current network as home unless it is the hotspot.
    func recordHomeNetwork() async {
        guard let ssid = await readSSID(), !ssid.isEmpty else { return }
        let hotspot = HotspotSSID.normalized(configProvider().hotspotSSID)
        guard ssid != hotspot else { return }
        homeSSID = ssid
    }

    /// While on the hotspot: rejoin home when it is visible, and go back
    /// to the hotspot if home has no internet. Internal so tests drive it.
    func switchBackTick() async {
        let epoch = self.epoch
        guard let home = homeSSID, let iface = wifiInterface ?? (ssidReader == nil ? nil : "en0") else { return }
        do {
            guard try await hotspotJoiner.isVisible(ssid: home, interfaceName: iface) else { return }
            guard try await hotspotJoiner.rejoinKnownNetwork(ssid: home, interfaceName: iface) else { return }
        } catch {
            Log.error("switch back to the previous Wi-Fi failed: \(error.localizedDescription)")
            return
        }
        try? await Task.sleep(for: settle)
        guard self.epoch == epoch else { return }
        if await probe.isInternetReachable() {
            Log.info("switched back to the previous Wi-Fi")
            switchBackTimer?.invalidate()
            switchBackTimer = nil
        } else {
            Log.info("previous Wi-Fi has no internet; back to the hotspot")
            await joinHotspot()
        }
    }

    private func scheduleSwitchBack() {
        switchBackTimer?.invalidate()
        let epoch = self.epoch
        let t = Timer(timeInterval: Self.switchBackInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.epoch == epoch else { return }
                self.track { [weak self] in await self?.switchBackTick() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        switchBackTimer = t
    }
```
Hook-ups: at the end of `start()` call `await recordHomeNetwork()`; in `probeTick()` after a success with no outage, call `await recordHomeNetwork()`; in `recovered(start:gap:)`, after `onRecovered?(gap)`: `if homeSSID != nil, await readSSID() == HotspotSSID.normalized(configProvider().hotspotSSID) { scheduleSwitchBack() }`; in `stop()`: `switchBackTimer?.invalidate(); switchBackTimer = nil`. Note the test interface name: when `ssidReader` is injected and `wifiInterface` is nil the driver uses `"en0"` so tests need no `networksetup`; the live path always resolves `wifiInterface` in `start()`.

- [ ] **Step 5: Run**

Run: `swift test --filter 'NetworkFailoverDriverTests|NetworkFailoverCancellationTests|FailoverMachineTests|ReachabilityTrackerTests'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Failover: switch back to the previous Wi-Fi once it is online

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: Failover in Awake mode (optional)

**Files:**
- Modify: `Sources/Insomnia/Model/Config.swift` (`awakeHotspotFailover`), `Sources/Insomnia/Core/AppServices.swift` (`startAwakeFailover`, `stopAwakeFailover`, stop it in `start(for:)`), `Sources/Insomnia/InsomniaApp.swift` (hook `awake.onChange`), `Sources/Insomnia/UI/SettingsView.swift` (`networkSection` toggle)
- Test: `ConfigTests.swift`, `IntegrationWiringTests.swift`

**Interfaces:**
- Consumes: `AwakeController.onChange` (Task 7).
- Produces: `Config.awakeHotspotFailover: Bool = false`; `AppServices.startAwakeFailover(config: @escaping @MainActor () -> Config)`, `AppServices.stopAwakeFailover()`, `AppServices.awakeFailoverRunning: Bool`.

- [ ] **Step 1: Write the failing tests**

`ConfigTests.swift`:
```swift
    func testAwakeHotspotFailoverDefaultsOffAndDecodes() throws {
        XCTAssertFalse(Config().awakeHotspotFailover)
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"awakeHotspotFailover":true}"#.utf8))
        XCTAssertTrue(c.awakeHotspotFailover)
    }
```
`IntegrationWiringTests.swift` (use its existing `AppServices` construction helper):
```swift
    func testAwakeFailoverStartsAndStopsWithoutASession() async {
        let services = makeServices()   // the file's existing helper
        services.startAwakeFailover { Config() }
        XCTAssertTrue(services.awakeFailoverRunning)
        services.stopAwakeFailover()
        XCTAssertFalse(services.awakeFailoverRunning)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests`
Expected: compile errors.

- [ ] **Step 3: Implement**

`Config.swift`, in the network block:
```swift
    /// Run hotspot failover in Awake mode too, not only in lid sessions.
    var awakeHotspotFailover: Bool = false
```
and `awakeHotspotFailover = try c.decodeIfPresent(Bool.self, forKey: .awakeHotspotFailover) ?? d.awakeHotspotFailover`.

`AppServices.swift`:
```swift
    /// Failover for Awake mode, separate from the session's (`network`).
    private var awakeNetwork: NetworkFailover?
    var awakeFailoverRunning: Bool { awakeNetwork != nil }

    func startAwakeFailover(config: @escaping @MainActor () -> Config) {
        guard awakeNetwork == nil, !running else { return }
        let net = NetworkFailover(paths: paths, keychain: keychain, notifier: notifier, config: config)
        net.onRecovered = { [weak self] gap in self?.status.lastGap = gap }
        net.onPasswordReport = { [weak self] report in self?.status.hotspotPasswordReport = report }
        awakeNetwork = net
        Task { await net.start() }
    }

    func stopAwakeFailover() {
        awakeNetwork?.stop()
        awakeNetwork = nil
    }
```
At the top of `start(for:)`: `stopAwakeFailover()` (a lid session runs its own).

`InsomniaApp.swift`, in `applicationDidFinishLaunching` after the status item:
```swift
        awake.onChange = { [weak self] state in
            guard let self, let services = self.manager.services else { return }
            if state != .off, self.manager.config.awakeHotspotFailover, !self.manager.config.hotspotSSID.isEmpty {
                services.startAwakeFailover { [weak manager = self.manager] in manager?.config ?? Config() }
            } else {
                services.stopAwakeFailover()
            }
        }
```
`SettingsView.swift`, in `networkSection` where the tmux rows were:
```swift
            Toggle("Use hotspot failover in Awake mode too", isOn: bind(\.awakeHotspotFailover))
```

- [ ] **Step 4: Run**

Run: `swift test --filter 'ConfigTests|IntegrationWiringTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Failover in Awake mode, off by default

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16b: End-to-end smoke test (user request 2026-10-14)

A script builds the real `Awake.app` in its **test build** (the existing lid-simulation build, `INSOMNIA_LID_SIMULATION=1` to `scripts/build-app.sh`, gated out of release builds by `scripts/check-lid-simulation-gate.sh`), launches it in a throwaway `AWAKE_HOME`, drives it through a test-only control channel, and checks real effects. It runs locally and in CI.

**Requirements:**
- **Control channel, test build only.** Under the same compile-time flag as `LidSimulationBuild` (and nowhere else), the app polls `$AWAKE_HOME/test-control` every 0.5 s; each line is one command, consumed and deleted: `awake-on`, `awake-on <seconds>`, `awake-off`, `lid-start <seconds>`, `lid-extend <seconds>`, `lid-end`, `quit`. Lid open/close is driven by the existing `simulate-lid` file (`scripts/simulate-lid.sh`).
- **No root in the test build.** The test build injects a simulated sleep guard (`SleepGuarding` that records `disablesleep 1/0` and low power into `$AWAKE_HOME/test-sleepguard.log` and keeps the bit in memory) instead of `PmsetSleepGuard`, and a recovery-agent stand-in that reports armed without launchctl. The IOPM assertion (screen mode) stays **real**.
- **Status file.** After every state change the test build writes `$AWAKE_HOME/test-status.json`: `{"awakeOn": Bool, "awakeEndsAt": String?, "lidActive": Bool, "lidPaused": Bool?, "lidRemaining": Number?, "lidHoldActive": Bool, "icon": "off"|"awake"|"lid", "title": String}`.
- **`scripts/smoke-test.sh`** (bash 3.2, ShellCheck clean): builds the test build into a temp dir; starts it with `AWAKE_HOME` set; waits for "launched" in the log; then runs these checks, each with a 10 s deadline, printing `PASS`/`FAIL <reason>` per step and exiting non-zero on any failure:
  1. idle: status icon `off`; `pmset -g assertions` has no "Awake mode".
  2. `awake-on`: icon `awake`; `pmset -g assertions` shows "Awake mode".
  3. `awake-off`: icon `off`; assertion gone.
  4. `lid-start 600` with the simulated lid **open**: `lidActive`, `lidPaused` true, icon `lid`, `lidHoldActive` true (assertion held), `session.json` has `pausedRemaining` 600, sleep-guard log shows `disablesleep 1`.
  5. simulate lid **closed**: `lidPaused` false, `lidHoldActive` false (assertion released), `session.json` `endsAt` about now+600.
  6. simulate lid **open**: paused again, remaining ≤ 600.
  7. `lid-end`: icon `off`, no `session.json`, sleep-guard log ends with `disablesleep 0`, assertion gone.
  8. `quit`: the process exits within 10 s; no "Awake mode" assertion remains.
  Always kills the app and removes the temp home on exit (trap).
- **CI:** a new job in `.github/workflows/ci.yml` (from Task 17) on `macos-26` runs `scripts/smoke-test.sh` on pull requests.
- **Swift tests** for the command parser and the status-file encoder (pure functions), in `Tests/InsomniaTests/TestControlTests.swift`.
- **The gate:** `scripts/check-lid-simulation-gate.sh` (and its test) must also prove the control channel is absent from a release build (grep the release binary for the `test-control` string, like it does for the simulation marker).

- [ ] Steps: write the parser/encoder tests (fail), implement them; add the test-build wiring (injected guard, control loop, status writer) behind the flag; write `scripts/smoke-test.sh`; run it locally until all 8 steps pass; extend the gate; add the CI job; ShellCheck; release build with warnings as errors; commit ("Tests: end-to-end smoke test of the real app (test build only)").

---

### Task 16c: Real-sleep check on a real Mac (user request 2026-10-14)

`scripts/real-sleep-check.sh`: a guided, interactive check for the person's own Mac that proves the lid-closed promise with macOS's own sleep log. Not run in CI; part of Task 18's checklist.

**Requirements:**
- Preconditions it verifies and explains if missing: Awake installed (`~/Applications/Awake.app`), running, `/etc/sudoers.d/awake` present, no lid session active, on power or battery above the end floor.
- Guided steps, printed one at a time with the exact menu clicks:
  1. "Start Keep awake with lid closed → Custom… → 3m, enter your password." The script waits for `session started` in `~/Library/Logs/Awake/awake.log`.
  2. "Close the lid now and leave it closed for at least 5 minutes, then open it and press Enter."
- After Enter it reads, for the window since the session started: Awake's log (lid closed/opened lines, `session end (timer)`, closed-lid sleep requested) and `log show --style compact --predicate 'process == "powerd" AND eventMessage CONTAINS "Entering Sleep"'`.
- Verdict, PASS only if all hold: (a) no "Entering Sleep" between the lid close and the session's timer end; (b) the session ended by `timer` about 3 minutes after the close (± 70 s: the clock counts closed time only); (c) an "Entering Sleep" within 60 s after that end. Each prints with its timestamps; any miss prints FAIL with what was seen.
- ShellCheck clean, bash 3.2. A `--dry-run` flag parses saved log excerpts from `Tests/Fixtures/real-sleep/` instead of the live logs, and a Swift test runs it against a passing and a failing fixture.

- [ ] Steps: write fixtures + the dry-run test (fail); write the script; dry-run test passes; ShellCheck; add item "4c. Run scripts/real-sleep-check.sh" to Task 18's checklist; commit ("Tests: guided real-sleep check for a real Mac").

---

### Task 16d: Make the timing-flaky tests reliable (user request 2026-10-14)

Known flaky under load (ledger): `PowerMonitorTests.testUnreadableBatteryIsRecheckedWhileStarted`, `ClosedLidSleepTests.testRepeatWaitsForALiveCommand` and the `ClosedLidSleepTests` negative assertions that use fixed 200-300 ms sleeps, `RecoveryScriptTests.testInstallMovesNeitherBundleWhenCodesignDoesNotAnswerDuringTheRepair`, `RecoveryScriptTests.testUninstallRestoresAppNapViaBackstopThenRemoves`, `ClosedLidClockTests` / `MenuBarTests` cases that wait on real timers.

**Requirements:**
- Replace wall-clock waits with deterministic synchronisation: injected clocks (`FakeClock`), `AsyncGate`s, or polling with a generous deadline and an exact end condition — never a fixed sleep followed by a negative assertion. For script tests whose limits are seconds, make the limit a patched constant in the fixture rather than a wall-clock race.
- No production behaviour changes; if a seam is needed in production code it must be an injected default that the live path does not change.
- **Proof:** a `scripts/stress-tests.sh` that runs each listed class 10 times in a row while 4 `yes > /dev/null` load processes run (killed on exit), and fails on any failure. Record its output in the report. All runs pass.

- [ ] Steps: run the stress script first to reproduce (record failures); fix each test; re-run the stress script until clean; fast set; commit ("Tests: make timing-sensitive tests deterministic").

---
### Task 17: Repository: CI, fast tests, README, LICENSE, Insomnia-only automation

**Files:**
- Create: `scripts/test-fast.sh`
- Replace: `.github/workflows/ci.yml`
- Delete: `.github/workflows/merge-gate.yml`, `.github/workflows/release.yml`, `.github/scripts/merge-gate*.sh`, `.github/scripts/shellcheck-hidden*.sh`, `.github/shellcheck-hidden.txt`, `.github/actionlint.yaml` only if nothing references it, `.greptile/`, `skills/`, `Tests/InsomniaTests/ReleaseWorkflowTests.swift`
- Modify: `README.md`, `LICENSE`, `CONTRIBUTING.md:30-32`, `SECURITY.md:17`, `docs/extras.md`, `docs/lid-close.md`, `docs/spec.md` (header note), `docs/releasing.md`, `docs/release-validation.md`

- [ ] **Step 1: Fast test script**

`scripts/test-fast.sh`:
```bash
#!/bin/bash
# Unit tests only: skips the script-driven classes that spawn bash, codesign
# or the built app (minutes instead of half an hour). Run the full suite
# (`swift test`) before a release.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift test --skip 'RecoveryScriptTests|AgentModeExitInANewBootTests|AppEncodedJournalScriptTests|PackagingTests|LidSimulationGateScriptTests|ResumeFrozenCommandTests' "$@"
```
`chmod +x scripts/test-fast.sh`. Run it: expected PASS in a few minutes.

- [ ] **Step 2: CI**

Replace `.github/workflows/ci.yml`:
```yaml
name: CI
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
jobs:
  swift:
    runs-on: macos-26
    permissions:
      contents: read
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Build
        run: swift build -c release -Xswiftc -warnings-as-errors
      - name: Fast tests
        run: scripts/test-fast.sh
        env:
          NSUnbufferedIO: "YES"
  shellcheck:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: ShellCheck
        run: shellcheck --shell=bash scripts/*.sh
```
Delete the files listed above. If `ShellCheck` is not preinstalled on ubuntu-24.04 at run time, add `sudo apt-get install -y shellcheck` before it.

- [ ] **Step 3: README and LICENSE**

Rewrite `README.md` for Awake. Keep Insomnia's still-true sections (install from source, what gets installed, recovery, lid-close actions, uninstall), updated for this plan. Required content:
- Title "Awake" and one line: keep your Mac awake, even with the lid closed. "Working title."
- "Awake is a fork of [Insomnia](https://github.com/krishhgg/Insomnia) by Krish Garg, with the one-click mode of [Caffeine](https://github.com/domzilla/Caffeine). Both are MIT licensed."
- Usage: left-click toggles Awake mode; right-click menu; lid mode asks for the password each time, is always timed, 24 h at most.
- What the installer changes: the app in `~/Applications/Awake.app`, the recovery LaunchAgent, and the three-line sudoers rule (quote it).
- Network: "Awake makes one kind of network request: while hotspot failover runs, it checks `http://captive.apple.com/hotspot-detect.html`, the address macOS itself uses to test the connection. Nothing else leaves your Mac."
- Requires macOS 26, Apple Silicon. Insomnia must be uninstalled first.
Remove the tmux, Docker and Chromium-flag-free claims that no longer hold; keep the Chromium relaunch section.

`LICENSE`: keep Insomnia's MIT text and notice unchanged; below it add:
```
Awake's Awake mode follows the idea of Caffeine:

MIT License

Copyright (c) 2006-2018 Tomas Franzén, Lighthead Software
Copyright (c) 2018 Michael Jones, IntelliScape Computer Solutions
Copyright (c) 2022 Dominic Rodemer
```
followed by the standard MIT permission text (copy it from `gh api repos/domzilla/Caffeine/contents/LICENSE`).

Docs: remove the tmux and Docker sections from `docs/extras.md`, `docs/lid-close.md`, `docs/releasing.md`, `docs/release-validation.md`, `CONTRIBUTING.md`, `SECURITY.md`; add at the top of `docs/spec.md`: "This is Insomnia's original spec; Awake's changes are in docs/superpowers/specs/2026-10-14-awake-design.md."

- [ ] **Step 4: Run**

Run: `scripts/test-fast.sh && swift build -c release -Xswiftc -warnings-as-errors && shellcheck --shell=bash scripts/*.sh`
Expected: PASS. `grep -rni 'tmux\|docker rule\|merge-gate\|greptile' README.md docs CONTRIBUTING.md SECURITY.md .github`: no hits except historical lines in `docs/spec.md`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Repo: Awake README and LICENSE, PR-only CI, fast tests; drop Insomnia's automation

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 18: Full verification, install, real-Mac checklist, PR

**Files:** none new.

- [ ] **Step 1: Full suite**

Run: `swift test 2>&1 | tee /tmp/awake-full.log; grep -E "' failed \(" /tmp/awake-full.log`
Expected: no failures, or only timing-flaky ones that pass when re-run alone with `--filter` (record which).

- [ ] **Step 2: Install on the development Mac**

Insomnia must be uninstalled first (`cd ~/Coding/Insomnia && ./scripts/uninstall.sh`; the installer refuses otherwise, Task 3). Then, in Terminal (it asks for the password once):
```bash
cd ~/Coding/Awake && ./scripts/install.sh && open ~/Applications/Awake.app
```
Verify: `cat /etc/sudoers.d/awake` shows the three lines; `launchctl list | grep app.chargingpixels.awake.recovery` shows the agent.

- [ ] **Step 3: Real-Mac checklist** (spec "Testing")

1. Left-click: the icon fills; `pmset -g assertions | grep "Awake mode"`; left-click again: gone.
2. Right-click → Keep awake with lid closed → 1 hour: the macOS password prompt appears (note whether it offers Touch ID). Cancel it: no notification, no error line, `pmset -g | grep SleepDisabled` shows nothing.
3. Start it again and enter the password: the robot icon and `1:00` show. Close the lid for 3 minutes with an agent running and Wi-Fi in use; open it: the agent kept working, Wi-Fi stayed up.
4. Start a 10-minute session, close the lid and leave it until the timer ends: the Mac sleeps (check `pmset -g log | grep -i "Entering Sleep"` afterwards).
4b. Start a 1-hour lid session with the lid open and leave it open 10 minutes: the countdown stays at 1:00, the screen stays on, and the menu says "paused while the lid is open". Close the lid for 10 minutes and open it: the countdown reads about 0:50 and the display had gone dark while closed.
4c. Run `scripts/real-sleep-check.sh` and follow it (start a 3-minute lid session, close the lid for 5 minutes, open it, press Enter): it must print `RESULT: PASS`, i.e. no "Entering Sleep" in macOS's log while the lid was closed and the timer ran, the session ended by timer about 3 minutes after the close, and macOS slept within 60 s of that end. Paste its output into the PR description.
5. Start a session, then `kill -9 $(pgrep -x Awake)`: within about 3 minutes `pmset -g` no longer shows `SleepDisabled 1` and `~/Library/Logs/Awake/awake.log` has "app not running for".
6. Relaunch the app during a session (quit is refused while a session runs, so use `kill -9` then `open` within a minute): no password prompt; the session continues.
7. With a hotspot configured: turn the router's internet off (or join a captive network): within about 40 s Awake joins the hotspot; restore the router: within about 70 s it switches back. If step 7's switch-back fails because `associate(to:password: nil)` is refused, apply the fallback in Task 15 step 3, rerun Task 15's tests, and repeat.
8. Right-click → Relaunch Chrome unthrottled (if Chrome shows as throttled): it quits and reopens with tabs.
9. Typing in other apps for 5 minutes never changes the menu bar item (the Insomnia "expanding" bug).

Write the results into the PR description, one line per item, with anything that did not pass.

- [ ] **Step 4: Update the spec's open questions**

In `docs/superpowers/specs/2026-10-14-awake-design.md`, mark open questions 2-4 with what the checklist found (26.6.2 revert behaviour, Touch ID at the prompt, iPhone hotspot visibility).

- [ ] **Step 5: Push and open the PR** (only after the user approves opening it)

```bash
git push
gh pr create --repo liviulica/awake --base main --head phase-1 --title "Awake phase 1" --body-file /tmp/awake-pr.md
```
Enable Actions for the repo first only if the user wants CI on the PR (`gh api -X PUT repos/liviulica/awake/actions/permissions -F enabled=true`).

---

---

### Task 19: Awake's own MIT license (user request 2026-10-14)

**Requirements:** `LICENSE` starts with Awake's own MIT notice — `MIT License`, `Copyright (c) 2026 Liviu Lica`, the standard MIT permission text — followed by a "Portions" section that keeps Insomnia's MIT notice verbatim (`Copyright (c) 2026 Krish Garg` and its text) and the Caffeine notice from Task 17. README's license section says "MIT. Awake is a fork of Insomnia (MIT, Krish Garg) and borrows its one-click idea from Caffeine (MIT)." `Package.swift` and any `About` text name the license consistently. If the person has not said otherwise, the copyright holder is Liviu Lica (the alternative they may pick is "Charging Pixels").

- [ ] Steps: edit LICENSE and README; `swift build`; commit ("License: Awake's MIT notice, with Insomnia's and Caffeine's kept").

---

### Task 20: Prepare the repository to be public (user request 2026-10-14)

**Requirements (an audit with a written result, then fixes):**
1. **Secrets:** install `gitleaks` (brew) and run `gitleaks git --redact` over the full history and `gitleaks dir` over the working tree. Any finding stops the task and is reported.
2. **Personal data in history:** list commit author/committer emails (`git log --all --format='%ae %ce' | sort -u`). Commits authored by the personal Gmail address are rewritten to `826835+liviulica@users.noreply.github.com` **only if the person approved it** (ledger); then set this repo's `user.email` to the no-reply address. Insomnia's upstream commits are never rewritten.
3. **Personal data in files:** grep the tree for the home folder path, the personal address, work-related names, private artifact links and `.superpowers`; replace local paths with `~/…`, keep design docs (`docs/superpowers/`) but replace private artifact links with "(private mockup)".
4. **Insomnia-only leftovers:** `SECURITY.md` (contact becomes GitHub private vulnerability reporting), `CONTRIBUTING.md`, `.github/ISSUE_TEMPLATE/*`, `.github/pull_request_template.md`, `docs/releasing.md`, `docs/release-validation.md`, `docs/install.md` (still describes the four-command rule and Insomnia releases): rewrite for Awake or delete where they only describe Insomnia's release process.
5. **README for strangers:** what it is, screenshots placeholder list, "build from source" install (no signed release yet), what the installer changes (three-line sudoers, LaunchAgent), the one network request, uninstall, credits, license.
6. **Repo metadata (applied in Task 21):** description, topics (`macos`, `menu-bar`, `caffeinate`, `sleep`, `ai-agents`), homepage none.
- Output: `docs/public-readiness.md` listing every check, what was found, and what was changed; nothing that the person must decide is left implicit — open decisions are listed at the top.

- [ ] Steps: run the audit; write `docs/public-readiness.md`; make the fixes; history rewrite only if approved; fast tests + release build; commit.

---

### Task 21: Make the repository public (user request 2026-10-14)

**Stops for the person first.** The controller shows the person `docs/public-readiness.md`'s open decisions and asks for the go-ahead (changing visibility is outward-facing and hard to undo once forked or indexed).

**Requirements:** after the go-ahead: push `main` and `phase-1` (force-push only if Task 20 rewrote history, and only before the flip); merge state as the person decides (merging is the person's action); `gh repo edit liviulica/awake --visibility public --accept-visibility-change-consequences`; set description and topics; enable Actions (`gh api -X PUT repos/liviulica/awake/actions/permissions -F enabled=true`); enable private vulnerability reporting (`gh api -X PUT repos/liviulica/awake/private-vulnerability-reporting`); confirm with `gh repo view --json visibility`.

- [ ] Steps: ask; apply; verify; report the public URL.

---

## Self-review notes

- Spec coverage: modes (Tasks 7, 10), menu and icons (8, 9, 10), closed-lid sleep (1), privileges phase 1 (11, 12), recovery (13), hotspot points 1-3 (14, 15, 16), point 4 is phase 2, point 5 is checklist item 7, what goes (4, 5, 10, 17), identity and coexistence (2, 3), credit (17), testing split (17), CI (17), upstream (Task 1 uses a fetched PR; future cherry-picks need nothing in the code). Phase 2 items (helper, signing, notarization, release workflow) are out of scope.
- Residual risks: `associate(to:password: nil)` for known networks (fallback written in Task 15); Touch ID at the osascript prompt (informational); macOS 26.6.2 reverting `disablesleep` (`SleepGuard` already detects it; the checklist reveals it); exact line numbers drift as earlier tasks land, so each task names the symbol as well as the line.
