import Foundation

/// The helper's two root commands, with every tool path injectable so the
/// tests run them against fakes as an ordinary user.
public struct HelperCommands: Sendable {
    public let pmset: String
    public let visudo: String
    public let install: String
    public let rulePath: String
    /// pmset normally exits in well under a second; past this it gets
    /// SIGTERM (never SIGKILL, which could leave a root change landing
    /// after the app moved on) and the reply still waits for its exit.
    public let pmsetTimeout: TimeInterval
    public let temporaryDirectory: URL

    public init(
        pmset: String = "/usr/bin/pmset",
        visudo: String = "/usr/sbin/visudo",
        install: String = "/usr/bin/install",
        rulePath: String = RestoreRule.path,
        pmsetTimeout: TimeInterval = 20,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.pmset = pmset
        self.visudo = visudo
        self.install = install
        self.rulePath = rulePath
        self.pmsetTimeout = pmsetTimeout
        self.temporaryDirectory = temporaryDirectory
    }

    public struct Result: Sendable, Equatable {
        public let status: Int32
        public let message: String
        public init(status: Int32, message: String) {
            self.status = status
            self.message = message
        }
    }

    /// `pmset -a disablesleep 1` with `lock` as standard input. Returns once
    /// pmset has exited, however long that takes.
    public func disableSleep(lock: FileHandle?) -> Result {
        let r = run(pmset, ["-a", "disablesleep", "1"], stdin: lock, timeout: pmsetTimeout)
        guard let status = r.status else {
            return Result(status: HelperStatus.notRun, message: "pmset did not start: \(r.output)")
        }
        if r.timedOut {
            return Result(status: status == 0 ? 1 : status, message: "pmset did not finish within \(Int(pmsetTimeout)) s and was sent SIGTERM; it exited \(status). \(r.output)")
        }
        return Result(status: status, message: r.output)
    }

    /// Writes the restore rule for `user` unless the file already holds it
    /// exactly. The new text is checked with `visudo -cf` before `install`
    /// puts it in place (root:wheel, 0440); a text visudo refuses is never
    /// installed.
    public func installRestoreRule(user: String) -> Result {
        guard RestoreRule.isValidUserName(user) else {
            return Result(status: HelperStatus.notRun, message: "'\(user)' is not a user name the rule can hold")
        }
        let text = RestoreRule.text(user: user)
        if let existing = try? String(contentsOfFile: rulePath, encoding: .utf8), existing == text {
            return Result(status: 0, message: "\(rulePath) already is the restore rule for \(user)")
        }
        let tmp = temporaryDirectory.appendingPathComponent("ember-sudoers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try Data(text.utf8).write(to: tmp, options: .withoutOverwriting)
        } catch {
            return Result(status: HelperStatus.notRun, message: "could not write the rule to \(tmp.path): \(error.localizedDescription)")
        }
        let check = run(visudo, ["-cf", tmp.path], stdin: nil, timeout: 20)
        guard check.status == 0, !check.timedOut else {
            return Result(status: check.status ?? HelperStatus.notRun, message: "visudo refused the rule, nothing installed: \(check.output)")
        }
        let put = run(install, ["-m", "0440", "-o", "root", "-g", "wheel", tmp.path, rulePath], stdin: nil, timeout: 20)
        guard put.status == 0, !put.timedOut else {
            return Result(status: put.status ?? HelperStatus.notRun, message: "install could not put the rule at \(rulePath): \(put.output)")
        }
        return Result(status: 0, message: "wrote the restore rule for \(user) to \(rulePath)")
    }

    struct RunResult {
        /// nil when the tool did not start.
        var status: Int32?
        var timedOut: Bool
        /// stderr then stdout, trimmed; the launch error when it did not start.
        var output: String
    }

    /// Runs one tool to its exit. At `timeout` it gets SIGTERM once; the
    /// wait goes on until it exits.
    func run(_ exe: String, _ args: [String], stdin: FileHandle?, timeout: TimeInterval) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardInput = stdin ?? FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return RunResult(status: nil, timedOut: false, output: error.localizedDescription)
        }
        // Read while it runs, so a chatty tool never blocks on a full pipe.
        let outData = Self.readAll(out.fileHandleForReading)
        let errData = Self.readAll(err.fileHandleForReading)
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            exited.wait()
        }
        let text = [errData.value, outData.value]
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return RunResult(status: process.terminationStatus, timedOut: timedOut, output: text)
    }

    /// Drains `handle` on a background queue; `value` waits for the end.
    private static func readAll(_ handle: FileHandle) -> Drain {
        let drain = Drain()
        DispatchQueue.global().async {
            drain.set(handle.readDataToEndOfFile())
        }
        return drain
    }

    private final class Drain: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private var data = Data()
        func set(_ d: Data) {
            data = d
            done.signal()
        }
        var value: Data {
            done.wait()
            done.signal()
            return data
        }
    }
}
