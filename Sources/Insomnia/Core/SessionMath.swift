import Foundation

/// Pure session arithmetic. No clocks, no side effects.
enum SessionMath {
    /// Shortest session we accept.
    static let minimumDuration: TimeInterval = 60

    /// Clamp a requested duration into `[minimumDuration, maxDuration]`.
    static func clamp(_ duration: TimeInterval, maxDuration: TimeInterval) -> TimeInterval {
        let upper = max(maxDuration, minimumDuration)
        return min(max(duration, minimumDuration), upper)
    }

    /// End time for a session starting at `start`.
    static func endsAt(start: Date, duration: TimeInterval, maxDuration: TimeInterval) -> Date {
        start.addingTimeInterval(clamp(duration, maxDuration: maxDuration))
    }

    /// Fresh session starting now.
    static func newSession(now: Date, duration: TimeInterval, maxDuration: TimeInterval) -> Session {
        Session(startedAt: now, endsAt: endsAt(start: now, duration: duration, maxDuration: maxDuration))
    }

    /// How far ahead a paused session's `endsAt` lease reaches. Renewed
    /// every minute while the app runs; if the app dies the session expires
    /// within this window and the recovery agent restores sleep.
    static let pauseLease: TimeInterval = 300

    /// Fresh session started with the lid open (or unknown): the closed-lid
    /// clock waits for the lid to close, and `endsAt` is a lease.
    static func newPausedSession(now: Date, duration: TimeInterval, maxDuration: TimeInterval) -> Session {
        Session(startedAt: now, endsAt: now.addingTimeInterval(pauseLease), pausedRemaining: clamp(duration, maxDuration: maxDuration))
    }

    /// Lid opened: stop the clock and keep what was left.
    static func paused(_ s: Session, now: Date) -> Session {
        guard !s.isPaused else { return s }
        var p = s
        p.pausedRemaining = s.remaining(at: now)
        p.endsAt = now.addingTimeInterval(pauseLease)
        return p
    }

    /// Lid closed: run the clock on what was left.
    static func resumed(_ s: Session, now: Date) -> Session {
        guard let left = s.pausedRemaining else { return s }
        var r = s
        r.pausedRemaining = nil
        r.endsAt = now.addingTimeInterval(left)
        return r
    }

    /// The closed-lid clock as the lid reads: paused only when the lid is
    /// known open, running when it is closed or unknown (a desktop, or a
    /// reading that failed), so a session whose lid cannot be read runs on
    /// the wall clock and always ends.
    static func followingLid(_ s: Session, lidClosed: Bool?, now: Date) -> Session {
        lidClosed == false ? paused(s, now: now) : resumed(s, now: now)
    }

    /// A paused session's lease, moved to `pauseLease` from `now`. A running
    /// session is returned unchanged.
    static func leaseRenewed(_ s: Session, now: Date) -> Session {
        guard s.isPaused else { return s }
        var r = s
        r.endsAt = now.addingTimeInterval(pauseLease)
        return r
    }

    /// Push `endsAt` out by `extra` seconds, never past `now + maxDuration`.
    /// Extending an already-expired session restarts the countdown from `now`.
    /// A paused session gains closed-lid time instead, never past
    /// `maxDuration` of it; its lease is left as it is.
    static func extended(_ session: Session, by extra: TimeInterval, now: Date, maxDuration: TimeInterval) -> Session {
        if let left = session.pausedRemaining {
            var s = session
            let newLeft = min(left + max(extra, 0), max(maxDuration, minimumDuration))
            s.extensions.append(newLeft - left)
            s.pausedRemaining = newLeft
            return s
        }
        let base = max(session.endsAt, now)
        let ceiling = now.addingTimeInterval(max(maxDuration, minimumDuration))
        let proposed = base.addingTimeInterval(max(extra, 0))
        let newEnd = min(proposed, ceiling)
        var s = session
        s.extensions.append(newEnd.timeIntervalSince(session.endsAt))
        s.endsAt = newEnd
        return s
    }

    /// Seconds from `now` to `endsAt`, floored at zero.
    static func remaining(until endsAt: Date, at now: Date) -> TimeInterval {
        max(endsAt.timeIntervalSince(now), 0)
    }

    static func isExpired(endsAt: Date, at now: Date) -> Bool {
        endsAt.timeIntervalSince(now) <= 0
    }

    /// Minute-granularity remaining time: "3d 2h", "2h 14m", "14m", "<1m".
    /// Zero secondary units are dropped ("2h", "3d"). Seconds are floored.
    static func formatRemaining(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(max(interval, 0) / 60)
        if totalMinutes < 1 { return "<1m" }
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }
}
