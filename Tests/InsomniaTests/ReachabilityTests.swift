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

final class FakeProbe: ReachabilityProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool]
    init(_ results: [Bool]) { self.results = results }
    /// Pops the next scripted answer; the last one repeats.
    func isInternetReachable() async -> Bool {
        lock.withLock { results.count > 1 ? results.removeFirst() : (results.first ?? true) }
    }
}
