# Awake: design

Date: 2026-10-14 · Status: approved in conversation, awaiting written review · Working title: **Awake**

Awake is a macOS menu bar app that keeps a Mac awake. It combines two ideas:

- **Awake mode** (the default): what [Caffeine](https://github.com/domzilla/Caffeine) does. The Mac and its display stay awake while the lid is open.
- **Lid mode**: what [Insomnia](https://github.com/krishhgg/Insomnia) does. The Mac keeps running with the lid closed, so coding agents keep working.

Awake is a fork of Insomnia (MIT). It borrows Caffeine's idea (also MIT), not its code. This document describes what changes relative to Insomnia at commit `b6a7499` (tag `nightly-20261013-b6a7499c183b`); Insomnia's own `docs/spec.md` stays the reference for everything not mentioned here.

## Goals

1. One menu bar app with two modes: a one-click Caffeine-style mode, and a timed lid-closed mode.
2. Safer by default than Insomnia: turning sleep off needs an administrator prompt, and a crashed app cannot leave the Mac sleepless for hours.
3. A public open-source app, signed and notarized, once phase 2 ships.

## Non-goals

- Controlling fans, or detecting that the Mac is in a bag.
- tmux nudge and the Docker rule (removed, see "What goes").
- An App Store release (a sleep-disabling helper is not App Store compatible).
- A full internal rename of the Swift module (deferred, see "Identity").

## Phases

| Phase | Ships | Repo |
|---|---|---|
| 1 | Everything below except the signed helper. Built and installed from source, ad-hoc signed. | private |
| 2 | Developer ID signing, notarization, an SMAppService privileged helper replacing the sudo rule and the password prompt, a release workflow. | public |

## User experience

### Menu bar icon

Template images drawn in code (like Insomnia's eye today), so macOS tints them for light and dark bars. An outline means off, a filled shape means on, as in Caffeine.

| State | Icon | Text beside it |
|---|---|---|
| Off | Laptop outline, blank screen | none |
| Awake mode | Laptop with the screen filled in | remaining time, only when timed |
| Lid mode | A thick line (the closed lid) with a small robot head above it: rounded head, antenna, two filled eyes | remaining time, always |

Mockups: (private mockup) (option "Robot head").

### Interaction

- **Left-click** toggles Awake mode on and off. On means "until I turn it off".
- **Right-click** opens a standard `NSMenu`:
  - Awake mode on/off, with a duration submenu: until I turn it off, 1h, 2h, 4h.
  - **Lid closed too…** with a duration submenu: 1h, 2h, 4h, 8h, Custom… Lid mode is always timed, with a 24h maximum. Starting it shows the macOS administrator prompt.
  - While a lid session runs: time left, **Add 1h**, **End now** (a plain menu item; Insomnia's press-and-hold control goes).
  - A status line: battery percentage and thermal state.
  - Settings…, Quit.
- Lid mode includes Awake mode. When a lid session ends, for any reason, Awake mode ends too and normal sleep returns.
- Left-click during a lid session does nothing destructive: it opens the menu instead of ending the session.

### When a lid session ends

Timer, battery floor, thermal critical, or End now: sleep is restored. If the lid is closed and macOS would sleep a closed Mac (no external display in clamshell mode), Awake asks macOS to sleep at once. This is Insomnia issue #94, fixed by Insomnia PR #61 (`IOPMSleepSystem`, retried every 30 s while refused). PR #61 is merged into Awake once the three test failures seen with it are explained (see "Open questions").

### Settings

Kept from Insomnia: battery floors (Low Power Mode below 40%, end below 10%), thermal rules, lid-close actions (dim display and keyboard light, mute, freeze listed apps, Low Power Mode), hotspot failover, App Nap off for listed agent apps (opt-in), Chromium relaunch, launch at login. Removed: tmux targets, the Docker rule. New: "Use hotspot failover in Awake mode too".

## Modes, technically

### Awake mode

An `IOPMAssertionCreateWithName` assertion of type `PreventUserIdleDisplaySleep` (which also keeps the system from idle sleep), released on toggle-off or timer end. It is not journaled: macOS releases an assertion when its process exits, so a crash cleans up by itself. No root, no password.

### Lid mode

Insomnia's session machinery, unchanged in shape: the recovery journal is written before each change, lid-close actions are applied and undone from it, and `pmset -a disablesleep 1/0` controls sleep. What changes is how root is obtained (next section) and how recovery treats a vanished app.

## Privileges

### Phase 1: password to start

- **Install** (administrator password once) writes `/etc/sudoers.d/awake` with three lines only:
  `pmset -a disablesleep 0`, `pmset -b lowpowermode 1`, `pmset -b lowpowermode 0`.
  None of them can keep the Mac awake. Insomnia's fourth line, `disablesleep 1`, is not granted.
- **Starting lid mode** writes the journal first, then runs `/usr/bin/pmset -a disablesleep 1` through the standard macOS administrator prompt (`/usr/bin/osascript -e 'do shell script "/usr/bin/pmset -a disablesleep 1" with administrator privileges'`, the only supported route without a helper). The command string is a constant: nothing user-provided reaches it. A cancelled prompt rolls the start back from the journal, as any failed start does today.
- **Ending, recovery and floors** stay passwordless through the three sudo lines.

### Phase 2: signed helper

An `SMAppService` daemon, signed with the same Developer ID, that accepts XPC calls only from Awake's code signature and exposes exactly: disable sleep, enable sleep, set Low Power Mode. It replaces both the sudoers file and the administrator prompt. The installer removes `/etc/sudoers.d/awake` when the helper is registered.

## Recovery

Insomnia's LaunchAgent backstop runs every 60 s but only recovers a session after its end time has passed. With a 24h session, a crash an hour in would leave the Mac sleepless for 23 hours with no battery or thermal checks.

Awake's backstop also ends a session when **the app has not been running for 2 consecutive minutes** while the journal says a lid session is active (the same idea as Insomnia PR #34, implemented here). Everything else about the backstop (code-signature pinning, the recovery lock, the sealed script) stays.

## Hotspot failover

Kept from Insomnia: during a lid session, Wi-Fi gone for 5 s triggers a join of the saved hotspot SSID (password in the login Keychain, joined through CoreWLAN), retried after 5, 10, 20, then every 30 s.

Changes:

1. **Internet check.** An outage also starts when Wi-Fi is associated but the internet is unreachable: an HTTP probe to `http://captive.apple.com/hotspot-detect.html` fails 3 times in a row, 10 s apart. This is the app's first network request (Insomnia makes none). It goes only to Apple's captive-portal endpoint, the one macOS itself uses, carries no identifying data, runs only while failover is active, and the README says so.
2. **Switch back.** While on the hotspot, Awake scans every 60 s for the network it was on before the outage. When that network is visible and the probe succeeds after joining it, Awake stays on it; if the probe fails there, it rejoins the hotspot.
3. **Awake mode too.** Optional, off by default.
4. **Keychain item survives reinstalls** in phase 2 (a stable Developer ID identity). In phase 1 the password must be re-entered after each reinstall, as in Insomnia.
5. **iPhone visibility.** To verify on hardware: whether an iPhone hotspot stays visible to a Mac that is not connected to it.

## What goes

| Module | Why |
|---|---|
| `TmuxNudge` + its Config keys, Settings rows and tests | Niche (tmux only), and keystrokes into a terminal cannot be undone. |
| `DockerRule` + `dockerRule` Config key, Settings row and tests | Freezing a VM host races with container starts; little gain. |
| Insomnia's custom menu bar UI: `StatusItemController` pill and duration-typing flow, `DurationInput`, `PillView`, `HoldToEndButton`, `Motion`, `EyeMark*`, `KeyCatcherPanel` | Replaced by a standard `NSMenu` controller. |
| `.github/workflows/merge-gate.yml`, `.github/scripts/merge-gate*`, `release.yml` nightly schedule | Insomnia maintainer's automation. |
| `.greptile/`, `skills/` | Insomnia-specific review and agent config. |

Kept although agent-specific: `BrowserThrottle` (Chromium relaunch), `AppNap` (opt-in).

## Identity

| Thing | Insomnia | Awake |
|---|---|---|
| Display name | Insomnia | Awake |
| Bundle id | `com.kgarg.insomnia` | `app.chargingpixels.awake` |
| Signing team (phase 2) | none (ad-hoc) | chargingpixels, `4UA742BB8G` |
| App Support / Logs | `~/Library/Application Support/Insomnia`, `~/Library/Logs/Insomnia` | `…/Awake`, `…/Awake` |
| LaunchAgent label | `com.insomnia.backstop` | `app.chargingpixels.awake.recovery` |
| sudoers file | `/etc/sudoers.d/insomnia` | `/etc/sudoers.d/awake` |
| Keychain service | `insomnia-hotspot` | `awake-hotspot` |
| Env override | `INSOMNIA_HOME` | `AWAKE_HOME` |

All user-visible names come from one place (`Paths` constants plus `scripts/build-app.sh` and `Resources/Info.plist`), so changing the working title is a small change. The Swift module, folder and type names stay `Insomnia` for now, to keep upstream fixes mergeable; a full rename is a later, separate change.

**Coexistence.** Insomnia and Awake both drive `disablesleep`, so they must not be installed together. `install.sh` refuses while `/etc/sudoers.d/insomnia`, `com.insomnia.backstop` or `Insomnia.app` exists, and names Insomnia's uninstaller.

**Credit.** README states the fork and links both projects; `LICENSE` keeps Insomnia's MIT notice and adds Caffeine's.

## Testing

- Keep Insomnia's XCTest suite (about 1,250 tests, about 27 minutes locally), minus the tests of removed modules.
- New tests: Awake mode assertion lifecycle; menu model (what each click does in each state); privileged start with a fake authorization runner (granted, cancelled, failed); backstop "app gone for 2 minutes" in `RecoveryScriptTests`; failover internet probe and switch-back in `FailoverMachine` (pure state machine).
- Split a **fast set** (unit tests, a few minutes) from the **full suite** (script and timing tests). The fast set runs on every change; the full suite before each release.
- **Real-Mac checklist** before each release: lid closed keeps agents and Wi-Fi alive; a session ending with the lid closed sleeps the Mac; `kill -9` mid-session restores sleep within about 3 minutes; router off switches to the hotspot and back; the start prompt appears (and whether it offers Touch ID); Chromium relaunch restores tabs.

## CI and releases

- GitHub Actions stays disabled on `liviulica/awake` until the new workflow lands.
- One CI workflow: on pull requests to `main`, build plus the fast set, on one macOS version.
- Phase 2 adds a release workflow on version tags: build, Developer ID sign, notarize, staple, publish the zip with `SHA256SUMS`. Secrets: the Developer ID certificate and an App Store Connect API key for notarization.

## Upstream

`upstream` points at `krishhgg/Insomnia`. Fixes are pulled by cherry-pick, not by merging `main`, since Awake removes and rewrites whole files. Insomnia PRs worth tracking: #61 (closed-lid sleep, adopted), #34 (backstop ending), #32 (password to start; too large to merge, reimplemented here).

## Open questions and residual risks

1. **Test failures with PR #61.** The full suite with #61 merged had 3 failures: `PowerMonitorTests.testUnreadableBatteryIsRecheckedWhileStarted` (a count off by one) and `RecoveryScriptTests.testInstallMovesNeitherBundleWhenCodesignDoesNotAnswerDuringTheRepair` (took 677 s against a 30 s limit), plus one not yet identified. Neither touches #61's code. They must be re-run in isolation on `b6a7499` before #61 is adopted.
2. **macOS 26.6.2 reverting `disablesleep`.** Insomnia's `SleepGuard` notes that on 26.6.2 (25G83) the setting can read back 0 about 2 s after being set, and fails the start. Whether this happens on the development Mac is untested.
3. **Touch ID at the administrator prompt.** Unknown whether the macOS 26 administrator prompt offers Touch ID for this call. Password-only is acceptable for phase 1.
4. **iPhone hotspot visibility** while no device is connected (see Hotspot failover, point 5).
5. **Developer ID certificate.** This Mac holds only Apple Development certificates. A Developer ID Application certificate for team `4UA742BB8G` is needed for phase 2 and can only be created by the team's Account Holder.
