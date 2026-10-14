import Foundation
import IOKit.pwr_mgt

/// Awake mode's hold on sleep (spec "Awake mode"): one IOPM assertion of
/// type PreventUserIdleDisplaySleep, which keeps the display and with it
/// the Mac awake while the lid is open. macOS releases an assertion when
/// its process exits, so a crash cleans up by itself: nothing is journaled.
protocol AwakeAsserting: Sendable {
    var isHeld: Bool { get }
    /// Takes the assertion; a second call while held does nothing.
    func hold() throws
    /// Releases it if held. A refused release is logged, never thrown:
    /// the process exit releases it anyway.
    func release()
}

struct AwakeAssertionError: Error, LocalizedError, Equatable {
    let code: IOReturn

    var errorDescription: String? {
        "IOPMAssertionCreateWithName returned \(String(format: "0x%08x", UInt32(bitPattern: code)))"
    }
}

final class IOPMAwakeAssertion: AwakeAsserting, @unchecked Sendable {
    /// The type string behind kIOPMAssertPreventUserIdleDisplaySleep, a
    /// CFSTR macro Swift does not import.
    static let type = "PreventUserIdleDisplaySleep"
    /// What `pmset -g assertions` shows for it.
    static let name = "Awake mode"

    private let lock = NSLock()
    private var id: IOPMAssertionID?

    var isHeld: Bool { lock.withLock { id != nil } }

    func hold() throws {
        try lock.withLock {
            guard id == nil else { return }
            var newID: IOPMAssertionID = 0
            let kr = IOPMAssertionCreateWithName(Self.type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.name as CFString, &newID)
            guard kr == kIOReturnSuccess else { throw AwakeAssertionError(code: kr) }
            id = newID
        }
    }

    func release() {
        lock.withLock {
            guard let current = id else { return }
            let kr = IOPMAssertionRelease(current)
            if kr != kIOReturnSuccess {
                Log.error("IOPMAssertionRelease returned \(String(format: "0x%08x", UInt32(bitPattern: kr)))")
            }
            id = nil
        }
    }
}
