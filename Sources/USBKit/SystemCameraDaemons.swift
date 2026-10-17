public import DeviceAPI
import Darwin
import Foundation
import Security

/// Releases a phone from macOS's own camera daemons, without admin rights (docs/DECISIONS.md, D-008).
///
/// `ptpcamerad` is a per-user, on-demand LaunchAgent: it runs as the logged-in user, so we may
/// signal it, and launchd starts it again the next time an app asks for cameras. We only ever
/// terminate a process after proving it is one of Apple's daemons; user apps are never touched.
public enum SystemCameraDaemons {
    public enum Outcome: Sendable, Equatable {
        case terminated(pid: Int32)
        /// The holder is not a system camera daemon (a user app or a driver). Ask the user instead.
        case notSystemDaemon
        /// The process was gone before we could signal it. Retrying the open is the right move.
        case alreadyExited
        case failed(String)
    }

    /// Terminates `holder` if, and only if, it is a verified Apple camera daemon owned by this user.
    public static func release(_ holder: InterfaceHolder) -> Outcome {
        guard case .process(let pid, _) = holder else { return .notSystemDaemon }
        guard let path = executablePath(of: pid) else { return .alreadyExited }
        guard isSystemCameraDaemon(path: path) else { return .notSystemDaemon }
        guard owner(of: pid) == getuid() else { return .failed("\(path) (pid \(pid)) belongs to another user") }
        guard hasAppleSignature(pid: pid) else { return .failed("\(path) (pid \(pid)) failed Apple signature check") }

        if kill(pid, SIGKILL) == 0 { return .terminated(pid: pid) }
        return errno == ESRCH ? .alreadyExited : .failed("kill(\(pid)): \(String(cString: strerror(errno)))")
    }

    /// Running camera daemons for this user, for `pulli-cli doctor` and support logs.
    public static func running() -> [(pid: Int32, path: String)] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [Int32](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<Int32>.size)))
        return pids.prefix(max(0, count)).compactMap { pid in
            guard pid > 0, let path = executablePath(of: pid), isSystemCameraDaemon(path: path),
                  owner(of: pid) == getuid() else { return nil }
            return (pid, path)
        }
    }

    /// Whether a holder's process name (from `UsbExclusiveOwner`) is one of macOS's camera services.
    public static func isSystemCameraDaemonName(_ name: String) -> Bool {
        name == "ptpcamerad" || name.hasPrefix("mscamerad")
    }

    static func isSystemCameraDaemon(path: String) -> Bool {
        if path == "/usr/libexec/ptpcamerad" { return true }
        // ImageCaptureCore's per-app camera service (mscamerad-xpc) runs inside apps that browse cameras.
        return path.hasPrefix("/System/Library/Frameworks/ImageCaptureCore.framework/")
            && (path as NSString).lastPathComponent.hasPrefix("mscamerad")
    }

    private static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func owner(of pid: Int32) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_uid
    }

    /// Checks the running process's code signature is Apple's. `/System` and `/usr/libexec` are
    /// SIP-protected, so path plus Apple anchor is enough to rule out look-alike binaries.
    private static func hasAppleSignature(pid: Int32) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
