import Foundation

/// Parses the short durations typed into settings ("30m", "2h", "1h30m", "3d").
enum DurationParser {
    /// Seconds, or nil when the text is not a duration. Bare numbers are minutes.
    static func seconds(from text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if let bare = Int(trimmed) {
            guard bare > 0 else { return nil }
            let (seconds, overflow) = bare.multipliedReportingOverflow(by: 60)
            return overflow ? nil : TimeInterval(seconds)
        }
        var total = 0
        var number = ""
        var sawUnit = false
        for ch in trimmed {
            if ch.isNumber {
                number.append(ch)
            } else if ch == " " {
                continue
            } else {
                guard let n = Int(number) else { return nil }
                let multiplier: Int
                switch ch {
                case "d": multiplier = 86_400
                case "h": multiplier = 3_600
                case "m": multiplier = 60
                default: return nil
                }
                // Reject rather than trap on absurd values.
                let (seconds, mulOverflow) = n.multipliedReportingOverflow(by: multiplier)
                guard !mulOverflow else { return nil }
                let (sum, addOverflow) = total.addingReportingOverflow(seconds)
                guard !addOverflow else { return nil }
                total = sum
                number = ""
                sawUnit = true
            }
        }
        guard number.isEmpty, sawUnit, total > 0 else { return nil }
        return TimeInterval(total)
    }
}
