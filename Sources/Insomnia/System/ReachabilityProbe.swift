import Foundation

/// Whether the internet answers, not only whether Wi-Fi is associated
/// (spec "Hotspot failover", point 1).
protocol ReachabilityProbing: Sendable {
    func isInternetReachable() async -> Bool
}

/// Apple's captive-portal check, the one macOS itself uses. The app's only
/// network request; made only while failover runs, with no cookies, cache
/// or identifying data.
struct CaptivePortalProbe: ReachabilityProbing {
    static let url = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    static let timeout: TimeInterval = 5

    func isInternetReachable() async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: Self.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            return String(decoding: data, as: UTF8.self).contains("Success")
        } catch {
            return false
        }
    }
}

/// Counts consecutive probe failures; an outage starts on the third.
struct ReachabilityTracker: Equatable {
    static let threshold = 3
    private(set) var failures = 0

    /// True exactly when this failure is the one that crosses the threshold.
    mutating func record(success: Bool) -> Bool {
        if success {
            failures = 0
            return false
        }
        failures += 1
        return failures == Self.threshold
    }
}
