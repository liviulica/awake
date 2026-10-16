import XCTest
@testable import Insomnia

/// The guided hotspot setup as a pure model (spec 2026-10-16 explanations,
/// part 3). The window that draws it is in HotspotSetupViewTests.
@MainActor
final class HotspotSetupTests: XCTestCase {
    private struct FakeScanner: WiFiScanning {
        var result: Result<ScannedNetworks, Error>
        func scan() async throws -> ScannedNetworks { try result.get() }
    }

    private struct ScanFailed: Error, LocalizedError {
        var errorDescription: String? { "No Wi-Fi interface" }
    }

    /// A store whose save can be told to fail.
    @MainActor
    private final class FlakyStore: HotspotSecretStore {
        var failSave = false
        /// Holds a save until opened.
        var gate: AsyncGate?
        private(set) var password: String?
        func load() async throws -> String? { password }
        func peek() async throws -> String? { password }
        func save(_ password: String) async throws -> HotspotPasswordChange {
            if let gate { await gate.wait() }
            if failSave { throw KeychainError(status: errSecIO) }
            self.password = password
            return HotspotPasswordChange(ssid: "")
        }
        func delete() async throws -> HotspotPasswordChange {
            password = nil
            return HotspotPasswordChange(ssid: "")
        }
    }

    /// The app's live config: the setup writes only its two fields into it.
    private var live = Config()
    private var savedConfigs: [Config] = []
    private var outcomes: [HotspotStoreOutcome] = []

    private func make(config: Config? = nil, scan: Result<ScannedNetworks, Error> = .success(ScannedNetworks(names: ["Home", "iPhone"], current: "Home")),
                      store: FlakyStore = FlakyStore()) -> HotspotSetup {
        if let config { live = config }
        return HotspotSetup(config: live, scanner: FakeScanner(result: scan), secrets: store,
                            saveHotspot: { [unowned self] ssid, alsoInScreenMode in
                                self.live.hotspotSSID = ssid
                                self.live.awakeHotspotFailover = alsoInScreenMode
                                self.savedConfigs.append(self.live)
                            },
                            passwordStored: { [unowned self] in self.outcomes.append($0) })
    }

    func testStartsAtWiFiNamesWithTheCurrentValues() {
        var config = Config()
        config.hotspotSSID = "Old Phone"
        config.awakeHotspotFailover = true
        let setup = make(config: config)
        XCTAssertEqual(setup.step, .wifiNames)
        XCTAssertEqual(setup.typedName, "Old Phone")
        XCTAssertTrue(setup.alsoInScreenMode)
        XCTAssertTrue(setup.canContinue, "step 1 never blocks: names can be typed later")
    }

    func testContinuingToTheHotspotStepScans() async {
        let setup = make()
        await setup.next()
        XCTAssertEqual(setup.step, .hotspot)
        XCTAssertEqual(setup.networks, ScannedNetworks(names: ["Home", "iPhone"], current: "Home"))
        XCTAssertNil(setup.scanError)
    }

    func testTheScannerNormalisesNames() {
        XCTAssertEqual(CoreWLANScanner.normalised(["b", "A", "b", "", "  "]), ["A", "b"])
    }

    /// Review focus 4: a failed scan still lets a typed name through.
    func testAFailedScanStillAllowsATypedName() async {
        let setup = make(scan: .failure(ScanFailed()))
        await setup.next()
        XCTAssertNil(setup.networks)
        XCTAssertEqual(setup.scanError, "No Wi-Fi interface")
        setup.typedName = "  "
        XCTAssertFalse(setup.canContinue)
        setup.typedName = "My iPhone"
        XCTAssertTrue(setup.canContinue)
    }

    func testPickingFillsTheName() async {
        let setup = make()
        await setup.next()
        setup.typedName = ""
        XCTAssertFalse(setup.canContinue)
        setup.pick("iPhone")
        XCTAssertEqual(setup.typedName, "iPhone")
        XCTAssertTrue(setup.canContinue)
    }

    func testThePasswordStepNeedsAPasswordOrTheNoPasswordBox() async {
        let setup = make()
        await setup.next()
        setup.pick("iPhone")
        await setup.next()
        XCTAssertEqual(setup.step, .password)
        XCTAssertFalse(setup.canContinue)
        setup.hasNoPassword = true
        XCTAssertTrue(setup.canContinue)
        setup.hasNoPassword = false
        setup.password = "secret"
        XCTAssertTrue(setup.canContinue)
    }

    func testSaveWritesTheNameTheToggleAndThePassword() async {
        let store = FlakyStore()
        let setup = make(store: store)
        await setup.next()
        setup.pick("iPhone")
        await setup.next()
        setup.password = "secret"
        setup.alsoInScreenMode = true
        await setup.next()
        XCTAssertEqual(setup.step, .done)
        XCTAssertEqual(savedConfigs.last?.hotspotSSID, "iPhone")
        XCTAssertEqual(savedConfigs.last?.awakeHotspotFailover, true)
        XCTAssertEqual(store.password, "secret")
        guard case .stored = outcomes.last else { return XCTFail("the failover was not told: \(outcomes)") }
    }

    /// Review focus 3: the keychain refuses. The name stays saved, the step
    /// stays on Password with the reason, and a retry finishes.
    func testAFailedPasswordSaveStaysAndARetryFinishes() async {
        let store = FlakyStore()
        store.failSave = true
        let setup = make(store: store)
        await setup.next()
        setup.pick("iPhone")
        await setup.next()
        setup.password = "secret"
        await setup.next()
        XCTAssertEqual(setup.step, .password)
        XCTAssertNotNil(setup.saveError)
        XCTAssertEqual(savedConfigs.last?.hotspotSSID, "iPhone", "the name is kept, not rolled back")
        store.failSave = false
        await setup.next()
        XCTAssertEqual(setup.step, .done)
        XCTAssertNil(setup.saveError)
        XCTAssertEqual(store.password, "secret")
    }

    func testNoPasswordClearsTheStoredOne() async {
        let store = FlakyStore()
        _ = try? await store.save("old")
        let setup = make(store: store)
        await setup.next()
        setup.pick("Open Hotspot")
        await setup.next()
        setup.hasNoPassword = true
        await setup.next()
        XCTAssertEqual(setup.step, .done)
        XCTAssertNil(store.password)
    }

    func testBackKeepsTheChoices() async {
        let setup = make()
        await setup.next()
        setup.pick("iPhone")
        await setup.next()
        setup.back()
        XCTAssertEqual(setup.step, .hotspot)
        XCTAssertEqual(setup.typedName, "iPhone")
        setup.back()
        XCTAssertEqual(setup.step, .wifiNames)
    }

    /// Review focus 5: a new setup from the saved config starts over with
    /// the saved name filled in.
    func testReopeningStartsAtStepOneWithTheSavedName() async {
        let setup = make()
        await setup.next()
        setup.pick("iPhone")
        await setup.next()
        setup.password = "secret"
        await setup.next()
        let again = make(config: savedConfigs.last ?? Config())
        XCTAssertEqual(again.step, .wifiNames)
        XCTAssertEqual(again.typedName, "iPhone")
    }

    /// Final review / Codex: a setting changed elsewhere while the window
    /// was open survives the save; only the two hotspot fields are written.
    func testSaveKeepsSettingsChangedWhileTheWindowWasOpen() async {
        let setup = make()
        live.lidKeepsScreenOn = false
        live.freezeList = ["com.example.app"]
        await setup.next()
        setup.pick("iPhone")
        await setup.next()
        setup.password = "secret"
        await setup.next()
        XCTAssertEqual(setup.step, .done)
        XCTAssertEqual(live.hotspotSSID, "iPhone")
        XCTAssertFalse(live.lidKeepsScreenOn, "the newer setting survived")
        XCTAssertEqual(live.freezeList, ["com.example.app"])
    }

    /// Codex: Back while the password save runs does nothing, and Done
    /// names the hotspot that was saved.
    func testBackIsIgnoredWhileSaving() async {
        let store = FlakyStore()
        let gate = AsyncGate()
        store.gate = gate
        let setup = make(store: store)
        await setup.next()
        setup.pick("iPhone")
        await setup.next()
        setup.password = "secret"
        let saving = Task { await setup.next() }
        await gate.waitUntilStarted()
        XCTAssertTrue(setup.saving)
        setup.back()
        XCTAssertEqual(setup.step, .password, "no going back mid-save")
        setup.typedName = "Other"
        await gate.open()
        await saving.value
        XCTAssertEqual(setup.step, .done)
        XCTAssertEqual(setup.savedName, "iPhone", "Done names what was saved")
    }
}
