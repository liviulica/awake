import Foundation
import XCTest
@testable import Insomnia

/// scripts/real-sleep-check.sh in `--dry-run` mode: it parses the saved
/// excerpts under Tests/Fixtures/real-sleep/ (an ember.log in UTC and a
/// `log show` powerd excerpt in the Mac's local time, here UTC+3) instead of
/// the live logs, skips the preconditions and the guided steps, and prints
/// the verdict. The real run needs a person at a real Mac and is Task 18.
final class RealSleepCheckScriptTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func run(_ fixture: String, extra: [String] = ["--dry-run"]) throws -> (status: Int32, out: String) {
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("real-sleep-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outURL) }
        let out = try FileHandle(forWritingTo: outURL)
        defer { try? out.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        let dir = Self.repoRoot.appendingPathComponent("Tests/Fixtures/real-sleep/\(fixture)").path
        p.arguments = [Self.repoRoot.appendingPathComponent("scripts/real-sleep-check.sh").path] + extra + [dir]
        // Europe/Bucharest is UTC+3 on 2026-10-14: the powerd excerpts are local.
        p.environment = ["TZ": "Europe/Bucharest", "HOME": NSTemporaryDirectory()]
        p.standardOutput = out
        p.standardError = out
        let exit = ProcessExit(p)
        try p.run()
        exit.wait()
        return (p.terminationStatus, (try? String(contentsOf: outURL, encoding: .utf8)) ?? "")
    }

    func testPassingFixtureProvesTheLidClosedPromise() throws {
        let r = try run("pass")

        XCTAssertEqual(r.status, 0, r.out)
        XCTAssertTrue(r.out.contains("PASS (a) no sleep while the lid was closed and the timer ran"), r.out)
        XCTAssertTrue(r.out.contains("PASS (b) the session ended by timer 181 s after the lid closed"), r.out)
        XCTAssertTrue(r.out.contains("PASS (c) macOS slept 2 s after the session ended"), r.out)
        XCTAssertTrue(r.out.contains("RESULT: PASS"), r.out)
        XCTAssertTrue(r.out.contains("2026-10-14T18:03:43Z"), "the sleep time is shown in UTC beside the local one: " + r.out)
    }

    func testASleepBeforeTheTimerEndFails() throws {
        let r = try run("fail-early-sleep")

        XCTAssertNotEqual(r.status, 0, r.out)
        XCTAssertTrue(r.out.contains("FAIL (a)"), r.out)
        XCTAssertTrue(r.out.contains("2026-10-14T18:01:10Z"), r.out)
        XCTAssertTrue(r.out.contains("FAIL (c)"), "no sleep follows the end: " + r.out)
        XCTAssertTrue(r.out.contains("RESULT: FAIL"), r.out)
    }

    func testASleepJustBeforeTheLoggedLidCloseStillFails() throws {
        // LidObserver logs "lid closed" about 2 s after the lid: the clamshell
        // sleep is stamped 1 s before that line, and must not slip past (a).
        let r = try run("fail-sleep-at-close")

        XCTAssertNotEqual(r.status, 0, r.out)
        XCTAssertTrue(r.out.contains("FAIL (a)"), r.out)
        XCTAssertTrue(r.out.contains("2026-10-14T18:00:39Z"), r.out)
        XCTAssertTrue(r.out.contains("a sleep at the close counts"), r.out)
        XCTAssertTrue(r.out.contains("PASS (c)"), r.out)
    }

    func testASleepMoreThanAMinuteAfterTheEndFailsOnlyTheLastCheck() throws {
        let r = try run("fail-late-sleep")

        XCTAssertNotEqual(r.status, 0, r.out)
        XCTAssertTrue(r.out.contains("PASS (a)"), r.out)
        XCTAssertTrue(r.out.contains("PASS (b)"), r.out)
        XCTAssertTrue(r.out.contains("FAIL (c)"), r.out)
        XCTAssertTrue(r.out.contains("109 s after"), r.out)
    }

    func testAMissingFixtureIsAnErrorNotAPass() throws {
        let r = try run("no-such-folder")

        XCTAssertNotEqual(r.status, 0, r.out)
        XCTAssertFalse(r.out.contains("RESULT: PASS"), r.out)
    }
}
