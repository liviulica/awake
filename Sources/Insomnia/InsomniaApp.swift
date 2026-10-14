import AppKit
import SwiftUI

/// Menu bar app. The status item is a plain `NSStatusItem`, and
/// the settings window is an `NSWindow` this app opens itself (see
/// `SettingsWindow`), so there is no SwiftUI scene with any content in it.
/// `App` still requires one, hence the empty `Settings`. main.swift starts
/// this app unless the command line asks for a one-shot mode first.
struct InsomniaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager: SessionManager
    let status: any StatusSource
    let secrets: any HotspotSecretStore
    let locationPermission: LocationPermission
    let loginItem = LoginItem()
    /// Awake mode (spec "Interaction"): the left-click hold.
    let awake = AwakeController(assertion: IOPMAwakeAssertion())
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindow?
    private var terminating = false

    override init() {
        let manager = SessionManager.live()
        self.manager = manager
        secrets = KeychainHotspotSecretStore(keychain: KeychainStore()) {
            manager.config.hotspotSSID
        }
        if let services = manager.services {
            status = LiveStatusSource(services: services)
            locationPermission = services.locationPermission
        } else {
            Log.error("live SessionManager has no AppServices; using placeholder status")
            status = PlaceholderStatus()
            locationPermission = LocationPermission()
        }
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch finishes, so the first notification already shows
        // while Insomnia is frontmost.
        ForegroundNotifications.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon even when run from `swift run` (the bundle has LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        Log.info("launched")
        if LidSimulationBuild.isCompiledIn {
            Log.info(LidSimulationBuild.marker)
        }
        // The login item is tied to the bundle's signature, which install.sh
        // renews on every run: register again if the flag is on, macOS no
        // longer reports the item and the install changed; follow the user
        // if they removed the item for the install macOS had on file.
        var config = manager.config
        if loginItem.healAtLaunch(config: &config) {
            manager.config = config
            do {
                try manager.store.saveConfig(config)
            } catch {
                Log.error("could not save config after the launch at login check: \(error.localizedDescription)")
            }
        }
        let settings = SettingsWindow { [manager, secrets, locationPermission, loginItem] in
            AnyView(
                SettingsView(
                    manager: manager,
                    secrets: secrets,
                    locationPermission: locationPermission,
                    loginItem: loginItem
                )
            )
        }
        settingsWindow = settings
        statusItem = StatusItemController(manager: manager, status: status, awake: awake) { [weak settings] in
            settings?.show()
        }
        // Awake mode runs hotspot failover when the setting is on. A lid
        // session (which includes screen mode) runs its own.
        awake.onChange = { [weak self] _ in self?.reconcileAwakeFailover() }
        observeAwakeFailoverInputs()
        Task { await manager.reconcile() }
    }

    /// Starts or stops Awake mode's failover from the current Awake state,
    /// setting, hotspot and lid session. Idempotent.
    private func reconcileAwakeFailover() {
        guard let services = manager.services else { return }
        let want = AppServices.shouldRunAwakeFailover(
            awakeOn: awake.state != .off,
            setting: manager.config.awakeHotspotFailover,
            hotspotSSID: manager.config.hotspotSSID,
            lidActive: manager.isActive
        )
        if want {
            services.startAwakeFailover { [weak manager = self.manager] in manager?.config ?? Config() }
        } else {
            services.stopAwakeFailover()
        }
    }

    /// Re-reconciles when the setting, the hotspot, a lid session or Awake
    /// mode changes (Settings edits `manager.config` directly).
    private func observeAwakeFailoverInputs() {
        withObservationTracking {
            _ = manager.config
            _ = manager.session
            _ = awake.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reconcileAwakeFailover()
                self.observeAwakeFailoverInputs()
            }
        }
    }

    /// Quitting always ends the session (spec 1). Terminate is deferred until
    /// the end has run. A second quit while that is pending is refused rather
    /// than allowed through: `.terminateNow` there would exit mid-cleanup.
    /// If the end could not run (recovery lock busy, journal unreadable),
    /// left the journal dirty with no agent to retry, or could not remove
    /// session.json, the app stays so its own retry can finish the job;
    /// quitting then would abandon a live session. It also stays while a
    /// `sudo pmset` that ignored SIGTERM is alive. The recovery lock would
    /// outlive a quit (the command holds it through its own descriptor),
    /// but the end the command holds up would not: the app is what retries
    /// it, and confirms an undo the command finishes, the moment it exits.
    /// It stays while a closed lid's sleep is owed: only the app asks for it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateCancel }
        terminating = true
        // Awake mode ends with the quit, right away: it needs no cleanup,
        // and a deferred session end below must not keep it running.
        awake.turnOff(reason: "quit")
        Task {
            let outcome = await manager.end(reason: .quit)
            if outcome.letsQuitGo, !manager.closedLidSleepOwed {
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                Log.error("quit deferred: recovery still pending (\(outcome)); staying to retry")
                terminating = false
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
