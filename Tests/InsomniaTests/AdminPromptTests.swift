import XCTest
@testable import Insomnia

/// `OsascriptAdminRunner` against a fake `osascript` (a `/bin/sh` script in a
/// private temp dir), so nothing here raises a real administrator prompt.
final class AdminPromptTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("admin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func fakeOsascript(exit status: Int, stderr: String) throws -> String {
        let url = dir.appendingPathComponent("osascript")
        try TestScripts.write("#!/bin/sh\necho \"$2\" > \"\(dir.path)/args\"\necho '\(stderr)' >&2\nexit \(status)\n", to: url)
        return url.path
    }

    func testScriptIsTheConstantCommandWithAdministratorPrivileges() {
        let s = OsascriptAdminRunner.script(command: PmsetSleepGuard.disableSleepCommand, prompt: PmsetSleepGuard.adminPrompt)
        XCTAssertEqual(s, "do shell script \"/usr/bin/pmset -a disablesleep 1\" with prompt \"\(PmsetSleepGuard.adminPrompt)\" with administrator privileges")
        XCTAssertFalse(PmsetSleepGuard.adminPrompt.contains("\""))
        XCTAssertFalse(PmsetSleepGuard.adminPrompt.contains("\\"))
    }

    /// What the precondition in `script` accepts: the real constants, and
    /// nothing with a quote or a backslash (which would end or escape the
    /// AppleScript string around a root command).
    func testOnlyQuoteAndBackslashFreeTextIsASafeLiteral() {
        XCTAssertTrue(OsascriptAdminRunner.isSafeLiteral(PmsetSleepGuard.disableSleepCommand))
        XCTAssertTrue(OsascriptAdminRunner.isSafeLiteral(PmsetSleepGuard.adminPrompt))
        XCTAssertFalse(OsascriptAdminRunner.isSafeLiteral(#"/usr/bin/true" & "x"#))
        XCTAssertFalse(OsascriptAdminRunner.isSafeLiteral("a\\\"b"))
        XCTAssertFalse(OsascriptAdminRunner.isSafeLiteral("C:\\path"))
        XCTAssertTrue(OsascriptAdminRunner.isSafeLiteral(""))
    }

    func testSuccess() async throws {
        let runner = OsascriptAdminRunner(osascript: try fakeOsascript(exit: 0, stderr: ""))
        try await runner.runAsAdministrator("/usr/bin/true", prompt: "p")
        let args = try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8)
        XCTAssertTrue(args.contains("with administrator privileges"), args)
    }

    func testCancelIsItsOwnError() async throws {
        let runner = OsascriptAdminRunner(osascript: try fakeOsascript(exit: 1, stderr: "0:94: execution error: User canceled. (-128)"))
        do {
            try await runner.runAsAdministrator("/usr/bin/true", prompt: "p")
            XCTFail("expected a cancel")
        } catch is AdminPromptCancelledError {
        }
    }

    func testOtherFailureIsASleepGuardError() async throws {
        let runner = OsascriptAdminRunner(osascript: try fakeOsascript(exit: 1, stderr: "execution error: something else (-1)"))
        do {
            try await runner.runAsAdministrator("/usr/bin/true", prompt: "p")
            XCTFail("expected a failure")
        } catch let e as SleepGuardError {
            XCTAssertEqual(e.status, 1)
        }
    }

    /// An osascript that stops on SIGTERM at the deadline: a timeout with
    /// its own error, never a cancel. (`exec`, so the signalled pid is the
    /// sleep and no grandchild holds the output pipe open for 30 s.)
    func testTimeoutIsAFailureNotACancel() async throws {
        let url = dir.appendingPathComponent("osascript")
        try TestScripts.write("#!/bin/sh\nexec sleep 30\n", to: url)
        let runner = OsascriptAdminRunner(osascript: url.path, timeout: 0.5)
        do {
            try await runner.runAsAdministrator("/usr/bin/true", prompt: "p")
            XCTFail("expected a timeout")
        } catch is AdminPromptCancelledError {
            XCTFail("a timeout must not read as a cancel")
        } catch let error as AdminPromptTimeoutError {
            XCTAssertEqual(error.timeout, 0.5)
        }
    }

    func testTimeoutTellsThePersonThePromptWasNotAnswered() {
        XCTAssertEqual(AdminPromptTimeoutError(timeout: OsascriptAdminRunner.timeout).localizedDescription, "the password prompt was not answered within 5 minutes")
    }

    /// An osascript that ignores SIGTERM is never SIGKILLed: killing it
    /// would not stop the root shell it started, which could disable sleep
    /// after the start was undone. It is reported as still running, so the
    /// caller keeps the lock and the journal until it exits.
    func testOsascriptThatIgnoresTermIsLeftRunningNotKilled() async throws {
        let pidFile = dir.appendingPathComponent("pid").path
        let url = dir.appendingPathComponent("osascript")
        try TestScripts.write("#!/bin/sh\ntrap '' TERM\nprintf '%s' $$ > '\(pidFile).partial' && mv '\(pidFile).partial' '\(pidFile)'\nexec sleep 30\n", to: url)
        // The deadline starts once the trap is in place, however slow the spawn.
        let runner = CancellableCommand(beforeDeadline: {
            for _ in 0..<1000 where !FileManager.default.fileExists(atPath: pidFile) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        })
        let admin = OsascriptAdminRunner(osascript: url.path, timeout: 0.5, stopGrace: 0.3, runner: runner)
        var reported: UnfinishedCommand?
        do {
            try await admin.runAsAdministrator("/usr/bin/true", prompt: "p")
            XCTFail("an osascript that ignores TERM returned")
        } catch let error as CommandStillRunningError {
            XCTAssertEqual(error.reason, .timeout(seconds: 0.5))
            XCTAssertEqual(error.grace, 0.3)
            reported = error.command
        }
        let command = try XCTUnwrap(reported)
        let pid = try XCTUnwrap(pid_t(try String(contentsOfFile: pidFile, encoding: .utf8)))
        XCTAssertEqual(command.pid, pid)
        // Still alive well after the second a SIGKILL would have landed.
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertTrue(kill(pid, 0) == 0, "the osascript was killed")
        XCTAssertTrue(command.isRunning)

        kill(pid, SIGKILL)
        await command.waitUntilExit()
        XCTAssertFalse(command.isRunning)
    }

    /// The sudoers hint is for sudo failures only: the administrator
    /// prompt does not use /etc/sudoers.d/awake.
    func testAdminPromptFailureCarriesNoSudoersHint() {
        let e = SleepGuardError(command: "osascript: \(PmsetSleepGuard.disableSleepCommand)", status: 1, stderr: "execution error: incorrect password (-60005)")
        XCTAssertFalse(e.localizedDescription.contains("install.sh"), e.localizedDescription)
        let sudo = SleepGuardError(command: "sudo -n /usr/bin/pmset -a disablesleep 0", status: 1, stderr: "sudo: a password is required")
        XCTAssertTrue(sudo.localizedDescription.contains("install.sh"), sudo.localizedDescription)
    }
}
