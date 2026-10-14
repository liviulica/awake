import XCTest
@testable import Insomnia

@MainActor
final class ClosedLidClockTests: XCTestCase {
    private var h: Harness!

    override func setUp() async throws {
        h = Harness()
    }

    func testStartWithTheLidOpenIsPausedWithALease() async throws {
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 3600)
        let s = try XCTUnwrap(m.session)
        XCTAssertEqual(s.pausedRemaining, 3600)
        XCTAssertEqual(s.endsAt, h.clock.now.addingTimeInterval(SessionMath.pauseLease))
        XCTAssertEqual(try h.store.loadSession(), s, "the paused state is on disk")
    }

    func testClosingTheLidStartsTheClockAndOpeningPausesIt() async throws {
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 3600)
        h.clamshell.closed = true
        await m.lidClosedClock()
        XCTAssertNil(m.session?.pausedRemaining)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(3600))
        h.clock.advance(600)
        h.clamshell.closed = false
        await m.lidOpenedClock()
        XCTAssertEqual(m.session?.pausedRemaining, 3000)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(SessionMath.pauseLease))
    }

    func testAPausedSessionIsNeverEndedByTheClock() async throws {
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 3600)
        for _ in 0..<10 {
            h.clock.advance(60)
            await m.renewLeaseIfPaused()
        }
        XCTAssertNotNil(m.session)
        XCTAssertEqual(m.session?.pausedRemaining, 3600, "open-lid time does not count")
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(SessionMath.pauseLease))
    }

    func testExtendWhilePausedAddsClosedTimeUpTo24Hours() async throws {
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 23 * 3600)
        await m.extend(by: 3600)
        XCTAssertEqual(m.session?.pausedRemaining, 24 * 3600)
        await m.extend(by: 3600)
        XCTAssertEqual(m.session?.pausedRemaining, 24 * 3600, "capped at 24 h of closed time")
    }

    func testReconcileResumesAPausedSessionWhenTheLidIsClosed() async throws {
        var s = Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(SessionMath.pauseLease))
        s.pausedRemaining = 1800
        try h.store.saveSession(s)
        var state = RuntimeState.clean
        state.sleepDisabledByUs = true
        try h.store.saveState(state)
        h.guardFake.sleepDisabled = true
        h.clamshell.closed = true
        let m = h.makeManager(closedLidClock: true)
        await m.reconcile()
        XCTAssertNil(m.session?.pausedRemaining)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(1800))
    }

    func testWallClockModeIsUnchanged() async throws {
        h.clamshell.closed = false
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertNil(m.session?.pausedRemaining)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(3600))
    }

    // Beyond the brief's six: the edges of the same rules.

    func testStartWithTheLidClosedRunsTheClock() async throws {
        h.clamshell.closed = true
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 3600)
        XCTAssertNil(m.session?.pausedRemaining)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(3600))
    }

    func testReconcilePausesARunningSessionWhenTheLidIsOpen() async throws {
        let s = Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(1800))
        try h.store.saveSession(s)
        var state = RuntimeState.clean
        state.sleepDisabledByUs = true
        try h.store.saveState(state)
        h.guardFake.sleepDisabled = true
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        await m.reconcile()
        XCTAssertEqual(m.session?.pausedRemaining, 1800)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(SessionMath.pauseLease))
        XCTAssertEqual(try h.store.loadSession(), m.session, "the paused state is on disk")
    }

    func testALidEventThatNoLongerMatchesTheLidChangesNothing() async throws {
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 3600)
        let paused = m.session
        // A close handled after the lid opened again (the hooks run after
        // the lid transactions, so their order can cross).
        await m.lidClosedClock()
        XCTAssertEqual(m.session, paused)
    }

    func testWallClockModeIgnoresTheLidHooks() async throws {
        h.clamshell.closed = true
        let m = h.makeManager()
        await m.start(duration: 3600)
        let running = m.session
        h.clock.advance(60)
        h.clamshell.closed = false
        await m.lidOpenedClock()
        await m.renewLeaseIfPaused()
        XCTAssertEqual(m.session, running)
    }

    /// The deadline timer firing on a paused session renews the lease
    /// rather than ending it (real clock, so the Timer actually fires).
    func testAnExpiringLeaseIsRenewedNotEnded() async throws {
        let real = Harness(now: Date())
        defer { real.home.destroy() }
        // The harness clock is fixed; the timer's expiry check needs time
        // to pass.
        let m = SessionManager(
            paths: real.home.paths,
            sleepGuard: real.guardFake,
            processControl: real.procs,
            backstop: real.backstop,
            notifier: real.notifier,
            clamshell: { false },
            clock: { Date() },
            closedLidClock: true
        )
        // session.json keeps whole seconds.
        let lease = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 2).rounded(.up))
        try real.store.saveSession(Session(startedAt: Date(), endsAt: lease, pausedRemaining: 1800))
        await m.reconcile()
        XCTAssertEqual(m.scheduledDeadline, lease)
        for _ in 0..<500 where (m.session?.endsAt ?? lease) <= lease {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(m.isActive, "a paused session is never ended by the clock")
        let renewed = try XCTUnwrap(m.session)
        XCTAssertGreaterThan(renewed.endsAt, lease)
        XCTAssertEqual(renewed.pausedRemaining, 1800)
        // session.json keeps whole seconds.
        let onDisk = try XCTUnwrap(real.store.loadSession())
        XCTAssertEqual(onDisk.endsAt.timeIntervalSince1970, renewed.endsAt.timeIntervalSince1970, accuracy: 1, "the renewed lease is on disk")
        XCTAssertEqual(onDisk.pausedRemaining, 1800)
        XCTAssertFalse(real.notifier.posts.contains { $0.title == "Session ended" })
    }

    func testCountdownShowsClosedLidTimeInAShapeThatFitsIt() async throws {
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 8 * 3600)
        h.clock.advance(120)
        m.refreshCountdown()
        XCTAssertEqual(m.countdownText, "8:00:00", "paused: the closed-lid time, in hours, not the lease")
    }
}

/// The lid observer's handlers drive the clock: a close starts it, an open
/// pauses it, each in its own transaction after the lid actions.
@MainActor
final class ClosedLidClockLidActionsTests: XCTestCase {
    func testLidActionsMoveTheClock() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let freezer = FakeFreezer(apps: [], processes: [], control: h.procs)
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        let actions = LidActions(manager: m, freezer: freezer, audio: h.audio, display: h.display, keyboard: h.keyboard, sampler: nil)
        await m.start(duration: 3600)
        XCTAssertEqual(m.session?.pausedRemaining, 3600)

        h.clamshell.closed = true
        await actions.onClose()
        XCTAssertNil(m.session?.pausedRemaining)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(3600))

        h.clock.advance(900)
        h.clamshell.closed = false
        await actions.onOpen()
        XCTAssertEqual(m.session?.pausedRemaining, 2700)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(SessionMath.pauseLease))
        XCTAssertEqual(try h.store.loadSession(), m.session)
    }
}
