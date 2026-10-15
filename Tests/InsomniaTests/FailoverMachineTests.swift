import XCTest
@testable import Insomnia

final class RecordingHotspotJoiner: HotspotJoining, @unchecked Sendable {
    struct Call: Equatable {
        let ssid: String
        let password: String
        let interfaceName: String
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _visible: Set<String> = []
    private var _leaves = 0
    private var _visibleError = false
    private var _onLeave: (@MainActor @Sendable () async -> Void)?
    private var _network: Locked<String?>?
    private var _autoJoin: String? = "Home"
    var result = true
    var calls: [Call] { lock.withLock { _calls } }
    var visible: Set<String> {
        get { lock.withLock { _visible } }
        set { lock.withLock { _visible = newValue } }
    }
    /// How many times the driver left the hotspot for a known network.
    var leaves: Int { lock.withLock { _leaves } }
    /// Runs inside `leaveForKnownNetwork`, after macOS's auto-join, as the
    /// network changes a leave causes.
    var onLeave: (@MainActor @Sendable () async -> Void)? {
        get { lock.withLock { _onLeave } }
        set { lock.withLock { _onLeave = newValue } }
    }
    /// The network the Mac is on, as the driver's SSID reader sees it. When
    /// set, a successful join moves it to the hotspot and a leave moves it
    /// to `autoJoin`.
    var network: Locked<String?>? {
        get { lock.withLock { _network } }
        set { lock.withLock { _network = newValue } }
    }
    /// The network macOS auto-joins after a leave; nil joins nothing.
    var autoJoin: String? {
        get { lock.withLock { _autoJoin } }
        set { lock.withLock { _autoJoin = newValue } }
    }
    /// Makes `isVisible` throw, as a failed scan does.
    var visibleError: Bool {
        get { lock.withLock { _visibleError } }
        set { lock.withLock { _visibleError = newValue } }
    }

    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool {
        let (ok, network) = lock.withLock {
            _calls.append(Call(ssid: ssid, password: password, interfaceName: interfaceName))
            return (result, _network)
        }
        if ok { network?.value = ssid }
        return ok
    }

    func isVisible(ssid: String, interfaceName: String) async throws -> Bool {
        if lock.withLock({ _visibleError }) { throw HotspotJoinError.missingInterface(interfaceName) }
        return lock.withLock { _visible.contains(ssid) }
    }

    func leaveForKnownNetwork(interfaceName: String) async throws {
        let (network, autoJoin, hook): (Locked<String?>?, String?, (@MainActor @Sendable () async -> Void)?) = lock.withLock {
            _leaves += 1
            return (_network, _autoJoin, _onLeave)
        }
        network?.value = autoJoin
        await hook?()
    }
}

final class FailoverMachineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testShortBlipDoesNotJoin() {
        var m = FailoverMachine()
        XCTAssertEqual(m.pathUnsatisfied(at: t0), [.scheduleRetry(after: 5)])
        // Satisfied again after 3 s: the driver cancels the timer; the
        // machine reports the recovery and no join ever happened.
        XCTAssertEqual(m.pathSatisfied(at: t0.addingTimeInterval(3)), [.recovered(start: t0, gap: 3)])
        XCTAssertFalse(m.inOutage)
        XCTAssertEqual(m.joins, 0)
        // A stale timer firing after recovery is ignored.
        XCTAssertEqual(m.timerFired(at: t0.addingTimeInterval(5)), [])
    }

    func testTimerBeforeInitialDelayDoesNotJoin() {
        var m = FailoverMachine()
        XCTAssertEqual(m.pathUnsatisfied(at: t0), [.scheduleRetry(after: 5)])
        XCTAssertEqual(m.timerFired(at: t0.addingTimeInterval(4.999)), [])
        XCTAssertEqual(
            m.timerFired(at: t0.addingTimeInterval(5)),
            [.joinHotspot, .scheduleRetry(after: 5)]
        )
    }

    func testLongOutageJoinsThenBacksOff() {
        var m = FailoverMachine()
        XCTAssertEqual(m.pathUnsatisfied(at: t0), [.scheduleRetry(after: 5)])
        var t = t0.addingTimeInterval(5)
        var delays: [TimeInterval] = []
        for _ in 0..<7 {
            let out = m.timerFired(at: t)
            XCTAssertEqual(out.first, .joinHotspot)
            guard case let .scheduleRetry(after)? = out.last else { return XCTFail("expected retry") }
            delays.append(after)
            t = t.addingTimeInterval(after)
        }
        XCTAssertEqual(delays, [5, 10, 20, 30, 30, 30, 30])
        XCTAssertEqual(m.joins, 7)
        let out = m.pathSatisfied(at: t)
        XCTAssertEqual(out, [.recovered(start: t0, gap: t.timeIntervalSince(t0))])
        XCTAssertEqual(m.joins, 0)
    }

    func testRepeatedUnsatisfiedDuringOutageIsIgnored() {
        var m = FailoverMachine()
        _ = m.pathUnsatisfied(at: t0)
        XCTAssertEqual(m.pathUnsatisfied(at: t0.addingTimeInterval(1)), [])
        XCTAssertEqual(m.outageStart, t0)
    }

    func testSatisfiedWithoutOutageIsIgnored() {
        var m = FailoverMachine()
        XCTAssertEqual(m.pathSatisfied(at: t0), [])
    }

    func testLogLineFormat() {
        let end = t0.addingTimeInterval(130)
        XCTAssertEqual(
            FailoverMachine.logLine(start: t0, end: end, gap: 130),
            "2027-01-15T08:02:10Z outage start=2027-01-15T08:00:00Z end=2027-01-15T08:02:10Z gap=130s"
        )
    }

    func testHumanGap() {
        XCTAssertEqual(FailoverMachine.humanGap(130), "2m 10s")
        XCTAssertEqual(FailoverMachine.humanGap(45), "45s")
        XCTAssertEqual(FailoverMachine.humanGap(3723), "1h 2m 3s")
        XCTAssertEqual(FailoverMachine.humanGap(120), "2m")
        XCTAssertEqual(FailoverMachine.humanGap(0), "0s")
    }
}

@MainActor
final class NetworkFailoverDriverTests: XCTestCase {
    var home: TempHome!

    override func setUp() async throws { home = TempHome() }
    override func tearDown() async throws { home.destroy() }

    func testLongOutageRecoveryNotifiesWithoutTmuxText() async throws {
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: notifier, clock: clock)
        await n.simulate(satisfied: false)
        clock.advance(NetworkFailover.recoveredNoticeThreshold)
        await n.simulate(satisfied: true)
        let post = try XCTUnwrap(notifier.posts.last)
        XCTAssertEqual(post.title, "Network recovered")
        XCTAssertFalse(post.body.contains("tmux"), post.body)
    }

    func testShortOutageRecoveryDoesNotNotify() async {
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: notifier, clock: clock)
        await n.simulate(satisfied: false)
        clock.advance(NetworkFailover.recoveredNoticeThreshold - 1)
        await n.simulate(satisfied: true)
        XCTAssertFalse(notifier.posts.contains { $0.title == "Network recovered" })
    }

    func testHotspotJoinUsesInjectedJoiner() async throws {
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "top secret")
        let joiner = RecordingHotspotJoiner()
        var config = Config()
        config.hotspotSSID = "Phone"
        let n = NetworkFailover(
            paths: home.paths,
            keychain: keychain,
            hotspotJoiner: joiner,
            probe: FakeProbe([true]),
            notifier: RecordingNotifier(),
            wifiInterface: "en0"
        ) { config }

        await n.joinHotspot()

        XCTAssertEqual(
            joiner.calls,
            [.init(ssid: "Phone", password: "top secret", interfaceName: "en0")]
        )
        XCTAssertNil(n.passwordReport?.problem)
    }

    /// A join whose keychain read waits behind a save in Settings (stuck
    /// on a keychain dialog) does not hold up stop(), and once the session
    /// has ended the read's answer neither joins nor reports anything.
    func testAJoinWaitingBehindABlockedSaveDoesNothingAfterTheSessionEnds() async throws {
        let queue = KeychainQueue()
        let keychain = BlockingKeychain(items: ["\(KeychainStore.service)/Phone": "old"])
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: queue) { "Phone" }
        let saving = Task { await SettingsView.storePassword("new", in: store) }
        await fulfillment(of: [keychain.entered], timeout: 5)

        let joiner = RecordingHotspotJoiner()
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let joining = expectation(description: "the join started")
        joining.assertForOverFulfill = false
        var config = Config()
        config.hotspotSSID = "Phone"
        let n = NetworkFailover(
            paths: home.paths,
            keychain: keychain,
            keychainQueue: queue,
            hotspotJoiner: joiner,
            probe: FakeProbe([true]),
            notifier: notifier,
            wifiInterface: "en0",
            clock: { clock.now }
        ) {
            joining.fulfill()
            return config
        }
        await n.simulate(satisfied: false)
        clock.advance(30)
        let tick = n.fireTimer()
        await fulfillment(of: [joining], timeout: 5)

        n.stop()
        XCTAssertTrue(keychain.isWaiting, "stop() ran while the save was still waiting")
        keychain.release()
        _ = await saving.value
        await tick.value

        XCTAssertEqual(joiner.calls, [])
        XCTAssertEqual(notifier.posts.map(\.title), [])
        XCTAssertNil(n.passwordReport?.problem)
        XCTAssertFalse(keychain.gaveUp)
    }

    /// Wi-Fi recovers while a join's keychain read waits behind a save in
    /// Settings. Once the save is answered the read finds the password,
    /// but the outage is over: nothing joins, so the recovered connection
    /// is not moved to the hotspot, and the retry the tick queued after
    /// the join is not scheduled.
    func testAJoinWaitingBehindABlockedSaveDoesNothingAfterWiFiRecovers() async throws {
        let keychain = BlockingKeychain(items: ["\(KeychainStore.service)/Phone": "old"])
        let blocked = try await outageWithAJoinBehindABlockedSave(keychain: keychain, savingFor: "Phone")

        await blocked.driver.simulate(satisfied: true)
        XCTAssertTrue(keychain.isWaiting, "Wi-Fi recovered while the save was still waiting")
        keychain.release()
        _ = await blocked.saving.value
        await blocked.tick.value

        XCTAssertEqual(blocked.joiner.calls, [])
        XCTAssertNil(blocked.driver.retryTimer, "a retry was scheduled after the outage ended")
        XCTAssertEqual(blocked.notifier.posts.map(\.title), [])
        XCTAssertNil(blocked.driver.passwordReport?.problem)
        XCTAssertEqual(blocked.driver.lastGap, 30)
        XCTAssertFalse(keychain.gaveUp)
        blocked.driver.stop()
    }

    /// The same wait, but the read then fails: there is no password for
    /// the hotspot. The outage is over, so nothing is reported, and the
    /// notification is still there for the next outage.
    func testAReadThatFailsAfterWiFiRecoveredLeavesTheNoticeForTheNextOutage() async throws {
        let keychain = BlockingKeychain()
        let blocked = try await outageWithAJoinBehindABlockedSave(keychain: keychain, savingFor: "Other Phone")

        await blocked.driver.simulate(satisfied: true)
        keychain.release()
        _ = await blocked.saving.value
        await blocked.tick.value

        XCTAssertEqual(blocked.notifier.posts.map(\.title), [])
        XCTAssertNil(blocked.driver.passwordReport?.problem)
        XCTAssertNil(blocked.driver.retryTimer)

        await blocked.driver.simulate(satisfied: false)
        blocked.clock.advance(30)
        await blocked.driver.fireTimer().value

        XCTAssertEqual(blocked.notifier.posts.map(\.title), ["Hotspot not joined"])
        XCTAssertEqual(blocked.notifier.posts.map(\.body), [HotspotPasswordProblem.missing.explanation])
        XCTAssertEqual(blocked.driver.passwordReport, HotspotPasswordReport(ssid: "Phone", problem: .missing))
        XCTAssertEqual(blocked.joiner.calls, [])
        blocked.driver.stop()
    }

    /// Settings changes the hotspot while a join's keychain read waits
    /// behind a save. The read finds the old hotspot's password, but that
    /// is not the hotspot to join any more: nothing joins or reports. The
    /// retry the tick queued still comes, and joins the hotspot
    /// configured then.
    func testAJoinWhoseHotspotChangedDuringTheReadDoesNotJoinTheOldOne() async throws {
        let keychain = BlockingKeychain(items: ["\(KeychainStore.service)/Phone": "old"])
        let blocked = try await outageWithAJoinBehindABlockedSave(keychain: keychain, savingFor: "Other Phone")

        blocked.hotspot.value = "Other Phone"
        keychain.release()
        _ = await blocked.saving.value
        await blocked.tick.value

        XCTAssertEqual(blocked.joiner.calls, [])
        XCTAssertEqual(blocked.notifier.posts.map(\.title), [])
        XCTAssertNil(blocked.driver.passwordReport?.problem)
        XCTAssertNotNil(blocked.driver.retryTimer, "the retry is still scheduled")

        blocked.clock.advance(30)
        await blocked.driver.fireTimer().value
        XCTAssertEqual(blocked.joiner.calls, [.init(ssid: "Other Phone", password: "new", interfaceName: "en0")])
        XCTAssertFalse(keychain.gaveUp)
        blocked.driver.stop()
    }

    /// The same, but the read finds no password for the old hotspot. The
    /// warning is about a hotspot no longer configured, so it is neither
    /// shown nor notified, and the one notification of this outage is
    /// still there when the next tick finds the new hotspot has no
    /// password either. Clearing the SSID drops the answer the same way.
    func testAWarningAboutTheOldHotspotIsDroppedWhenTheSSIDChanged() async throws {
        for changed in ["Third Phone", " "] {
            let keychain = BlockingKeychain()
            let blocked = try await outageWithAJoinBehindABlockedSave(keychain: keychain, savingFor: "Other Phone")

            blocked.hotspot.value = changed
            keychain.release()
            _ = await blocked.saving.value
            await blocked.tick.value

            XCTAssertEqual(blocked.notifier.posts.map(\.title), [], "SSID changed to \"\(changed)\"")
            XCTAssertNil(blocked.driver.passwordReport?.problem, "SSID changed to \"\(changed)\"")
            XCTAssertNotNil(blocked.driver.retryTimer, "SSID changed to \"\(changed)\"")

            blocked.clock.advance(30)
            await blocked.driver.fireTimer().value
            if HotspotSSID.normalized(changed).isEmpty {
                XCTAssertEqual(blocked.notifier.posts.map(\.title), [], "no hotspot is configured")
                XCTAssertNil(blocked.driver.passwordReport?.problem)
            } else {
                XCTAssertEqual(blocked.notifier.posts.map(\.body), [HotspotPasswordProblem.missing.explanation])
                XCTAssertEqual(blocked.driver.passwordReport, HotspotPasswordReport(ssid: "Third Phone", problem: .missing))
            }
            XCTAssertEqual(blocked.joiner.calls, [])
            XCTAssertFalse(keychain.gaveUp)
            blocked.driver.stop()
        }
    }

    private struct BlockedJoin {
        let driver: NetworkFailover
        let saving: Task<HotspotStoreOutcome, Never>
        let tick: Task<Void, Never>
        let joiner: RecordingHotspotJoiner
        let notifier: RecordingNotifier
        let clock: FakeClock
        /// The configured hotspot SSID, "Phone" until a test changes it.
        let hotspot: Locked<String>
    }

    /// A save for `ssid` blocked inside `keychain`, then an outage on
    /// hotspot "Phone" whose first join has started and queued its read
    /// behind that save.
    private func outageWithAJoinBehindABlockedSave(keychain: BlockingKeychain, savingFor ssid: String) async throws -> BlockedJoin {
        let queue = KeychainQueue()
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: queue) { ssid }
        let saving = Task { await SettingsView.storePassword("new", in: store) }
        await fulfillment(of: [keychain.entered], timeout: 5)

        let joiner = RecordingHotspotJoiner()
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let joining = expectation(description: "the join started")
        joining.assertForOverFulfill = false
        let hotspot = Locked("Phone")
        let n = NetworkFailover(
            paths: home.paths,
            keychain: keychain,
            keychainQueue: queue,
            hotspotJoiner: joiner,
            probe: FakeProbe([true]),
            notifier: notifier,
            wifiInterface: "en0",
            clock: { clock.now }
        ) {
            joining.fulfill()
            var config = Config()
            config.hotspotSSID = hotspot.value
            return config
        }
        await n.simulate(satisfied: false)
        clock.advance(30)
        let tick = n.fireTimer()
        await fulfillment(of: [joining], timeout: 5)
        return BlockedJoin(driver: n, saving: saving, tick: tick, joiner: joiner, notifier: notifier, clock: clock, hotspot: hotspot)
    }

    func testProbeFailuresStartAnOutage() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: RecordingNotifier(),
                       clock: clock, probe: FakeProbe([false]))
        await n.probeTick()
        await n.probeTick()
        XCTAssertFalse(n.machine.inOutage)
        await n.probeTick()
        XCTAssertTrue(n.machine.inOutage, "Wi-Fi associated but no internet counts as an outage")
    }

    func testProbeSuccessEndsAnOutageTheProbeStarted() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: RecordingNotifier(),
                       clock: clock, probe: FakeProbe([false, false, false, true]))
        await n.probeTick()
        await n.probeTick()
        await n.probeTick()
        XCTAssertTrue(n.machine.inOutage)
        clock.advance(20)
        await n.probeTick()
        XCTAssertFalse(n.machine.inOutage, "the internet answering again ends it with no path change")
        XCTAssertEqual(n.lastGap, 20)
    }

    func testStartArmsTheProbeTimerAndStopClearsIt() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: RecordingNotifier(),
                       clock: clock)
        await n.start()
        XCTAssertNotNil(n.probeTimer)
        n.stop()
        XCTAssertNil(n.probeTimer)
    }

    /// No hotspot configured: nothing to fail over to, so no internet
    /// check and no SSID reads (networksetup), only the Wi-Fi path.
    func testWithoutAHotspotNothingIsProbedOrRead() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let probe = CountingProbe(false)
        let reads = Locked(0)
        let n = NetworkFailover(
            paths: home.paths,
            keychain: FakeKeychainStore(),
            hotspotJoiner: RecordingHotspotJoiner(),
            probe: probe,
            ssidReader: { reads.value += 1; return "Home" },
            settle: .zero,
            probeRetryDelay: .zero,
            notifier: RecordingNotifier(),
            wifiInterface: "en0",
            clock: { clock.now }
        ) { Config() }
        await n.start()
        XCTAssertNil(n.probeTimer, "start() scheduled a probe with no hotspot")
        await n.probeTick()
        XCTAssertNil(n.probeTimer)
        await n.simulate(satisfied: false)
        await n.simulate(satisfied: true)
        XCTAssertFalse(n.machine.inOutage, "the path back is the recovery")
        await n.recordHomeNetwork()
        await n.switchBackTick()
        XCTAssertEqual(probe.count, 0)
        XCTAssertEqual(reads.value, 0)
        XCTAssertNil(n.homeSSID)
        n.stop()
    }

    /// A hotspot set in Settings during the session starts the check;
    /// clearing it stops the check.
    func testSettingAndClearingTheHotspotStartsAndStopsTheProbe() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let hotspot = Locked("")
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: RecordingNotifier(),
                       clock: clock, hotspot: hotspot)
        await n.start()
        XCTAssertNil(n.probeTimer)
        hotspot.value = "Phone"
        n.syncProbe()
        XCTAssertNotNil(n.probeTimer)
        hotspot.value = " "
        n.syncProbe()
        XCTAssertNil(n.probeTimer)
        n.stop()
    }

    func testStopDuringAProbeDoesNotRearmTheProbe() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let probe = GatedProbe()
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: RecordingNotifier(),
                       clock: clock, probe: probe)
        let tick = Task { await n.probeTick() }
        await probe.gate.waitUntilStarted()
        n.stop()
        await probe.gate.open()
        await tick.value
        XCTAssertNil(n.probeTimer, "a probe that finished after stop() re-armed itself")
    }

    func testANewOutageIsDetectedAfterARecovery() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: RecordingNotifier(),
                       clock: clock, probe: FakeProbe([false, false, false, true, false]))
        for _ in 0..<3 { await n.probeTick() }
        XCTAssertTrue(n.machine.inOutage)
        await n.simulate(satisfied: true)
        XCTAssertFalse(n.machine.inOutage, "path recovery with the internet back")
        for _ in 0..<3 { await n.probeTick() }
        XCTAssertTrue(n.machine.inOutage, "three fresh failures start a new outage")
    }

    func testPathBackWithoutInternetDoesNotEndTheOutage() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: RecordingNotifier(),
                       clock: clock, probe: FakeProbe([false]))
        await n.simulate(satisfied: false)
        await n.simulate(satisfied: true)
        XCTAssertTrue(n.machine.inOutage)
    }

    func testPathBackWithInternetEndsTheOutage() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: RecordingNotifier(),
                       clock: clock, probe: FakeProbe([true]))
        await n.simulate(satisfied: false)
        await n.simulate(satisfied: true)
        XCTAssertFalse(n.machine.inOutage)
    }

    private func driver(
        keychain: FakeKeychainStore,
        joiner: RecordingHotspotJoiner,
        notifier: RecordingNotifier,
        clock: FakeClock,
        probe: any ReachabilityProbing = FakeProbe([true]),
        hotspot: Locked<String> = Locked("Phone"),
        ssid: Locked<String?> = Locked("Home"),
        wifiInterface: String? = "en0"
    ) -> NetworkFailover {
        NetworkFailover(
            paths: home.paths,
            keychain: keychain,
            hotspotJoiner: joiner,
            probe: probe,
            ssidReader: { ssid.value },
            settle: .zero,
            probeRetryDelay: .zero,
            notifier: notifier,
            wifiInterface: wifiInterface,
            clock: { clock.now }
        ) {
            var config = Config()
            config.hotspotSSID = hotspot.value
            return config
        }
    }

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var testClock = FakeClock(NetworkFailoverDriverTests.t0)

    /// A driver that knew "Home" and is now on the "Phone" hotspot.
    private func onTheHotspot(
        joiner: RecordingHotspotJoiner,
        keychain: FakeKeychainStore = FakeKeychainStore(),
        probe: any ReachabilityProbing = FakeProbe([true]),
        wifiInterface: String? = "en0"
    ) async -> (driver: NetworkFailover, ssid: Locked<String?>) {
        let ssid = Locked<String?>("Home")
        testClock = FakeClock(Self.t0)
        let n = driver(keychain: keychain, joiner: joiner, notifier: RecordingNotifier(),
                       clock: testClock, probe: probe, ssid: ssid, wifiInterface: wifiInterface)
        await n.recordHomeNetwork()
        ssid.value = "Phone"
        // Joins and leaves move the network the SSID reader sees; macOS
        // auto-joins "Home" after a leave unless a test says otherwise.
        joiner.network = ssid
        return (n, ssid)
    }

    func testSwitchBackLeavesTheHotspotForHomeWhenItIsVisibleAndOnline() async {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        let (n, ssid) = await onTheHotspot(joiner: joiner)
        XCTAssertEqual(n.homeSSID, "Home")
        await n.switchBackTick()
        XCTAssertEqual(joiner.leaves, 1)
        XCTAssertEqual(ssid.value, "Home")
        XCTAssertEqual(joiner.calls, [])
        XCTAssertNil(n.switchBackTimer, "back home: no more attempts")
    }

    /// R22: macOS auto-joins the hotspot again, not home. That is a failed
    /// attempt (the wait grows), and the Mac stays on the hotspot.
    func testMacOSRejoiningTheHotspotCountsAsAFailedSwitchBack() async {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        joiner.autoJoin = "Phone"
        let probe = CountingProbe(true)
        let (n, _) = await onTheHotspot(joiner: joiner, probe: probe)
        await n.switchBackTick()
        XCTAssertEqual(joiner.leaves, 1)
        XCTAssertEqual(joiner.calls, [], "already on the hotspot: nothing to join")
        XCTAssertEqual(probe.count, 0, "the hotspot is not tested as if it were home")
        XCTAssertEqual(n.switchBackDelay, 120)
        XCTAssertNotNil(n.switchBackTimer)
        n.stop()
    }

    /// macOS joins some other known network: a failed attempt, and the Mac
    /// is left where macOS put it.
    func testMacOSJoiningAnotherNetworkCountsAsAFailedSwitchBack() async throws {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        joiner.autoJoin = "Other"
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "pw")
        let probe = CountingProbe(true)
        let (n, ssid) = await onTheHotspot(joiner: joiner, keychain: keychain, probe: probe)
        await n.switchBackTick()
        XCTAssertEqual(joiner.calls, [])
        XCTAssertEqual(ssid.value, "Other")
        XCTAssertEqual(probe.count, 0)
        XCTAssertEqual(n.switchBackDelay, 120)
        n.stop()
    }

    /// Nothing is associated after the leave: back to the hotspot, and the
    /// attempt counts as failed.
    func testNoNetworkAfterTheLeaveGoesBackToTheHotspot() async throws {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        joiner.autoJoin = nil
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "pw")
        let (n, ssid) = await onTheHotspot(joiner: joiner, keychain: keychain)
        await n.switchBackTick()
        XCTAssertEqual(joiner.calls.map(\.ssid), ["Phone"])
        XCTAssertEqual(ssid.value, "Phone")
        XCTAssertEqual(n.switchBackDelay, 120)
        n.stop()
    }

    /// While a switch-back tick tests home, an outage retry (the leave
    /// itself starts an outage) must not move the Mac back to the hotspot:
    /// the probe would then test the hotspot and call home online. The
    /// retry waits and joins once the tick is done.
    func testAnOutageRetryDuringASwitchBackTickDoesNotJoin() async throws {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "pw")
        let probe = GatedAnswerProbe(false)
        let (n, ssid) = await onTheHotspot(joiner: joiner, keychain: keychain, probe: probe)
        let tick = Task { await n.switchBackTick() }
        await probe.gate.waitUntilStarted()
        XCTAssertEqual(ssid.value, "Home", "the tick is testing home")
        await n.simulate(satisfied: false)
        testClock.advance(FailoverMachine.initialDelay)
        await n.fireTimer().value
        XCTAssertEqual(joiner.calls, [], "the retry joined the hotspot under the tick")
        XCTAssertEqual(ssid.value, "Home")
        XCTAssertEqual(n.machine.joins, 0, "the deferred retry used up an attempt")
        XCTAssertNotNil(n.retryTimer, "the retry was dropped, not deferred")
        await probe.gate.open()
        await tick.value
        XCTAssertEqual(joiner.calls.map(\.ssid), ["Phone"], "home had no internet: the tick went back to the hotspot")
        // The tick is done: the retry joins again as usual.
        testClock.advance(FailoverMachine.initialDelay)
        await n.fireTimer().value
        XCTAssertEqual(n.machine.joins, 1)
        n.stop()
    }

    func testSwitchBackRejoinsHotspotWhenHomeHasNoInternet() async throws {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "pw")
        let (n, _) = await onTheHotspot(joiner: joiner, keychain: keychain, probe: FakeProbe([false]))
        await n.switchBackTick()
        XCTAssertEqual(joiner.leaves, 1)
        XCTAssertEqual(joiner.calls.last?.ssid, "Phone", "back to the hotspot: home has no internet")
        n.stop()
    }

    func testAHomeProbeThatFailsOnceIsRetriedBeforeHomeIsCalledOffline() async {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        let (n, _) = await onTheHotspot(joiner: joiner, probe: FakeProbe([false, true]))
        await n.switchBackTick()
        XCTAssertEqual(joiner.calls, [], "the second probe passed: stay home")
        XCTAssertNil(n.switchBackTimer)
    }

    func testFailedSwitchBacksBackOffAndLeaveOncePerTick() async throws {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "pw")
        let (n, _) = await onTheHotspot(joiner: joiner, keychain: keychain, probe: FakeProbe([false]))
        await n.switchBackTick()
        XCTAssertEqual(joiner.leaves, 1)
        XCTAssertEqual(n.switchBackDelay, 120)
        XCTAssertNotNil(n.switchBackTimer)
        await n.switchBackTick()
        XCTAssertEqual(joiner.leaves, 2)
        XCTAssertEqual(n.switchBackDelay, 240)
        for _ in 0..<6 { await n.switchBackTick() }
        XCTAssertEqual(n.switchBackDelay, NetworkFailover.switchBackMaxInterval, "capped at 10 minutes")
        n.stop()
        XCTAssertEqual(n.switchBackDelay, 60, "stop resets the backoff")
    }

    func testANewOutageResetsTheBackoff() async throws {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "pw")
        let (n, _) = await onTheHotspot(joiner: joiner, keychain: keychain, probe: FakeProbe([false]))
        await n.switchBackTick()
        XCTAssertEqual(n.switchBackDelay, 120)
        testClock.advance(NetworkFailover.selfInducedOutageWindow + 1)
        await n.simulate(satisfied: false)
        XCTAssertEqual(n.switchBackDelay, 60)
        XCTAssertNil(n.switchBackTimer)
        n.stop()
    }

    /// Answers from a switch the test flips.
    private final class SwitchableProbe: ReachabilityProbing, @unchecked Sendable {
        let answer = Locked(true)
        func isInternetReachable() async -> Bool { answer.value }
    }

    /// Wi-Fi blinks out and back on the hotspot, as a rejoin can make it do.
    private func blink(_ n: NetworkFailover, probe: SwitchableProbe) async {
        probe.answer.value = true
        await n.simulate(satisfied: false)
        await n.simulate(satisfied: true)
        probe.answer.value = false
    }

    func testOutagesTheSwitchBackCausesKeepTheBackoff() async throws {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "pw")
        let probe = SwitchableProbe()
        probe.answer.value = false
        let (n, _) = await onTheHotspot(joiner: joiner, keychain: keychain, probe: probe)
        // The leave itself blinks the path while the tick runs.
        joiner.onLeave = { await self.blink(n, probe: probe) }
        await n.switchBackTick()
        XCTAssertEqual(n.switchBackDelay, 120, "the blink during the tick did not reset the count")
        // The fallback join blinks it just after the tick.
        joiner.onLeave = nil
        await blink(n, probe: probe)
        XCTAssertEqual(n.switchBackDelay, 120, "recovery schedules with the current backoff, not 60")
        await n.switchBackTick()
        XCTAssertEqual(n.switchBackDelay, 240)
        await blink(n, probe: probe)
        XCTAssertEqual(n.switchBackDelay, 240)
        n.stop()
    }

    func testAGenuineOutageResetsTheBackoff() async throws {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "pw")
        let probe = SwitchableProbe()
        probe.answer.value = false
        let (n, _) = await onTheHotspot(joiner: joiner, keychain: keychain, probe: probe)
        await n.switchBackTick()
        XCTAssertEqual(n.switchBackDelay, 120)
        testClock.advance(NetworkFailover.selfInducedOutageWindow + 1)
        await blink(n, probe: probe)
        XCTAssertEqual(n.switchBackDelay, 60)
        n.stop()
    }

    func testNoSwitchBackWhileHomeIsOutOfRange() async {
        let joiner = RecordingHotspotJoiner()
        let (n, _) = await onTheHotspot(joiner: joiner)
        await n.switchBackTick()
        XCTAssertEqual(joiner.leaves, 0)
        XCTAssertNotNil(n.switchBackTimer, "home may come into range: keep trying")
        n.stop()
    }

    func testTheHotspotIsNeverRecordedAsHome() async {
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: RecordingNotifier(),
                       clock: FakeClock(Self.t0), ssid: Locked<String?>("Phone"))
        await n.recordHomeNetwork()
        XCTAssertNil(n.homeSSID)
    }

    func testNoSwitchBackWithoutAWifiInterface() async {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        let (n, _) = await onTheHotspot(joiner: joiner, wifiInterface: nil)
        await n.switchBackTick()
        XCTAssertEqual(joiner.leaves, 0)
    }

    func testNoSwitchBackOffTheHotspot() async {
        for other in ["Home", "Other"] {
            let joiner = RecordingHotspotJoiner()
            joiner.visible = ["Home"]
            let (n, ssid) = await onTheHotspot(joiner: joiner)
            ssid.value = other
            await n.switchBackTick()
            XCTAssertEqual(joiner.leaves, 0, other)
            XCTAssertNil(n.switchBackTimer, other)
        }
    }

    func testAScanThatThrowsLogsAndKeepsTheTimer() async {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        joiner.visibleError = true
        let (n, _) = await onTheHotspot(joiner: joiner)
        await n.switchBackTick()
        XCTAssertEqual(joiner.leaves, 0)
        XCTAssertEqual(joiner.calls, [])
        XCTAssertEqual(n.switchBackDelay, 60)
        XCTAssertNotNil(n.switchBackTimer)
        n.stop()
    }

    func testStopDuringATickJoinsNothingAndLeavesNoTimer() async {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        let probe = GatedProbe()
        let (n, _) = await onTheHotspot(joiner: joiner, probe: probe)
        let tick = Task { await n.switchBackTick() }
        await probe.gate.waitUntilStarted()
        n.stop()
        await probe.gate.open()
        await tick.value
        XCTAssertEqual(joiner.calls, [], "no hotspot join after stop")
        XCTAssertNil(n.switchBackTimer)
    }

    func testOverlappingTicksDoNotRunTwice() async {
        let joiner = RecordingHotspotJoiner()
        joiner.visible = ["Home"]
        let probe = GatedProbe()
        let (n, _) = await onTheHotspot(joiner: joiner, probe: probe)
        let first = Task { await n.switchBackTick() }
        await probe.gate.waitUntilStarted()
        await n.switchBackTick()
        XCTAssertEqual(joiner.leaves, 1, "the second tick found the first still running")
        n.stop()
        await probe.gate.open()
        await first.value
    }

    func testRecoveringOnTheHotspotTwiceLeavesOneLiveTimer() async throws {
        let (n, _) = await onTheHotspot(joiner: RecordingHotspotJoiner())
        await n.simulate(satisfied: false)
        await n.simulate(satisfied: true)
        let first = try XCTUnwrap(n.switchBackTimer)
        XCTAssertTrue(first.isValid)
        await n.simulate(satisfied: false)
        await n.simulate(satisfied: true)
        let second = try XCTUnwrap(n.switchBackTimer)
        XCTAssertFalse(first.isValid)
        XCTAssertTrue(second.isValid)
        n.stop()
        XCTAssertFalse(second.isValid)
    }

    func testRecoveringOffTheHotspotSchedulesNoSwitchBack() async {
        let (n, ssid) = await onTheHotspot(joiner: RecordingHotspotJoiner())
        ssid.value = "Home"
        await n.simulate(satisfied: false)
        await n.simulate(satisfied: true)
        XCTAssertNil(n.switchBackTimer)
    }

    /// A join with no saved password is not a silent skip: the problem is
    /// published for the menu and notified once, not on every retry.
    func testMissingPasswordIsSurfacedOnceAndNoJoinIsAttempted() async throws {
        let joiner = RecordingHotspotJoiner()
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: joiner, notifier: notifier, clock: clock)
        let published = Locked<[HotspotPasswordProblem?]>([])
        n.onPasswordReport = { published.value.append($0?.problem) }

        await n.simulate(satisfied: false)
        for _ in 0..<3 {
            clock.advance(30)
            await n.fireTimer().value
        }

        XCTAssertEqual(joiner.calls, [])
        XCTAssertEqual(n.passwordReport, HotspotPasswordReport(ssid: "Phone", problem: .missing))
        XCTAssertEqual(published.value, [.missing])
        XCTAssertEqual(notifier.posts.map(\.title), ["Hotspot not joined"])
        XCTAssertEqual(notifier.posts.map(\.body), ["No hotspot password is saved. Enter it in Settings."])
    }

    /// The item exists but belongs to another build (the keychain refuses
    /// it with prompts forbidden): same surfacing, with the re-enter wording.
    func testUnreadablePasswordIsSurfacedWithTheReenterWording() async throws {
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "old build's secret")
        keychain.unreadable = ["\(KeychainStore.service)/Phone"]
        let joiner = RecordingHotspotJoiner()
        let notifier = RecordingNotifier()
        let n = driver(keychain: keychain, joiner: joiner, notifier: notifier, clock: FakeClock(Date()))

        await n.joinHotspot()

        XCTAssertEqual(joiner.calls, [])
        XCTAssertEqual(n.passwordReport?.problem, .unreadable)
        XCTAssertEqual(n.passwordReport?.problem.menuLine, "\u{26A0} Hotspot password unreadable by this build: enter it again in Settings")
        XCTAssertEqual(notifier.posts.map(\.body), [HotspotPasswordProblem.unreadable.explanation])
        XCTAssertTrue(HotspotPasswordProblem.unreadable.explanation.contains("Enter it again in Settings"))
    }

    /// Saving in Settings clears the problem at once, and a read that then
    /// succeeds keeps it clear; a problem that comes back after a save is
    /// notified again.
    func testSavingThePasswordClearsTheProblemAndRearmsTheNotification() async throws {
        let keychain = FakeKeychainStore()
        let joiner = RecordingHotspotJoiner()
        let notifier = RecordingNotifier()
        let n = driver(keychain: keychain, joiner: joiner, notifier: notifier, clock: FakeClock(Date()))
        let published = Locked<[HotspotPasswordProblem?]>([])
        n.onPasswordReport = { published.value.append($0?.problem) }

        await n.joinHotspot()
        XCTAssertEqual(n.passwordReport?.problem, .missing)
        n.passwordChanged(.init(ssid: "Phone"), configuredSSID: "Phone")
        XCTAssertNil(n.passwordReport?.problem)
        XCTAssertEqual(published.value, [.missing, nil])

        try keychain.set(service: KeychainStore.service, account: "Phone", value: "pw")
        await n.joinHotspot()
        XCTAssertNil(n.passwordReport?.problem)
        XCTAssertEqual(joiner.calls.map(\.password), ["pw"])

        try keychain.delete(service: KeychainStore.service, account: "Phone")
        await n.joinHotspot()
        XCTAssertEqual(n.passwordReport?.problem, .missing)
        XCTAssertEqual(notifier.posts.count, 2, "the problem returned after a save, so it is notified again")
    }

    /// The user configures another hotspot during the outage. Its problem
    /// is reported for it, and notified once for it too: the notification
    /// about the first hotspot did not tell the user about this one.
    /// Going back to the first hotspot in the same outage notifies
    /// nothing new.
    func testAHotspotConfiguredDuringTheOutageIsNotifiedForItself() async throws {
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Other Phone", value: "old build's secret")
        keychain.unreadable = ["\(KeychainStore.service)/Other Phone"]
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let hotspot = Locked("Phone")
        let n = driver(keychain: keychain, joiner: RecordingHotspotJoiner(), notifier: notifier, clock: clock, hotspot: hotspot)
        func tick() async {
            clock.advance(30)
            await n.fireTimer().value
        }

        await n.simulate(satisfied: false)
        await tick()
        hotspot.value = "Other Phone"
        await tick()
        await tick()

        XCTAssertEqual(n.passwordReport, HotspotPasswordReport(ssid: "Other Phone", problem: .unreadable))
        XCTAssertEqual(notifier.posts.map(\.body), [HotspotPasswordProblem.missing.explanation, HotspotPasswordProblem.unreadable.explanation])

        hotspot.value = "Phone"
        await tick()
        XCTAssertEqual(n.passwordReport, HotspotPasswordReport(ssid: "Phone", problem: .missing))
        XCTAssertEqual(notifier.posts.count, 2)
        n.stop()
    }

    /// A save in Settings for another SSID, one edited away while it
    /// waited, leaves the report about the hotspot configured now, and
    /// its notification, if the save did not remove that hotspot's item
    /// either. Any other save clears the report and re-arms the
    /// notification: one that removed the configured hotspot's item (the
    /// account the window loaded), one for the configured hotspot, and one
    /// whose report is about an SSID no longer configured.
    func testASaveClearsEveryReportButOneAboutTheConfiguredHotspotItDidNotStore() async throws {
        let notifier = RecordingNotifier()
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: notifier, clock: FakeClock(Date()))
        let phone = HotspotPasswordReport(ssid: "Phone", problem: .missing)

        await n.joinHotspot()
        n.passwordChanged(.init(ssid: "Other Phone"), configuredSSID: "Phone")
        XCTAssertEqual(n.passwordReport, phone)
        await n.joinHotspot()
        XCTAssertEqual(notifier.posts.count, 1, "the report stood, and so did its notification")

        n.passwordChanged(.init(ssid: "Other Phone", removed: "Phone"), configuredSSID: "Phone")
        XCTAssertNil(n.passwordReport, "the save removed the reported hotspot's item")
        await n.joinHotspot()
        XCTAssertEqual(notifier.posts.count, 2, "what the next read finds is notified afresh")

        n.passwordChanged(.init(ssid: "Phone"), configuredSSID: " Phone ")
        XCTAssertNil(n.passwordReport)
        await n.joinHotspot()
        XCTAssertEqual(notifier.posts.count, 3)

        n.passwordChanged(.init(ssid: "Phone"), configuredSSID: "Other Phone")
        XCTAssertNil(n.passwordReport, "the save wrote the reported hotspot's item")
        await n.joinHotspot()
        n.passwordChanged(.init(ssid: "Other Phone"), configuredSSID: "Other Phone")
        XCTAssertNil(n.passwordReport, "the save may have moved the reported hotspot's item")
    }

    /// stop() ends the session: the problem goes (and with it the menu
    /// line), and the once-per-outage guard does not outlive the session.
    func testStopClearsTheProblemAndRearmsTheNotification() async throws {
        let joiner = RecordingHotspotJoiner()
        let notifier = RecordingNotifier()
        let n = driver(keychain: FakeKeychainStore(), joiner: joiner, notifier: notifier, clock: FakeClock(Date()))
        let published = Locked<[HotspotPasswordProblem?]>([])
        n.onPasswordReport = { published.value.append($0?.problem) }

        await n.joinHotspot()
        await n.joinHotspot()
        XCTAssertEqual(notifier.posts.count, 1)
        n.stop()
        XCTAssertNil(n.passwordReport?.problem)
        XCTAssertEqual(published.value, [.missing, nil])
        await n.joinHotspot()
        XCTAssertEqual(notifier.posts.count, 2)
    }

    /// A second outage in the same session is notified again: recovery
    /// re-arms the once-per-outage guard.
    func testANewOutageAfterRecoveryIsNotifiedAgain() async throws {
        let joiner = RecordingHotspotJoiner()
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: joiner, notifier: notifier, clock: clock)
        func skipped() -> Int { notifier.posts.filter { $0.title == "Hotspot not joined" }.count }

        await n.simulate(satisfied: false)
        for _ in 0..<2 {
            clock.advance(30)
            await n.fireTimer().value
        }
        XCTAssertEqual(skipped(), 1)

        clock.advance(30)
        await n.simulate(satisfied: true)
        XCTAssertEqual(skipped(), 1, "recovery itself reports nothing about the password")

        await n.simulate(satisfied: false)
        clock.advance(30)
        await n.fireTimer().value
        XCTAssertEqual(skipped(), 2)
        XCTAssertEqual(joiner.calls, [])
    }
}

/// Counts its calls and gives one answer.
final class CountingProbe: ReachabilityProbing, @unchecked Sendable {
    private let calls = Locked(0)
    private let answer: Bool
    init(_ answer: Bool) { self.answer = answer }
    var count: Int { calls.value }
    func isInternetReachable() async -> Bool {
        calls.value += 1
        return answer
    }
}

/// Gives `answer` once `gate` opens.
final class GatedAnswerProbe: ReachabilityProbing, @unchecked Sendable {
    let gate = AsyncGate()
    private let answer: Bool
    init(_ answer: Bool) { self.answer = answer }
    func isInternetReachable() async -> Bool {
        await gate.wait()
        return answer
    }
}
