# Ember

**Keep your Mac awake, even with the lid closed.**

Ember is a macOS menu bar app with two modes. *Screen mode* keeps the Mac and
its screen on while you work, with one click. *Lid mode* keeps the Mac running
with the lid closed, for a set time, so a long job or a coding agent can carry
on in a bag-free, well-ventilated spot.

Ember is a fork of [Insomnia](https://github.com/krishhgg/Insomnia) by Krish
Garg, with the one-click mode of [Caffeine](https://github.com/domzilla/Caffeine).
Both are MIT licensed.

> **Use a stable, well-ventilated surface, not a closed bag.** Ember is
> experimental. Recovery can fail, and a running timer is not a safety
> guarantee. [Apple's ventilation guidance](https://support.apple.com/en-us/102336)

## Screenshots

To come. The planned set:

- The menu bar icon in its three states: off, screen mode, lid mode.
- The right-click menu, without and with a lid session running (time left,
  Add 1 hour, End now).
- The administrator prompt that starts lid mode.
- Settings: battery and heat rules, lid-close actions, hotspot failover.

## Install

Requires macOS 26 or later on an Apple Silicon Mac.

**Insomnia must be uninstalled first.** Both apps control the same macOS sleep
setting and cannot be used together.

1. Download `Ember-<version>.dmg` from the
   [latest release](https://github.com/liviulica/ember/releases/latest).
2. Open it and drag **Ember** into **Applications**, then open Ember from
   Applications. It is signed and notarized by Charging Pixels; macOS asks
   once to confirm opening an app downloaded from the internet.
3. Lid mode needs one approval: macOS shows "Ember added a background item",
   and Ember's menu says "Lid mode needs your approval". Click **Open Login
   Items…** and turn Ember on. Screen mode works right away.

Ember updates itself: it checks once a day, and "Check for Updates…" in the
menu checks now. An update never restarts Ember during a lid session or while
screen mode is on; it installs when that ends. Turn automatic checks off in
Settings → Updates.

<details>
<summary><strong>What Ember changes on your Mac</strong></summary>

- The app, in `/Applications`.
- A **helper** (`app.chargingpixels.ember.helper`), a small program macOS runs
  as root once you approve it in Login Items. It answers only Ember (checked
  by code signature) and does two things: turns sleep off for a lid session,
  and writes the sudoers rule below.
- A **sudoers rule** at `/etc/sudoers.d/ember-<your uid>`, written by the helper. A
  sudoers rule decides who can run what with `sudo`. This one lets your user
  account run only the commands that give sleep back or switch Low Power
  Mode, so the recovery agent can restore the Mac without the app:

  ```text
  /usr/bin/pmset -a disablesleep 0
  /usr/bin/pmset -b lowpowermode 1
  /usr/bin/pmset -b lowpowermode 0
  ```

- A **recovery agent**, a `launchd` job (`app.chargingpixels.ember.recovery`)
  that runs every minute. If the app is gone, it tries to undo a session's
  changes (see [How recovery works](#how-recovery-works)).

</details>

<details>
<summary><strong>Build from source instead</strong></summary>

Needs Xcode with Swift 6.2 or later. The installer refuses while a release is
in `/Applications`, and while Insomnia is installed.

```bash
git clone https://github.com/liviulica/ember.git
cd ember
./scripts/install.sh
open "$HOME/Applications/Ember.app"
```

A source build is ad-hoc signed, has no helper and no updates, and goes in
`~/Applications`. The installer asks for your administrator password once to
write `/etc/sudoers.d/ember` with the three lines above plus
`/usr/bin/pmset -a disablesleep 1`, so lid mode starts without asking. Any
program running as you can use that fourth line to keep the Mac awake;
review it before you install. A release removes that file once its helper is
approved and has written its own, and offers to move the source build in `~/Applications` to the
Trash.

</details>

## Using it

The menu bar icon is a flame, like a pilot light:

| Icon | Meaning |
|---|---|
| Flame outline | Off. The Mac sleeps as usual. |
| Filled flame | Screen mode: the Mac and its screen stay on. A countdown shows beside it when the mode is timed. |
| Flame on a thick line (the closed lid) | Lid mode. The remaining time always shows beside it. |

- **Left-click** turns screen mode on and off ("until I turn it off").
  During a lid session it opens the menu, so a stray click never ends it.
- **Right-click** (or ctrl-click) opens the menu:
  - At the top, **Off | Screen | Lid**: click one to switch. Lid starts for
    8 hours by default (a setting); Off ends whatever runs.
  - Under the tabs, one line says what the mode does; hover a tab to read
    it before you switch. Lid mode keeps the screen on while the lid is open
    unless you turn that off in Settings → Modes.
  - Under it, quick times for the running mode. Screen: until I turn it
    off, 1, 2 or 4 hours, or Custom. Lid: 1, 2, 4, 8 or 12 hours, or
    Custom, which set the closed-lid time left. A line shows the time left.
  - A **Mac** block: battery, temperature, Wi-Fi and hotspot failover, and
    what the lid close changed while it is still in effect.
  - Warnings only when something needs a decision (a browser that pauses
    hidden tabs, an output still muted, a recovery problem), each followed
    by the item that resolves it.
  - **Settings…** and **Quit Ember**.

**Lid mode** turns sleep off for the whole system, through the sudoers rule
(no password; an install from before October 2026 still shows the standard
macOS administrator prompt until `scripts/install.sh` runs again). It is
always timed, and its timer counts only the time the lid is closed: it pauses
while the lid is open and resumes when the lid closes. A session holds at most
24 hours of closed-lid time, and Add 1 hour never goes past that. While the lid
is open, lid mode behaves like screen mode and keeps the screen on; when the lid
closes the screen goes dark. A running screen mode is folded into the lid
session. When a lid session ends, for any reason, everything ends and normal
sleep returns. If the lid is closed then, Ember puts the Mac to sleep at once,
unless macOS keeps it awake closed (an external display in clamshell mode).

On battery power, Ember turns on Low Power Mode below 40% and ends a lid
session below 10%. Those are the defaults, and you can change both in
Settings (an end floor of 0 turns the battery end off). The heat rules turn on
Low Power Mode when the Mac gets seriously hot and end the session at critical
heat. They are on by default. These rules only work while the app runs. The
length the Lid tab starts with is under Settings → Modes (1 to 24 hours).

Before your first lid session, check Settings. Then run a short session you
can watch, and read `~/Library/Logs/Ember/ember.log` afterward.

## What happens when the lid closes

During a lid session, closing the lid does each of these, and opening it tries
to undo them:

- **Display and keyboard light go off.** Ember saves their brightness first.
  With sleep turned off, macOS no longer does this by itself.
- **Apps on the freeze list are frozen.** Freezing sends an app's processes
  `SIGSTOP`, which pauses them until `SIGCONT` on lid open. The list starts
  with Slack, WhatsApp and Discord. "Freeze every other app" is off by
  default. Even when on, it skips meeting, recording and dictation apps: Zoom,
  Teams, Webex, FaceTime, Wispr Flow, Granola, Otter, OBS and Loom.
- **Audio is muted.** Lid open unmutes each output Ember muted.
- **Low Power Mode turns on.** It turns off when the lid opens, unless a
  battery or heat rule still needs it.

On Mac laptops with Apple silicon or a T2 chip, closing the lid disconnects the
built-in microphone in hardware. Recording a meeting with the lid closed needs
AirPods or an external mic.

[docs/lid-close.md](docs/lid-close.md) has the details.

## How recovery works

Ember writes each change to a **recovery journal**, a file on disk, before it
makes the change. Ending a session undoes what the journal lists. If the app
crashes or quits, the recovery agent checks every minute: it leaves a valid
session alone while the app runs, and ends it once the app has been gone for
about 2 minutes. A lid session therefore cannot leave the Mac sleepless for
hours after a crash.

Some things need you:

- The recovery agent can't restore audio. Open Ember again for that.
- The recovery agent doesn't watch the battery or the temperature.
- Ember only unfreezes a process it can prove it froze. A frozen process it
  can't prove stays frozen until you check it.

If the menu shows a recovery warning, deal with it before you leave the Mac
alone. [docs/recovery.md](docs/recovery.md) explains each case.

## Optional extras

<details>
<summary><strong>iPhone hotspot failover</strong></summary>

During a lid session, if Wi-Fi drops, or Wi-Fi is up but the internet is not,
Ember joins your iPhone's hotspot.

To set it up, right-click the menu bar icon, choose **Lid**, then **Set up
hotspot failover…** (or Settings → Network failover → **Set up…**). A small
window walks you through it: Location access, your iPhone's Personal Hotspot
screen (keep it open while you pick it from the list), the Mac's Ask to join
hotspots setting, and the password. The password stays in your login
Keychain. Ember asks for Location
Services access, because macOS requires it to read Wi-Fi network names. It
never reads your location. After you reinstall Ember, enter the password again.

While on the hotspot, Ember looks every minute for the network it left. When
it is in range, Ember leaves the hotspot so macOS rejoins that network with
the password it saved, and stays only if the internet works there; otherwise
it goes back to the hotspot and waits longer before it tries again. "Use hotspot failover in
screen mode too" in Settings (off by default) runs the same failover in screen
mode.

**Network.** Ember makes two kinds of network request. While hotspot failover
runs with a hotspot configured, it checks
`http://captive.apple.com/hotspot-detect.html`, the address macOS itself uses
to test the connection; the request carries a neutral user agent and no
cookies. A release also checks for updates (once a day, or when you ask) at
`https://chargingpixels.com/ember/appcast.xml`, which redirects to the latest
GitHub release, sending only Ember's and Sparkle's version in the user agent.
Nothing else leaves your Mac.

[docs/extras.md](docs/extras.md) has the details.

</details>

<details>
<summary><strong>Chrome, Chromium, Arc and Comet throttling</strong></summary>

These browsers slow down windows that macOS reports as hidden, which includes
every window while the lid is closed. If a running browser lacks
`--disable-backgrounding-occluded-windows` or
`--disable-renderer-backgrounding`, the right-click menu offers "Relaunch
[browser] unthrottled". It asks first, because relaunching quits the browser,
and tabs come back only if the browser reopens them on startup. Some web apps
may still stop with the lid closed.
[docs/extras.md](docs/extras.md#chrome-chromium-arc-and-comet-throttling) has
the details.

</details>

<details>
<summary><strong>Configuration and privacy</strong></summary>

Settings live in `~/Library/Application Support/Ember/config.json` and logs in
`~/Library/Logs/Ember/`. Ember sets both folders and their files to owner-only
permissions. It leaves symlinks and access control lists (ACLs, extra
per-account permission entries) as they are, so another account can still have
access through one. Logs can contain Wi-Fi names and process details, so check
them before you share one.
[docs/extras.md](docs/extras.md#configuration-and-privacy) has the details.

</details>

## Uninstall

A release:

```bash
/Applications/Ember.app/Contents/Resources/uninstall.sh          # the app, the helper, the agent and the sudoers rule
/Applications/Ember.app/Contents/Resources/uninstall.sh --purge  # also settings and logs
```

A source build, from your checkout: `./scripts/uninstall.sh` (or `--purge`).

The uninstaller undoes any open session first and stops if it can't.

## Development

```bash
swift build
scripts/test-fast.sh   # unit tests, a few minutes
swift test             # the full suite, before a release
scripts/release.sh X.Y.Z --dry-run   # build, sign, notarize, DMG and appcast, not published
```

The tests use fakes and temporary folders, so they never change your power
settings. See [Contributing](CONTRIBUTING.md), [Security reporting](SECURITY.md)
and the [design](docs/superpowers/specs/2026-10-14-awake-design.md). Insomnia's
original notes are in [docs/spec.md](docs/spec.md).

## Credits

- [Insomnia](https://github.com/krishhgg/Insomnia) by Krish Garg and its
  contributors. Ember is a fork of Insomnia: lid mode, recovery and hotspot
  failover all started there.
- [Caffeine](https://github.com/domzilla/Caffeine), by Tomas Franzén, Michael
  Jones and Dominic Rodemer: the idea behind the one-click screen mode.

## License

MIT. Ember is a fork of Insomnia (MIT, Krish Garg) and borrows its one-click
idea from Caffeine (MIT). See [LICENSE](LICENSE).
