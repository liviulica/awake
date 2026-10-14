import IOKit.ps
import XCTest
@testable import Insomnia

/// `PowerMonitor` with power source descriptions built by hand and an
/// injected reader. Nothing here changes power state.
@MainActor
final class PowerMonitorTests: XCTestCase {
    private func battery(current: Int? = 50, max: Int? = 100, state: String = kIOPSBatteryPowerValue, charging: Bool = false) -> [String: Any] {
        var d: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSPowerSourceStateKey: state,
            kIOPSIsChargingKey: charging,
        ]
        if let current { d[kIOPSCurrentCapacityKey] = current }
        if let max { d[kIOPSMaxCapacityKey] = max }
        return d
    }

    /// `classify` with the registry probes fixed. `external` is what the
    /// AppleSmartBattery driver says about the charger, nil when unreadable.
    private func classify(_ sources: [[String: Any]]?, service: Bool, external: Bool? = nil) -> (battery: BatteryStatus, charging: Bool) {
        PowerMonitor.classify(sources: sources, hasBatteryService: { service }, externalPowerConnected: { external })
    }

    // MARK: classify: no battery vs. battery present but unreadable

    func testReadableBatteryIsAPercent() {
        let r = PowerMonitor.classify(
            sources: [battery(current: 42, max: 100)],
            hasBatteryService: { XCTFail("service checked with an entry present"); return true },
            externalPowerConnected: { XCTFail("charger probed with an entry present"); return true }
        )
        XCTAssertEqual(r.battery, .percent(42))
        XCTAssertFalse(r.charging)
        XCTAssertTrue(classify([battery(state: kIOPSACPowerValue)], service: true).charging)
        XCTAssertTrue(classify([battery(charging: true)], service: true).charging)
    }

    func testEmptyListIsNoBatteryOnADesktop() {
        let r = PowerMonitor.classify(
            sources: [],
            hasBatteryService: { false },
            externalPowerConnected: { XCTFail("charger probed on a desktop"); return true }
        )
        XCTAssertEqual(r.battery, .none)
        XCTAssertFalse(r.charging)
    }

    func testEmptyListWithABatteryServiceIsUnreadable() {
        XCTAssertEqual(classify([], service: true).battery, .unreadable(misses: 1))
    }

    func testUnavailableListFollowsTheBatteryService() {
        XCTAssertEqual(classify(nil, service: true).battery, .unreadable(misses: 1))
        XCTAssertEqual(classify(nil, service: false).battery, .none)
    }

    /// Greptile caught this: a laptop on a charger whose list is unreadable
    /// or has no battery entry was reported as on battery, so the two-miss
    /// rule ended its session. The charger state comes from the driver's
    /// `ExternalConnected` instead. When that is unreadable too the laptop
    /// is taken to be on battery, so the session ends rather than running
    /// with no floor on a battery that may be draining.
    func testUnreadableListTakesTheChargerFromTheDriver() {
        XCTAssertEqual(classify(nil, service: true, external: true).battery, .unreadable(misses: 1))
        XCTAssertTrue(classify(nil, service: true, external: true).charging)
        XCTAssertTrue(classify([], service: true, external: true).charging)
        XCTAssertFalse(classify(nil, service: true, external: false).charging)
        XCTAssertFalse(classify([], service: true, external: false).charging)
        XCTAssertFalse(classify(nil, service: true, external: nil).charging, "unknown charger state must fail closed")
    }

    /// An entry without a usable capacity is unreadable even though the
    /// power source state is known; charging still comes from the entry.
    func testEntryWithoutCapacityIsUnreadableButKeepsCharging() {
        let noCurrent = classify([battery(current: nil, state: kIOPSACPowerValue)], service: false)
        XCTAssertEqual(noCurrent.battery, .unreadable(misses: 1))
        XCTAssertTrue(noCurrent.charging)
        XCTAssertEqual(classify([battery(max: 0)], service: false).battery, .unreadable(misses: 1))
    }

    func testOtherPowerSourcesAreIgnored() {
        let ups: [String: Any] = [kIOPSTypeKey: kIOPSUPSType, kIOPSCurrentCapacityKey: 90, kIOPSMaxCapacityKey: 100]
        XCTAssertEqual(classify([ups], service: false).battery, .none)
        XCTAssertEqual(classify([ups, battery(current: 70)], service: false).battery, .percent(70))
    }

    // MARK: consecutive misses and the recheck

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var _next: (battery: BatteryStatus, charging: Bool) = (.unreadable(misses: 1), false)
        private var _count = 0
        var next: (battery: BatteryStatus, charging: Bool) {
            get { lock.withLock { _next } }
            set { lock.withLock { _next = newValue } }
        }
        var count: Int { lock.withLock { _count } }
        func read() -> (battery: BatteryStatus, charging: Bool) {
            lock.withLock { _count += 1; return _next }
        }
    }

    /// Stands in for the recheck's `Task.sleep`: each wait stays parked
    /// until `fire()` lets the oldest one return, or until its task is
    /// cancelled, when it throws at once as `Task.sleep` does. `pending`
    /// counts the parked waits, `cancelled` the ones a cancel ended and
    /// `returned` the waits that have gone back to the monitor (on the main
    /// actor, as the recheck that calls it runs). No test here depends on
    /// how long anything takes.
    private final class ManualWait: @unchecked Sendable {
        private let lock = NSLock()
        private var parked: [(id: Int, resume: CheckedContinuation<Void, Error>)] = []
        private var nextId = 0
        private var _cancelled = 0
        private var _returned = 0
        var pending: Int { lock.withLock { parked.count } }
        var cancelled: Int { lock.withLock { _cancelled } }
        var returned: Int { lock.withLock { _returned } }

        @MainActor
        func wait(_: Duration) async throws {
            let id: Int = lock.withLock { nextId += 1; return nextId }
            defer { lock.withLock { _returned += 1 } }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    let cancelledAlready: Bool = lock.withLock {
                        if Task.isCancelled { _cancelled += 1; return true }
                        parked.append((id, c))
                        return false
                    }
                    if cancelledAlready { c.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let c: CheckedContinuation<Void, Error>? = lock.withLock {
                    guard let i = parked.firstIndex(where: { $0.id == id }) else { return nil }
                    _cancelled += 1
                    return parked.remove(at: i).resume
                }
                c?.resume(throwing: CancellationError())
            }
        }

        /// Lets the oldest parked wait return, as if its delay had passed.
        func fire(file: StaticString = #filePath, line: UInt = #line) {
            let c: CheckedContinuation<Void, Error>? = lock.withLock { parked.isEmpty ? nil : parked.removeFirst().resume }
            XCTAssertNotNil(c, "no recheck was waiting", file: file, line: line)
            c?.resume()
        }
    }

    /// A started monitor whose rechecks wait on `wait` and that hears
    /// nothing from the real Mac: no IOKit battery events, no thermal
    /// changes (a loaded machine warms up and changes its thermal state,
    /// which is an `onChange` of its own).
    private func monitor(_ reads: Reads, _ wait: ManualWait) -> PowerMonitor {
        PowerMonitor(reader: { reads.read() }, wait: { try await wait.wait($0) }, systemEvents: false)
    }

    /// Lets the parked recheck run and waits until it has read the battery.
    /// The read and everything the recheck does with it (the new state,
    /// `onChange`, the next recheck) is one synchronous main-actor step, so
    /// a test on the main actor that sees the read sees all of it.
    private func runRecheck(_ wait: ManualWait, _ reads: Reads, file: StaticString = #filePath, line: UInt = #line) async {
        await pollUntil("no recheck was scheduled", file: file, line: line) { wait.pending == 1 }
        let before = reads.count
        wait.fire(file: file, line: line)
        await pollUntil("the recheck never read the battery", file: file, line: line) { reads.count == before + 1 }
    }

    /// The menu's refresh never counts a miss: the count only moves on the
    /// event path, where the floor rules see it. A readable read still
    /// replaces the state, and a miss after it starts the count over.
    func testMenuRefreshKeepsTheMissCountWhereItIs() {
        let reads = Reads()
        let monitor = PowerMonitor(reader: { reads.read() }, recheckDelay: .seconds(3600))
        XCTAssertEqual(monitor.battery, .none)
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1))
        XCTAssertNil(monitor.percent)
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1), "the menu counted a miss")
        reads.next = (.percent(55), true)
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .percent(55))
        XCTAssertEqual(monitor.percent, 55)
        XCTAssertTrue(monitor.isCharging)
        reads.next = (.unreadable(misses: 1), false)
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1), "misses carried over a readable read")
        XCTAssertFalse(monitor.isCharging)
    }

    /// Greptile caught this: the menu's refresh moved the count to two on
    /// its own, and the recheck then saw two become two, so the floor rules
    /// never ran. A menu opened during the first miss leaves the count at
    /// one; the recheck makes it two and reports the change.
    func testMenuRefreshDuringAMissDoesNotHideTheSecondMissFromTheFloorRules() async {
        let reads = Reads()
        let wait = ManualWait()
        let monitor = monitor(reads, wait)
        var changes = 0
        monitor.onChange = { changes += 1 }

        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1))
        monitor.refreshBattery()
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1), "the menu counted a miss")
        XCTAssertEqual(changes, 0)

        await runRecheck(wait, reads)
        XCTAssertEqual(monitor.battery, .unreadable(misses: 2), "second miss never reached")
        XCTAssertEqual(changes, 1, "the move to two misses was not reported")
    }

    /// A battery that turns unreadable between IOKit events, seen first by
    /// the menu, still gets its recheck, so the second miss is reached.
    func testMenuRefreshStartsTheRecheckWhenTheBatteryTurnsUnreadable() async {
        let reads = Reads()
        reads.next = (.percent(80), false)
        let wait = ManualWait()
        let monitor = monitor(reads, wait)
        var changes = 0
        monitor.onChange = { changes += 1 }

        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.battery, .percent(80))
        XCTAssertEqual(wait.pending, 0, "a readable battery is not rechecked")
        reads.next = (.unreadable(misses: 1), false)
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1))

        await runRecheck(wait, reads)
        XCTAssertEqual(monitor.battery, .unreadable(misses: 2), "second miss never reached")
        XCTAssertEqual(changes, 1)
    }

    /// IOKit sends no event for a read that keeps failing. While started
    /// and unreadable, the monitor re-reads on its own and reports the
    /// second miss as a change; the count is capped there, so a battery
    /// that stays unreadable is not a change on every re-read; once
    /// readable again it stops re-reading.
    func testUnreadableBatteryIsRecheckedWhileStarted() async {
        let reads = Reads()
        let wait = ManualWait()
        let monitor = monitor(reads, wait)
        var changes = 0
        monitor.onChange = { changes += 1 }

        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1))
        XCTAssertEqual(reads.count, 1)

        await runRecheck(wait, reads)
        XCTAssertEqual(monitor.battery, .unreadable(misses: 2), "second miss never reached")
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(reads.count, 2)
        await runRecheck(wait, reads)
        await runRecheck(wait, reads)
        XCTAssertEqual(reads.count, 4, "no re-read at two misses")
        XCTAssertEqual(monitor.battery, .unreadable(misses: 2))
        XCTAssertEqual(changes, 1, "a capped count was reported as a change")

        reads.next = (.percent(80), false)
        await runRecheck(wait, reads)
        XCTAssertEqual(monitor.battery, .percent(80), "recovery never seen")
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(wait.pending, 0, "still re-reading a readable battery")
    }

    /// Misses before a stop are not consecutive with the next start.
    func testStartBeginsAFreshCount() async {
        let reads = Reads()
        let wait = ManualWait()
        let monitor = monitor(reads, wait)
        monitor.start()
        await runRecheck(wait, reads)
        XCTAssertEqual(monitor.battery, .unreadable(misses: 2), "second miss never reached")
        monitor.stop()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1))
    }

    /// The recheck waiting at the stop is cancelled, and once its wait has
    /// gone back to the monitor (which then finds the task cancelled) it
    /// has read nothing.
    func testStopCancelsTheRecheck() async {
        let reads = Reads()
        let wait = ManualWait()
        let monitor = monitor(reads, wait)
        monitor.start()
        await pollUntil("no recheck was scheduled") { wait.pending == 1 }
        let returned = wait.returned
        monitor.stop()
        XCTAssertEqual(wait.cancelled, 1, "stop left the recheck waiting")
        XCTAssertEqual(wait.pending, 0)
        let after = reads.count
        await pollUntil("the cancelled recheck never returned") { wait.returned == returned + 1 }
        XCTAssertEqual(reads.count, after, "re-read after stop")
        // Not started: a refresh schedules nothing.
        monitor.refreshBattery()
        XCTAssertEqual(reads.count, after + 1)
        XCTAssertEqual(wait.pending, 0)
    }
}
