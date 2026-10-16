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

    @ObservationIgnored private var config: Config
    @ObservationIgnored private let scanner: any WiFiScanning
    @ObservationIgnored private let secrets: any HotspotSecretStore
    @ObservationIgnored private let saveConfig: @MainActor (Config) throws -> Void
    @ObservationIgnored private let passwordStored: @MainActor (HotspotStoreOutcome) -> Void

    init(config: Config, scanner: any WiFiScanning, secrets: any HotspotSecretStore,
         saveConfig: @escaping @MainActor (Config) throws -> Void,
         passwordStored: @escaping @MainActor (HotspotStoreOutcome) -> Void) {
        self.config = config
        self.scanner = scanner
        self.secrets = secrets
        self.saveConfig = saveConfig
        self.passwordStored = passwordStored
        typedName = config.hotspotSSID
        alsoInScreenMode = config.awakeHotspotFailover
    }

    var chosenName: String { HotspotSSID.normalized(typedName) }

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
        var updated = config
        updated.hotspotSSID = chosenName
        updated.awakeHotspotFailover = alsoInScreenMode
        do {
            try saveConfig(updated)
        } catch {
            saveError = "Could not save the settings: \(error.localizedDescription)"
            return
        }
        config = updated
        let outcome = await SettingsView.storePassword(hasNoPassword ? "" : password, in: secrets)
        passwordStored(outcome)
        if let notice = outcome.notice {
            saveError = notice
            return
        }
        saveError = nil
        step = .done
    }
}
