import XCTest
@testable import Insomnia

final class ReachabilityTrackerTests: XCTestCase {
    func testThirdConsecutiveFailureStartsAnOutageOnce() {
        var t = ReachabilityTracker()
        XCTAssertFalse(t.record(success: false))
        XCTAssertFalse(t.record(success: false))
        XCTAssertTrue(t.record(success: false))
        XCTAssertFalse(t.record(success: false), "only the crossing reports")
    }

    func testASuccessResetsTheCount() {
        var t = ReachabilityTracker()
        _ = t.record(success: false)
        _ = t.record(success: false)
        XCTAssertFalse(t.record(success: true))
        XCTAssertFalse(t.record(success: false))
    }
}

final class CaptivePortalProbeTests: XCTestCase {
    private let page = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"

    func testAppleSuccessPageIsOnline() {
        XCTAssertTrue(CaptivePortalProbe.isSuccess(statusCode: 200, host: "captive.apple.com", body: page))
    }

    func testAnotherHostIsAPortal() {
        XCTAssertFalse(CaptivePortalProbe.isSuccess(statusCode: 200, host: "login.hotel.example", body: page))
    }

    func testAPortalPageMentioningSuccessIsNotOnline() {
        XCTAssertFalse(CaptivePortalProbe.isSuccess(statusCode: 200, host: "captive.apple.com", body: "Successfully logged in"))
    }

    func testARedirectIsNotOnline() {
        XCTAssertFalse(CaptivePortalProbe.isSuccess(statusCode: 302, host: "captive.apple.com", body: page))
    }
}

/// Answers once `gate` opens, so a test can stop the driver mid-probe.
final class GatedProbe: ReachabilityProbing, @unchecked Sendable {
    let gate = AsyncGate()
    func isInternetReachable() async -> Bool {
        await gate.wait()
        return false
    }
}

final class FakeProbe: ReachabilityProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool]
    init(_ results: [Bool]) { self.results = results }
    /// Pops the next scripted answer; the last one repeats.
    func isInternetReachable() async -> Bool {
        lock.withLock { results.count > 1 ? results.removeFirst() : (results.first ?? true) }
    }
}
