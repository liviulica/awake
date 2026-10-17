# Contributing

Ember is a native Swift macOS app, forked from
[Insomnia](https://github.com/krishhgg/Insomnia). Build and run the Swift test
suite on macOS 26 with an Xcode toolchain that supports the package's Swift 6.2
tools version. Pull requests should include regression tests for changed
behavior and pass CI. The Swift module and type names are still `Insomnia`, to
keep upstream fixes mergeable; user-visible names are Ember.

## Tests

- `scripts/test-fast.sh` runs the unit tests and skips the script-driven
  classes that spawn bash, codesign or the built app. It takes a few minutes
  and is what CI runs. It passes extra arguments to `swift test`. When a class
  becomes slow, add it to the skip list in that script.
- `swift test` runs the full suite (about half an hour). Run it before a
  release. A few timing tests can fail under load; re-run a failure alone with
  `--filter` before treating it as real.
- `scripts/stress-tests.sh` runs the timing-sensitive tests over and over on a
  loaded machine, to show they do not depend on how fast the machine is. Run it
  after changing one of them, or pass filters to stress other tests.
- `scripts/smoke-test.sh` builds the test build of the app, launches it in test
  mode in a throwaway `EMBER_HOME`, and drives it end to end. CI runs it too.

## CI

CI runs on every pull request to `main` (`.github/workflows/ci.yml`):

- **Build and fast tests:** `swift build -c release -Xswiftc -warnings-as-errors`
  and `scripts/test-fast.sh`, so a compiler warning fails the build.
- **End-to-end smoke test:** `scripts/smoke-test.sh`.
- **ShellCheck:** `shellcheck --shell=bash scripts/*.sh`.

The scripts run under macOS `/bin/bash` 3.2 (the recovery agent, `install.sh`
and `uninstall.sh`): no `mapfile`, no `declare -A`, no `${x,,}`, and no empty
array expansion under `set -u`.

## Releases

Releases are built on the maintainer's Mac, not in CI (spec
`docs/superpowers/specs/2026-10-17-ember-installer-and-updates-design.md`):

1. In a pull request, set `CFBundleShortVersionString` in `Resources/Info.plist`
   to X.Y.Z and `CFBundleVersion` to X·1000000 + Y·1000 + Z; merge it.
2. On `main`, run `swift test` (the full suite), then
   `scripts/release.sh X.Y.Z --dry-run` to build, sign, notarize and staple the
   app and the DMG and write `dist/X.Y.Z/appcast.xml`.
3. `scripts/release.sh X.Y.Z` does the same and, after asking, creates the
   GitHub release vX.Y.Z with the DMG and `appcast.xml`. Every installed copy
   finds it through `https://chargingpixels.com/ember/appcast.xml`, which
   redirects to the latest release's `appcast.xml`.

It needs the Developer ID Application certificate of CHARGING PIXELS S.R.L.
in the login keychain, the notarytool keychain profile `ember-notary`, and the
Sparkle EdDSA key (account `ember`) in the login keychain. The public half of
that key is `SUPublicEDKey` in Info.plist; an update signed with any other key
is refused, so the private key must never be lost or replaced.

## Writing tests

Use injected system dependencies and temporary journals for automated tests.
The test bundle links the InsomniaTestHome target (Tests/InsomniaTestHome),
whose constructor points `EMBER_HOME` at a throwaway directory when the bundle
loads, before XCTest runs anything and whatever `--filter` is used, so no test
writes to the real ~/Library/Logs or ~/Library/Application Support.
TestIsolationTests fails if `EMBER_HOME` is unset or missing, or if any path
the app resolves, such as the log a default-argument line goes to, falls
outside it or inside the real ~/Library.

Do not execute installation, uninstallation, power-setting changes, process
freezing, or hotspot switching against a contributor's working machine as part
of the test suite. Never embed credentials or personal SSIDs in fixtures or
logs.

For lifecycle changes, test suspension at asynchronous boundaries, shutdown
during in-flight work, failed restoration, persistence failures, and recovery
after interruption. Assert observable settings and journal consistency, not
only that a mock method was called.

## Real-Mac checks

Passing CI is review evidence, not a safety certification. Real-machine
validation needs a supervised run on a ventilated surface with recoverable
work; never stress or heat a machine in a bag. The checklist is in the design
spec, "Testing" ([docs/superpowers/specs/2026-10-14-awake-design.md](docs/superpowers/specs/2026-10-14-awake-design.md)).
New behavior that needs a real-Mac check adds an item to it. In a pull
request, say which checks you ran, on which macOS and hardware, with the log
lines (`~/Library/Logs/Ember/ember.log`) and `pmset` readings that show the
result, and which you did not run.

## App icon

The app icon is the lit flame, the menu bar's screen-on icon filled, in
moon-white on the midnight tile (decided 2026-10-17; the open eye was left
over from Awake and Insomnia). [AppIconArtwork](Sources/Insomnia/UI/AppIconArtwork.swift)
draws it from [FlameGeometry](Sources/Insomnia/UI/FlameGeometry.swift), the
same path `MenuBarIcon` draws, so the two cannot drift. After changing the
artwork, run `./scripts/generate-app-icon.sh`. It regenerates the packaged PNG
and ICNS and `docs/assets/app-icon.svg` offline, with Xcode's swiftc and
iconutil.
