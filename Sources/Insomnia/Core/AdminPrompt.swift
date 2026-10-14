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

struct OsascriptAdminRunner: AdminCommandRunning {
    static let osascript = "/usr/bin/osascript"
    /// Long enough to read the prompt and type a password; the 20 s pmset
    /// limit would cut a person off mid-password.
    static let timeout: TimeInterval = 300

    let osascriptPath: String
    let commandTimeout: TimeInterval
    let runner: CancellableCommand

    init(osascript: String = Self.osascript, timeout: TimeInterval = Self.timeout, runner: CancellableCommand = CancellableCommand()) {
        osascriptPath = osascript
        commandTimeout = timeout
        self.runner = runner
    }

    /// `command` and `prompt` are constants with no quotes or backslashes
    /// (AdminPromptTests pins this): nothing user-provided reaches the script.
    static func script(command: String, prompt: String) -> String {
        "do shell script \"\(command)\" with prompt \"\(prompt)\" with administrator privileges"
    }

    func runAsAdministrator(_ command: String, prompt: String) async throws {
        let result = try await runner.run(
            osascriptPath,
            ["-e", Self.script(command: command, prompt: prompt)],
            timeout: commandTimeout,
            stop: .terminateThenKill,
            holding: RecoveryLock.held
        )
        if result.status == 0 { return }
        // AppleScript's "User canceled." is error -128.
        if result.stderr.contains("(-128)") { throw AdminPromptCancelledError() }
        throw SleepGuardError(command: "osascript: \(command)", status: result.status, stderr: result.stderr)
    }
}
