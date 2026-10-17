import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping while a transfer runs. The display may still sleep.
///
/// This cannot stop lid-close or Apple-menu sleep (IOPMLib.h); the transfer engine handles those
/// as an ordinary pause and resumes on wake.
public final class PowerAssertion: @unchecked Sendable {
    private var assertionID: IOPMAssertionID = 0
    private let lock = NSLock()

    public init() {}

    deinit { release() }

    /// Takes the assertion if not already held. Returns false if the system refused it.
    @discardableResult
    public func hold(reason: String) -> Bool {
        lock.withLock {
            guard assertionID == 0 else { return true }
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            guard result == kIOReturnSuccess else { return false }
            assertionID = id
            return true
        }
    }

    public func release() {
        lock.withLock {
            guard assertionID != 0 else { return }
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }
}
