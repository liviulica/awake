import CoreWLAN
import Foundation

/// The networks a Wi-Fi scan saw, for the hotspot setup's list.
struct ScannedNetworks: Equatable, Sendable {
    /// Names de-duplicated and sorted; empty without Location access,
    /// because macOS hides them.
    let names: [String]
    /// The network the Mac is on now, when its name can be read.
    let current: String?
}

protocol WiFiScanning: Sendable {
    func scan() async throws -> ScannedNetworks
}

struct WiFiScanError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A scan of every network on the Wi-Fi interface (CoreWLAN). It blocks for
/// a few seconds, so it runs off the main actor.
struct CoreWLANScanner: WiFiScanning {
    func scan() async throws -> ScannedNetworks {
        try await Task.detached(priority: .userInitiated) {
            guard let interface = CWWiFiClient.shared().interface() else {
                throw WiFiScanError(message: "No Wi-Fi interface")
            }
            let networks = try interface.scanForNetworks(withSSID: nil)
            return ScannedNetworks(names: Self.normalised(networks.compactMap(\.ssid)), current: interface.ssid())
        }.value
    }

    /// Blank names dropped, duplicates removed, sorted case-insensitively.
    static func normalised(_ names: [String]) -> [String] {
        let kept = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        return kept.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
