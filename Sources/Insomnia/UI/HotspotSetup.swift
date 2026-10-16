import Foundation
import Observation

/// The guided hotspot setup (spec 2026-10-16 explanations, part 3) as a
/// model: the step, the choices and what Continue does. `HotspotSetupView`
/// only draws it. A new one starts at step 1 with the current values.
@MainActor
@Observable
final class HotspotSetup {
    enum Step: Int, CaseIterable {
        case wifiNames, hotspot, password, done
    }

    private(set) var step: Step = .wifiNames
    /// The hotspot's name as typed; picking a network fills it.
    var typedName: String
    private(set) var networks: ScannedNetworks?
    private(set) var scanError: String?
    private(set) var scanning = false
    var password = ""
    var hasNoPassword = false
    var alsoInScreenMode: Bool
    private(set) var saveError: String?
    private(set) var saving = false

    @ObservationIgnored private let scanner: any WiFiScanning
    @ObservationIgnored private let secrets: any HotspotSecretStore
    /// Writes the hotspot name and the screen-mode toggle into the app's
    /// live config and config.json, leaving every other setting as it is.
    @ObservationIgnored private let saveHotspot: @MainActor (_ ssid: String, _ alsoInScreenMode: Bool) throws -> Void
    @ObservationIgnored private let passwordStored: @MainActor (HotspotStoreOutcome) -> Void

    init(config: Config, scanner: any WiFiScanning, secrets: any HotspotSecretStore,
         saveHotspot: @escaping @MainActor (_ ssid: String, _ alsoInScreenMode: Bool) throws -> Void,
         passwordStored: @escaping @MainActor (HotspotStoreOutcome) -> Void) {
        self.scanner = scanner
        self.secrets = secrets
        self.saveHotspot = saveHotspot
        self.passwordStored = passwordStored
        typedName = config.hotspotSSID
        alsoInScreenMode = config.awakeHotspotFailover
    }

    var chosenName: String { HotspotSSID.normalized(typedName) }

    /// The name the last save wrote (what Done names).
    private(set) var savedName = ""

    var canContinue: Bool {
        guard !saving else { return false }
        switch step {
        case .wifiNames, .done: return true
        case .hotspot: return !chosenName.isEmpty
        case .password: return hasNoPassword || !password.isEmpty
        }
    }

    /// Step 1 to 2 starts a scan; step 3 saves and moves on only when the
    /// save went through.
    func next() async {
        guard canContinue else { return }
        switch step {
        case .wifiNames:
            step = .hotspot
            await rescan()
        case .hotspot:
            step = .password
        case .password:
            await save()
        case .done:
            break
        }
    }

    func back() {
        // Not while a save runs: it would finish for the name it started with.
        guard !saving else { return }
        switch step {
        case .hotspot: step = .wifiNames
        case .password: step = .hotspot
        case .wifiNames, .done: break
        }
    }

    func pick(_ name: String) {
        typedName = name
    }

    func rescan() async {
        scanning = true
        defer { scanning = false }
        do {
            networks = try await scanner.scan()
            scanError = nil
        } catch {
            networks = nil
            scanError = error.localizedDescription
        }
    }

    /// The name and the toggle first: the keychain store keys the password
    /// by the configured hotspot. A refused password keeps the name saved
    /// and stays on this step with the reason.
    private func save() async {
        saving = true
        defer { saving = false }
        let name = chosenName
        do {
            try saveHotspot(name, alsoInScreenMode)
        } catch {
            saveError = "Could not save the settings: \(error.localizedDescription)"
            return
        }
        let outcome = await SettingsView.storePassword(hasNoPassword ? "" : password, in: secrets)
        passwordStored(outcome)
        if let notice = outcome.notice {
            saveError = notice
            return
        }
        saveError = nil
        savedName = name
        step = .done
    }
}
