#if DEBUG || INSOMNIA_LID_SIMULATION
import Foundation

/// The mode scripts/smoke-test.sh launches the app in. Compiled in with the
/// lid simulation (`LidSimulationBuild`), and on only when the environment
/// asks for it twice over: `AWAKE_TEST_MODE=1` and a relocated
/// `AWAKE_HOME`. A lid simulation build installed for the real-Mac checks
/// (docs/superpowers/specs/2026-10-14-awake-design.md, "Testing") runs without either and keeps the real `pmset`, the
/// real recovery agent and the real lid.
///
/// In test mode the app needs no root and changes nothing outside its
/// `AWAKE_HOME`:
/// - `SimulatedSleepGuard` keeps the sleep and Low Power Mode bits in
///   memory and logs every change to `sleepGuardLog`, in place of
///   `PmsetSleepGuard` (no sudo, no administrator prompt).
/// - `RecoveryAgentStandIn` reports the agent armed without launchctl.
/// - The lid the session reads is the one scripts/simulate-lid.sh last
///   wrote (open until it writes), not the hinge, so a simulated close
///   runs the closed-lid clock too; macOS is never asked to sleep.
/// - A simulated close changes nothing on the host, whatever config.json
///   in `AWAKE_HOME` says: the output volume, the display and keyboard
///   backlight, other apps' processes (no freeze) and other apps' App Nap
///   preferences are all left alone (`NoopAudioControl`,
///   `NoopDisplayDimmer`, `NoopKeyboardBacklight`, `NoopFreezer`,
///   `NoopAppNapPreferences`).
/// - `TestControl` takes commands from `controlFile` and writes
///   `statusFile`.
/// The Awake assertion stays the real IOPM one: that is what the smoke
/// test checks with `pmset -g assertions`.
struct TestMode: Equatable, Sendable {
    static let switchKey = "AWAKE_TEST_MODE"
    /// Logged at launch in test mode. Also what the release gate looks for:
    /// a plain release binary must not contain it.
    static let marker = "Test mode: commands from test-control, simulated sleep guard (no root), recovery agent stand-in (no launchctl)"

    let paths: Paths

    /// Test mode when `AWAKE_TEST_MODE` is exactly "1" and `AWAKE_HOME` is
    /// set and not empty; nil otherwise.
    static func requested(in env: [String: String] = ProcessInfo.processInfo.environment) -> TestMode? {
        guard env[switchKey] == "1", let home = env[Paths.environmentKey], !home.isEmpty else { return nil }
        return TestMode(paths: Paths(root: URL(fileURLWithPath: home, isDirectory: true)))
    }

    /// Commands, one per line; consumed and deleted (`TestControl`).
    var controlFile: URL { paths.appSupport.appendingPathComponent("test-control") }
    /// `TestControlStatus`, rewritten whenever it changes.
    var statusFile: URL { paths.appSupport.appendingPathComponent("test-status.json") }
    /// One line per sleep guard change: `disablesleep 1|0`, `lowpowermode 1|0`.
    var sleepGuardLog: URL { paths.appSupport.appendingPathComponent("test-sleepguard.log") }

    /// `SessionManager.live` with the stand-ins above.
    @MainActor
    func makeManager() -> SessionManager {
        let lid = SimulatedLidState()
        return SessionManager.live(
            paths: paths,
            sleepGuard: SimulatedSleepGuard(log: sleepGuardLog),
            backstop: RecoveryAgentStandIn(),
            clamshell: { lid.isClosed },
            closedLidSleep: NoopClosedLidSleep(),
            lidSimulation: SimulatedLidWatcher(state: lid),
            audio: NoopAudioControl(),
            display: NoopDisplayDimmer(),
            keyboard: NoopKeyboardBacklight(),
            appNap: NoopAppNapPreferences(),
            freezer: NoopFreezer()
        )
    }
}

/// Freezes nothing and signals nothing: a test-mode lid close never stops
/// another app on the host.
struct NoopFreezer: Freezing {
    func plan(config: Config) -> [FreezeGroup] { [] }
    func suspend(_ processes: [FrozenProcess], expectedParents: [Int32: Int32]) -> SuspendReport {
        SuspendReport(skipped: processes.map(\.pid))
    }
    func resume(_ processes: [FrozenProcess]) -> ResumeReport { ResumeReport(gone: processes.map(\.pid)) }
    func cancelStops(_ processes: [FrozenProcess]) -> ResumeReport { ResumeReport(gone: processes.map(\.pid)) }
}

/// `SleepGuarding` without root: the bits live in memory and every change
/// is appended to a log the smoke test reads.
final class SimulatedSleepGuard: SleepGuarding, @unchecked Sendable {
    private let log: URL
    private let lock = NSLock()
    private var sleepDisabled = false
    private var lowPowerOn = false

    init(log: URL) {
        self.log = log
    }

    func setSleepDisabled(_ disabled: Bool) async throws {
        try lock.withLock {
            sleepDisabled = disabled
            try record("disablesleep \(disabled ? 1 : 0)")
        }
    }

    func isSleepDisabled() async throws -> Bool {
        lock.withLock { sleepDisabled }
    }

    func setLowPowerMode(_ on: Bool) async throws {
        try lock.withLock {
            lowPowerOn = on
            try record("lowpowermode \(on ? 1 : 0)")
        }
    }

    func isLowPowerModeOn() async throws -> Bool {
        lock.withLock { lowPowerOn }
    }

    /// Called with the lock held, so lines land in the order of the changes.
    private func record(_ line: String) throws {
        let data = Data((line + "\n").utf8)
        guard FileManager.default.fileExists(atPath: log.path) else {
            try data.write(to: log)
            return
        }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

/// `BackstopScheduling` without launchctl: always armed.
struct RecoveryAgentStandIn: BackstopScheduling {
    func arm() async throws {
        Log.info("test mode: recovery agent stand-in reports armed (no launchctl)")
    }
}

/// The lid as scripts/simulate-lid.sh last set it, for the session's
/// `clamshell` reading. Open until the first simulated event.
final class SimulatedLidState: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    var isClosed: Bool { lock.withLock { closed } }

    func set(closed: Bool) {
        lock.withLock { self.closed = closed }
    }
}

/// The lid simulation's file watcher, recording each event in
/// `SimulatedLidState` before it is delivered, so the session reads the
/// lid the event describes.
@MainActor
final class SimulatedLidWatcher: LidSimulating {
    var onEvent: ((Bool) -> Void)?

    private let inner = LidSimulation()
    private let state: SimulatedLidState

    init(state: SimulatedLidState) {
        self.state = state
    }

    func start(directory: URL, file: URL) {
        inner.onEvent = { [weak self] closed in
            guard let self else { return }
            state.set(closed: closed)
            onEvent?(closed)
        }
        inner.start(directory: directory, file: file)
    }

    func stop() {
        inner.stop()
        inner.onEvent = nil
    }
}
#endif
