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
    static let host = "captive.apple.com"
    /// Apple's own probe agent: nothing that identifies this app or the Mac.
    static let userAgent = "CaptiveNetworkSupport/1.0 wispr"
    /// The marker in Apple's success page.
    static let successMarker = "<TITLE>Success</TITLE>"

    /// Whether an answer means the internet is there. A redirect, or a final
    /// host other than Apple's, is a captive portal, not "online".
    static func isSuccess(statusCode: Int, host: String?, body: String) -> Bool {
        statusCode == 200 && host == Self.host && body.contains(successMarker)
    }

    func isInternetReachable() async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: Self.url)
            guard let http = response as? HTTPURLResponse else { return false }
            return Self.isSuccess(statusCode: http.statusCode, host: http.url?.host, body: String(decoding: data, as: UTF8.self))
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
