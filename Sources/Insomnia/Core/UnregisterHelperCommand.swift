import EmberHelperKit
import Foundation
import ServiceManagement

/// `Ember --unregister-helper`: one-shot mode for uninstall.sh, which must
/// unregister the helper before it removes the bundle (only the app itself
/// can). Prints one line and exits 0 when the helper is gone or was never
/// registered, 1 when unregistering failed.
enum UnregisterHelperCommand {
    static let flag = "--unregister-helper"

    /// nil when the arguments are not this mode.
    static func run(_ args: [String]) -> Int32? {
        guard args == [flag] else { return nil }
        let service = SMAppService.daemon(plistName: HelperNames.daemonPlistName)
        guard service.status != .notRegistered, service.status != .notFound else {
            print("helper not registered")
            return 0
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        service.unregister { error in
            failure = error
            done.signal()
        }
        done.wait()
        if let failure {
            print("could not unregister the helper: \(failure.localizedDescription)")
            return 1
        }
        print("helper unregistered")
        return 0
    }
}
