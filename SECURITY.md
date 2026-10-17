# Security

Ember is experimental software. There is no security-response SLA.

## Reporting a vulnerability

Report it privately through GitHub: on this repository's **Security** tab,
choose **Report a vulnerability** (GitHub's private vulnerability reporting).
Only you and the maintainer see the report. Test against the current `main`
branch and include the affected revision and a minimal, non-destructive
reproduction. Do not open a public issue for a vulnerability, and do not
publish passwords, Keychain data, personal logs, or weaponized exploit details
anywhere public.

## What the app can and cannot protect

A release turns sleep off through its privileged helper, a launchd daemon
registered with `SMAppService` that runs as root once the user approves it
in Login Items. The helper accepts connections only from code signed by team
4UA742BB8G with Ember's identifier, and the app talks only to a helper
signed the same way. It does two fixed things: `pmset -a disablesleep 1`,
and writing `/etc/sudoers.d/ember` with three restore-only lines for the
calling user (the name comes from the connection's uid, never from the
message, and must be a plain account name). Those lines, listed in the README,
let any process running as that user turn sleep back on or switch Low Power
Mode without a password, which the recovery agent needs; none of them turns
sleep off. A source build (`scripts/install.sh`) has no helper: its rule has a
fourth line, `pmset -a disablesleep 1`, which any process running as that user
can use to keep the Mac awake. The app is not
sandboxed; local logs can contain SSIDs, process metadata.
The lines the app writes to `ember.log` also reach the unified log with the
body marked private, so programs reading `log show` see `<private>` instead of
those names unless private data logging is enabled on the Mac. The files
Ember creates (logs, journal, session, config, recovery lock) are mode 0600
and its directories 0700; the backstop runs with `umask 077`. Ember sets
only these modes and leaves any access control list (ACL) on these files as it
is, so an ACL someone added can still give another account access. Logs are capped at
1 MiB with one older copy kept. A log the user replaced with a symlink is not
rotated: the file it points to is the user's to manage. Location
Services access is requested only when a hotspot is saved or a session starts
with one configured; it is used to read Wi-Fi network names and the app never
requests location updates. With the App Nap setting on (off by default), the
app writes `NSAppSleepDisabled` into the preferences of each app on the agent
list, after recording the previous value in its journal, and puts it back at
session end.

The hotspot password is a generic-password item in the login Keychain
(service `ember-hotspot`). Its access list names only the Ember build
that saved it, so any other program asking for it gets the system Keychain
prompt, which you can refuse. Ember itself reads the item with prompts
switched off: an item it may not read is reported in the menu and in Settings
instead of being prompted for or silently ignored. Two limits remain. In a
source build, ad-hoc signing gives every install a new code identity, so the
access list pins one build and the password must be entered again after a
reinstall; a release's Developer ID signature stays the same across updates,
so its access list keeps working (moving from a source build to a release
asks for the password once). And the item lives in the file-based login Keychain, which
ignores the data-protection accessibility classes (this device only, when
unlocked); using that Keychain needs an access-group entitlement, which needs
a team id and is not done yet.

In builds of the current source, the recovery LaunchAgent runs only the `backstop.sh` sealed inside the
signed app bundle, after `codesign --verify --strict` passes against the code
requirement pinned in its plist (the build's cdhash for an ad-hoc signature).
An edited bundle or script is refused and logged. The app pins the code it is
running (its own designated requirement, after confirming that the bundle on
disk is still that code and passes the agent's check), so a bundle edited or
re-signed under the running app is refused, not re-pinned. The plist itself
lives in `~/Library/LaunchAgents` and, like every per-user LaunchAgent, can be
edited by any program running as that user. With ad-hoc signatures these
checks are integrity against accidents and against the app relaying a
tampered bundle; they are not a boundary against a process running as the
same user, which can edit the plist, load its own agent, replace and relaunch
the app, and invoke the four pmset commands directly.

Releases are signed with the Developer ID of CHARGING PIXELS S.R.L., use the
hardened runtime, and are notarized; source builds are ad-hoc signed on the
machine that installs them. A release updates itself with Sparkle 2: the feed
is fetched over HTTPS and an update is installed only when its EdDSA signature
matches `SUPublicEDKey` in the running app's Info.plist (and Sparkle checks
that the new bundle is signed by the same team). Ember makes two kinds of
network request: while hotspot failover runs with a hotspot configured, a
`GET` of `http://captive.apple.com/hotspot-detect.html` with a neutral user
agent, and a release's update check (see the README). Starting a lid session
asks the helper when it is approved; otherwise, or when the helper cannot be
reached, it runs `sudo -n pmset -a disablesleep 1`, and on a rule without that
line it raises the standard macOS administrator prompt. Every command string
is a constant, and nothing a user can type reaches it. A lid session does not
start until the restore lines are in place.

One known window remains in the prompt fallback. A prompt left open until its 300 s
limit is stopped with SIGTERM (never SIGKILL) to osascript, and the start is
undone from the journal. If the password was accepted in the last moment
before that, osascript can exit while the root shell it started is still
running, and that shell can then turn sleep off after the undo: sleep stays
disabled with a clean journal, so neither the backstop nor the next launch
restores it (the next launch only warns in the menu), until a later session
end or `sudo pmset -a disablesleep 0`.
The window is milliseconds wide. A release with its helper approved never
reaches the prompt, so it does not have this window.

Passing automated checks or a secret scan does not establish the absence of
vulnerabilities. Do not probe recovery by disrupting someone else's processes,
power settings, network, or data.
