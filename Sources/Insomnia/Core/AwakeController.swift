import Foundation
import Observation

/// Awake mode: the Caffeine-style hold, toggled by a left click (spec
/// "Interaction"). Independent of `SessionManager`: no journal, no root,
/// no recovery agent. Lid mode includes it (`lidSessionChanged`): during a
/// lid session the same assertion is held while the lid is open and
/// released while it is closed, because a held display assertion would
/// keep `LidActions` from sleeping the panel (`DisplayDimming.requestSleep`).
@MainActor
@Observable
final class AwakeController {
    enum State: Equatable {
        case off
        /// `until` is nil for "until I turn it off".
        case on(until: Date?)
    }

    private(set) var state: State = .off
    /// Why the last `turnOn` did not take; shown in the menu.
    private(set) var lastError: String?
    /// True while lid mode holds the screen on (lid session, lid open).
    private(set) var lidHoldActive = false
    /// True while a lid session runs; Awake mode cannot start then (screen
    /// mode is part of lid mode).
    private(set) var lidSessionActive = false
    /// The lid as the session reports it (a paused session has it open).
    @ObservationIgnored private var sessionLidOpen = false
    /// The last lid event during this lid session was a close. It drops
    /// the hold at the event itself, before the lid actions run, so the
    /// display sleep `LidActions` asks for is not refused for it; the
    /// session only stops reading as paused after those actions.
    @ObservationIgnored private var lidClosedByEvent = false

    var isOn: Bool { state != .off }
    var endsAt: Date? {
        if case let .on(until) = state { return until }
        return nil
    }

    /// Called after every state change, for the hotspot failover hookup.
    @ObservationIgnored var onChange: (@MainActor (State) -> Void)?

    @ObservationIgnored private let assertion: any AwakeAsserting
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var timer: Timer?

    init(assertion: any AwakeAsserting, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.assertion = assertion
        self.clock = clock
    }

    /// `duration` nil keeps the Mac awake until turned off.
    func turnOn(for duration: TimeInterval?) {
        guard !lidSessionActive else {
            Log.info("awake mode ignored: a lid session is active")
            return
        }
        do {
            try assertion.hold()
        } catch {
            lastError = "Could not keep the Mac awake: \(error.localizedDescription)"
            Log.error("awake mode: \(error.localizedDescription)")
            set(.off)
            return
        }
        lastError = nil
        let until = duration.map { clock().addingTimeInterval($0) }
        schedule(until)
        Log.info("awake mode on " + (until.map { "until \(ISO8601DateFormatter().string(from: $0))" } ?? "until turned off"))
        set(.on(until: until))
    }

    func turnOff(reason: String) {
        timer?.invalidate()
        timer = nil
        guard state != .off else { return }
        // The assertion is shared with the lid hold, which owns it while held.
        if !lidHoldActive { assertion.release() }
        Log.info("awake mode off (\(reason))")
        set(.off)
    }

    func toggle() {
        isOn ? turnOff(reason: "user") : turnOn(for: nil)
    }

    /// The deadline timer's target; internal so tests drive it with a fake clock.
    func expireIfDue() {
        guard let endsAt, clock() >= endsAt else { return }
        turnOff(reason: "timer")
    }

    /// Screen mode inside a lid session (spec "Interaction"): a running
    /// Awake mode folds in when the session starts; the assertion is held
    /// while the lid is open and released while it is closed or once the
    /// session ends. Called on every session change; idempotent.
    func lidSessionChanged(active: Bool, lidOpen: Bool) {
        lidSessionActive = active
        sessionLidOpen = lidOpen
        // The next session starts from the lid as it reads then.
        if !active { lidClosedByEvent = false }
        if active, state != .off {
            turnOff(reason: "folded into lid mode")
        }
        syncLidHold()
    }

    /// A lid event during a lid session, delivered as it arrives
    /// (`AppServices.onLidEvent`), before the close or open actions run.
    /// A close releases the screen hold at once; an open lets the session
    /// take it again once it reads as paused.
    func lidEvent(closed: Bool) {
        lidClosedByEvent = closed
        syncLidHold()
    }

    private func syncLidHold() {
        let want = lidSessionActive && sessionLidOpen && !lidClosedByEvent
        guard want != lidHoldActive else { return }
        if want {
            do {
                try assertion.hold()
                lidHoldActive = true
                lastError = nil
            } catch {
                lastError = "Could not keep the screen on: \(error.localizedDescription)"
                Log.error("lid-mode screen hold: \(error.localizedDescription)")
            }
        } else {
            // Awake mode may still own the shared assertion; release only when it does not.
            if state == .off { assertion.release() }
            lidHoldActive = false
        }
    }

    private func set(_ new: State) {
        guard new != state else { return }
        state = new
        onChange?(new)
    }

    private func schedule(_ until: Date?) {
        timer?.invalidate()
        timer = nil
        guard let until else { return }
        let t = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.expireIfDue() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
