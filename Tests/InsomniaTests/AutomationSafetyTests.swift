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

// MARK: - DockerRule second check

final class DockerRuleSecondCheckTests: XCTestCase {
    /// Docker Desktop runs as pid 400 with one child, so planning finds its
    /// group and only the rule setting decides whether the probe runs.
    private func rule(_ probe: @escaping DockerRule.ContainerProbe) -> DockerRule {
        let freezer = FakeFreezer(
            apps: [RunningApp(pid: 400, bundleId: DockerRule.bundleId, name: "Docker")],
            processes: [
                ProcessEntry(pid: 1, ppid: 0, startedAt: 1),
                ProcessEntry(pid: 400, ppid: 1, startedAt: 4000),
                ProcessEntry(pid: 401, ppid: 400, startedAt: 4001),
            ],
            control: FakeProcessControl()
        )
        return DockerRule(freezer: freezer, probe: probe)
    }

    /// Only a clean idle answer lets the SIGSTOP go ahead. Busy, a failed
    /// `docker ps` and a timeout all say no.
    func testOnlyACleanIdleAnswerIsStillIdle() async {
        let idle = await rule { true }.isStillIdle()
        XCTAssertTrue(idle)
        let busy = await rule { false }.isStillIdle()
        XCTAssertFalse(busy)
        let failed = await rule { throw SleepGuardError(command: "docker ps -q", status: 1, stderr: "Cannot connect") }.isStillIdle()
        XCTAssertFalse(failed)
        let timedOut = await rule { throw ShellTimeoutError.timedOut(exe: "docker", seconds: 5) }.isStillIdle()
        XCTAssertFalse(timedOut)
    }

    /// The rule off: no group, and the probe never runs, while Docker
    /// Desktop is running. The same fixture with the rule on probes once
    /// and returns Desktop's group, so the first half cannot pass just
    /// because no Docker was running.
    func testRuleOffNeverProbes() async {
        let probes = Locked(0)
        let docker = rule { probes.value += 1; return true }
        var config = Config()
        config.dockerRule = false
        let off = await docker.idleDockerGroup(config: config)
        XCTAssertNil(off)
        XCTAssertEqual(probes.value, 0, "the probe ran with the rule off")

        config.dockerRule = true
        let on = await docker.idleDockerGroup(config: config)
        XCTAssertEqual(on?.bundleId, DockerRule.bundleId)
        XCTAssertEqual(on?.pids, [400, 401])
        XCTAssertEqual(probes.value, 1)
    }
}

// MARK: - DockerRule endpoint binding

final class DockerRuleEndpointTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        // Short path: sockaddr_un limits socket paths to ~104 bytes.
        dir = URL(fileURLWithPath: "/tmp/ins-\(getpid())-\(UInt16.random(in: 0...UInt16.max))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes an executable that records its argv and behaves as `stdout`/`exit` say.
    private func fakeDocker(stdout: String, exit: Int32) throws -> (exe: String, argvFile: String) {
        let argv = dir.appendingPathComponent("argv").path
        let exe = dir.appendingPathComponent("docker").path
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argv)'
        printf '%s' '\(stdout)'
        exit \(exit)
        """
        try TestScripts.write(script, to: URL(fileURLWithPath: exe))
        return (exe, argv)
    }

    private func recordedArgv(_ path: String) throws -> [String] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func testProbeBindsToDesktopSocketAndReportsIdle() async throws {
        let sock = dir.appendingPathComponent("d.sock").path
        let fixture = try XCTUnwrap(UnixSocketFixture(path: sock))
        let (exe, argv) = try fakeDocker(stdout: "\n", exit: 0)
        let probe = DockerRule.makeProbe(docker: exe, socketPath: fixture.path)

        let idle = try await probe()

        XCTAssertTrue(idle)
        XCTAssertEqual(try recordedArgv(argv), ["--host", "unix://\(sock)", "ps", "-q"])
    }

    func testProbeReportsBusyWhenDesktopListsContainers() async throws {
        let fixture = try XCTUnwrap(UnixSocketFixture(path: dir.appendingPathComponent("d.sock").path))
        let (exe, _) = try fakeDocker(stdout: "fe9b30f60a57\n", exit: 0)
        let probe = DockerRule.makeProbe(docker: exe, socketPath: fixture.path)
        let idle = try await probe()
        XCTAssertFalse(idle)
    }

    func testProbeFailureIsAnError() async throws {
        let fixture = try XCTUnwrap(UnixSocketFixture(path: dir.appendingPathComponent("d.sock").path))
        let (exe, _) = try fakeDocker(stdout: "", exit: 1)
        let probe = DockerRule.makeProbe(docker: exe, socketPath: fixture.path)
        do {
            _ = try await probe()
            XCTFail("failed docker ps reported an answer")
        } catch {}
    }

    func testMissingDesktopSocketSkipsDockerWithoutRunningTheCLI() async throws {
        let (exe, argv) = try fakeDocker(stdout: "\n", exit: 0)
        let probe = DockerRule.makeProbe(docker: exe, socketPath: dir.appendingPathComponent("absent.sock").path)
        do {
            _ = try await probe()
            XCTFail("probe answered without a Desktop endpoint")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: argv), "docker CLI ran against an unverified endpoint")
    }

    func testRegularFileAtSocketPathIsNotAnEndpoint() async throws {
        let notASocket = dir.appendingPathComponent("d.sock").path
        try "".write(toFile: notASocket, atomically: true, encoding: .utf8)
        let (exe, argv) = try fakeDocker(stdout: "\n", exit: 0)
        let probe = DockerRule.makeProbe(docker: exe, socketPath: notASocket)
        do {
            _ = try await probe()
            XCTFail("probe answered through a plain file")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: argv))
    }
}
