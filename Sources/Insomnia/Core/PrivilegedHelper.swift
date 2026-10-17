import EmberHelperKit
import Foundation
import ServiceManagement

/// Where the privileged helper stands, from `SMAppService`'s status.
enum HelperState: Equatable, Sendable {
    /// Not a release build: there is no helper to register.
    case unavailable
    case notRegistered
    /// Registered; macOS waits for the person to allow it in System
    /// Settings > General > Login Items.
    case requiresApproval
    case enabled
    /// macOS cannot find the daemon plist in the bundle.
    case notFound
}

/// The XPC call could not be made or got no answer (the helper is not
/// running, was refused, or crashed). Nothing is known to have run, so the
/// caller may fall back to another way; a command that ran and failed comes
/// back as a status instead.
struct HelperConnectionError: Error, LocalizedError, Sendable {
    let reason: String
    var errorDescription: String? { "Ember's helper did not answer: \(reason)" }
}

/// What the app asks of its helper (spec 2026-10-17 "The helper").
protocol PrivilegedHelping: Sendable {
    var state: HelperState { get }
    func register() throws
    func unregister() async throws
    /// Opens System Settings > General > Login Items.
    func openApprovalSettings()
    /// `pmset -a disablesleep 1` as root, holding `lock` until pmset exits.
    func disableSleep(holding lock: RecoveryLockHandle) async throws -> HelperCommands.Result
    func installRestoreRule() async throws -> HelperCommands.Result
}

/// The helper this build talks to: the registered one in a release build,
/// none in a source build.
let liveHelper: any PrivilegedHelping = ReleaseSignature.isDeveloperID ? ServiceManagementHelper.shared : NoHelper()

/// A source build's helper: there is none.
struct NoHelper: PrivilegedHelping {
    var state: HelperState { .unavailable }
    func register() throws {}
    func unregister() async throws {}
    func openApprovalSettings() {}
    func disableSleep(holding lock: RecoveryLockHandle) async throws -> HelperCommands.Result {
        throw HelperConnectionError(reason: "this build has no helper")
    }
    func installRestoreRule() async throws -> HelperCommands.Result {
        throw HelperConnectionError(reason: "this build has no helper")
    }
}

/// The release build's helper, registered with `SMAppService` and reached
/// over its Mach service. Each call opens its own connection, held to the
/// helper's code requirement, and closes it after the reply.
struct ServiceManagementHelper: PrivilegedHelping {
    static let shared = ServiceManagementHelper()

    private var service: SMAppService { SMAppService.daemon(plistName: HelperNames.daemonPlistName) }

    var state: HelperState {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .enabled: return .enabled
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    func register() throws { try service.register() }

    func unregister() async throws { try await service.unregister() }

    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    func disableSleep(holding lock: RecoveryLockHandle) async throws -> HelperCommands.Result {
        guard let fd = lock.descriptorForChild() else {
            throw HelperConnectionError(reason: "the recovery lock it must hold was already released")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return try await call { proxy, reply in
            proxy.disableSleep(lock: handle) { reply(HelperCommands.Result(status: $0, message: $1)) }
        }
    }

    func installRestoreRule() async throws -> HelperCommands.Result {
        try await call { proxy, reply in
            proxy.installRestoreRule { reply(HelperCommands.Result(status: $0, message: $1)) }
        }
    }

    private func call(_ body: @escaping @Sendable (EmberHelperProtocol, @escaping @Sendable (HelperCommands.Result) -> Void) -> Void) async throws -> HelperCommands.Result {
        let connection = NSXPCConnection(machServiceName: HelperNames.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: EmberHelperProtocol.self)
        connection.setCodeSigningRequirement(HelperNames.helperRequirement)
        connection.resume()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(throwing: HelperConnectionError(reason: error.localizedDescription))
            }
            guard let helper = proxy as? EmberHelperProtocol else {
                once.resume(throwing: HelperConnectionError(reason: "the connection has no helper interface"))
                return
            }
            body(helper) { once.resume(returning: $0) }
        }
    }
}

/// A continuation resumed by whichever comes first, the reply or the
/// connection's error handler.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HelperCommands.Result, Error>?

    init(_ continuation: CheckedContinuation<HelperCommands.Result, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: HelperCommands.Result) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<HelperCommands.Result, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
