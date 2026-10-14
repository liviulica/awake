import XCTest
@testable import Insomnia

/// The test build's control channel (scripts/smoke-test.sh): the command
/// parser, the status file it writes, and when it turns on. Compiled into
/// debug builds, so `swift test` covers it; a plain release build has none
/// of it (scripts/check-lid-simulation-gate.sh).
@MainActor
final class TestControlTests: XCTestCase {
    // MARK: Commands

    func testParsesEveryCommand() {
        XCTAssertEqual(TestControlCommand.parse("awake-on"), .awakeOn(nil))
        XCTAssertEqual(TestControlCommand.parse("awake-on 3600"), .awakeOn(3600))
        XCTAssertEqual(TestControlCommand.parse("awake-off"), .awakeOff)
        XCTAssertEqual(TestControlCommand.parse("lid-start 600"), .lidStart(600))
        XCTAssertEqual(TestControlCommand.parse("lid-extend 1.5"), .lidExtend(1.5))
        XCTAssertEqual(TestControlCommand.parse("lid-end"), .lidEnd)
        XCTAssertEqual(TestControlCommand.parse("quit"), .quit)
    }

    func testToleratesSurroundingAndRepeatedWhitespace() {
        XCTAssertEqual(TestControlCommand.parse("  lid-start \t 600 \r"), .lidStart(600))
        XCTAssertEqual(TestControlCommand.parse("quit\r"), .quit)
    }

    func testRejectsMalformedLines() {
        let bad = [
            "", "   ", "Quit", "bogus",
            "lid-start", "lid-extend", "lid-start abc", "lid-start 600s",
            "lid-start -5", "lid-start 0", "lid-start inf", "lid-start nan", "lid-start 600 600",
            "awake-on 0", "awake-on -1", "awake-on 1 2",
            "awake-off now", "lid-end 5", "quit 3",
        ]
        for line in bad {
            XCTAssertNil(TestControlCommand.parse(line), "\"\(line)\" should not parse")
        }
    }

    func testSplitsAFileIntoLinesInOrderAndSkipsBlankOnes() {
        let parsed = TestControlCommand.parseFile("awake-on\n\n  \nlid-start 600\nbogus\nquit")
        XCTAssertEqual(parsed, [
            .init(text: "awake-on", command: .awakeOn(nil)),
            .init(text: "lid-start 600", command: .lidStart(600)),
            .init(text: "bogus", command: nil),
            .init(text: "quit", command: .quit),
        ])
    }

    // MARK: Status file

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Decodes the encoded status as the shell sees it: every key present,
    /// a missing value as JSON null.
    private func decode(_ status: TestControlStatus) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: status.encoded())
        return try XCTUnwrap(object as? [String: Any])
    }

    private static let keys: Set<String> = ["awakeOn", "awakeEndsAt", "lidActive", "lidPaused", "lidRemaining", "lidHoldActive", "icon", "title"]

    func testIdleStatusWritesEveryKeyWithNullsForWhatDoesNotApply() throws {
        let json = try decode(TestControlStatus(awake: .off, lidHoldActive: false, session: nil, now: now))

        XCTAssertEqual(Set(json.keys), Self.keys)
        XCTAssertEqual(json["awakeOn"] as? Bool, false)
        XCTAssertTrue(json["awakeEndsAt"] is NSNull)
        XCTAssertEqual(json["lidActive"] as? Bool, false)
        XCTAssertTrue(json["lidPaused"] is NSNull)
        XCTAssertTrue(json["lidRemaining"] is NSNull)
        XCTAssertEqual(json["lidHoldActive"] as? Bool, false)
        XCTAssertEqual(json["icon"] as? String, "off")
        XCTAssertEqual(json["title"] as? String, "")
    }

    func testAwakeModeUntilTurnedOff() throws {
        let json = try decode(TestControlStatus(awake: .on(until: nil), lidHoldActive: false, session: nil, now: now))

        XCTAssertEqual(json["awakeOn"] as? Bool, true)
        XCTAssertTrue(json["awakeEndsAt"] is NSNull)
        XCTAssertEqual(json["icon"] as? String, "awake")
        XCTAssertEqual(json["title"] as? String, "")
    }

    func testTimedAwakeModeCarriesItsEndAndCountdown() throws {
        let until = now.addingTimeInterval(3600)
        let json = try decode(TestControlStatus(awake: .on(until: until), lidHoldActive: false, session: nil, now: now))

        XCTAssertEqual(json["awakeEndsAt"] as? String, "2027-01-15T09:00:00Z")
        XCTAssertEqual(json["icon"] as? String, "awake")
        XCTAssertEqual(json["title"] as? String, "1:00")
    }

    func testPausedLidSessionWithTheScreenHeld() throws {
        let session = Session(startedAt: now, endsAt: now.addingTimeInterval(300), pausedRemaining: 600)
        let json = try decode(TestControlStatus(awake: .off, lidHoldActive: true, session: session, now: now))

        XCTAssertEqual(json["lidActive"] as? Bool, true)
        XCTAssertEqual(json["lidPaused"] as? Bool, true)
        XCTAssertEqual(json["lidRemaining"] as? Int, 600)
        XCTAssertEqual(json["lidHoldActive"] as? Bool, true)
        XCTAssertEqual(json["icon"] as? String, "lid")
        XCTAssertEqual(json["title"] as? String, "0:10")
    }

    /// The closed-lid clock runs: the time left is to `endsAt`, in whole
    /// seconds, and the lid icon wins over the Awake state.
    func testRunningLidSessionCountsDownToItsEnd() throws {
        let session = Session(startedAt: now, endsAt: now.addingTimeInterval(299.6))
        let json = try decode(TestControlStatus(awake: .on(until: nil), lidHoldActive: false, session: session, now: now))

        XCTAssertEqual(json["lidPaused"] as? Bool, false)
        XCTAssertEqual(json["lidRemaining"] as? Int, 300)
        XCTAssertEqual(json["icon"] as? String, "lid")
        XCTAssertEqual(json["title"] as? String, "0:05")
    }

    // MARK: Turning it on

    func testTestModeNeedsTheSwitchAndARelocatedHome() {
        XCTAssertEqual(TestMode.requested(in: ["AWAKE_TEST_MODE": "1", "AWAKE_HOME": "/tmp/x"])?.paths, Paths(root: URL(fileURLWithPath: "/tmp/x", isDirectory: true)))
        XCTAssertNil(TestMode.requested(in: [:]))
        XCTAssertNil(TestMode.requested(in: ["AWAKE_HOME": "/tmp/x"]))
        XCTAssertNil(TestMode.requested(in: ["AWAKE_TEST_MODE": "1"]))
        XCTAssertNil(TestMode.requested(in: ["AWAKE_TEST_MODE": "1", "AWAKE_HOME": ""]))
        XCTAssertNil(TestMode.requested(in: ["AWAKE_TEST_MODE": "yes", "AWAKE_HOME": "/tmp/x"]))
    }

    // MARK: Simulated sleep guard

    func testSimulatedSleepGuardKeepsTheBitAndLogsEachChange() async throws {
        let home = TempHome()
        defer { home.destroy() }
        let log = home.paths.appSupport.appendingPathComponent("test-sleepguard.log")
        let guardian = SimulatedSleepGuard(log: log)

        let before = try await guardian.isSleepDisabled()
        XCTAssertFalse(before)
        try await guardian.setSleepDisabled(true)
        let during = try await guardian.isSleepDisabled()
        XCTAssertTrue(during)
        try await guardian.setLowPowerMode(true)
        let lowPower = try await guardian.isLowPowerModeOn()
        XCTAssertTrue(lowPower)
        try await guardian.setLowPowerMode(false)
        try await guardian.setSleepDisabled(false)
        let after = try await guardian.isSleepDisabled()
        XCTAssertFalse(after)

        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["disablesleep 1", "lowpowermode 1", "lowpowermode 0", "disablesleep 0"])
    }
}
