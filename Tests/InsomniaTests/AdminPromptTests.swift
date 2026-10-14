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

    func testTimeoutIsAFailureNotACancel() async throws {
        let url = dir.appendingPathComponent("osascript")
        try TestScripts.write("#!/bin/sh\nexec sleep 30\n", to: url)
        let runner = OsascriptAdminRunner(osascript: url.path, timeout: 0.5)
        do {
            try await runner.runAsAdministrator("/usr/bin/true", prompt: "p")
            XCTFail("expected a timeout")
        } catch is AdminPromptCancelledError {
            XCTFail("a timeout must not read as a cancel")
        } catch {
        }
    }
}
