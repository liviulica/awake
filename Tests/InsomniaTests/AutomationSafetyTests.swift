import Darwin
import XCTest
@testable import Insomnia

// Doubles live here on purpose: TestSupport.swift belongs to another worker.

/// A real AF_UNIX socket bound at `path`; closes and unlinks on deinit.
private final class UnixSocketFixture {
    let path: String
    private let fd: Int32

    init?(path: String) {
        self.path = path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: tuple.pointee)) { buf in
                path.withCString { c in
                    guard strlen(c) < MemoryLayout.size(ofValue: tuple.pointee) else { return false }
                    strcpy(buf, c)
                    return true
                }
            }
        }
        guard ok else { close(fd); return nil }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); return nil }
    }

    deinit {
        close(fd)
        unlink(path)
    }
}

/// Hotspot joiner double that blocks inside `join` until released.
private final class GatedJoiner: HotspotJoining, @unchecked Sendable {
    let gate = AsyncGate()
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool {
        lock.withLock { _calls += 1 }
        await gate.wait()
        return true
    }
}

// MARK: - NetworkFailover: ending a session must end its work

@MainActor
final class NetworkFailoverCancellationTests: XCTestCase {
    var home: TempHome!
    var notifier: RecordingNotifier!
    var clock: FakeClock!

    override func setUp() async throws {
        home = TempHome()
        notifier = RecordingNotifier()
        clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
    }

    override func tearDown() async throws { home.destroy() }

    private func makeDriver() -> NetworkFailover {
        let config = Config()
        let clock = self.clock!
        return NetworkFailover(paths: home.paths, keychain: FakeKeychainStore(), notifier: notifier, clock: { clock.now }) { config }
    }

    /// A path update that was queued before `stop()` but runs after it must
    /// not schedule a retry timer (and later a hotspot join) for a session
    /// that no longer exists.
    func testQueuedPathUpdateAfterStopDoesNotStartOutage() async throws {
        let n = makeDriver()
        n.handlePath(satisfied: false)
        n.stop()
        // Give the queued task every chance to run.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(n.machine.inOutage, "stopped driver entered an outage from a stale path update")
    }

    private func makeJoiningDriver(joiner: GatedJoiner) throws -> NetworkFailover {
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "secret")
        var config = Config()
        config.hotspotSSID = "Phone"
        let clock = self.clock!
        return NetworkFailover(paths: home.paths, keychain: keychain, hotspotJoiner: joiner,
            notifier: notifier, wifiInterface: "en0", clock: { clock.now }) { config }
    }

    /// A retry tick yields `[.joinHotspot, .scheduleRetry]`. If the session
    /// ends while the join is in flight, the retry must not be scheduled
    /// afterwards: that timer would outlive the session it belonged to.
    func testStopDuringHotspotJoinDoesNotRescheduleRetry() async throws {
        let joiner = GatedJoiner()
        let n = try makeJoiningDriver(joiner: joiner)
        await n.simulate(satisfied: false)
        clock.advance(FailoverMachine.initialDelay)
        n.fireTimer()
        await joiner.gate.waitUntilStarted()

        n.stop()
        XCTAssertNil(n.retryTimer)
        await joiner.gate.open()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(joiner.calls, 1)
        XCTAssertNil(n.retryTimer, "cancelled join re-armed the retry timer after stop()")
    }

    /// Stop, start a new outage, then let the old join finish: the new
    /// outage's retry timer must survive untouched.
    func testOldJoinCannotReplaceNewSessionsRetryTimer() async throws {
        let joiner = GatedJoiner()
        let n = try makeJoiningDriver(joiner: joiner)
        await n.simulate(satisfied: false)
        clock.advance(FailoverMachine.initialDelay)
        n.fireTimer()
        await joiner.gate.waitUntilStarted()
        n.stop()

        clock.advance(60)
        await n.simulate(satisfied: false)
        let fresh = try XCTUnwrap(n.retryTimer, "new outage did not arm a retry")
        await joiner.gate.open()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(n.retryTimer === fresh, "old session's outputs replaced the new session's retry timer")
        XCTAssertTrue(n.machine.inOutage)
        XCTAssertEqual(n.machine.joins, 0, "old session's join leaked into the new outage")
    }
}
