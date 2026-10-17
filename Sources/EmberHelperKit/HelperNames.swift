import Foundation

/// The names and code requirements the app and its helper agree on. One
/// place, so the helper's launchd plist, the app's registration and both
/// sides' signature checks cannot drift apart (HelperKitTests pins the
/// plist against these).
public enum HelperNames {
    /// The team that signs release builds (CHARGING PIXELS S.R.L.).
    public static let teamID = "4UA742BB8G"
    public static let appIdentifier = "app.chargingpixels.ember"
    /// The helper's code signing identifier, launchd label and Mach service.
    public static let helperIdentifier = "app.chargingpixels.ember.helper"
    public static let machService = helperIdentifier
    /// The plist under Contents/Library/LaunchDaemons that
    /// `SMAppService.daemon(plistName:)` registers.
    public static let daemonPlistName = "\(helperIdentifier).plist"
    /// Where the helper binary sits in the bundle (the plist's BundleProgram).
    public static let bundleProgram = "Contents/MacOS/EmberHelper"

    /// Code signed by the team with the given identifier, under an Apple
    /// anchor: what a Developer ID build of Ember or its helper satisfies,
    /// and no ad-hoc or other team's build does.
    public static func requirement(identifier: String) -> String {
        #"anchor apple generic and identifier "\#(identifier)" and certificate leaf[subject.OU] = "\#(teamID)""#
    }

    /// What the helper requires of every caller.
    public static var appRequirement: String { requirement(identifier: appIdentifier) }
    /// What the app requires of the helper it talks to.
    public static var helperRequirement: String { requirement(identifier: helperIdentifier) }
}
