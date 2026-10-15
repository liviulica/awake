import XCTest
@testable import Insomnia

final class SessionMathTests: XCTestCase {
    let maxDuration: TimeInterval = 24 * 3600
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testClampFloorAndCeiling() {
        XCTAssertEqual(SessionMath.clamp(0, maxDuration: maxDuration), SessionMath.minimumDuration)
        XCTAssertEqual(SessionMath.clamp(-5, maxDuration: maxDuration), SessionMath.minimumDuration)
        XCTAssertEqual(SessionMath.clamp(3600, maxDuration: maxDuration), 3600)
        XCTAssertEqual(SessionMath.clamp(maxDuration + 1, maxDuration: maxDuration), maxDuration)
        XCTAssertEqual(SessionMath.clamp(40 * 24 * 3600, maxDuration: maxDuration), maxDuration)
    }

    func testEndsAtUsesClampedDuration() {
        let end = SessionMath.endsAt(start: t0, duration: 100 * 24 * 3600, maxDuration: maxDuration)
        XCTAssertEqual(end, t0.addingTimeInterval(maxDuration))
    }

    func testPauseKeepsWhatIsLeftAndResumeRunsOnIt() {
        let running = Session(startedAt: t0, endsAt: t0.addingTimeInterval(3600))
        let p = SessionMath.paused(running, now: t0.addingTimeInterval(600))
        XCTAssertEqual(p.pausedRemaining, 3000)
        XCTAssertEqual(p.endsAt, t0.addingTimeInterval(600 + SessionMath.pauseLease))
        XCTAssertEqual(SessionMath.paused(p, now: t0.addingTimeInterval(900)), p, "pausing twice changes nothing")
        let r = SessionMath.resumed(p, now: t0.addingTimeInterval(7200))
        XCTAssertNil(r.pausedRemaining)
        XCTAssertEqual(r.endsAt, t0.addingTimeInterval(7200 + 3000))
        XCTAssertEqual(SessionMath.resumed(r, now: t0.addingTimeInterval(7300)), r, "resuming a running clock changes nothing")
    }

    func testLeaseRenewalMovesOnlyAPausedSession() {
        let p = SessionMath.newPausedSession(now: t0, duration: 3600, maxDuration: maxDuration)
        XCTAssertEqual(p.pausedRemaining, 3600)
        let renewed = SessionMath.leaseRenewed(p, now: t0.addingTimeInterval(60))
        XCTAssertEqual(renewed.endsAt, t0.addingTimeInterval(60 + SessionMath.pauseLease))
        XCTAssertEqual(renewed.pausedRemaining, 3600)
        let running = Session(startedAt: t0, endsAt: t0.addingTimeInterval(3600))
        XCTAssertEqual(SessionMath.leaseRenewed(running, now: t0.addingTimeInterval(60)), running)
    }

    func testExtendWhilePausedAddsClosedTimeAndLeavesTheLease() {
        let p = SessionMath.newPausedSession(now: t0, duration: 3600, maxDuration: maxDuration)
        let e = SessionMath.extended(p, by: 1800, now: t0.addingTimeInterval(120), maxDuration: maxDuration)
        XCTAssertEqual(e.pausedRemaining, 5400)
        XCTAssertEqual(e.endsAt, p.endsAt)
        XCTAssertEqual(e.extensions, [1800])
        let capped = SessionMath.extended(e, by: maxDuration, now: t0, maxDuration: maxDuration)
        XCTAssertEqual(capped.pausedRemaining, maxDuration)
        XCTAssertEqual(capped.extensions, [1800, maxDuration - 5400])
    }

    func testExtendAddsToEndAndRecordsExtension() {
        let s = Session(startedAt: t0, endsAt: t0.addingTimeInterval(3600))
        let e = SessionMath.extended(s, by: 1800, now: t0.addingTimeInterval(600), maxDuration: maxDuration)
        XCTAssertEqual(e.endsAt, t0.addingTimeInterval(5400))
        XCTAssertEqual(e.extensions, [1800])
        XCTAssertEqual(e.startedAt, t0)
    }

    func testExtendIsClampedToMaxFromNow() {
        let s = Session(startedAt: t0, endsAt: t0.addingTimeInterval(23 * 3600))
        let now = t0.addingTimeInterval(3600)
        let e = SessionMath.extended(s, by: 5 * 3600, now: now, maxDuration: maxDuration)
        XCTAssertEqual(e.endsAt, now.addingTimeInterval(maxDuration))
    }

    func testExtendExpiredSessionRestartsFromNow() {
        let s = Session(startedAt: t0, endsAt: t0.addingTimeInterval(60))
        let now = t0.addingTimeInterval(3600)
        let e = SessionMath.extended(s, by: 600, now: now, maxDuration: maxDuration)
        XCTAssertEqual(e.endsAt, now.addingTimeInterval(600))
    }

    func testRemainingNeverNegative() {
        XCTAssertEqual(SessionMath.remaining(until: t0, at: t0.addingTimeInterval(10)), 0)
        XCTAssertEqual(SessionMath.remaining(until: t0.addingTimeInterval(90), at: t0), 90)
    }

    func testExpiryBoundary() {
        let s = Session(startedAt: t0, endsAt: t0.addingTimeInterval(60))
        XCTAssertFalse(s.isExpired(at: t0.addingTimeInterval(59.999)))
        XCTAssertTrue(s.isExpired(at: t0.addingTimeInterval(60)))
        XCTAssertTrue(s.isExpired(at: t0.addingTimeInterval(61)))
        XCTAssertEqual(s.remaining(at: t0.addingTimeInterval(60)), 0)
    }

    func testFormatFourShapes() {
        XCTAssertEqual(SessionMath.formatRemaining(3 * 86400 + 2 * 3600 + 5 * 60), "3d 2h")
        XCTAssertEqual(SessionMath.formatRemaining(2 * 3600 + 14 * 60 + 59), "2h 14m")
        XCTAssertEqual(SessionMath.formatRemaining(14 * 60 + 1), "14m")
        XCTAssertEqual(SessionMath.formatRemaining(59), "<1m")
        XCTAssertEqual(SessionMath.formatRemaining(0), "<1m")
        XCTAssertEqual(SessionMath.formatRemaining(-5), "<1m")
    }

    func testFormatDropsZeroSecondaryUnits() {
        XCTAssertEqual(SessionMath.formatRemaining(2 * 3600), "2h")
        XCTAssertEqual(SessionMath.formatRemaining(3 * 86400), "3d")
        XCTAssertEqual(SessionMath.formatRemaining(60), "1m")
    }
}
