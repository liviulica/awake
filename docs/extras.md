# Optional extras

The [README](../README.md#optional-extras) has a summary of each.

## iPhone hotspot handoff

During a lid session, and in screen mode too if you turn on "Use hotspot
failover in screen mode too" in Settings (off by default), Ember watches the
network. An outage starts when Wi-Fi has been gone for 5 seconds, or when
Wi-Fi is up but the internet is not: three checks in a row, 10 seconds apart,
fail. Ember then joins the saved hotspot, retrying after 5, 10 and 20 seconds
and then every 30 seconds.

While it is on the hotspot, Ember looks every 60 seconds for the network it was
on before the outage. When that network is visible it leaves the hotspot so
macOS rejoins its known network with the password macOS saved. If macOS joins
that network and the internet check passes there, Ember stays. Otherwise (no
internet there, macOS picked the hotspot or another network, or nothing joined)
it waits longer before the next try (60 seconds, doubling up to 10 minutes),
and goes back to the hotspot itself when there is no internet or no network.

The internet check is Ember's only network request: a plain `GET` of
`http://captive.apple.com/hotspot-detect.html`, the address macOS itself uses
to test the connection, with Apple's own neutral user agent
(`CaptiveNetworkSupport/1.0 wispr`) and no cookies. It runs only while failover
is running with a hotspot configured, and it reaches Apple's server only.

Set **System Settings → Wi-Fi → Ask to join hotspots → Automatically**, then
enter the hotspot SSID and password in Ember Settings. The password is
stored in the login Keychain under service `ember-hotspot`. Ember uses
CoreWLAN to find and join that network without putting the password in process
arguments.

The Keychain item's access list names only the build of Ember that saved
it, and Ember reads it with Keychain prompts switched off, so a join during
an outage never raises a dialog. The installer signs each build ad hoc, which
gives every install a new identity: after a reinstall the saved password is
unreadable by the new build. Ember then skips the join, shows "Hotspot
password unreadable by this build" in the right-click menu and in Settings,
and sends one notification per outage. The warning belongs to the SSID it was
read for. Change the SSID and it goes, and Settings checks the new SSID's
saved password instead. Enter the password again in Settings and save; the
save writes the new password before it removes the old item,
and macOS may ask you to allow Ember to delete the old one, or to unlock
the login keychain. If that save is cut off after the old item is gone,
the password reads as missing and you enter it once more: Ember never
reads a half-finished save's copy. The Save button reads "Saving…" until
macOS answers, and "Saved" only while the SSID and password fields still
hold what was saved. A join that was waiting while you changed the SSID is
dropped, and the next retry uses the new SSID. A Settings read that was
waiting is dropped too, and Settings reads the new SSID's password instead.
Anything you type in the password field while Settings is still loading the
saved one stays, even if you delete it again. The rest of Ember,
including the battery floor and End, keeps running while the dialog is open.
A build signed with a stable identity would keep the item readable across
upgrades.

macOS requires Location Services permission to reveal network names. Ember
requests it on the first hotspot save, or when starting a session with a
configured hotspot, not merely on launch. If denied, use the Location row in
Settings to open **Privacy & Security → Location Services**. Mac apps have no
when-in-use grant, so System Settings records it as Location Services access
for Ember. Ember uses it only to read Wi-Fi network names through
CoreWLAN and never requests your location.

## Chrome, Chromium, Arc and Comet throttling

Chromium browsers can throttle windows macOS considers occluded, including
when the lid is closed. Ember detects supported running browsers missing
`--disable-backgrounding-occluded-windows` or `--disable-renderer-backgrounding`
and offers **Relaunch [browser] unthrottled** in the right-click menu. The item
asks first, because the browser is quit and its windows and tabs come back only
if it is set to reopen them on startup. If the browser has quit by the time you
confirm, nothing is quit or launched and a notification says so. Ember reads the browser's profile
arguments before quitting and carries them over. If it cannot read them, cannot
read the kernel's start time that ties them to the browser, or the browser
quits on its own while they are read, it quits nothing and says so. If the
browser has not quit after 10 s, nothing is launched, and a notification says
so: a second copy beside the first would be worse than a throttled one. The
quit request stands, so a browser that closes later has to be opened again by
hand. After `open` returns, Ember waits up to 5 s for the browser to show up
as running and notifies if it does not. Each of these reasons also stays in the
right-click menu as a warning line, one per browser, until that browser's next
relaunch or the next session, so it is there even with notifications off. A
relaunch that ends after its session ended, or after a newer relaunch of the
same browser started, reports nothing. This is not a guarantee that every web
app will keep working while the lid is closed.

## Configuration and privacy

Configuration lives in `~/Library/Application Support/Ember/config.json`.
Use Settings for the app's controls; [Config.swift](../Sources/Ember/Model/Config.swift)
defines the full configuration and defaults. Local logs can contain SSIDs,
and process metadata. Check them before sharing publicly.
Lines the app writes to `ember.log` also go to the unified log with their
bodies marked private, so `log show` and other local programs see `<private>`
in place of the text unless private data logging is enabled on the Mac. The
backstop's lines go only to `ember.log`, which keeps the full text of both.
The files in Application Support/Ember and Logs/Ember (config, session,
journal, recovery lock, the record of a power command left running, the two
logs) are owner-only, mode 0600 with those two directories 0700, and one left
looser by an older build is tightened the next time the app or the backstop
opens it. Ember sets only these modes and
leaves any access control list (ACL) on these files and folders as it is, so
an ACL someone added, or one inherited from a parent folder, can still give
another account access (`ls -le` shows it). The LaunchAgent plist and the installed
scripts hold no private data and keep the modes the installer gives them.
`ember.log` and `handoffs.log` are capped at 1 MiB: a
log past the cap is renamed to `ember.log.1` or `handoffs.log.1`,
replacing the previous copy, and a new file starts. The cap does not apply
to a log you replace with a symlink. Ember writes through the link and
never rotates it, since the rename would move the link and not the file it
points to, and it logs that once. You set up the link, so trimming the file
it points to is up to you.

`EMBER_HOME` relocates app support files, logs, and LaunchAgents for testing.
It is **not an installation sandbox**: installation/removal also involves the
app bundle and sudoers rule. The installer refuses a relocated home. See
[Paths.swift](../Sources/Ember/Store/Paths.swift) for the layout.
