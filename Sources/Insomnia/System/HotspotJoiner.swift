import CoreWLAN
import Foundation

protocol HotspotJoining: Sendable {
    /// Returns false when the SSID-filtered scan finds no matching network.
    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool
    /// Whether an SSID-filtered scan sees the network now.
    func isVisible(ssid: String, interfaceName: String) async throws -> Bool
    /// Leaves the current network (the hotspot) so macOS auto-joins its
    /// preferred known network with the credentials it stored. CoreWLAN
    /// cannot join a WEP/WPA/WPA2 Personal network itself without the
    /// passphrase (CWInterface.h), and only macOS holds it; which network
    /// macOS picks is read back afterwards.
    func leaveForKnownNetwork(interfaceName: String) async throws
}

enum HotspotJoinError: Error, LocalizedError {
    case missingInterface(String)

    var errorDescription: String? {
        switch self {
        case let .missingInterface(name):
            return "CoreWLAN could not open Wi-Fi interface \(name)"
        }
    }
}

struct CoreWLANHotspotJoiner: HotspotJoining {
    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool {
        guard let interface = CWWiFiClient.shared().interface(withName: interfaceName) else {
            throw HotspotJoinError.missingInterface(interfaceName)
        }
        // macOS may require Location Services permission for SSID visibility.
        // Keep this scan SSID-filtered: association works with the returned
        // CWNetwork even when its `ssid` property is redacted.
        let networks = try interface.scanForNetworks(withSSID: ssid.data(using: .utf8))
        guard let network = networks.first else { return false }
        try interface.associate(to: network, password: password)
        return true
    }

    func isVisible(ssid: String, interfaceName: String) async throws -> Bool {
        try !scan(ssid: ssid, interfaceName: interfaceName).isEmpty
    }

    func leaveForKnownNetwork(interfaceName: String) async throws {
        guard let interface = CWWiFiClient.shared().interface(withName: interfaceName) else {
            throw HotspotJoinError.missingInterface(interfaceName)
        }
        interface.disassociate()
    }

    private func scan(ssid: String, interfaceName: String) throws -> Set<CWNetwork> {
        guard let interface = CWWiFiClient.shared().interface(withName: interfaceName) else {
            throw HotspotJoinError.missingInterface(interfaceName)
        }
        return try interface.scanForNetworks(withSSID: ssid.data(using: .utf8))
    }
}
