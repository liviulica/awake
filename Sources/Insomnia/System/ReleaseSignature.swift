import EmberHelperKit
import Foundation
import Security

/// Whether this process is a release build: code signed with the team's
/// Developer ID as Ember (`HelperNames.appRequirement`). Only a release
/// build registers the helper, runs the updater, offers to move an old
/// install aside and checks where it runs from. A source build (ad-hoc,
/// install.sh) or `swift run` behaves as it always has.
enum ReleaseSignature {
    /// Read once: a running process's signature does not change.
    static let isDeveloperID: Bool = satisfies(HelperNames.appRequirement)

    static func satisfies(_ requirementText: String) -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
