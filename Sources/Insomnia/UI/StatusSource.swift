import Foundation
import Observation

/// Live machine status shown in the right-click menu. The system layer
/// (lid, battery, network, freeze, browser throttle) provides the real
/// object; the UI only ever talks to this protocol.
@MainActor
protocol StatusSource: AnyObject, Observable {
    var lidClosed: Bool { get }
    var batteryPercent: Int? { get }
    var isCharging: Bool { get }
    var wifiSSID: String? { get }
    /// Length of the most recent network outage, nil if none this session.
    var lastGap: TimeInterval? { get }
    var frozenCount: Int { get }
    /// Browsers running without the occlusion flags.
    var throttledBrowsers: [ThrottledBrowser] { get }
    /// Why each browser's last relaunch did not happen, ordered by
    /// bundle id; one menu warning line each.
    var relaunchProblems: [String] { get }
    /// Why a hotspot join was skipped this session, if one was, and for
    /// which SSID.
    var hotspotPasswordReport: HotspotPasswordReport? { get }

    /// Called when the menu opens; observers refresh anything not pushed.
    func refreshOnDemand()
    /// The part of that refresh that needs no awaiting, so a caller that has
    /// to read the status right now still gets it fresh.
    func refreshInstant()
    /// Battery draw read on demand from AppleSmartBattery. Never polled.
    func instantWatts() -> Double?
    /// Relaunch the browser the user confirmed, as the menu item named it.
    func relaunchUnthrottled(_ browser: ThrottledBrowser)
}

/// Stand-in until the system layer is plugged in. Reports nothing.
@MainActor
@Observable
final class PlaceholderStatus: StatusSource {
    var lidClosed: Bool = false
    var batteryPercent: Int? = nil
    var isCharging: Bool = false
    var wifiSSID: String? = nil
    var lastGap: TimeInterval? = nil
    var frozenCount: Int = 0
    var throttledBrowsers: [ThrottledBrowser] = []
    var relaunchProblems: [String] = []
    var hotspotPasswordReport: HotspotPasswordReport? = nil

    init() {}

    func refreshOnDemand() {}
    func refreshInstant() {}
    func instantWatts() -> Double? { nil }
    func relaunchUnthrottled(_ browser: ThrottledBrowser) {}
}

/// Pure formatting for the menu's "Mac" block (spec 2026-10-15 "The menu"),
/// kept out of the views so it can be tested. A nil line is left out.
enum StatusLines {
    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Temperature normal"
        case .fair: "Temperature warm"
        case .serious: "Temperature hot"
        case .critical: "Temperature critical"
        @unknown default: "Temperature unknown"
        }
    }

    /// "Battery 68%, charging"; nil on a Mac with no battery.
    static func battery(percent: Int?, isCharging: Bool) -> String? {
        guard let percent else { return nil }
        return isCharging ? "Battery \(percent)%, charging" : "Battery \(percent)%"
    }

    /// The SF Symbol for the battery line: the bolt while charging, else
    /// the nearest quarter.
    static func batterySymbol(percent: Int?, isCharging: Bool) -> String? {
        guard let percent else { return nil }
        if isCharging { return "battery.100percent.bolt" }
        let quarter = Int((Double(percent) / 25).rounded()) * 25
        return "battery.\(min(max(quarter, 0), 100))percent"
    }

    /// "Wi-Fi: Home", with " · last outage 12 s" after an outage this
    /// session. macOS hides the name until Location is allowed: say so.
    /// Nothing known and Location allowed: no line.
    static func wifi(ssid: String?, locationAuthorized: Bool, lastGap: TimeInterval?) -> String? {
        guard let shown = WiFiStatusName.display(ssid: ssid, locationAuthorized: locationAuthorized) else { return nil }
        var line = shown == WiFiStatusName.redacted ? "Wi-Fi on \u{00B7} name needs Location access" : "Wi-Fi: \(shown)"
        if let gap = lastGap, gap > 0 {
            line += " \u{00B7} last outage \(Int(gap.rounded())) s"
        }
        return line
    }

    /// "Hotspot failover: iPhone"; nil when no hotspot is configured.
    static func hotspot(ssid: String) -> String? {
        let name = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : "Hotspot failover: \(name)"
    }

    /// What the lid close changed and has not undone yet; nil when nothing.
    static func whileClosed(frozenCount: Int, muted: Bool, lowPower: Bool) -> String? {
        var parts: [String] = []
        if frozenCount > 0 {
            parts.append(frozenCount == 1 ? "1 app frozen" : "\(frozenCount) apps frozen")
        }
        if muted { parts.append("audio muted") }
        if lowPower { parts.append("Low Power Mode") }
        return parts.isEmpty ? nil : "While closed: " + parts.joined(separator: " \u{00B7} ")
    }

    /// One warning per browser running without the occlusion flags.
    static func throttleWarning(_ browser: String) -> String {
        "\(browser) pauses hidden tabs; agents in it may stall"
    }
}

/// The one line about sleep, read from the journal
/// (`RuntimeState.sleepDisabledByUs`) rather than inferred from the presence
/// of a session. The journal records what Ember asked pmset to do; it is
/// not live proof. The texts are plain; that caveat lives in the spec.
/// Pure so it can be tested.
enum SleepHeldLine {
    struct Line: Equatable {
        let text: String
        let isWarning: Bool
    }

    static func line(sessionActive: Bool, sleepHeld: Bool) -> Line? {
        switch (sessionActive, sleepHeld) {
        case (true, true):
            Line(text: "Sleep off while the lid is closed", isWarning: false)
        case (true, false):
            Line(text: "Sleep is not off: this session is not keeping the Mac awake", isWarning: true)
        case (false, true):
            Line(text: "Sleep is still off with no session running", isWarning: true)
        case (false, false):
            nil
        }
    }
}

/// macOS hides Wi-Fi network names until Location is allowed; say so rather
/// than reporting no network at all.
enum WiFiStatusName {
    static let redacted = "on (name hidden until Location is allowed)"

    static func display(ssid: String?, locationAuthorized: Bool) -> String? {
        if let ssid, !ssid.isEmpty { return ssid }
        return locationAuthorized ? nil : redacted
    }
}
