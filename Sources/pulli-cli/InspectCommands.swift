import ArgumentParser
import DeviceAPI
import Foundation
import MTPKit
import USBKit

struct Devices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List connected Android phones without opening them."
    )

    func run() async throws {
        let phones = await Phones.candidates()
        guard !phones.isEmpty else {
            print("No Android phone found. Plug it in with a data cable and unlock it.")
            return
        }
        for phone in phones {
            let usb = phone.record.summary
            let maker = Phones.androidVendors[usb.vendorID] ?? usb.vendorName ?? "Unknown"
            print(String(format: "%04x:%04x  %@ %@", usb.vendorID, usb.productID, maker, usb.productName ?? ""))
            print("  serial   \(usb.usbSerial ?? "none")")
            print("  link     \(Format.link(usb))")
            print("  path     \(usb.throughHub ? "through a hub (monitor, dock or adapter)" : "direct to the Mac")")
            print("  mode     \(phone.record.hasMTPInterface ? "File transfer (MTP)" : "no MTP interface (Charging only?)")")
            if let holder = phone.record.mtpHolder {
                print("  held by  \(holder)")
            }
        }
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Explain what stands between Pulli and the phone. Changes nothing."
    )

    func run() async throws {
        let daemons = SystemCameraDaemons.running()
        if daemons.isEmpty {
            print("Camera services: none running")
        } else {
            for daemon in daemons { print("Camera service running: \(daemon.path) (pid \(daemon.pid))") }
        }

        let phones = await Phones.candidates()
        if phones.isEmpty {
            print("No Android phone connected.")
            return
        }
        for phone in phones {
            let usb = phone.record.summary
            print("\n\(usb.productName ?? "Phone") [\(usb.usbSerial ?? "no serial")]")
            print("  link: \(Format.link(usb))" + (usb.linkGeneration == .usb2 ? "  (USB 2 limits speed to ~40 MB/s; try a USB 3 cable and port)" : ""))
            if !phone.record.hasMTPInterface {
                print("  ✗ " + Phones.guidance(for: DeviceError.noMTPInterface))
                continue
            }
            for interface in phone.record.interfaces {
                let kind = interface.looksLikeMTP ? "MTP" : String(format: "class %02x/%02x/%02x", interface.interfaceClass, interface.interfaceSubClass, interface.interfaceProtocol)
                print("  interface \(interface.number): \(kind)\(interface.name.map { " \"\($0)\"" } ?? "")\(interface.holder.map { " — held by \($0)" } ?? "")")
            }
            if let holder = phone.record.mtpHolder {
                print("  ✗ " + Phones.guidance(for: DeviceError.contended(holder: holder)))
            } else {
                print("  ✓ nothing is holding the phone")
            }
            print("  libmtp recognises it: \(phone.listedByLibmtp ? "yes" : "no")")
        }
    }
}

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open a session and show the phone's details.")

    @OptionGroup var phone: PhoneOptions

    @Flag(help: "Also print libmtp's raw DeviceInfo dump (supported operations, extensions).")
    var dump = false

    func run() async throws {
        let session = try await Phones.open(options: phone)
        let info = session.info
        print("\(info.displayName)")
        print("  manufacturer  \(info.manufacturer ?? "?")")
        print("  model         \(info.model ?? "?")")
        print("  identity      \(info.key)")
        print("  MTP serial    \(info.mtpSerial ?? "none")")
        print("  link          \(Format.link(info.usb))")
        print("  reads         \(info.readStrategy.rawValue)" + (info.readStrategy == .partial64 ? " (resumable at any size)" : ""))

        let storages = try await session.storages()
        if storages.isEmpty {
            print("  storage       none visible. " + Phones.guidance(for: DeviceError.noStorage))
        }
        for storage in storages {
            let free = storage.freeBytes.map(Format.bytes) ?? "?"
            let total = storage.capacityBytes.map(Format.bytes) ?? "?"
            print("  storage       \(hex(storage.id))  \(storage.description)  \(free) free of \(total)")
        }
        if dump {
            print("\n--- libmtp device dump ---")
            await session.dumpDeviceInfo()
        }
        await session.close()
    }
}

struct Thumbnail: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thumb",
        abstract: "Save the phone's own preview of a file (MTP GetThumb), and time it."
    )

    @OptionGroup var phone: PhoneOptions
    @OptionGroup var storageOption: StorageOption

    @Argument(help: "File on the phone, e.g. /DCIM/Camera/IMG.jpg.")
    var path: String

    @Argument(help: "Where to save the JPEG.")
    var output: String

    func run() async throws {
        let session = try await Phones.open(options: phone)
        let storage = try await Phones.storage(of: session, matching: storageOption.storage)
        guard let entry = try await session.stat(RemotePath(path), storage: storage.id) else { throw CLIError("\(path) is not on the phone") }
        let start = ContinuousClock.now
        let data = try await session.thumbnail(entry.ref)
        let elapsed = ContinuousClock.now - start
        if let data {
            try data.write(to: URL(fileURLWithPath: output))
            print("\(Format.bytes(UInt64(data.count))) preview in \(elapsed.formatted(.units(allowed: [.milliseconds]))) → \(output)")
        } else {
            print("The phone has no preview for \(path) (\(elapsed.formatted(.units(allowed: [.milliseconds]))))")
        }
        await session.close()
    }
}

struct Put: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy files from the Mac into a phone folder (created if missing). Not resumable: MTP cannot append."
    )

    @OptionGroup var phone: PhoneOptions
    @OptionGroup var storageOption: StorageOption

    @Argument(help: "Mac files, then the phone folder, e.g. notes.txt /Download/Pulli.")
    var paths: [String]

    func run() async throws {
        guard paths.count >= 2 else { throw CLIError("give at least one Mac file and a phone folder") }
        let folder = RemotePath(paths.last!)
        let session = try await Phones.open(options: phone)
        let storage = try await Phones.storage(of: session, matching: storageOption.storage)
        var parent = RemotePath.root
        for component in folder.components {
            _ = try await session.makeFolder(component, in: parent, storage: storage.id)
            parent = parent.appending(component)
        }
        for path in paths.dropLast() {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let start = ContinuousClock.now
            let entry = try await session.upload(url, as: url.lastPathComponent, into: folder, storage: storage.id) { _ in }
            print("\(url.lastPathComponent) → \(folder.appending(url.lastPathComponent)) · \(Format.bytes(entry.size)) in \((ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds])))")
        }
        await session.close()
    }
}

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Delete one file or empty folder from the phone. Requires --yes."
    )

    @OptionGroup var phone: PhoneOptions
    @OptionGroup var storageOption: StorageOption

    @Argument(help: "File or empty folder on the phone.")
    var path: String

    @Flag(help: "Really delete it.")
    var yes = false

    func run() async throws {
        guard yes else { throw CLIError("add --yes to delete \(path) from the phone") }
        let session = try await Phones.open(options: phone)
        let storage = try await Phones.storage(of: session, matching: storageOption.storage)
        guard let entry = try await session.stat(RemotePath(path), storage: storage.id) else { throw CLIError("\(path) is not on the phone") }
        try await session.delete(entry.ref)
        print("Deleted \(path)")
        await session.close()
    }
}

struct DiskUsage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "du",
        abstract: "Walk a folder tree on the phone and total it (what the storage map does)."
    )

    @OptionGroup var phone: PhoneOptions
    @OptionGroup var storageOption: StorageOption

    @Argument(help: "Folder on the phone.")
    var path: String = "/"

    func run() async throws {
        let session = try await Phones.open(options: phone)
        let storage = try await Phones.storage(of: session, matching: storageOption.storage)
        let start = ContinuousClock.now
        var queue = [RemotePath(path)]
        var index = 0
        var files = 0
        var bytes: UInt64 = 0
        var top: [String: UInt64] = [:]
        while index < queue.count {
            let folder = queue[index]
            index += 1
            for try await page in session.list(folder, storage: storage.id) {
                for entry in page {
                    if entry.isFolder { queue.append(folder.appending(entry.name)); continue }
                    files += 1
                    bytes += entry.size
                    let first = folder.appending(entry.name).components.dropFirst(RemotePath(path).components.count).first ?? entry.name
                    top[first, default: 0] += entry.size
                }
            }
        }
        for (name, size) in top.sorted(by: { $0.value > $1.value }).prefix(12) {
            print("\(Format.bytes(size).padding(toLength: 10, withPad: " ", startingAt: 0))  \(name)")
        }
        print("\(files) files in \(index) folders, \(Format.bytes(bytes)), walked in \((ContinuousClock.now - start).formatted(.units(allowed: [.minutes, .seconds])))")
        await session.close()
    }
}

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List one folder on the phone, streaming entries as they arrive."
    )

    @OptionGroup var phone: PhoneOptions
    @OptionGroup var storageOption: StorageOption

    @Argument(help: "Folder on the phone, e.g. /DCIM/Camera.")
    var path: String = "/"

    @Flag(help: "Only print the count and timing (for folders with tens of thousands of files).")
    var summary = false

    @OptionGroup var backendOption: BackendOption

    func run() async throws {
        let session: any DeviceSession = if backendOption.backend == .icc {
            try await ICCPhones.open(ICCPhones.connector(), serial: phone.serial)
        } else {
            try await Phones.open(options: phone)
        }
        let storage = try await Phones.storage(of: session, matching: storageOption.storage)

        let start = ContinuousClock.now
        var files = 0, folders = 0
        var bytes: UInt64 = 0
        var firstPage: Duration?
        for try await page in session.list(RemotePath(path), storage: storage.id) {
            firstPage = firstPage ?? (ContinuousClock.now - start)
            for entry in page {
                if entry.isFolder { folders += 1 } else { files += 1; bytes += entry.size }
                guard !summary else { continue }
                let date = Date(timeIntervalSince1970: TimeInterval(entry.modifiedWallClock)).formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                print(entry.isFolder ? "d  \(String(repeating: " ", count: 10))  \(String(repeating: " ", count: 19))  \(entry.name)/"
                                     : "f  \(Format.bytes(entry.size).padding(toLength: 10, withPad: " ", startingAt: 0))  \(date)  \(entry.name)")
            }
            if summary { Log.note("… \(files + folders) entries") }
        }
        let elapsed = ContinuousClock.now - start
        print("\(folders) folders, \(files) files, \(Format.bytes(bytes)) in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])))"
              + (firstPage.map { ", first page after \($0.formatted(.units(allowed: [.seconds, .milliseconds])))" } ?? ""))
        await session.close()
    }
}
