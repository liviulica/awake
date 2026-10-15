# Menu v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mode tabs (Off | Screen | Lid) with quick-time chips at the top of the menu, a left-click that only toggles screen mode, a way to set a lid session's time left, and lid starts without a password.

**Architecture:** A pure `ModeHeader` model (tabs, chips, caption, tab transitions) is tested without AppKit; a small AppKit `ModeHeaderView` renders it inside an `NSMenuItem.view`. `SessionMath.withRemaining` plus `SessionManager.setRemaining` mirror the extend path. `PmsetSleepGuard` tries `sudo -n` for `disablesleep 1` and falls back to the administrator prompt when sudo wants a password. `install.sh` writes and checks a fourth rule line.

**Tech Stack:** Swift 6.2, AppKit (`NSMenu`, `NSSegmentedControl`, `NSButton`, `NSStackView`), XCTest, bash (install.sh), the existing script-test fixtures.

**Spec:** `docs/superpowers/specs/2026-10-16-ember-menu-v2-design.md`

## Global Constraints

- Branch `menu-v2`; commits as `liviulica <826835+liviulica@users.noreply.github.com>` (repo config), ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Merge locally (`git merge --no-ff`), never `gh pr merge`; merging needs the owner's yes.
- `swift build -c release -Xswiftc -warnings-as-errors` stays clean; `scripts/test-fast.sh`, `scripts/smoke-test.sh`, `scripts/check-lid-simulation-gate.sh`, `shellcheck scripts/*.sh` pass.
- No em dashes in user-facing strings or docs.
- Lid chips: 1, 2, 4, 8, 12 h and Custom; screen chips: ∞, 1, 2, 4 h and Custom; lid time always within [`SessionMath.minimumDuration`, `Config.lidMaxDuration`].
- The header never shows a mode the Mac is not in: its selection is computed from `StatusItemController.mode` on every refresh.

## Review Focus

1. A lid start that falls back to the password prompt and is cancelled from the Lid tab: the header must snap back to the real mode (Task 5 test).
2. `setRemaining` racing an end (the person ends the session while a chip's change is in flight): no resurrected session (Task 1 test, like `testEndDuringExtendMustNotResurrectSession`).
3. A three-line sudoers rule (today's install): lid start still works through the prompt, and the log says to re-run install.sh (Task 2 test).
4. Screen → Lid tab: screen mode folds in exactly once and the shared assertion is not double-released (Task 5 test with `FakeAwakeAssertion`).
5. A chip clicked for a mode that ended meanwhile (menu open across a timer end): the action is ignored, not applied to a new session (Task 5 test).

---

### Task 1: Set a lid session's time left

**Files:**
- Modify: `Sources/Insomnia/Core/SessionMath.swift`
- Modify: `Sources/Insomnia/Core/SessionManager.swift` (next to `extend(by:)` and `performExtend`)
- Test: `Tests/InsomniaTests/SessionMathTests.swift`, `Tests/InsomniaTests/ClosedLidClockTests.swift`, `Tests/InsomniaTests/ReconcileTests.swift`, `Tests/InsomniaTests/RecoverySafetyTests.swift`

**Interfaces:**
- Produces: `SessionMath.withRemaining(_ session: Session, remaining: TimeInterval, now: Date, maxDuration: TimeInterval) -> Session`; `SessionManager.setRemaining(_ seconds: TimeInterval) async`.

- [ ] **Step 1: Failing tests**

`SessionMathTests`:

```swift
    func testWithRemainingSetsAPausedSessionsClosedTimeAndLeavesTheLease() {
        let p = SessionMath.newPausedSession(now: t0, duration: 8 * 3600, maxDuration: maxDuration)
        let s = SessionMath.withRemaining(p, remaining: 2 * 3600, now: t0.addingTimeInterval(60), maxDuration: maxDuration)
        XCTAssertEqual(s.pausedRemaining, 2 * 3600)
        XCTAssertEqual(s.endsAt, p.endsAt, "the lease is not the end")
        XCTAssertEqual(s.extensions, [-6 * 3600])
    }

    func testWithRemainingMovesARunningSessionsEndAndClamps() {
        let s = Session(startedAt: t0, endsAt: t0.addingTimeInterval(3600))
        let now = t0.addingTimeInterval(600)
        XCTAssertEqual(SessionMath.withRemaining(s, remaining: 4 * 3600, now: now, maxDuration: maxDuration).endsAt, now.addingTimeInterval(4 * 3600))
        XCTAssertEqual(SessionMath.withRemaining(s, remaining: 30 * 3600, now: now, maxDuration: maxDuration).endsAt, now.addingTimeInterval(maxDuration))
        XCTAssertEqual(SessionMath.withRemaining(s, remaining: 5, now: now, maxDuration: maxDuration).endsAt, now.addingTimeInterval(SessionMath.minimumDuration))
        XCTAssertEqual(SessionMath.withRemaining(s, remaining: 1800, now: now, maxDuration: maxDuration).extensions, [-1200])
    }
```

`ClosedLidClockTests` (uses the class's `h`):

```swift
    func testSetRemainingWhilePausedSetsClosedTime() async throws {
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 8 * 3600)
        await m.setRemaining(2 * 3600)
        XCTAssertEqual(m.session?.pausedRemaining, 2 * 3600)
        XCTAssertEqual(try h.store.loadSession()?.pausedRemaining, 2 * 3600, "journaled")
    }
```

`ReconcileTests` (uses `h`):

```swift
    func testSetRemainingRewritesJournalAndReschedules() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        h.clock.advance(600)
        await m.setRemaining(1800)
        let s = try XCTUnwrap(m.session)
        XCTAssertEqual(s.endsAt, h.clock.now.addingTimeInterval(1800))
        XCTAssertEqual(try h.store.loadSession(), s)
        XCTAssertEqual(h.backstop.arms, 2)
        XCTAssertEqual(m.scheduledDeadline, s.endsAt)
    }
```

`RecoverySafetyTests`: copy `testEndDuringExtendMustNotResurrectSession` (line 137) as `testEndDuringSetRemainingMustNotResurrectSession`, replacing the `extend(by:)` call with `setRemaining(1800)` and keeping every assertion.

- [ ] **Step 2: Run, see them fail** — `swift test --filter 'SessionMathTests|ClosedLidClockTests|ReconcileTests|RecoverySafetyTests' 2>&1 | grep -E "error:|Executed" | tail`. Expected: compile errors for `withRemaining` / `setRemaining`.

- [ ] **Step 3: Implement**

`SessionMath`, after `extended`:

```swift
    /// The time left set to `remaining` (a lid chip), shorter or longer,
    /// within [`minimumDuration`, `maxDuration`]. A paused session's
    /// closed-lid time is set and its lease left alone; a running session's
    /// end moves to `now + remaining`. The change is recorded in
    /// `extensions` as a signed delta.
    static func withRemaining(_ session: Session, remaining: TimeInterval, now: Date, maxDuration: TimeInterval) -> Session {
        let target = clamp(remaining, maxDuration: maxDuration)
        var s = session
        if let left = session.pausedRemaining {
            s.extensions.append(target - left)
            s.pausedRemaining = target
            return s
        }
        let newEnd = now.addingTimeInterval(target)
        s.extensions.append(newEnd.timeIntervalSince(session.endsAt))
        s.endsAt = newEnd
        return s
    }
```

(`clamp(_:maxDuration:)` exists; `testClampFloorAndCeiling` pins it.)

`SessionManager`, after `extend(by:)`:

```swift
    /// Sets the closed-lid time left (a lid chip in the menu). Same
    /// sequence and guards as `extend`: a shorter deadline only brings
    /// recovery forward.
    func setRemaining(_ seconds: TimeInterval) async {
        guard session != nil else { return }
        let ticket = endTicket
        _ = await exclusive("set remaining") { await self.performSetRemaining(seconds, ticket: ticket) }
    }
```

and after `performExtend`, a `performSetRemaining(_:ticket:)` that is `performExtend` with `SessionMath.withRemaining(current, remaining: seconds, now: clock(), maxDuration: config.maxDuration)` in place of `SessionMath.extended(...)`, "set remaining abandoned: end requested meanwhile" as the abandon log, and the success log `"session time left set to \(Int(updated.closedLidRemaining(at: clock())))s" + (updated.isPaused ? " of closed-lid time (paused)" : " until \(iso(updated.endsAt))")`. Copy `performExtend`'s body line for line otherwise (backstop arm, ticket and equality re-check, `store.saveSession`, publish, `lastError = nil`, `armDeadline`, `syncLeaseTimer`).

- [ ] **Step 4: Run** the same filter. Expected: all pass.

- [ ] **Step 5: Commit** `git commit -m "Lid session: set the time left (for the menu's lid chips)"` with the trailer.

---

### Task 2: No password per lid start (stopgap)

**Files:**
- Modify: `scripts/install.sh` (comment at 265, `pmset_rule_effective` at 280, heredoc at 408–414)
- Modify: `Sources/Insomnia/Core/SleepGuard.swift` (header comment, `setSleepDisabled`)
- Modify: `scripts/uninstall.sh:774-776` (message lists the commands)
- Modify: `README.md:50-66`, `SECURITY.md:63` and `:66-67`, `docs/superpowers/specs/2026-10-14-awake-design.md` (pointer under "Phase 1: password to start")
- Test: `Tests/InsomniaTests/RecoveryScriptTests.swift:4322-4335`, `Tests/InsomniaTests/SleepGuardReadBackTests.swift`

**Interfaces:**
- Produces: `PmsetSleepGuard.passwordRequired(_ error: SleepGuardError) -> Bool` (static, internal).

- [ ] **Step 1: Failing tests**

`RecoveryScriptTests`: rename `testInstallWritesExactlyTheThreeSafeCommands` to `testInstallWritesTheFourPmsetCommands`, update its doc comment ("The rule holds the four pmset commands Ember runs. Turning sleep off without a password is the owner's accepted stopgap until the signed helper; spec 2026-10-16."), keep the first three `contains` assertions, and replace the two `XCTAssertFalse` lines with:

```swift
        XCTAssertTrue(rule.contains("NOPASSWD: /usr/bin/pmset -a disablesleep 1"), rule)
        XCTAssertTrue(fx.calls().contains("sudo -n -l /usr/bin/pmset -a disablesleep 1"), "the check covers the fourth line: \(fx.calls())")
```

`SleepGuardReadBackTests`: make the fake sudo run what it is given after `-n`, so the disable reaches the fake pmset. In `fakeGuard`, replace the sudo script body with:

```swift
        let sudo = try script("sudo", """
        printf 'sudo %s\\n' "$*" >> '\(calls)'
        [ "$1" = "-n" ] && shift
        exec "$@"
        """)
```

and `expectedCalls` with:

```swift
        ["sudo -n \(file("pmset")) -a disablesleep 1", "pmset -a disablesleep 1", "wait 5.0", "pmset -g"]
```

Add a fallback test and its fake:

```swift
    /// An install made before the fourth rule line: sudo wants a password,
    /// so the disable falls back to the administrator prompt (here the fake
    /// admin runner running pmset), and the read-back follows as before.
    func testAThreeLineRuleFallsBackToThePrompt() async throws {
        let calls = file("calls")
        let settled = file("settled")
        let sudo = try script("sudo", """
        printf 'sudo %s\\n' "$*" >> '\(calls)'
        echo 'sudo: a password is required' >&2
        exit 1
        """)
        let pmset = try script("pmset", """
        printf 'pmset %s\\n' "$*" >> '\(calls)'
        printf 'System-wide power settings:\\n SleepDisabled\\t\\t1\\n'
        """)
        let sleepGuard = PmsetSleepGuard(sudo: sudo, pmset: pmset, timeout: 5, stopGrace: 1, settleWait: { seconds in
            try Self.append("wait \(seconds)\n", to: calls)
            FileManager.default.createFile(atPath: settled, contents: nil)
        }, admin: FakeAdminRunner(pmset: pmset))
        try await disableSleep(sleepGuard)
        XCTAssertEqual(try self.calls(), ["sudo -n \(pmset) -a disablesleep 1", "pmset -a disablesleep 1", "wait 5.0", "pmset -g"])
    }

    func testOnlyAPasswordRefusalCountsAsAThreeLineRule() {
        XCTAssertTrue(PmsetSleepGuard.passwordRequired(SleepGuardError(command: "sudo -n pmset", status: 1, stderr: "sudo: a password is required\n")))
        XCTAssertFalse(PmsetSleepGuard.passwordRequired(SleepGuardError(command: "sudo -n pmset", status: 1, stderr: "pmset: something else")))
    }
```

- [ ] **Step 2: Run, see them fail** — `swift test --filter 'SleepGuardReadBackTests|RecoveryScriptTests/testInstallWritesTheFourPmsetCommands' 2>&1 | grep -E "error|Executed" | tail`. Expected: the four-line test fails on the rule text; the read-back tests fail on call order; `passwordRequired` does not compile.

- [ ] **Step 3: Implement**

`install.sh` heredoc:

```bash
cat > "$TMP_SUDOERS" <<SUDO
# Installed by Ember install.sh. The four pmset commands Ember runs. Turning
# sleep off without a password is a stopgap until the signed helper: any
# program running as $USER can use it to keep the Mac awake.
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0
SUDO
```

`pmset_rule_effective` gains `pmset_rule_check -a disablesleep 1 && ` as its first link; the comment at line 265 says "the four pmset commands". Step 2's "(requires your password once)" stays true.

`SleepGuard.swift`: the file header becomes "The only things Ember ever does as root: the four sudoers-allowed pmset commands written by install.sh, with `disablesleep 1` falling back to the administrator prompt (`AdminCommandRunning`) on an install made before that line existed." The struct comment's first sentence becomes "`sudo -n pmset …` for every command; `disablesleep 1` falls back to the administrator prompt (`admin`) when sudo wants a password." In `setSleepDisabled`, replace the `admin.runAsAdministrator` line with:

```swift
        do {
            try await sudoPmset(["-a", "disablesleep", "1"])
        } catch let error as SleepGuardError where Self.passwordRequired(error) {
            Log.info("sudoers has no passwordless disablesleep 1 line; asking for the password (run scripts/install.sh once to stop this)")
            try await admin.runAsAdministrator(Self.disableSleepCommand, prompt: Self.adminPrompt)
        }
```

and add:

```swift
    /// sudo refused for want of a password: the rule predates its fourth
    /// line. Any other failure is pmset's own and is not retried.
    static func passwordRequired(_ error: SleepGuardError) -> Bool {
        error.stderr.contains("a password is required")
    }
```

Update the doc comment of `setSleepDisabled` ("Disabling goes through `sudo -n`, or the administrator prompt on an older rule, which throws `AdminPromptCancelledError` when the person cancels it").

`uninstall.sh` message: `'sudo pmset -a disablesleep 0' / 'sudo pmset -b lowpowermode 0'` stays (it is about restoring); no change needed beyond confirming.

README `50-66`: "This one lets your user account, not just Ember, run these four commands without a password, so lid mode starts without asking. Any program running as you can use it too, including to keep the Mac awake; that is a stopgap until a signed helper replaces the rule. If you installed before October 2026, run `scripts/install.sh` once more to get the fourth line; until then lid mode asks for your password." and the code block lists `/usr/bin/pmset -a disablesleep 1` first. SECURITY.md: "the three pmset commands" → "the four pmset commands", and the sentence about the administrator prompt becomes "Starting a lid session runs `sudo -n pmset -a disablesleep 1`; on an install made before that rule line it raises the standard macOS administrator prompt instead." Add under "### Phase 1: password to start" in the 2026-10-14 spec: "> Superseded on 2026-10-16: the rule has a fourth line, `disablesleep 1`, and the prompt is a fallback (`2026-10-16-ember-menu-v2-design.md`)."

- [ ] **Step 4: Run** the Step 2 filter, then `swift test --filter RecoveryScriptTests 2>&1 | grep -E "error: -\[|Executed" | tail -3` (slow; run in the background) and `shellcheck scripts/install.sh`. Expected: all pass. Any other RecoveryScriptTests failure that pins the rule's comment or line count: update it to the four-line text and say so in the commit message.

- [ ] **Step 5: Commit** `git commit -m "Lid mode starts without a password (stopgap until the signed helper)"`.

---

### Task 3: Left-click toggles screen mode only

**Files:**
- Modify: `Sources/Insomnia/UI/StatusItemController.swift` (`ClickAction`, `clickAction`, `handle`)
- Test: `Tests/InsomniaTests/MenuBarTests.swift` (`StatusItemControllerLogicTests`)

**Interfaces:**
- Produces: `ClickAction` = `turnOnScreen | turnOffScreen | showMenu`.

- [ ] **Step 1: Failing test** — replace `testLeftClickCyclesAndModifiedClicksOpenTheMenu` with:

```swift
    /// Spec 2026-10-16 "Left-click": off ↔ screen; a lid session opens the
    /// menu; right-click and ctrl-click open it in every mode.
    func testLeftClickTogglesScreenModeAndALidSessionOpensTheMenu() {
        XCTAssertEqual(StatusItemController.clickAction(isRightClick: false, controlHeld: false, mode: .off), .turnOnScreen)
        XCTAssertEqual(StatusItemController.clickAction(isRightClick: false, controlHeld: false, mode: .screen), .turnOffScreen)
        XCTAssertEqual(StatusItemController.clickAction(isRightClick: false, controlHeld: false, mode: .lid), .showMenu)
        for mode in [StatusItemController.Mode.off, .screen, .lid] {
            XCTAssertEqual(StatusItemController.clickAction(isRightClick: true, controlHeld: false, mode: mode), .showMenu, "\(mode)")
            XCTAssertEqual(StatusItemController.clickAction(isRightClick: false, controlHeld: true, mode: mode), .showMenu, "\(mode)")
        }
    }
```

Replace `testClickCycleStartsAnEightHourSessionAndEndsIt` with a screen toggle test:

```swift
    func testClicksTurnScreenModeOnAndOff() async {
        let h = Harness()
        defer { h.home.destroy() }
        let a = FakeAwakeAssertion()
        let awake = AwakeController(assertion: a, clock: { h.clock.now })
        let c = StatusItemController(manager: h.makeManager(), status: PlaceholderStatus(), awake: awake, showSettings: {})
        defer { c.stop() }
        await c.handle(.turnOnScreen)
        XCTAssertEqual(awake.state, .on(until: nil))
        await c.handle(.turnOffScreen)
        XCTAssertEqual(awake.state, .off)
        XCTAssertFalse(a.isHeld)
    }
```

`testACancelledLidStartLeavesScreenModeOn` and `testAStartDuringThePromptIsIgnored` call `c.startLidSession(...)` instead of `c.handle(.startLid)` (replace `await c.handle(.startLid)` with `await c.startLidSession(8 * 3600)`).

- [ ] **Step 2: Run, fail** — `swift test --filter StatusItemControllerLogicTests`.

- [ ] **Step 3: Implement** — `ClickAction { case turnOnScreen, turnOffScreen, showMenu }`; `clickAction` maps `.off → .turnOnScreen`, `.screen → .turnOffScreen`, `.lid → .showMenu` after the right/ctrl check; doc comment: "Right-click and ctrl-click open the menu. A plain left click toggles screen mode; during a lid session it opens the menu, so a stray click never ends a session." `handle`: `.turnOnScreen → awake.turnOn(for: nil); refresh()`, `.turnOffScreen → awake.turnOff(reason: "user"); refresh()`, `.showMenu → break`. The class doc comment's click sentence follows.

- [ ] **Step 4: Run, pass.** **Step 5: Commit** `"Left-click toggles screen mode only; lid mode lives in the menu"`.

---

### Task 4: The header model (pure)

**Files:**
- Create: `Sources/Insomnia/UI/ModeHeader.swift`
- Test: `Tests/InsomniaTests/ModeHeaderTests.swift`

**Interfaces:**
- Produces:

```swift
enum ModeHeader {
    enum Tab: Int, CaseIterable, Equatable { case off, screen, lid }
    enum ChipAction: Equatable {
        case screenFor(TimeInterval?)   // nil: until I turn it off
        case screenCustom
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
        let caption: String
    }
    enum Transition: Equatable { case none, turnOffScreen, endLid, turnOnScreen, endLidThenTurnOnScreen, startLid }

    static let tabTitles: [String]               // ["Off", "Screen", "Lid"]
    static let screenChips: [TimeInterval?]      // [nil, 3600, 7200, 14400]
    static let lidChips: [TimeInterval]          // [3600, 7200, 14400, 28800, 43200]
    static func tab(for mode: StatusItemController.Mode) -> Tab
    static func transition(from mode: StatusItemController.Mode, to tab: Tab) -> Transition
    static func model(mode: StatusItemController.Mode, awakeEndsAt: Date?, screenChosen: TimeInterval?,
                      lidRemaining: TimeInterval?, lidPaused: Bool, lidChosen: TimeInterval?, now: Date) -> Model
}
```

- [ ] **Step 1: Failing tests** (`ModeHeaderTests.swift`):

```swift
import XCTest
@testable import Insomnia

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

    func testOffHasNoChips() {
        let m = ModeHeader.model(mode: .off, awakeEndsAt: nil, screenChosen: nil, lidRemaining: nil, lidPaused: false, lidChosen: nil, now: now)
        XCTAssertEqual(m.selected, .off)
        XCTAssertTrue(m.chips.isEmpty)
        XCTAssertEqual(m.caption, "The Mac sleeps as usual.")
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
```

- [ ] **Step 2: Run, fail** (`swift test --filter ModeHeaderTests`: no such type).

- [ ] **Step 3: Implement** `ModeHeader.swift` to the interface. Titles: `"\u{221E}"` for nil, `"\(h) h"` for hours, `"Custom\u{2026}"`; accessibility labels `"Until I turn it off"`, `StatusMenu.durationTitle(seconds)` ("1 hour", "2 hours"), `"Custom duration"`. Highlight: screen untimed (`awakeEndsAt == nil`) → ∞; timed → the chip whose length equals `screenChosen`, else Custom when `screenChosen` is non-nil and matches none; lid → the chip equal to `lidChosen`, Custom when `lidChosen` matches none, nothing when nil. Captions as in the tests (`Countdown.short`). `transition` is the table.

- [ ] **Step 4: Run, pass.** **Step 5: Commit** `"Menu header model: tabs, chips, captions, transitions"`.

---

### Task 5: The header view and its wiring; the old control items go

**Files:**
- Create: `Sources/Insomnia/UI/ModeHeaderView.swift`
- Modify: `Sources/Insomnia/UI/StatusMenu.swift` (drop `controlItems`, the control `Kind`s and their selectors; `menu(...)` takes `header: NSView?`)
- Modify: `Sources/Insomnia/UI/StatusItemController.swift` (build the header, apply tab and chip actions, remember chosen lengths, refresh the open header, generalise the Custom prompt)
- Test: `Tests/InsomniaTests/MenuBarTests.swift`, `Tests/InsomniaTests/StatusMenuWarningTests.swift`, new `Tests/InsomniaTests/ModeHeaderViewTests.swift`

**Interfaces:**
- `final class ModeHeaderView: NSView` with `init(model: ModeHeader.Model, onTab: @escaping @MainActor (ModeHeader.Tab) -> Void, onChip: @escaping @MainActor (ModeHeader.ChipAction) -> Void)` and `func update(_ model: ModeHeader.Model)`; internal `segments: NSSegmentedControl`, `chipButtons: [NSButton]`, `captionLabel: NSTextField` for tests.
- `StatusMenu.menu(_ items:, header: NSView? = nil, target:, settings:, quit:, relaunchBrowser:, stopWaitingForOutput:) -> NSMenu`; when `header` is non-nil the first item is an `NSMenuItem` whose `view` is the header, followed by a separator.
- `StatusMenu.items(mac:sessionActive:sleepHeld:throttledBrowsers:...)` (the `controls:` parameter goes).
- `StatusItemController`: `func applyTab(_ tab: ModeHeader.Tab) async`, `func applyChip(_ action: ModeHeader.ChipAction) async`, `private(set) var screenChosen: TimeInterval?`, `private(set) var lidChosen: TimeInterval?`; `askDurationText` becomes `@MainActor (DurationPrompt) -> String?` with `enum DurationPrompt { case screen, lid }`.

- [ ] **Step 1: Failing tests**

`ModeHeaderViewTests.swift`:

```swift
import AppKit
import XCTest
@testable import Insomnia

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
        v.segments.sendAction(v.segments.action, to: v.segments.target)
        XCTAssertEqual(tabs, [.lid])
        XCTAssertEqual(v.segments.selectedSegment, ModeHeader.Tab.screen.rawValue, "the view waits for the real mode")
        v.chipButtons[2].performClick(nil)
        XCTAssertEqual(chips, [.screenFor(7200)])

        let off = ModeHeader.model(mode: .off, awakeEndsAt: nil, screenChosen: nil, lidRemaining: nil, lidPaused: false, lidChosen: nil, now: now)
        v.update(off)
        XCTAssertEqual(v.segments.selectedSegment, 0)
        XCTAssertTrue(v.chipButtons.allSatisfy(\.isHidden))
        XCTAssertGreaterThan(v.fittingSize.width, 200)
    }
}
```

In `MenuBarTests.swift`: delete `StatusMenuControlTests`' control-item tests (`testIdleControls`, `testTheOneClickLidItemReadsTheSetting`, `testTimedAwakeShowsTimeLeft`, `testLidSessionControls`, `testPausedLidSessionSaysTheClockWaitsForTheLid`); rewrite `testControlsThenMacBlockThenSettings` as `testMacBlockThenSettings` (no controls: the expected kinds start at `.header`); rewrite `testMenuBuildsSubmenusHeadersAndSymbols` as `testMenuPutsTheHeaderViewFirst`:

```swift
    @MainActor
    func testMenuPutsTheHeaderViewFirst() {
        let s = #selector(NSObject.description)
        let header = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
        let mac = StatusMenu.macLines(battery: "Battery 68%", batterySymbol: "battery.75percent", thermal: "Temperature normal", wifi: nil, hotspot: nil, whileClosed: nil)
        let menu = StatusMenu.menu(StatusMenu.items(mac: mac, sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: nil),
                                   header: header, target: nil, settings: s, quit: s, relaunchBrowser: s, stopWaitingForOutput: s)
        XCTAssertTrue(menu.items[0].view === header)
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertTrue(menu.items[2].isSectionHeader)
        XCTAssertNil(menu.items[3].attributedTitle, "status lines keep the menu's own font")
    }
```

Controller tests in `StatusItemControllerLogicTests`:

```swift
    /// Spec "Tabs": each move against a real manager (review focus 4: the
    /// screen hold folds in once and nothing is left held).
    func testTabsSwitchModes() async {
        let h = Harness()
        defer { h.home.destroy() }
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        let a = FakeAwakeAssertion()
        let awake = AwakeController(assertion: a, clock: { h.clock.now })
        let c = StatusItemController(manager: m, status: PlaceholderStatus(), awake: awake, showSettings: {})
        defer { c.stop() }

        await c.applyTab(.screen)
        XCTAssertEqual(awake.state, .on(until: nil))
        await c.applyTab(.lid)
        c.stateChanged()
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.session?.closedLidRemaining(at: h.clock.now) ?? 0, 8 * 3600, accuracy: 1)
        XCTAssertEqual(awake.state, .off)
        XCTAssertTrue(a.isHeld, "lid open: the screen stays on")
        await c.applyTab(.screen)
        c.stateChanged()
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(awake.state, .on(until: nil))
        await c.applyTab(.off)
        XCTAssertEqual(awake.state, .off)
        XCTAssertFalse(a.isHeld)
    }

    func testChipsSetLengths() async {
        let h = Harness()
        defer { h.home.destroy() }
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        let awake = AwakeController(assertion: FakeAwakeAssertion(), clock: { h.clock.now })
        let c = StatusItemController(manager: m, status: PlaceholderStatus(), awake: awake, showSettings: {})
        defer { c.stop() }
        await c.applyTab(.screen)
        await c.applyChip(.screenFor(7200))
        XCTAssertEqual(awake.endsAt, h.clock.now.addingTimeInterval(7200))
        XCTAssertEqual(c.screenChosen, 7200)
        await c.applyTab(.lid)
        await c.applyChip(.lidRemaining(2 * 3600))
        XCTAssertEqual(m.session?.pausedRemaining, 2 * 3600)
        XCTAssertEqual(c.lidChosen, 2 * 3600)
    }

    /// Review focus 5: a chip for a mode that has ended does nothing.
    func testAStaleChipIsIgnored() async {
        let h = Harness()
        defer { h.home.destroy() }
        let m = h.makeManager()
        let awake = AwakeController(assertion: FakeAwakeAssertion(), clock: { h.clock.now })
        let c = StatusItemController(manager: m, status: PlaceholderStatus(), awake: awake, showSettings: {})
        defer { c.stop() }
        await c.applyChip(.lidRemaining(3600))
        XCTAssertFalse(m.isActive, "no session is started by a lid chip")
        await c.applyChip(.screenFor(3600))
        XCTAssertEqual(awake.state, .off, "no screen mode is started by a screen chip")
    }

    /// Review focus 1: a cancelled lid start from the Lid tab leaves the
    /// header on the real mode.
    func testACancelledLidTabLeavesTheModeWhereItWas() async {
        let h = Harness()
        defer { h.home.destroy() }
        h.guardFake.cancelDisable = true
        let m = h.makeManager()
        let awake = AwakeController(assertion: FakeAwakeAssertion(), clock: { h.clock.now })
        let c = StatusItemController(manager: m, status: PlaceholderStatus(), awake: awake, showSettings: {})
        defer { c.stop() }
        await c.applyTab(.screen)
        await c.applyTab(.lid)
        XCTAssertEqual(StatusItemController.mode(lidActive: m.isActive, awake: awake.state), .screen)
        XCTAssertEqual(c.headerModel(now: h.clock.now).selected, .screen)
    }
```

Update `testAnUnreadableCustomDurationShowsANotice` for the new prompt signature (`askDurationText: { _ in typed.value }`, `c.customDuration(.lid)`).

`StatusMenuWarningTests`: no `controls:` argument is used there; it keeps compiling once the parameter is dropped (its calls pass none). Confirm with the build.

- [ ] **Step 2: Run, fail** (`swift test --filter 'ModeHeaderViewTests|StatusItemControllerLogicTests|StatusMenu'`).

- [ ] **Step 3: Implement**

`ModeHeaderView`: a vertical `NSStackView` (spacing 6, edge insets 8/14/8/14, matching menu item insets) of: the `NSSegmentedControl(labels: ModeHeader.tabTitles, trackingMode: .selectOne, target: self, action: #selector(tabChanged))`, full width, `controlSize = .regular`, each segment's `setToolTip` and accessibility label = its title; a horizontal `NSStackView` of chip buttons (`NSButton(title:target:action:)`, `bezelStyle = .recessed`, `setButtonType(.pushOnPushOff)`, `controlSize = .small`, `tag` = index), rebuilt by `update` when the chip set changes (compare titles), states set from `isSelected`; an `NSTextField(labelWithString:)` caption, `.secondaryLabelColor`, `NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)`. `tabChanged` reads the new segment, restores the segment to the model's `selected` (the view waits for the real mode), then calls `onTab`. A chip click restores its state from the model, then calls `enclosingMenuItem?.menu?.cancelTracking()` and `onChip`. `update(_:)` stores the model and applies selection, chips (hidden when empty), caption. The frame width is `max(fittingSize.width, 260)`; set `translatesAutoresizingMaskIntoConstraints = true` on the root and `frame.size = fittingSize` after each update so `NSMenuItem.view` sizes correctly.

`StatusMenu`: remove `controlItems`, `awakeDurations`, `lidDurations`, the `Kind` cases `toggleAwake`, `awakeFor`, `startLid`, `extendLid`, `endLid`, `submenu` and their `build` branches and optional selectors; keep `durationTitle` (Settings uses it). `items` loses `controls:` (its `sections` start with the Mac block). `menu(...)` gains `header: NSView? = nil` and inserts it as described.

`StatusItemController`:
- `headerModel(now:) -> ModeHeader.Model` from `mode`, `awake.endsAt`, `screenChosen`, `manager.session?.closedLidRemaining(at:)`, `isPaused`, `lidChosen`.
- `private weak var openHeader: ModeHeaderView?`; `showMenu()` builds `ModeHeaderView(model: headerModel(now: clock()), onTab: { [weak self] t in Task { @MainActor in await self?.applyTab(t) } }, onChip: { [weak self] a in Task { @MainActor in await self?.applyChip(a) } })`, stores it in `openHeader`, passes it to `StatusMenu.menu(header:)`, and clears `openHeader` after `popUp` returns. `refresh()` ends with `openHeader?.update(headerModel(now: clock()))`.
- `applyTab(_:)`: switch `ModeHeader.transition(from: mode, to: tab)`: `.turnOnScreen` → `awake.turnOn(for: nil)`, `screenChosen = nil`; `.turnOffScreen` → `awake.turnOff(reason: "user")`; `.startLid` → `lidChosen = manager.config.lidClickDuration; await startLidSession(lidChosen!)`; `.endLid` → `_ = await manager.end(reason: .user)`; `.endLidThenTurnOnScreen` → end, then if `!manager.isActive` turn screen on; `.none` → nothing. Then `refresh()`. Reset `lidChosen = nil` whenever the mode leaves lid and `screenChosen = nil` when it leaves screen (in `stateChanged`, comparing with a stored last mode).
- `applyChip(_:)`: `.screenFor(d)` only when mode is `.screen` → `awake.turnOn(for: d)`, `screenChosen = d`; `.lidRemaining(d)` only when `.lid` → `await manager.setRemaining(d)`, `lidChosen = d`; `.screenCustom` / `.lidCustom` → on the next main-queue turn (`DispatchQueue.main.async`, so the alert never runs inside menu tracking) ask `customDuration(.screen | .lid)` and apply as the matching chip (lid capped at `Config.lidMaxDuration`). Then `refresh()`.
- `DurationPrompt` and the injected `askDurationText: @MainActor (DurationPrompt) -> String?`; `askCustomDurationText(_:)` uses "Keep the screen awake for how long?" / "Keep awake with the lid closed for how long?" and, for lid, "The most is 24 hours."; `customDuration(_ kind: DurationPrompt)`.
- Delete `menuToggleAwake`, `menuAwakeFor`, `menuStartLid`, `menuExtendLid`, `menuEndLid` and their selector arguments.

- [ ] **Step 4: Run** `swift build 2>&1 | grep -E "error|warning:"` then `swift test --filter 'ModeHeader|StatusItemControllerLogicTests|StatusMenu|MenuBarTests|IntegrationWiringTests|LidActionsTests|LidSimulationTests'`. Fix any remaining call sites that passed `controls:` or used the removed kinds.

- [ ] **Step 5: Commit** `"Menu: Off | Screen | Lid tabs with quick-time chips replace the control items"`.

---

### Task 6: Settings text, README, spec pointers

**Files:** `Sources/Insomnia/UI/SettingsView.swift` (`modesSection`), `README.md` ("Using it"), `docs/superpowers/specs/2026-10-15-ember-menu-and-click-design.md` (pointer at the top of "Left-click" and "The menu").

- [ ] **Step 1:** `modesSection` text: "Click the menu bar icon to turn screen mode on and off. Lid mode starts from the menu's Lid tab."; picker label "Lid mode starts for".
- [ ] **Step 2:** README: left-click bullet → "turns screen mode on and off ("until I turn it off"); during a lid session it opens the menu." Right-click bullet: replace the control lines with "At the top, **Off | Screen | Lid**: click one to switch. Under it, quick times for the running mode (screen: until I turn it off, 1, 2 or 4 hours, Custom; lid: 1 to 12 hours, Custom, which set the closed-lid time left)." Keep the Mac block, warnings and Settings/Quit lines. Change "The length of the one-click lid mode is under Settings → Modes" to "The length the Lid tab starts with is under Settings → Modes (1 to 24 hours)."
- [ ] **Step 3:** In the 2026-10-15 spec, under "## Left-click" and "## The menu": "> Superseded on 2026-10-16 by `2026-10-16-ember-menu-v2-design.md` (click toggles screen only; tabs and chips replace the control items)."
- [ ] **Step 4:** `swift build`; commit `"docs and Settings: the tabs, the screen-only click"`.

---

### Task 7: Verify, review, ship

- [ ] **Step 1:** `swift build -c release -Xswiftc -warnings-as-errors`, `scripts/test-fast.sh`, `scripts/smoke-test.sh`, `scripts/check-lid-simulation-gate.sh`, `shellcheck scripts/*.sh`. All green, or fix.
- [ ] **Step 2:** The smoke test starts lid mode through test-control's `lid-start` command (`scripts/smoke-test.sh:228`), not through clicks, so the click change leaves it alone; if it fails, the cause is elsewhere: investigate, do not edit the test to pass.
- [ ] **Step 3:** Self-review (fresh agent, same brief as 2026-10-15) and `codex-companion.mjs review --wait --base main --scope branch`. Fix confirmed findings with tests; record dropped ones.
- [ ] **Step 4:** Push `menu-v2`, open the PR with `gh pr create` (body ends with the Claude Code line). Wait for CI. Merge only on the owner's yes, locally: `git checkout main && git merge --no-ff menu-v2 && git push origin main`, then delete the branch.
- [ ] **Step 5:** Owner installs (`./scripts/install.sh`, writes the fourth rule line) and tries: the Lid tab starts without a password; Screen chips; Lid chips change the caption; Off ends it; left-click toggles screen only.
