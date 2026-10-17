# Ember: signed installer, privileged helper, auto-updates

Date: 2026-10-17. Status: design approved by the owner in conversation
("go"). Phase 2 of `2026-10-14-awake-design.md` ("Phase 2: signed helper"),
minus building releases in CI.

## Why

Installing Ember today means cloning the repo and running `install.sh` in
Terminal, which builds an ad-hoc signed app into `~/Applications` and writes
`/etc/sudoers.d/ember`. There are no updates. Lid mode starts without a
password only because of a fourth sudoers line (`disablesleep 1` without a
password), accepted on 2026-10-15 as a stopgap: any program running as the
user can use it.

The owner wants an installer and auto-updates. Apple side is ready (Developer
ID Application certificate for CHARGING PIXELS S.R.L., team 4UA742BB8G;
notarytool keychain profile `ember-notary`); a throwaway spike notarized a
bundle with Sparkle 2.10.0 and an SMAppService daemon inside it.

## What the owner gets

1. **Download** `Ember-<version>.dmg` from the GitHub release (linked from
   chargingpixels.com/ember). Drag Ember into Applications, open it. Signed,
   notarized and stapled: macOS only asks the usual "downloaded from the
   internet" confirmation once.
2. **One approval.** Ember registers its helper at first launch; macOS asks
   to allow it in System Settings → General → Login Items. Until then the
   menu shows "Lid mode needs your approval" with a button that opens that
   pane. Screen mode works from the start. Lid mode waits for the approval,
   because without the helper nothing can turn sleep back on after a crash.
3. **Updates.** Ember checks daily (Sparkle). "Check for Updates…" in the
   menu, an "Automatically check for updates" switch and the version in
   Settings. An update never relaunches Ember while a lid session or screen
   mode is on: it waits until that ends, and the menu says so.
4. **No more passwordless sleep switch.** Once the helper is approved, the
   sudoers rule shrinks to the three restore-only lines.

## 1. Bundle layout (release and source builds alike)

```
Ember.app/Contents/
  Info.plist                      version, SUFeedURL, SUPublicEDKey
  MacOS/Ember                     the app
  MacOS/EmberHelper               the privileged helper (root, launchd)
  Frameworks/Sparkle.framework
  Library/LaunchDaemons/app.chargingpixels.ember.helper.plist
  Resources/backstop.sh           sealed, as today
  Resources/uninstall.sh          sealed, for DMG installs
  Resources/AppIcon.icns
```

`scripts/build-app.sh` assembles it and signs inside out (Sparkle's XPC
services, Autoupdate, Updater.app, the framework, the helper, the app).
`--sign -` (default) keeps today's ad-hoc build; `--sign <identity>` adds the
hardened runtime, a secure timestamp and `Resources/Ember.entitlements`
(`com.apple.security.personal-information.location`, which the hardened
runtime needs for the Wi-Fi name lookup). A build with
`INSOMNIA_LID_SIMULATION=1` refuses a real identity.

Swift packages: Sparkle 2.10.0 (`exact:`), linked with rpath
`@executable_path/../Frameworks`. New targets: `EmberHelperKit` (library:
the XPC protocol, the names and code requirements, the restore rule text,
the helper's command logic; shared by app, helper and tests) and
`EmberHelper` (executable: wiring only).

## 2. The helper

- **Registration:** `SMAppService.daemon(plistName:)`. Plist: `Label` and
  the Mach service `app.chargingpixels.ember.helper`, `BundleProgram
  Contents/MacOS/EmberHelper`, `AssociatedBundleIdentifiers
  [app.chargingpixels.ember]`.
- **Who may call:** the listener's connection code-signing requirement is
  `anchor apple generic and identifier "app.chargingpixels.ember" and
  certificate leaf[subject.OU] = "4UA742BB8G"`. The app holds the helper to
  the same requirement with `identifier "app.chargingpixels.ember.helper"`.
- **What it does, and nothing else:**
  - `disableSleep(lock:)`: runs `/usr/bin/pmset -a disablesleep 1`. The lock
    is a descriptor on the recovery lock (`RecoveryLockHandle
    .descriptorForChild()`), sent over XPC and installed as pmset's standard
    input, so the lock lives as long as pmset does even if the app or the
    helper dies (the same guarantee `sudo pmset` has today). At 20 s pmset
    gets SIGTERM, never SIGKILL. The reply comes only after pmset exited:
    the app's transaction waits for it, as it waits for a sudo that ignores
    SIGTERM today.
  - `installRestoreRule()`: writes `/etc/sudoers.d/ember-<uid>` with the
    three restore-only lines for the calling user (uid from the connection,
    never from the message; the name must match `^[a-z_][a-z0-9_.-]*$`).
    One file per account, so a second user never takes the first one's lines
    away; named by uid because sudo skips file names with a dot. Unchanged
    file: nothing is written. Otherwise a temp file, `visudo -cf`, then
    `install -m 0440 -o root -g wheel`, as install.sh does. Then install.sh's
    `/etc/sudoers.d/ember` is removed when every rule line in it is this
    user's (review, Codex).
  - `version()`: the helper's CFBundleShortVersionString, for the log.
- **Lifetime:** launchd starts it on demand; it exits 10 s after its last
  connection closes, so an updated bundle's helper takes over at the next
  call.

### The restore rule (three lines)

```
<user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
<user> ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1
<user> ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0
```

backstop.sh keeps restoring through `sudo -n pmset` exactly as today; the
app's restores and Low Power Mode calls keep going through sudo too. Only
turning sleep *off* moves to the helper.

## 3. The app

- **Release build:** the running app satisfies the team requirement above
  (`ReleaseSignature.isDeveloperID`). Only then: helper registration,
  updater, legacy-install migration, the translocation check, the launch
  re-arm. Source builds (ad-hoc) behave exactly as today.
- **Launch (release build):**
  1. Running translocated or from a read-only volume (straight from the
     DMG): an alert "Move Ember to Applications" and quit.
  2. A copy at `~/Applications/Ember.app` (the install.sh location) while
     this one runs elsewhere: offer to move it to the Trash.
  3. Helper: `.notRegistered` → `register()`; `.enabled` →
     `installRestoreRule()`. Status is read again whenever the menu opens.
  4. If the recovery LaunchAgent plist exists, re-arm it, so it pins this
     bundle (after a migration it still points at the old one).
- **Turning sleep off** (`PmsetSleepGuard.setSleepDisabled(true)`): helper
  first when it is enabled; a connection failure (not a pmset failure) falls
  back to today's chain (`sudo -n`, then the administrator prompt), once no
  root `pmset -a disablesleep 1` is running (the helper may have died after
  starting one, which then holds this transaction's own lock). A pmset
  failure through the helper throws as today.
- **Lid start gate:** before the start journals anything,
  `sleepGuard.restoreProblem()` runs `sudo -n pmset -a disablesleep 0` (sleep
  is on before a start, so it changes nothing; `sudo -l` alone passes for a
  command that needs a password when any other rule is passwordless) and
  checks the two Low Power Mode lines with `sudo -n -l`. Helper enabled and rule missing: it asks the
  helper to write it and checks again. Still missing: the start fails with
  "Lid mode needs your approval in System Settings → Login Items: Ember
  can't turn sleep back on without it" (helper builds) or "…run
  scripts/install.sh" (source builds). Test guards answer ready.
- **Menu:** while the helper needs approval (release build), a line "Lid
  mode needs your approval" with "Open Login Items…". "Check for Updates…"
  above Settings (release builds). "Update ready: installs when this
  session ends" while one is held back.
- **Settings → Updates** (release builds): "Automatically check for
  updates" (Sparkle's own setting, on by default via
  `SUEnableAutomaticChecks`), "Check Now", "Version 0.2.0 (2000)".
- **Updater:** `SPUStandardUpdaterController`, started only in release
  builds and never in test mode. Delegate
  `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)` holds
  the relaunch while a lid session or screen mode is on and runs it once
  both are off (`RelaunchGate`, pure and tested).
- **One-shot mode** `Ember --unregister-helper` (for uninstall.sh): calls
  `unregister()` and exits.

## 4. Versions

`Resources/Info.plist` is the version file. `CFBundleShortVersionString`
X.Y.Z, `CFBundleVersion` = X·1000000 + Y·1000 + Z (Sparkle compares it).
This branch moves to 0.2.0 / 2000.

## 5. Releasing: `scripts/release.sh X.Y.Z [--dry-run]`

From the owner's Mac. Refuses unless the tree is clean, Info.plist already
says X.Y.Z with the matching build number, the identity and notary profile
exist and Sparkle's `sign_update` is resolved. Then:

1. `build-app.sh --sign "Developer ID Application: CHARGING PIXELS S.R.L. (4UA742BB8G)"`.
2. Verify: `codesign --verify --deep --strict`, hardened runtime flag on
   app and helper, no lid simulation marker in the binary.
3. Notarize the app (zip → `notarytool submit --wait`), staple.
4. DMG (`hdiutil`, Ember.app + an Applications link), sign it, notarize,
   staple, `spctl -a -t open --context context:primary-signature`.
5. `sign_update` (EdDSA key in the login keychain), write `appcast.xml`
   (one item: version, short version, minimum system 26.0, enclosure on the
   GitHub release download URL, length, signature).
6. Not with `--dry-run`: `gh release create vX.Y.Z` with the DMG and
   `appcast.xml`, notes generated from commits.

**Feed address:** `https://chargingpixels.com/ember/appcast.xml`, a 302 in
the site's `public/_redirects` to
`https://github.com/liviulica/ember/releases/latest/download/appcast.xml`.
One line in the chargingpixels site repo, deployed with the owner's yes.

**Update key:** `generate_keys --account ember` on the owner's Mac; the
public key goes in Info.plist, the private key stays in the login keychain
and is exported once for LastPass.

## 6. Moving from an install.sh install

- First launch from /Applications offers to trash `~/Applications/Ember.app`
  and re-arms the agent to pin the new bundle.
- After the approval the helper replaces the four-line rule with three.
- backstop.sh finds the app binary (for `--resume-frozen`) in the bundle it
  runs from, so the agent works wherever the bundle lives.
- The hotspot password must be entered again once (keychain access is tied
  to the signature, and Developer ID signatures stay the same across
  updates from then on).
- install.sh stays for building from source, unchanged except that it
  refuses to run when `/Applications/Ember.app` exists (two copies would
  fight over the same setting).
- uninstall.sh: finds the app in the bundle it runs from, else
  `/Applications`, else `~/Applications`; unregisters the helper through
  `--unregister-helper` before removing the bundle. A DMG user runs
  `/Applications/Ember.app/Contents/Resources/uninstall.sh`.

## Testing

- Unit: restore rule text and user name check; helper command logic with
  fake pmset/visudo/install (lock descriptor reaches pmset's stdin, reply
  after exit, SIGTERM only, unchanged rule not rewritten, invalid rule not
  installed); requirement strings; sleep guard order (helper, fallback on
  connection failure only); the start gate; `RelaunchGate`; migration and
  translocation decisions; version number rule.
- Packaging: the build has the layout above and verifies deep and strict.
- release.sh: dry run with fake tools.
- On the owner's Mac: signed build through the smoke test (hardened
  runtime); approve the helper and run a lid session through it; publish
  0.2.0, install from the DMG; publish 0.2.1 and update to it.

## Residual risks

- SMAppService registration and approval can only be exercised on a real
  install (it registers a system daemon). Tested together on the owner's Mac.
- Sparkle following the chargingpixels.com → GitHub → CDN redirects:
  standard, verified by the 0.2.1 update.
- Whether approval survives updates: Background Task Management keys
  approval on the team identity, which updates keep. Verified by 0.2.1.
- A helper crash between spawning pmset and its exit is covered (pmset
  holds the lock itself); a crash before spawn is a connection failure and
  falls back to sudo.

## Not included

Companion app and notifications; building releases in GitHub Actions; a
Settings "Uninstall" button; delta updates.
