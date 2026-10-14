import Foundation

/// Runs one fixed command as root through the macOS administrator prompt
/// (spec "Phase 1: password to start"). Only `disablesleep 1` goes this
/// way; everything that gives sleep back stays passwordless in sudoers.
protocol AdminCommandRunning: Sendable {
    func runAsAdministrator(_ command: String, prompt: String) async throws
}

/// The person closed the administrator prompt: their choice, not a failure.
struct AdminPromptCancelledError: Error, LocalizedError, Equatable {
    var errorDescription: String? { "The administrator prompt was cancelled" }
}

/// The administrator prompt was left open past `OsascriptAdminRunner.timeout`
/// and osascript stopped on SIGTERM. A failure, never a cancel: the start
/// is undone from the journal and the person is told why.
struct AdminPromptTimeoutError: Error, LocalizedError, Equatable {
    let timeout: TimeInterval

    var errorDescription: String? {
        let wait = timeout >= 60 ? "\(Int(timeout / 60)) minutes" : "\(Int(timeout)) seconds"
        return "the password prompt was not answered within \(wait)"
    }
}

struct OsascriptAdminRunner: AdminCommandRunning {
    static let osascript = "/usr/bin/osascript"
    /// Long enough to read the prompt and type a password; the 20 s pmset
    /// limit would cut a person off mid-password.
    static let timeout: TimeInterval = 300

    let osascriptPath: String
    let commandTimeout: TimeInterval
    let grace: TimeInterval
    let runner: CancellableCommand

    init(
        osascript: String = Self.osascript,
        timeout: TimeInterval = Self.timeout,
        stopGrace: TimeInterval = PmsetSleepGuard.stopGrace,
        runner: CancellableCommand = CancellableCommand()
    ) {
        osascriptPath = osascript
        commandTimeout = timeout
        grace = stopGrace
        self.runner = runner
    }

    /// `command` and `prompt` are constants with no quotes or backslashes
    /// (AdminPromptTests pins this): nothing user-provided reaches the script.
    static func script(command: String, prompt: String) -> String {
        "do shell script \"\(command)\" with prompt \"\(prompt)\" with administrator privileges"
    }

    /// SIGTERM only, never SIGKILL (`StopPolicy.terminateOnly`), as for
    /// `sudo pmset`: killing osascript would not stop the root shell it
    /// started, which could then disable sleep after the start was undone.
    /// An osascript that outlives the grace throws
    /// `CommandStillRunningError`; the caller keeps the lock and the journal
    /// until it exits. One that stops at the deadline throws
    /// `AdminPromptTimeoutError`.
    func runAsAdministrator(_ command: String, prompt: String) async throws {
        let result: ShellResult
        do {
            result = try await runner.run(
                osascriptPath,
                ["-e", Self.script(command: command, prompt: prompt)],
                timeout: commandTimeout,
                stop: .terminateOnly(grace: grace),
                holding: RecoveryLock.held
            )
        } catch is ShellTimeoutError {
            throw AdminPromptTimeoutError(timeout: commandTimeout)
        }
        if result.status == 0 { return }
        // AppleScript's "User canceled." is error -128.
        if result.stderr.contains("(-128)") { throw AdminPromptCancelledError() }
        throw SleepGuardError(command: "osascript: \(command)", status: result.status, stderr: result.stderr)
    }
}
