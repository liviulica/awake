import Foundation

/// What the helper answers over XPC. Every reply carries an exit status (0
/// is success) and a message for the log; a status below 0 means the
/// helper did not get as far as running the command.
@objc public protocol EmberHelperProtocol {
    /// Runs `/usr/bin/pmset -a disablesleep 1` with `lock`, a descriptor on
    /// the app's recovery lock, as its standard input, so the lock stays
    /// held until pmset exits even if the app or the helper dies first.
    /// Replies once pmset has exited.
    func disableSleep(lock: FileHandle, withReply reply: @escaping (Int32, String) -> Void)
    /// Makes /etc/sudoers.d/ember the restore rule for the calling user.
    /// Replies 0 when the file is that rule (written now or already).
    func installRestoreRule(withReply reply: @escaping (Int32, String) -> Void)
    /// The helper's CFBundleShortVersionString as built into it.
    func version(withReply reply: @escaping (String) -> Void)
}

public enum HelperStatus {
    /// The helper could not run the command (bad caller, unknown user, a
    /// tool that did not start).
    public static let notRun: Int32 = -1
}
