public import DeviceAPI
public import Foundation
import ImageCaptureCore

/// What to tell the user when ImageCaptureCore sees the phone but none of its files.
public enum ICCGuidance {
    /// In "File transfer" (MTP) mode Image Capture finds the phone but an empty catalogue
    /// (spike 1, Galaxy Z Fold7); only "Transferring images" (PTP) shows photos and videos.
    public static let chooseTransferringImages =
        "The phone shows no photos or videos to this Mac. Unlock it, open the USB notification and choose \"Transferring images\" (also called PTP)."

    public static let noPhone =
        "No phone found. Plug it in with a data cable, unlock it, and in the USB notification choose \"Transferring images\"."
}

/// A failure of our own around an ImageCaptureCore call.
public struct ICCError: Error, Sendable, CustomStringConvertible, LocalizedError {
    public var description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

/// Classifies ImageCaptureCore's errors for the engine's retry policy (`DeviceError`).
public enum ICCErrorMapping {
    /// - Parameter deviceRemoved: Image Capture said the phone left; that outranks whatever error
    ///   the interrupted call reported.
    public static func deviceError(_ error: any Error, deviceRemoved: Bool = false) -> DeviceError {
        if deviceRemoved { return .deviceGone }
        if let error = error as? DeviceError { return error }
        if error is CancellationError { return .transient("cancelled") }
        if let error = error as? ICCError { return .transient(error.description) }
        let ns = error as NSError
        guard ns.domain == ICErrorDomain || knownCodes.contains(ns.code) else {
            return .transient(ns.localizedDescription)
        }
        let detail = "\(ns.localizedDescription) (Image Capture \(ns.code))"
        switch ns.code {
        case gone: return .deviceGone
        case locked: return .noStorage
        case notAuthorised: return .rejected("this Mac is not allowed to open the phone: \(detail)")
        case objectMissing: return .rejected("object no longer exists")
        case badOffset, tooLarge: return .unsupported("the phone refused this read: \(detail)")
        default: return .transient(detail)
        }
    }

    // ImageCaptureConstants.h. Raw numbers: the Swift names of these enums differ between SDKs.

    /// Driver exited, session closed suddenly, ejected suddenly, session not open.
    static let gone: Set<Int> = [-21350, -21349, -21348, -9958]
    /// ICReturnDeviceIsPasscodeLocked.
    static let locked: Set<Int> = [-9943]
    /// Not authorised to open the device, or to send PTP commands.
    static let notAuthorised: Set<Int> = [-21343, -21249]
    /// ICReturnCodeObjectDoesNotExist.
    static let objectMissing: Set<Int> = [-21450]
    /// ICReturnCodeObjectDataOffsetInvalid.
    static let badOffset: Set<Int> = [-21449]
    /// ICReturnCodeObjectDataRequestTooLarge.
    static let tooLarge: Set<Int> = [-21446]

    /// Codes recognised whatever domain they arrive in (the read API does not document one).
    static let knownCodes: Set<Int> = gone.union(locked).union(notAuthorised).union(objectMissing).union(badOffset).union(tooLarge)
        .union([-9923, -9927, -9934, -9954, -9955, -9956, -9957, -21250, -21345, -21344, -21347, -21448, -21447])
}

private func ~= (set: Set<Int>, value: Int) -> Bool { set.contains(value) }
