import Foundation

/// The `h:mm` countdown shown next to the menu bar icon and in the menu.
/// Minutes round up, so "0:00" appears only when the time is up.
enum Countdown {
    static func short(_ remaining: TimeInterval) -> String {
        let minutes = max(0, Int((remaining / 60).rounded(.up)))
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
