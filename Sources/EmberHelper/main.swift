import EmberHelperKit
import Foundation
import os

// Ember's privileged helper. launchd starts it as root on demand (the
// daemon plist the app registers with SMAppService) when Ember connects to
// its Mach service; it answers only code signed as Ember by the team, and
// exits once idle.
let logger = Logger(subsystem: HelperNames.helperIdentifier, category: "helper")
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
let delegate = HelperListenerDelegate(version: version) { message in
    logger.log("\(message, privacy: .public)")
}
let listener = NSXPCListener(machServiceName: HelperNames.machService)
listener.setConnectionCodeSigningRequirement(HelperNames.appRequirement)
listener.delegate = delegate
listener.resume()
delegate.scheduleIdleExit()
logger.log("EmberHelper \(version, privacy: .public) listening")
dispatchMain()
