# Awake

**Keep your Mac awake, even with the lid closed.**

Awake is a macOS menu bar app with two modes. *Awake mode* keeps the Mac and
its screen on while you work, with one click. *Lid mode* keeps the Mac running
with the lid closed, for a set time, so a long job or a coding agent can carry
on in a bag-free, well-ventilated spot.

"Awake" is a working title. It may become Ember.

Awake is a fork of [Insomnia](https://github.com/krishhgg/Insomnia) by Krish
Garg, with the one-click mode of [Caffeine](https://github.com/domzilla/Caffeine).
Both are MIT licensed.

> **Use a stable, well-ventilated surface, not a closed bag.** Awake is
> experimental. Recovery can fail, and a running timer is not a safety
> guarantee. [Apple's ventilation guidance](https://support.apple.com/en-us/102336)

## Screenshots

To come. The planned set:

- The menu bar icon in its three states: off, Awake mode, lid mode.
- The right-click menu, without and with a lid session running (time left,
  Add 1 hour, End now).
- The administrator prompt that starts lid mode.
- Settings: battery and heat rules, lid-close actions, hotspot failover.

## Install

Requires macOS 26 or later on an Apple Silicon Mac. There is no signed release
yet, so Awake is built from source (Xcode with Swift 6.2 or later).

**Insomnia must be uninstalled first.** Both apps control the same macOS sleep
setting and cannot be installed together. The installer refuses while Insomnia
is present and tells you to run `scripts/uninstall.sh` from your Insomnia
checkout.

```bash
git clone https://github.com/liviulica/awake.git
cd awake
./scripts/install.sh
open "$HOME/Applications/Awake.app"
```

<details>
<summary><strong>What the installer changes on your Mac</strong></summary>

The installer asks for your administrator password once, because the sudoers
rule is a system file. It installs:

- The app, at `~/Applications/Awake.app`.
- A **recovery agent**, a `launchd` job (`app.chargingpixels.awake.recovery`)
  that runs every minute. If the app is gone, it tries to undo a session's
  changes (see [How recovery works](#how-recovery-works)).
- A **sudoers rule** at `/etc/sudoers.d/awake`. A sudoers rule decides who can
  run what with `sudo`. This one lets your user account, not just Awake, run
  these three commands without a password. None of them can keep your Mac
  awake: starting lid mode (`disablesleep 1`) asks for your administrator
  password each time.

```text
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -b lowpowermode 1
/usr/bin/pmset -b lowpowermode 0
```

Any program running as you can use that rule too, so review it before you
install.

</details>

## Using it

The menu bar icon is a flame, like a pilot light:

| Icon | Meaning |
|---|---|
| Flame outline | Off. The Mac sleeps as usual. |
| Filled flame | Awake mode: the Mac and its screen stay on. A countdown shows beside it when the mode is timed. |
| Small flame on a thick line (the closed lid) | Lid mode. The remaining time always shows beside it. |

- **Left-click** turns Awake mode on and off. On means "until I turn it off".
  During a lid session a left-click opens the menu instead of ending anything.
- **Right-click** opens the menu:
  - **Keep awake**, and **Keep awake for** (until I turn it off, 1, 2 or 4
    hours).
  - **Keep awake with lid closed** (1, 2, 4 or 8 hours, or Custom).
  - During a lid session: the time left, **Add 1 hour** and **End now**.
  - Battery and temperature status, **Settings...** and **Quit**.

**Lid mode** asks for your administrator password each time it starts (the
standard macOS prompt), because it turns sleep off for the whole system. It is
always timed, and its timer counts only the time the lid is closed: it pauses
while the lid is open and resumes when the lid closes. A session holds at most
24 hours of closed-lid time, and Add 1 hour never goes past that. While the lid
is open, lid mode behaves like Awake mode and keeps the screen on; when the lid
closes the screen goes dark. A running Awake mode is folded into the lid
session. When a lid session ends, for any reason, everything ends and normal
sleep returns. If the lid is closed then, Awake puts the Mac to sleep at once,
unless macOS keeps it awake closed (an external display in clamshell mode).

On battery power, Awake turns on Low Power Mode below 40% and ends a lid
session below 10%. Those are the defaults, and you can change both in
Settings (an end floor of 0 turns the battery end off). The heat rules turn on
Low Power Mode when the Mac gets seriously hot and end the session at critical
heat. They are on by default. These rules only work while the app runs.

Before your first lid session, check Settings. Then run a short session you
can watch, and read `~/Library/Logs/Awake/awake.log` afterward.

## What happens when the lid closes

During a lid session, closing the lid does each of these, and opening it tries
to undo them:

- **Display and keyboard light go off.** Awake saves their brightness first.
  With sleep turned off, macOS no longer does this by itself.
- **Apps on the freeze list are frozen.** Freezing sends an app's processes
  `SIGSTOP`, which pauses them until `SIGCONT` on lid open. The list starts
  with Slack, WhatsApp and Discord. "Freeze every other app" is off by
  default. Even when on, it skips meeting, recording and dictation apps: Zoom,
  Teams, Webex, FaceTime, Wispr Flow, Granola, Otter, OBS and Loom.
- **Audio is muted.** Lid open unmutes each output Awake muted.
- **Low Power Mode turns on.** It turns off when the lid opens, unless a
  battery or heat rule still needs it.

On Mac laptops with Apple silicon or a T2 chip, closing the lid disconnects the
built-in microphone in hardware. Recording a meeting with the lid closed needs
AirPods or an external mic.

[docs/lid-close.md](docs/lid-close.md) has the details.

## How recovery works

Awake writes each change to a **recovery journal**, a file on disk, before it
makes the change. Ending a session undoes what the journal lists. If the app
crashes or quits, the recovery agent checks every minute: it leaves a valid
session alone while the app runs, and ends it once the app has been gone for
about 2 minutes. A lid session therefore cannot leave the Mac sleepless for
hours after a crash.

Some things need you:

- The recovery agent can't restore audio. Open Awake again for that.
- The recovery agent doesn't watch the battery or the temperature.
- Awake only unfreezes a process it can prove it froze. A frozen process it
  can't prove stays frozen until you check it.

If the menu shows a recovery warning, deal with it before you leave the Mac
alone. [docs/recovery.md](docs/recovery.md) explains each case.

## Optional extras

<details>
<summary><strong>iPhone hotspot failover</strong></summary>

During a lid session, if Wi-Fi drops, or Wi-Fi is up but the internet is not,
Awake joins your iPhone's hotspot. Set System Settings > Wi-Fi > Ask to join
hotspots to Automatically, then enter the hotspot's name and password in
Settings. The password stays in your login Keychain. Awake asks for Location
Services access, because macOS requires it to read Wi-Fi network names. It
never reads your location. After you reinstall Awake, enter the password again.

While on the hotspot, Awake looks every minute for the network it left. When
it is in range, Awake leaves the hotspot so macOS rejoins that network with
the password it saved, and stays only if the internet works there; otherwise
it goes back to the hotspot and waits longer before it tries again. "Use hotspot failover in
Awake mode too" in Settings (off by default) runs the same failover in Awake
mode.

**Network.** Awake makes one kind of network request: while hotspot failover
runs with a hotspot configured, it checks
`http://captive.apple.com/hotspot-detect.html`, the address macOS itself uses
to test the connection. The request carries a neutral user
agent and no cookies. Nothing else leaves your Mac.

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

Settings live in `~/Library/Application Support/Awake/config.json` and logs in
`~/Library/Logs/Awake/`. Awake sets both folders and their files to owner-only
permissions. It leaves symlinks and access control lists (ACLs, extra
per-account permission entries) as they are, so another account can still have
access through one. Logs can contain Wi-Fi names and process details, so check
them before you share one.
[docs/extras.md](docs/extras.md#configuration-and-privacy) has the details.

</details>

## Uninstall

From your checkout:

```bash
./scripts/uninstall.sh          # removes the app, the agent and the sudoers rule
./scripts/uninstall.sh --purge  # also removes settings and logs
```

The uninstaller undoes any open session first and stops if it can't.

## Development

```bash
swift build
scripts/test-fast.sh   # unit tests, a few minutes
swift test             # the full suite, before a release
```

The tests use fakes and temporary folders, so they never change your power
settings. See [Contributing](CONTRIBUTING.md), [Security reporting](SECURITY.md)
and the [design](docs/superpowers/specs/2026-10-14-awake-design.md). Insomnia's
original notes are in [docs/spec.md](docs/spec.md).

## Credits

- [Insomnia](https://github.com/krishhgg/Insomnia) by Krish Garg and its
  contributors. Awake is a fork of Insomnia: lid mode, recovery and hotspot
  failover all started there.
- [Caffeine](https://github.com/domzilla/Caffeine), by Tomas Franzén, Michael
  Jones and Dominic Rodemer: the idea behind the one-click Awake mode.

## License

MIT. Awake is a fork of Insomnia (MIT, Krish Garg) and borrows its one-click
idea from Caffeine (MIT). See [LICENSE](LICENSE).
