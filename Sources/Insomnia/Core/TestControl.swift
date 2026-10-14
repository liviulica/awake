#if DEBUG || INSOMNIA_LID_SIMULATION
import Foundation

// The test build's control channel, for scripts/smoke-test.sh. Compiled in
// with the lid simulation (`LidSimulationBuild`) and nowhere else, and
// active only in test mode (`TestMode`). A plain release build has none
// of it: scripts/check-lid-simulation-gate.sh fails on any copy of the
// `TestMode.marker` text in that binary.

/// One line of `$AWAKE_HOME/test-control`.
enum TestControlCommand: Equatable, Sendable {
    /// Awake mode on, for `seconds` or (nil) until turned off.
    case awakeOn(TimeInterval?)
    case awakeOff
    /// A lid session of this many seconds of closed-lid time.
    case lidStart(TimeInterval)
    case lidExtend(TimeInterval)
    case lidEnd
    /// Quit the app the way the menu's Quit does.
    case quit

    /// A non-blank line of the file and what it parsed to (nil: not a
    /// command, logged and skipped).
    struct ParsedLine: Equatable, Sendable {
        let text: String
        let command: TestControlCommand?
    }

    /// `awake-on [seconds]`, `awake-off`, `lid-start <seconds>`,
    /// `lid-extend <seconds>`, `lid-end` or `quit`, with any whitespace
    /// around and between the words. Seconds are a positive finite number.
    /// Anything else, extra words included, is nil.
    static func parse(_ line: String) -> TestControlCommand? {
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let verb = words.first else { return nil }
        let arguments = Array(words.dropFirst())
        switch (verb, arguments.count) {
        case ("awake-on", 0): return .awakeOn(nil)
        case ("awake-on", 1): return seconds(arguments[0]).map { .awakeOn($0) }
        case ("awake-off", 0): return .awakeOff
        case ("lid-start", 1): return seconds(arguments[0]).map { .lidStart($0) }
        case ("lid-extend", 1): return seconds(arguments[0]).map { .lidExtend($0) }
        case ("lid-end", 0): return .lidEnd
        case ("quit", 0): return .quit
        default: return nil
        }
    }

    /// Every non-blank line of the file, in order.
    static func parseFile(_ text: String) -> [ParsedLine] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { ParsedLine(text: $0, command: parse($0)) }
    }

    private static func seconds(_ word: String) -> TimeInterval? {
        guard let value = TimeInterval(word), value.isFinite, value > 0 else { return nil }
        return value
    }
}

/// What `$AWAKE_HOME/test-status.json` holds: the state the status item
/// shows, and the lid hold that decides the real IOPM assertion. Every key
/// is always written; a value that does not apply is JSON null.
struct TestControlStatus: Equatable, Encodable {
    let awakeOn: Bool
    /// ISO 8601; nil when Awake mode is off or runs until turned off.
    let awakeEndsAt: String?
    let lidActive: Bool
    /// nil without a lid session.
    let lidPaused: Bool?
    /// Closed-lid seconds left, rounded to whole seconds; nil without a
    /// lid session.
    let lidRemaining: Int?
    let lidHoldActive: Bool
    /// "off", "awake" or "lid", as `StatusItemController.presentation` picks.
    let icon: String
    /// The countdown beside the icon; empty when nothing is timed.
    let title: String

    @MainActor
    init(awake: AwakeController.State, lidHoldActive: Bool, session: Session?, now: Date) {
        let remaining = session?.closedLidRemaining(at: now)
        let presentation = StatusItemController.presentation(lidRemaining: remaining, awake: awake, now: now)
        if case let .on(until) = awake {
            awakeOn = true
            awakeEndsAt = until.map { ISO8601DateFormatter().string(from: $0) }
        } else {
            awakeOn = false
            awakeEndsAt = nil
        }
        lidActive = session != nil
        lidPaused = session?.isPaused
        lidRemaining = remaining.map { Int($0.rounded()) }
        self.lidHoldActive = lidHoldActive
        switch presentation.icon {
        case .off: icon = "off"
        case .awake: icon = "awake"
        case .lid: icon = "lid"
        }
        title = presentation.title
    }

    private enum CodingKeys: String, CodingKey {
        case awakeOn, awakeEndsAt, lidActive, lidPaused, lidRemaining, lidHoldActive, icon, title
    }

    /// Written by hand so a nil is an explicit null rather than a missing
    /// key (the synthesized encoder leaves it out).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(awakeOn, forKey: .awakeOn)
        try c.encode(awakeEndsAt, forKey: .awakeEndsAt)
        try c.encode(lidActive, forKey: .lidActive)
        try c.encode(lidPaused, forKey: .lidPaused)
        try c.encode(lidRemaining, forKey: .lidRemaining)
        try c.encode(lidHoldActive, forKey: .lidHoldActive)
        try c.encode(icon, forKey: .icon)
        try c.encode(title, forKey: .title)
    }

    /// Pretty-printed with sorted keys, so a change is easy to read in a
    /// failed run's copy of the file.
    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Bools, strings, an Int and nulls: nothing here can fail to encode.
        return (try? encoder.encode(self)) ?? Data()
    }
}

/// Polls `TestMode.controlFile` every 0.5 s and runs each command in it, in
/// order, one at a time; writes `TestMode.statusFile` whenever what it
/// holds changes. The file is claimed (renamed) before it is read, like
/// the lid simulation's trigger, so a command is never run twice or half
/// read.
@MainActor
final class TestControl {
    static let pollInterval: TimeInterval = 0.5

    private let mode: TestMode
    private let manager: SessionManager
    private let awake: AwakeController
    private let quit: @MainActor () -> Void
    private var timer: Timer?
    /// A batch of commands is running; the next poll only refreshes the
    /// status, so the batch's commands keep their order.
    private var running = false
    private var written: Data?

    init(mode: TestMode, manager: SessionManager, awake: AwakeController, quit: @escaping @MainActor () -> Void) {
        self.mode = mode
        self.manager = manager
        self.awake = awake
        self.quit = quit
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        writeStatus()
    }

    private func poll() {
        guard !running, let text = claim() else {
            writeStatus()
            return
        }
        running = true
        Task { @MainActor in
            for line in TestControlCommand.parseFile(text) {
                await run(line)
                writeStatus()
            }
            running = false
        }
    }

    private func run(_ line: TestControlCommand.ParsedLine) async {
        guard let command = line.command else {
            Log.error("test mode: ignoring control line \"\(line.text)\"")
            return
        }
        Log.info("test mode: control line \"\(line.text)\"")
        switch command {
        case let .awakeOn(seconds): awake.turnOn(for: seconds)
        case .awakeOff: awake.turnOff(reason: "test control")
        case let .lidStart(seconds): await manager.start(duration: min(seconds, Config.lidMaxDuration))
        case let .lidExtend(seconds): await manager.extend(by: seconds)
        case .lidEnd: _ = await manager.end(reason: .user)
        case .quit: quit()
        }
    }

    /// Writes the status file when its content changed. Atomic, so the
    /// script never reads half a file.
    private func writeStatus() {
        let data = TestControlStatus(awake: awake.state, lidHoldActive: awake.lidHoldActive, session: manager.session, now: Date()).encoded()
        guard data != written else { return }
        do {
            try data.write(to: mode.statusFile, options: .atomic)
            written = data
        } catch {
            Log.error("test mode: cannot write \(mode.statusFile.path): \(error.localizedDescription)")
        }
    }

    /// Renames the control file to a per-process path, then reads and
    /// removes it. nil when there is no file.
    private func claim() -> String? {
        let file = mode.controlFile
        let claimed = file.appendingPathExtension("claimed.\(getpid())")
        guard rename(file.path, claimed.path) == 0 else {
            let code = errno
            if code != ENOENT {
                Log.error("test mode: cannot claim \(file.path): \(String(cString: strerror(code)))")
            }
            return nil
        }
        defer { try? FileManager.default.removeItem(at: claimed) }
        return (try? String(contentsOf: claimed, encoding: .utf8)) ?? ""
    }
}
#endif
