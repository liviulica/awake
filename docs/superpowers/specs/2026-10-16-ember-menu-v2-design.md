# Ember menu v2: mode tabs, quick times, a click that only toggles the screen, no password per start

Date: 2026-10-16. Status: directions approved by the owner in conversation
(tabs with quick times; left-click toggles off and screen only; the
passwordless `disablesleep 1` line, trade-off accepted). This written spec
awaits the owner's review.

Supersedes, in `2026-10-15-ember-menu-and-click-design.md`: "Left-click",
"The click duration" (renamed, same key) and the control items of "The menu".
The Mac block, the warnings, the symbols and the lid icon stay as they are.
Supersedes "Phase 1: password to start" in `2026-10-14-awake-design.md`.

## Why

From the owner, after a day with the 2026-10-15 menu:

1. "I don't understand the double settings line." Each mode had a one-click
   item and a look-alike submenu ("Lid closed for 8 hours" and "Lid closed
   for ›").
2. Entering the administrator password at every lid start is annoying.
3. Cycling off → screen → lid on left-click "is not great"; cycle off and
   screen (caffeinate) only.
4. Tabs in the menu for off, screen on and lid closed, so switching is one
   click, with quick time settings underneath; screen mode gets Custom too.

## Left-click

Off ↔ screen mode ("until I turn it off"), Caffeine style. During a lid
session a left-click opens the menu, as before the 2026-10-15 change, so a
stray click never ends a session. Right-click and ctrl-click open the menu in
every state. A double-click stays one step.

`StatusItemController.ClickAction` becomes `turnOnScreen`, `turnOffScreen`,
`showMenu`. `clickAction(isRightClick:controlHeld:mode:)` maps off →
`turnOnScreen`, screen → `turnOffScreen`, lid → `showMenu`. The lid-start
in-flight guard stays (the tabs can still start a lid session).

## The menu's top: mode tabs and quick times

One custom view (`NSMenuItem.view`), built in AppKit (`NSStackView`,
`NSSegmentedControl`, recessed `NSButton`s) rather than SwiftUI hosting,
because AppKit controls track mouse and keyboard reliably inside a menu.
Below it, the existing Mac block, warnings, Settings and Quit, unchanged.

```
 ┌───────────────────────────────────────────────┐
 │ [   Off   |  Screen  |   Lid   ]              │   segmented, full width
 │  ∞   1 h   2 h   4 h   Custom…                │   chips for the selected mode
 │  Until you turn it off                        │   caption
 └───────────────────────────────────────────────┘
 ────────
 MAC
 …
```

**Tabs** show the current mode and switch it at once:

| Tab clicked | From off | From screen | From lid |
|---|---|---|---|
| Off | nothing | screen mode off | end the lid session (sleep restored) |
| Screen | screen mode on, until turned off | nothing | end the lid session, then screen mode on |
| Lid | start a lid session for the default length | start it; screen mode folds in (as today) | nothing |

A lid start that fails or is cancelled leaves the tab on the mode the Mac is
actually in. The segmented control always mirrors the real state
(`StatusItemController.mode`), never the last click.

**Chips** belong to the selected mode:

- Off: no chips. Caption: "The Mac sleeps as usual."
- Screen: `∞` (until I turn it off), `1 h`, `2 h`, `4 h`, `Custom…`. A click
  (re)starts screen mode for that long. The chip matching the current mode is
  highlighted (`∞` when untimed, the length last chosen when timed). Caption:
  "Until you turn it off" or "2:00 left".
- Lid: `1 h`, `2 h`, `4 h`, `8 h`, `12 h`, `Custom…`. A click sets the
  closed-lid time left to that length (shorter or longer; capped at 24 h).
  The chip last chosen this session is highlighted. Caption: "7:12 of
  closed-lid time left", plus " · lid open, clock paused" while paused.

`Custom…` opens the existing duration prompt ("90m, 3h or 1h30m"); for
screen mode the same prompt with screen-mode wording and no 24 h ceiling
other than the parser's.

Clicking a tab keeps the menu open, so a chip can follow. Clicking a chip
closes it. Esc and a click outside close it as usual. The caption's countdown
redraws on the existing 30 s tick, which runs in the menu's tracking mode
(`.common`).

**Accessibility:** the segmented control's segments carry their labels; each
chip is a button with its full label ("1 hour", "Until I turn it off").
Keyboard: Tab moves between the control and the chips, arrows move within the
segmented control, Space/Return activates.

**Removed from the menu:** "Keep screen awake", "Keep screen awake for ›",
"Lid closed for <default>", "Lid closed for ›", "Lid mode · time left",
"Add 1 hour", "End now". Their jobs are the tabs and chips.

## Setting a lid session's time left

New `SessionManager.setRemaining(_ seconds: TimeInterval) async`, run through
`exclusive` like `extend`, built on a new pure
`SessionMath.withRemaining(_:remaining:now:maxDuration:) -> Session`:

- paused session: `pausedRemaining = clamp(seconds)`; the lease is untouched;
- running session: `endsAt = now + clamp(seconds)`;
- `clamp` keeps it within [`SessionMath.minimumDuration`, `maxDuration`];
- the change is appended to `extensions` as a signed delta.

Same sequence as `performExtend`: confirm the backstop is armed, save the
session, publish, re-arm the deadline and the lease timer. A shorter deadline
only brings recovery forward, so no new safety case arises.

## The default lid length

`Config.lidClickDuration` keeps its key (configs stay compatible) and now
means the length the Lid tab starts with. Settings → Modes:

- Text: "Click the menu bar icon to turn screen mode on and off. Lid mode
  starts from the menu's Lid tab."
- Picker: "Lid mode starts for" with 1, 2, 4, 8, 12, 24 hours.

## No password per start (stopgap until phase 2)

The owner accepted the trade-off on 2026-10-15: any process running as the
owner can then turn sleep off without a prompt. It is not a privilege
escalation (the worst case is a Mac kept awake, for example hot in a bag),
and Ember's safety nets do not cover a session it did not start, though its
"Sleep is disabled by something other than Ember" warning still appears. The
proper fix, a signed SMAppService helper, is phase 2
(atelier inbox `2026-10-15-ember-phase-2-signing-helper-updater`).

- `install.sh` writes a fourth line,
  `$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1`, updates the
  file's comment, and `pmset_rule_effective` checks all four.
- `SleepGuard.setSleepDisabled(true)` runs `sudo -n /usr/bin/pmset -a
  disablesleep 1` (inside the recovery lock, through the same bounded runner
  as the other three). Only when sudo refuses for want of a password (an
  install made before this change) does it fall back to the administrator
  prompt, unchanged. The read-back after the settle delay is unchanged.
- `uninstall.sh` removes the whole file as today; its messages that list the
  commands are updated.
- Docs: README (no password per start; re-run `install.sh` once to get the
  new line), SECURITY.md, `docs/recovery.md`, and a pointer in
  `2026-10-14-awake-design.md` "Privileges".

The owner's installed rule has three lines until `install.sh` runs again;
until then the fallback keeps lid mode working with the prompt.

## Testing

- `clickAction`: off → turnOnScreen, screen → turnOffScreen, lid → showMenu;
  right-click and ctrl-click → showMenu in every mode.
- The tab table: each cell against a real `SessionManager` with the harness
  (including a cancelled lid start leaving the mode where it was).
- Chips: screen chips (re)start screen mode with the right length; lid chips
  call `setRemaining`; highlight rules; Off shows none.
- `SessionMath.withRemaining`: paused and running, shorter and longer, both
  clamps, the extensions delta.
- `SessionManager.setRemaining`: persists, re-arms, abandons when an end is
  requested meanwhile (same shape as the extend tests).
- `SleepGuard`: `sudo -n` succeeds → no prompt; sudo refuses for a password
  → prompt fallback; the prompt's cancel still maps to
  `AdminPromptCancelledError`.
- Recovery and installer script tests that pin the rule's lines: four lines,
  the check covers four.
- The view: built in a test (no menu shown); the segmented control's
  selection follows the mode; chip titles per mode.
- Full suite, smoke test, gate, shellcheck; then the owner installs and runs
  `install.sh` (writes the new rule line) and tries the tabs.

## Out of scope

- The signed helper, notarization and an auto-updater (phase 2, joint).
- Changing the Mac block, the warnings or the icon.
- Renaming the SwiftPM product from Insomnia to Ember (separate small PR,
  offered).
