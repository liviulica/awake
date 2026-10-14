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

    // MARK: Self-healing and the unknown lid (review round 1)

    /// R10: an unknown lid (a desktop, an unreadable reading) never pauses,
    /// so the session runs on the wall clock and always ends.
    func testStartWithAnUnknownLidRuns() async throws {
        h.clamshell.closed = nil
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 3600)
        XCTAssertNil(m.session?.pausedRemaining)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(3600))
    }

    /// A close that never reached the clock is caught by the next tick.
    func testALeaseTickWithTheLidClosedResumesTheClock() async throws {
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 3600)
        h.clock.advance(60)
        h.clamshell.closed = true
        await m.renewLeaseIfPaused()
        XCTAssertNil(m.session?.pausedRemaining)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(3600))
        XCTAssertEqual(try h.store.loadSession(), m.session, "running on disk too")
    }

    func testALeaseTickWithAnUnknownLidResumesTheClock() async throws {
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 3600)
        h.clamshell.closed = nil
        await m.renewLeaseIfPaused()
        XCTAssertNil(m.session?.pausedRemaining)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(3600))
    }

    /// "Enter, then close the lid": the close lands while the start waits
    /// on `disablesleep 1` (the administrator prompt), when no lid event
    /// reaches a session that is not active yet. The start settles on the
    /// lid as it reads once sleep is disabled.
    func testALidCloseDuringTheStartWindowEndsUpRunning() async throws {
        h.clamshell.closed = false
        let gate = AsyncGate()
        h.guardFake.sleepGate = gate
        let m = h.makeManager(closedLidClock: true)
        let start = Task { await m.start(duration: 3600) }
        await gate.waitUntilStarted()
        h.clock.advance(280)
        h.clamshell.closed = true
        await gate.open()
        await start.value
        XCTAssertNil(m.session?.pausedRemaining)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(3600))
        XCTAssertEqual(try h.store.loadSession(), m.session, "running on disk too")
    }

    /// A prompt that outlasts most of the lease: a session still paused
    /// after the start gets a fresh lease, not the one written before it.
    func testAStartStillPausedAfterALongPromptHasAFreshLease() async throws {
        h.clamshell.closed = false
        let gate = AsyncGate()
        h.guardFake.sleepGate = gate
        let m = h.makeManager(closedLidClock: true)
        let start = Task { await m.start(duration: 3600) }
        await gate.waitUntilStarted()
        h.clock.advance(280)
        await gate.open()
        await start.value
        XCTAssertEqual(m.session?.pausedRemaining, 3600)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(SessionMath.pauseLease))
        XCTAssertEqual(try h.store.loadSession(), m.session)
    }

    /// A lid close whose write fails (here the agent cannot be confirmed)
    /// leaves the session paused; the next tick heals it.
    func testAFailedLidCloseHealsOnTheNextTick() async throws {
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 3600)
        h.clamshell.closed = true
        h.backstop.failArm = true
        await m.lidClosedClock()
        XCTAssertEqual(m.session?.pausedRemaining, 3600, "the failed write changed nothing")
        h.backstop.failArm = false
        h.clock.advance(60)
        await m.renewLeaseIfPaused()
        XCTAssertNil(m.session?.pausedRemaining)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(3600))
    }

    /// The same for a close refused because the recovery lock is busy.
    func testALidCloseRefusedByABusyLockHealsOnTheNextTick() async throws {
        h.clamshell.closed = false
        let m = h.makeManager(closedLidClock: true)
        await m.start(duration: 3600)
        h.clamshell.closed = true
        let held = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        await m.lidClosedClock()
        XCTAssertEqual(m.session?.pausedRemaining, 3600, "refused: nothing changed")
        held.release()
        await m.renewLeaseIfPaused()
        XCTAssertNil(m.session?.pausedRemaining)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(3600))
    }

    func testReconcileResumesAPausedSessionWhenTheLidIsUnknown() async throws {
        var s = Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(SessionMath.pauseLease))
        s.pausedRemaining = 1800
        try h.store.saveSession(s)
        var state = RuntimeState.clean
        state.sleepDisabledByUs = true
        try h.store.saveState(state)
        h.guardFake.sleepDisabled = true
        h.clamshell.closed = nil
        let m = h.makeManager(closedLidClock: true)
        await m.reconcile()
        XCTAssertNil(m.session?.pausedRemaining)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(1800))
    }

    /// The deadline timer firing on a paused session renews the lease
    /// rather than ending it. The timer is real, so its fire date is a real
    /// time a moment ahead; the expiry check reads the harness clock, which
    /// stands still until the test moves it past the lease. How long the
    /// reconcile or the wait for the timer takes therefore changes nothing.
    func testAnExpiringLeaseIsRenewedNotEnded() async throws {
        let real = Harness(now: Date())
        defer { real.home.destroy() }
        let clock = real.clock
        let m = SessionManager(
            paths: real.home.paths,
            sleepGuard: real.guardFake,
            processControl: real.procs,
            backstop: real.backstop,
            notifier: real.notifier,
            clamshell: { false },
            clock: { clock.now },
            closedLidClock: true
        )
        // session.json keeps whole seconds.
        let lease = Date(timeIntervalSince1970: (clock.now.timeIntervalSince1970 + 1).rounded(.up))
        try real.store.saveSession(Session(startedAt: clock.now, endsAt: lease, pausedRemaining: 1800))
        real.guardFake.sleepDisabled = true
        await m.reconcile()
        XCTAssertEqual(m.scheduledDeadline, lease)
        XCTAssertEqual(m.session?.endsAt, lease, "the lease was moved before it ran out")
        // Relies on reconcile not suspending after armDeadline: the deadline
        // timer only fires once the main actor is free, so it cannot run
        // before the clock moves past the lease here. Had it fired earlier,
        // it would have found the lease unexpired and never fired again.
        clock.now = lease.addingTimeInterval(1)
        await pollUntil("the deadline timer never acted on the expired lease") { (m.session?.endsAt ?? .distantFuture) > lease }
        XCTAssertTrue(m.isActive, "a paused session is never ended by the clock")
        let renewed = try XCTUnwrap(m.session)
        XCTAssertEqual(renewed.endsAt, clock.now.addingTimeInterval(SessionMath.pauseLease))
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
