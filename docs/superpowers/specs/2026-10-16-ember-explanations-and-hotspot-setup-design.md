# Ember: mode explanations, a lid screen toggle, guided hotspot setup

Date: 2026-10-16. Status: design approved by the owner in conversation
(step-by-step setup window; the toggle defaults to on). This written spec
awaits the owner's review.

Builds on `2026-10-16-ember-menu-v2-design.md` (the Off | Screen | Lid
header). Nothing here changes the Mac block's other lines, the warnings or
the icon.

## Why

From the owner, using the merged menu v2:

1. "It's not clear how to set up the hotspot": the only place is a bare
   section at the bottom of Settings (a name field, a password field, a
   Location status), and nothing says the iPhone only advertises its
   hotspot while its Personal Hotspot screen is open.
2. Each mode needs a short sentence saying what it does, like "The Mac
   sleeps as usual". Lid mode also keeps the screen on while the lid is
   open; say so, and let the owner turn that off.
3. Earlier: the Wi-Fi line's "name needs Location access" was unclear, and
   it only matters once a hotspot is set up.

## 1. Mode explanations

`ModeHeader.Model` gains `explanation: String`, shown under the tabs above
the existing caption (which becomes the status line). The explanation
follows the selected tab; while a lid start runs (Lid selected early), the
Lid explanation shows.

| Tab | Explanation |
|---|---|
| Off | "The Mac sleeps as usual." |
| Screen | "Keeps the Mac and its screen awake. Closing the lid still puts it to sleep." |
| Lid, screen toggle on | "Keeps the Mac running with the lid closed. While the lid is open, the screen stays on too." |
| Lid, screen toggle off | "Keeps the Mac running with the lid closed. While the lid is open, the screen sleeps as usual." |

Status lines (the former caption): Off has none; Screen "Until you turn it
off" or "2:00 left"; Lid "7:12 of closed-lid time left", plus " · lid open,
clock paused" while paused; a lid start "Starting lid mode…".
("The Mac sleeps as usual." moves from the caption to Off's explanation.)

Each segment's tooltip and accessibility help is its tab's explanation, so
a mode can be read before it is chosen. `ModeHeader.explanation(for:lidKeepsScreenOn:)`
is the single source for both.

## 2. "Lid mode keeps the screen on while the lid is open"

- New config key `lidKeepsScreenOn: Bool`, default `true` (today's
  behaviour). Missing in an older config.json: `true`.
- Settings → Modes gets the toggle, worded as the key.
- `AwakeController` holds the lid-session screen assertion only when the
  setting is on: `syncLidHold` wants `lidSessionActive && sessionLidOpen &&
  !lidClosedByEvent && keepsScreenOn`. The controller reads the setting
  through an injected `@MainActor () -> Bool`, so a change takes effect at
  the next state change; Settings calls `awake.settingsChanged()` after a
  change so it applies at once.
- With it off, a lid session still disables sleep; only the display is left
  to its own idle timer while the lid is open. Folding a running screen
  mode into a lid session is unchanged (screen mode still ends when a lid
  session starts).

## 3. Hotspot setup

### Where it starts

- **The menu header:** when the selected tab is Lid and no hotspot is
  configured (`HotspotSSID.normalized(config.hotspotSSID)` is empty), a
  small borderless button "Set up hotspot failover…" sits under the status
  line. Clicking it closes the menu and opens the setup window. With a
  hotspot configured there is no button; the Mac block's "Hotspot
  failover: <name>" line stays.
- **Settings → Network failover:** a "Set up…" button at the top of the
  section opens the same window. The plain fields stay for later edits.

### The Wi-Fi line

`StatusLines.wifi` gains `hotspotConfigured: Bool`. Without a hotspot the
Location hint is not shown: the line reads "Wi-Fi on" when the name is
hidden (and "Wi-Fi: <name>" when known). With a hotspot it stays as today
("Wi-Fi on · name needs Location access").

### The setup window

Its own small window (`HotspotSetupWindow`, an `NSWindow` hosting a SwiftUI
view, opened and brought forward like `SettingsWindow`), one step at a
time, with Back and Continue. A pure model, `HotspotSetup`, holds the step,
the choices and what Continue does; the view only draws it.

**Step 1 of 3: Wi-Fi names.**
"macOS hides Wi-Fi network names from apps unless they have Location
access. Ember uses it only to see network names, never your location."
- Status from `LocationPermission`: Allowed / Not requested / Denied.
- "Allow" (not requested) calls `requestWhenInUse()`; "Open Location
  Services" (denied) opens the pane.
- Continue is always enabled; without Location, step 2 says names cannot be
  listed and offers only the text field.

**Step 2 of 3: Your hotspot.**
"On your iPhone, open Settings → Personal Hotspot, turn on Allow Others to
Join, and keep that screen open while you choose it here."
- A list of the network names Ember sees (a CoreWLAN scan of all networks
  on the Wi-Fi interface, names de-duplicated and sorted, the current
  network marked), with a Rescan button. Scanning runs off the main actor;
  a failed scan shows its error under the list.
- "Not listed? Type its name:" text field.
- Continue is enabled once a name is picked or typed (trimmed, non-empty).
  Picking fills the field.
- A second line: "On this Mac: System Settings → Wi-Fi → Ask to join
  hotspots: Automatically" (the README's existing requirement), with a
  button that opens the Wi-Fi settings pane.

**Step 3 of 3: Password.**
"The hotspot's password, from the same iPhone screen. It is kept in your
login Keychain."
- A secure field, saved through `HotspotSecretStore.save` (the same store
  Settings uses), and the toggle "Also use it in screen mode"
  (`awakeHotspotFailover`).
- Continue ("Save") writes `config.hotspotSSID`, the toggle, and the
  password; a store error stays on this step with its message. An empty
  password is allowed only when the person confirms the hotspot has none
  (a checkbox "This hotspot has no password").

**Done.**
"Hotspot failover is set up. When Wi-Fi drops during a lid session, Ember
joins <name>, and switches back when your Wi-Fi returns." Button: Done
(closes the window).

Closing the window early saves nothing. Opening it again starts at step 1
with the current values filled in.

## Testing

- `ModeHeader`: explanations per tab and per toggle; status lines; the
  starting state shows the Lid explanation; tooltips come from the same
  function.
- `ModeHeaderView`: explanation and status labels; the setup button shows
  only for Lid without a hotspot, and calls its handler.
- `Config`: `lidKeepsScreenOn` defaults to true, decodes missing as true,
  round-trips.
- `AwakeController`: with the setting off, a lid session with the lid open
  holds no assertion; turning it back on holds it at the next change; screen
  mode itself is unaffected.
- `StatusLines.wifi`: the hint only with a hotspot configured.
- `HotspotSetup` model, with a fake scanner, a fake secret store and a
  permission stand-in: step order; Continue enabled rules; scan results
  de-duplicated, sorted, current marked; a scan error; Save writes the SSID,
  the toggle and the password; a store error stays on step 3; the
  no-password checkbox; Back keeps choices; reopening starts at step 1 with
  current values.
- Full suite, smoke test, gate, shellcheck; the owner tries the window.

## Out of scope

- Detecting the iPhone automatically, or a "test failover now" button.
- Changing how failover itself works.
- Phase 2 (signing, helper, updater).
