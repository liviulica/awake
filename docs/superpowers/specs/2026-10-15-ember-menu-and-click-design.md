# Ember: one-click modes, a readable menu, a matching lid icon

Date: 2026-10-15. Status: approved by the owner in conversation (icon, click
cycle and 8 h setting; menu structure A; symbols on menu lines).

Supersedes the "Menu bar icon" lid row and the "Interaction" section of
`2026-10-14-awake-design.md`. Everything else in that spec stands.

## Why

After the first day on a real Mac, three things stood out:

1. The lid-mode icon (a small flame on a line) reads lighter and smaller
   than the other two states; it looks like a different family.
2. Starting lid mode takes a right-click, a submenu and a duration pick
   before the password prompt. The owner wants it one click away, 8 h by
   default.
3. The right-click menu is a list of small grey lines in Insomnia's internal
   vocabulary ("Sleep held per journal — not verified live", "0.0 W",
   "throttled"). Hard to read, and it does not say what to do.

Research: Apple's HIG asks a menu bar extra to "display a menu, not a
popover", drawn with symbol-like template images on the 24 pt bar. Caffeine
and KeepingYouAwake both toggle on left-click and keep durations and
preferences in the right-click menu; Amphetamine leads its menu with
quick-start presets and "End Session". Upstream Insomnia went the other way
(an inline pill entry and a popover) and spent a whole spec on the jank that
caused. Ember keeps the plain `NSMenu` and fixes the content.

## Menu bar icon

Only the lid state changes. The small flame grows from 0.6 to about 0.78 of
the full flame, its bottom point at (12, 17.2) in the 24-unit grid; the lid
line thickens from 2.2 to 2.6 and shortens to x 3.5–20.5, so the glyph has
the mass of the filled flame. The exact numbers are tuned on a side-by-side
render of the three states at 1x and 2x; the test pins the intent, not the
decimals: the lid flame's bounds are at least 75% of the full flame's height,
and the lid line is at least as thick as the outline stroke (1.7).
Accessibility descriptions do not change.

## Left-click: off → screen → lid → off

| From | Left-click does | Notes |
|---|---|---|
| Off | Screen mode on, until turned off | As today. |
| Screen mode (timed or not) | Start a lid session for the click duration | The administrator prompt appears. Cancel or a failed start leaves screen mode on. A failed start shows its reason in the menu, as for a menu start today; a cancel is the person's own choice and shows nothing. |
| Lid session (clock running or paused with the lid open) | End the session | Sleep restored, screen hold released, state off. One stray click ends a session; the owner accepted this cost (the next start is another password prompt). "End now" in the menu remains the deliberate route. |

Right-click and ctrl-click open the menu in every state. The decision is a
pure function `clickAction(isRightClick:controlHeld:mode:)` returning
`.turnOnScreen`, `.startLid`, `.endLid` or `.showMenu`, where `mode` is
`.off`, `.screen` or `.lid`. The menu bar title (the countdown) is unchanged.

## The click duration

- New config key `lidClickDuration: TimeInterval`, default 8 h, allowed
  values 1, 2, 4, 8, 12 and 24 h, always capped at `Config.lidMaxDuration`.
- `presets` and `defaultPreset` were never read by Ember and go, together
  with `chipLabel` (their only helper). `Config.init(from:)` reads keys with
  `decodeIfPresent`, so a config.json that still carries them, or lacks the
  new key, loads fine. The owner's installed config has no `lidClickDuration`
  and gets 8 h.
- Settings gains a "Modes" section at the top: one line, "Click the menu bar
  icon to cycle: off, screen awake, lid closed, off.", and a picker "Lid
  mode on click" with the six durations.

## The menu

Standard `NSMenu`, `autoenablesItems` off. Rules:

- Every line at the menu's normal size. No attributed small font.
- `NSMenuItem.sectionHeader(title:)` for the "Mac" header.
- Status lines are disabled items. Warnings are disabled items in
  `systemOrange` with a warning symbol, shown only when something needs a
  decision, and the item that resolves them comes right after.
- Each line carries an SF Symbol in `NSMenuItem.image`
  (`NSImage(systemSymbolName:accessibilityDescription:)`). A nil image, on a
  macOS without that symbol, means no image: never a crash, never a gap in
  the text.
- Keyboard equivalents stay: Settings ⌘, and Quit ⌘Q.

### Off, or screen mode

```
[flame]           Keep screen awake                 ✓ when on; "· 2:00 left" when timed
[flame]           Keep screen awake for           ▸ Until I turn it off · 1 hour · 2 hours · 4 hours
[laptopcomputer]  Lid closed for 8 hours            from lidClickDuration; one click, then the password prompt
[laptopcomputer]  Lid closed for                  ▸ 1 hour · 2 hours · 4 hours · 8 hours · 12 hours · Custom…
──────────
MAC
[battery.N]       Battery 68%, charging             battery.0/25/50/75/100percent by level; ".bolt" when charging; omitted when unknown
[thermometer]     Temperature normal                normal / warm / hot / critical
[wifi]            Wi-Fi: Home                       or "Wi-Fi on · name needs Location access"; omitted when nothing is known
[personalhotspot] Hotspot failover: iPhone          only when a hotspot SSID is configured
──────────
[gearshape]       Settings…                      ⌘,
                  Quit Ember                     ⌘Q
```

### Lid session running

```
[laptopcomputer]  Lid mode · 7:12 left              "· lid open, clock paused" appended while paused
[plus]            Add 1 hour
[stop]            End now
──────────
MAC
[moon.zzz]        Sleep off while the lid is closed
[battery.N]       Battery 57%, charging
[thermometer]     Temperature normal
[wifi]            Wi-Fi: Home · last outage 12 s    the outage part only when lastGap > 0
[personalhotspot] Hotspot failover: iPhone
[pause]           While closed: 2 apps frozen · audio muted · Low Power Mode    only the parts that apply; omitted when none
──────────
[warning]         Arc pauses hidden tabs; agents in it may stall      one pair per throttled browser
                  Relaunch Arc without throttling…
[warning]         Speakers still muted (not connected)
                  Stop waiting for Speakers
──────────
[gearshape]       Settings…                      ⌘,
                  Quit Ember                     ⌘Q
```

The sleep line reflects the journal (`RuntimeState.sleepDisabledByUs`), as
today, and keeps its three cases:

| Session | Journal says held | Line |
|---|---|---|
| yes | yes | "Sleep off while the lid is closed" (status) |
| yes | no | warning: "Sleep is not off: this session is not keeping the Mac awake" |
| no | yes | warning: "Sleep is still off with no session running" |

Other warnings keep their current sentences from `SessionManager`
(`lastError`, `commandWarning`, `foreignSleepWarning`), the hotspot-password
line and the test-build marker, now with the warning symbol instead of the
"⚠" character. Every warning sits in the warning section, after the Mac
block.

Dropped from the menu: the watts reading (and `instantWatts()` is no longer
called when the menu opens), "N apps frozen · last gap" as a bare line, and
the words "throttled", "journal", "verified live".

The "While closed" line needs what the journal holds: frozen count from the
status source, muted from `savedAudioOutputs` being non-empty, Low Power Mode
from `lowPowerSetByUs`. It is visible in practice only on a closed Mac with an
external display, or in the seconds after a lid open before restore ends.

## Documentation

- README "Using it": the click cycle, the one-click lid item, the menu as
  above.
- `2026-10-14-awake-design.md`: a one-line pointer at the top of "Interaction"
  and in the icon table to this spec.
- `docs/lid-close.md` is unchanged (the actions are the same).

## Testing

- `MenuBarIconTests`: lid flame bounds ≥ 75% of the full flame's height; lid
  line width ≥ 1.7.
- `StatusItemController.clickAction`: the full table (3 modes × right-click ×
  ctrl).
- `Config`: default `lidClickDuration` is 8 h; a JSON with `presets` and
  `defaultPreset` and no `lidClickDuration` decodes; the setting round-trips.
- `StatusMenu`: control items in both states read as above, with the click
  duration in the one-click title; the Mac block omits unknown parts; the
  symbol names on each kind; warnings only when their input is present and
  each followed by its action; the sleep line's three cases.
- `StatusLines`: battery, temperature, Wi-Fi, hotspot and "While closed"
  wording.
- Existing suites keep passing (`scripts/test-fast.sh`, smoke test, the
  lid-simulation gate, shellcheck).

## Out of scope

- A custom header view in the menu (approach B). Can be added above the
  items later without redoing them.
- Phone push for session end (liviulica/ember#1).
- The notification permission (denied on this Mac; a System Settings matter).
- Changing what the countdown next to the icon shows.
