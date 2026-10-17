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
    /// Screen mode (spec "Interaction"): the left-click hold.
    let awake = AwakeController(assertion: IOPMAwakeAssertion())
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindow?
    private var hotspotSetupWindow: HotspotSetupWindow?
    /// The helper and the updater of a release build (spec 2026-10-17); nil
    /// in a source build and in test mode.
    private var release: ReleaseSetup?
    private var terminating = false
    #if DEBUG || INSOMNIA_LID_SIMULATION
    /// The smoke test's mode (`TestMode`): nil unless the environment asks
    /// for it, so a lid simulation build otherwise runs like a release one.
    private let testMode: TestMode?
    private var testControl: TestControl?
    #endif

    override init() {
        #if DEBUG || INSOMNIA_LID_SIMULATION
        let testMode = TestMode.requested()
        self.testMode = testMode
        let manager = testMode?.makeManager() ?? SessionManager.live()
        #else
        let manager = SessionManager.live()
        #endif
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
        awake.keepsScreenOnWhileLidOpen = { [manager] in manager.config.lidKeepsScreenOn }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch finishes, so the first notification already shows
        // while Insomnia is frontmost.
        ForegroundNotifications.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon even when run from `swift run` (the bundle has LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        Log.info("launched \(SettingsView.versionText())\(ReleaseSignature.isDeveloperID ? ", release build" : "")")
        if wantsReleaseSetup {
            // Before anything is armed or registered against this path.
            guard ReleaseSetup.checkLocation() else { exit(0) }
            let manager = self.manager, awake = self.awake
            let updater = Updater(
                moment: {
                    let session = manager.session
                    return UpdateMoment.of(
                        screenOn: awake.state != .off,
                        lidActive: session != nil,
                        lidPaused: session?.isPaused ?? false,
                        lidRemaining: session?.closedLidRemaining(at: Date()) ?? 0
                    )
                },
                restoreLid: { ResumeAfterUpdate.save(remaining: $0, at: manager.paths.resumeAfterUpdateFile) },
                turnOffScreen: { awake.turnOff(reason: "update") }
            )
            release = ReleaseSetup(helper: liveHelper, updater: updater)
        }
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
        let setup = HotspotSetupWindow(make: { [manager, secrets] in
            HotspotSetup(
                config: manager.config,
                scanner: CoreWLANScanner(),
                secrets: secrets,
                saveHotspot: { ssid, alsoInScreenMode in
                    manager.config.hotspotSSID = ssid
                    manager.config.awakeHotspotFailover = alsoInScreenMode
                    try manager.store.saveConfig(manager.config)
                },
                passwordStored: { outcome in
                    SettingsView.passwordStored(outcome, configuredSSID: manager.config.hotspotSSID, services: manager.services)
                }
            )
        }, locationPermission: locationPermission)
        hotspotSetupWindow = setup
        let settings = SettingsWindow { [manager, secrets, locationPermission, loginItem, awake, weak setup, release] in
            AnyView(
                SettingsView(
                    manager: manager,
                    secrets: secrets,
                    locationPermission: locationPermission,
                    loginItem: loginItem,
                    lidScreenSettingChanged: { awake.settingsChanged() },
                    showHotspotSetup: { setup?.show() },
                    release: release
                )
            )
        }
        settingsWindow = settings
        statusItem = StatusItemController(manager: manager, status: status, awake: awake, showSettings: { [weak settings] in
            settings?.show()
        }, showHotspotSetup: { [weak setup] in
            setup?.show()
        }, release: release)
        #if DEBUG || INSOMNIA_LID_SIMULATION
        if let testMode {
            Log.info(TestMode.marker)
            let control = TestControl(mode: testMode, manager: manager, awake: awake) {
                // Not from the main actor's queue: terminate waits for the
                // deferred reply (applicationShouldTerminate) in a nested
                // run loop, and the end that sends it runs on that queue,
                // which cannot drain while it is inside one of its own jobs.
                // A run loop block runs outside it, as a menu click does.
                RunLoop.main.perform {
                    MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
                }
            }
            control.start()
            testControl = control
        }
        #endif
        // Screen mode runs hotspot failover when the setting is on. A lid
        // session (which includes screen mode) runs its own.
        awake.onChange = { [weak self] _ in self?.reconcileAwakeFailover() }
        observeAwakeFailoverInputs()
        Task { await manager.reconcile() }
        release?.launch(manager: manager)
    }

    /// A release build outside test mode.
    private var wantsReleaseSetup: Bool {
        #if DEBUG || INSOMNIA_LID_SIMULATION
        if testMode != nil { return false }
        #endif
        return ReleaseSignature.isDeveloperID
    }

    /// Starts or stops screen mode's failover from the current screen mode state,
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

    /// Re-reconciles when the setting, the hotspot, a lid session or Ember
    /// mode changes (Settings edits `manager.config` directly), and lets a
    /// lid session's failover start or stop its internet check.
    private func observeAwakeFailoverInputs() {
        withObservationTracking {
            _ = manager.config
            _ = manager.session
            _ = awake.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reconcileAwakeFailover()
                self.manager.services?.configChanged()
                self.release?.updater?.busyChanged()
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
        // Screen mode ends with the quit, right away: it needs no cleanup,
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
