import AppKit
import SwiftUI

/// The hotspot setup window's content (spec 2026-10-16 explanations, part
/// 3), drawn from a `HotspotSetup` model, one step at a time.
struct HotspotSetupView: View {
    @Bindable var setup: HotspotSetup
    let locationPermission: LocationPermission
    let onDone: @MainActor () -> Void

    /// The Wi-Fi pane's extension ID on macOS 26 (Wi-Fi.appex allows the
    /// x-apple.systempreferences scheme).
    private static let wifiSettingsURL = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Set up hotspot failover").font(.headline)
                Spacer()
                if setup.step != .done {
                    Text("Step \(setup.step.rawValue + 1) of 3").foregroundStyle(.secondary)
                }
            }
            switch setup.step {
            case .wifiNames: wifiNames
            case .hotspot: hotspot
            case .password: password
            case .done: done
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        // One fixed size for every step: the window is sized once and is
        // not resizable, so a taller step would push Back/Continue out of
        // it. Step 2 needs about 400 points.
        .frame(width: 440, height: 440)
    }

    // MARK: Steps

    private var wifiNames: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("macOS hides Wi-Fi network names from apps unless they have Location access. Ember uses it only to see network names, never your location.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Location: \(locationPermission.statusDescription)").foregroundStyle(.secondary)
                Spacer()
                if locationPermission.authorizationStatus == .notDetermined {
                    Button("Allow") { locationPermission.requestWhenInUse() }
                } else if locationPermission.isDenied {
                    Button("Open Location Services") { locationPermission.openLocationServicesSettings() }
                }
            }
            Text("Without it you can still type the hotspot's name in the next step.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hotspot: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On your iPhone, open Settings \u{2192} Personal Hotspot, turn on Allow Others to Join, and keep that screen open while you choose it here.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("On this Mac: System Settings \u{2192} Wi-Fi \u{2192} Ask to join hotspots: Automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let url = Self.wifiSettingsURL {
                    Button("Open Wi-Fi Settings") { NSWorkspace.shared.open(url) }.controlSize(.small)
                }
            }
            networkList
            HStack {
                Text("Not listed? Type its name:")
                TextField("Hotspot name", text: $setup.typedName)
            }
        }
    }

    private var networkList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Networks Ember sees").font(.subheadline)
                Spacer()
                if setup.scanning { ProgressView().controlSize(.small) }
                Button("Rescan") { Task { await setup.rescan() } }
                    .controlSize(.small)
                    .disabled(setup.scanning)
            }
            if let names = setup.networks?.names, !names.isEmpty {
                List(names, id: \.self) { name in
                    Button {
                        setup.pick(name)
                    } label: {
                        HStack {
                            Image(systemName: setup.chosenName == name ? "largecircle.fill.circle" : "circle")
                            Text(name)
                            if name == setup.networks?.current {
                                Text("(current)").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 120)
            } else if !setup.scanning {
                Text(setup.networks == nil ? "No scan yet." : "No names visible. Allow Location access, or type the name below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = setup.scanError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var password: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The hotspot's password, from the same iPhone screen. It is kept in your login Keychain.")
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $setup.password)
                .disabled(setup.hasNoPassword)
            Toggle("This hotspot has no password", isOn: $setup.hasNoPassword)
            Toggle("Also use it in screen mode", isOn: $setup.alsoInScreenMode)
            if let error = setup.saveError {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var done: some View {
        Text("Hotspot failover is set up. When Wi-Fi drops during a lid session, Ember joins \(setup.savedName), and switches back when your Wi-Fi returns.")
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if setup.step == .hotspot || setup.step == .password {
                Button("Back") { setup.back() }
                    .disabled(setup.saving)
            }
            Spacer()
            if setup.saving { ProgressView().controlSize(.small) }
            Button(continueTitle) {
                if setup.step == .done {
                    onDone()
                } else {
                    Task { await setup.next() }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!setup.canContinue)
        }
    }

    private var continueTitle: String {
        switch setup.step {
        case .wifiNames, .hotspot: "Continue"
        case .password: "Save"
        case .done: "Done"
        }
    }
}
