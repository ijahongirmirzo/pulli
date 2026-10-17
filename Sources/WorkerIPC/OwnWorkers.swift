public import Darwin
import Foundation

/// Pulli's own phone workers (`pulli-mtp-worker` or legacy `relay-mtp-worker`) found holding a phone: never "another app".
/// Whose worker it is decides what to do:
/// - this engine's: it is letting go of the phone (after a stall or a reconnect); wait.
/// - nobody's (its engine has gone): a leftover; stop it so the phone can be opened.
/// - another Pulli engine's (the background helper, or a second copy of the app): say which.
public enum OwnWorkers: Sendable {
    public static let name = "pulli-mtp-worker"
    public static let legacyName = "relay-mtp-worker"

    public static func isOwnWorker(_ processName: String) -> Bool {
        processName == name || processName == legacyName
    }

    public enum Owner: Equatable, Sendable {
        case thisEngine
        case orphan
        case backgroundHelper
        case otherPulli
    }

    public static func owner(of pid: Int32) -> Owner {
        if let procUid = uid(of: pid), procUid != getuid() { return .otherPulli }
        guard let parent = parentPID(of: pid) else { return .orphan }
        if parent == getpid() { return .thisEngine }
        if parent <= 1 || !isAlive(parent) { return .orphan }
        let parentName = processName(parent)
        return (parentName == "pulli-helper" || parentName == "relay-helper") ? .backgroundHelper : .otherPulli
    }

    /// Stops a leftover worker (its engine is gone, so nothing else will). Only ever a process
    /// named `pulli-mtp-worker` or `relay-mtp-worker`.
    public static func stopLeftover(_ pid: Int32) {
        guard let procName = processName(pid), isOwnWorker(procName) else { return }
        if let procUid = uid(of: pid), procUid != getuid() { return }
        Darwin.kill(pid, SIGKILL)
    }

    public static func parentPID(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }

    public static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func uid(of pid: Int32) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_uid
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }
}
