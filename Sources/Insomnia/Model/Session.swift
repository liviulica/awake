import Foundation

/// An active keep-awake session. `endsAt` is the only thing that keeps sleep
/// disabled; everything else is bookkeeping.
struct Session: Codable, Equatable, Sendable {
    var startedAt: Date
    var endsAt: Date
    /// Every extension applied, in order, in seconds.
    var extensions: [TimeInterval]
    /// Closed-lid seconds left while the lid is open (spec "Lid mode"): the
    /// timer counts only closed-lid time. nil while the clock runs. While
    /// set, `endsAt` is a short lease (`SessionMath.pauseLease`) the app
    /// renews, so recovery still finds a deadline if the app dies. Optional,
    /// so an Insomnia-era session.json decodes as a running clock.
    var pausedRemaining: TimeInterval?

    init(startedAt: Date, endsAt: Date, extensions: [TimeInterval] = [], pausedRemaining: TimeInterval? = nil) {
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.extensions = extensions
        self.pausedRemaining = pausedRemaining
    }

    var isPaused: Bool { pausedRemaining != nil }

    /// Closed-lid time left: the paused amount, or the time to `endsAt`.
    func closedLidRemaining(at now: Date) -> TimeInterval {
        pausedRemaining ?? remaining(at: now)
    }

    /// Seconds left until `endsAt`, never negative.
    func remaining(at now: Date) -> TimeInterval {
        SessionMath.remaining(until: endsAt, at: now)
    }

    /// True once `now` reaches `endsAt`.
    func isExpired(at now: Date) -> Bool {
        SessionMath.isExpired(endsAt: endsAt, at: now)
    }

    /// Shape of the menu bar countdown, derived from the session's span so it
    /// survives a relaunch without another persisted field. Because
    /// `remaining` never exceeds this span, the shape always has room for the
    /// value. An extension widens the span and can promote the shape, which
    /// is a one-off change at a user action, never a per-tick one.
    /// A paused session's `endsAt` is only the lease, so the closed-lid time
    /// left counts too: the shape always has room for what is shown.
    var countdownShape: CountdownShape {
        CountdownShape(initialDuration: max(endsAt.timeIntervalSince(startedAt), pausedRemaining ?? 0))
    }
}
