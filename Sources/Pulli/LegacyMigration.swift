import Darwin
import Foundation
import ServiceManagement
import TransferCore

/// One-off migration of settings, processes and data from legacy Relay to Pulli.
@MainActor
enum LegacyMigration {
    /// Migrates user defaults, background helper processes and data folders from Relay to Pulli.
    static func run() {
        let migrationKey = "migratedFromRelay"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        // 1. Stop the old background helper and its workers; if it was on, turn Pulli's on.
        if stopOldHelperAndWorkers() {
            try? HelperRegistration.setEnabled(true)
        }

        // 2. Settings: copy old persistent domain values if not already present.
        let oldSettings = UserDefaults.standard.persistentDomain(forName: "app.relay.mac")
        if let oldSettings {
            for (key, value) in oldSettings {
                if UserDefaults.standard.object(forKey: key) == nil {
                    UserDefaults.standard.set(value, forKey: key)
                }
            }
        }

        // 3. Open at login: re-register under Pulli if the old installation was configured for login launch.
        if oldSettings?["loginItemAppPath"] != nil {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(Bundle.main.bundlePath, forKey: "loginItemAppPath")
        }

        // 4. Touch DataFolder.current so the data folder moves now (after stopping old processes).
        _ = DataFolder.current

        // 5. Mark migration complete so it never runs again.
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    /// Stops the old LaunchAgent service and terminates any leftover relay helper or worker
    /// processes. True when the old background helper was in use (its job was loaded, or its
    /// process was running), so the new one should be switched on in its place.
    private static func stopOldHelperAndWorkers() -> Bool {
        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "gui/\(getuid())/app.relay.mac.helper"]
        bootout.standardOutput = FileHandle.nullDevice
        bootout.standardError = FileHandle.nullDevice
        var helperWasOn = false
        if (try? bootout.run()) != nil {
            bootout.waitUntilExit()
            helperWasOn = bootout.terminationStatus == 0
        }

        var targetPids: [Int32] = []
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [Int32](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<Int32>.size)))

        for pid in pids.prefix(max(0, count)) where pid > 0 && pid != getpid() {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            guard info.pbi_uid == getuid() else { continue }

            var buffer = [CChar](repeating: 0, count: 256)
            let len = proc_name(pid, &buffer, UInt32(buffer.count))
            guard len > 0 else { continue }
            let name = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name == "relay-helper" || name == "relay-mtp-worker" {
                if name == "relay-helper" { helperWasOn = true }
                targetPids.append(pid)
                kill(pid, SIGTERM)
            }
        }

        let deadline = Date().addingTimeInterval(3.0)
        while !targetPids.isEmpty && Date() < deadline {
            usleep(100_000)
            targetPids.removeAll { kill($0, 0) != 0 }
        }
        return helperWasOn
    }
}
