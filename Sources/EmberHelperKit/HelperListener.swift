import Foundation

/// The helper's XPC side: the exported object for one connection, and the
/// listener delegate that accepts only Ember (the listener's code signing
/// requirement does the check before the delegate sees a connection) and
/// ends the process once it has been idle for a while.
public final class HelperService: NSObject, EmberHelperProtocol, @unchecked Sendable {
    let commands: HelperCommands
    /// The caller's effective uid, from the connection: whose rule to write.
    let callerUID: uid_t
    let version: String
    let log: @Sendable (String) -> Void

    public init(commands: HelperCommands, callerUID: uid_t, version: String, log: @escaping @Sendable (String) -> Void) {
        self.commands = commands
        self.callerUID = callerUID
        self.version = version
        self.log = log
    }

    public func disableSleep(lock: FileHandle, withReply reply: @escaping (Int32, String) -> Void) {
        let r = commands.disableSleep(lock: lock)
        // The helper's own copy of the lock goes now; pmset's went when it exited.
        try? lock.close()
        log("disablesleep 1 for uid \(callerUID): status \(r.status) \(r.message)")
        reply(r.status, r.message)
    }

    public func installRestoreRule(withReply reply: @escaping (Int32, String) -> Void) {
        guard let user = RestoreRule.userName(forUID: callerUID) else {
            reply(HelperStatus.notRun, "no account for uid \(callerUID)")
            return
        }
        let r = commands.installRestoreRule(user: user, uid: callerUID)
        log("restore rule for \(user): status \(r.status) \(r.message)")
        reply(r.status, r.message)
    }

    public func version(withReply reply: @escaping (String) -> Void) {
        reply(version)
    }
}

public final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let commands: HelperCommands
    let version: String
    let idleExit: TimeInterval
    let exitProcess: @Sendable () -> Void
    let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var open = 0
    private var generation = 0

    public init(
        commands: HelperCommands = HelperCommands(),
        version: String,
        idleExit: TimeInterval = 10,
        exitProcess: @escaping @Sendable () -> Void = { exit(0) },
        log: @escaping @Sendable (String) -> Void
    ) {
        self.commands = commands
        self.version = version
        self.idleExit = idleExit
        self.exitProcess = exitProcess
        self.log = log
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: EmberHelperProtocol.self)
        connection.exportedObject = HelperService(commands: commands, callerUID: connection.effectiveUserIdentifier, version: version, log: log)
        connection.invalidationHandler = { [weak self] in self?.closed() }
        lock.withLock {
            open += 1
            generation += 1
        }
        connection.resume()
        return true
    }

    /// Starts the idle clock; call once at launch too, for a start with no
    /// connection.
    public func scheduleIdleExit() {
        let mine: Int = lock.withLock { generation }
        DispatchQueue.global().asyncAfter(deadline: .now() + idleExit) { [weak self] in
            guard let self else { return }
            let idle = self.lock.withLock { self.open == 0 && self.generation == mine }
            if idle { self.exitProcess() }
        }
    }

    private func closed() {
        lock.withLock {
            open -= 1
            generation += 1
        }
        scheduleIdleExit()
    }
}
