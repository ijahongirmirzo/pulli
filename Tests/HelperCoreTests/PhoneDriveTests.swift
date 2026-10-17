import DeviceAPI
import Foundation
@testable import HelperCore
import MockDevice
import PulliProtocol
import Testing

/// The phone drive over real HTTP (URLSession), against the simulated phone. Set
/// PULLI_MOUNT_TEST=1 to also mount it with macOS's own WebDAV client and use it like Finder.
@Suite(.serialized) struct PhoneDriveTests {
    static func phone() -> MockDevice {
        let device = MockDevice(serial: "DRIVE1")
        device.addFile("DCIM/Camera/a.jpg", size: 300_000)
        device.addFile("DCIM/Camera/clip.mp4", size: 5_000_000)
        device.addFile("Download/doc.pdf", size: 50_000)
        return device
    }

    private func request(_ url: URL, _ method: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> (Int, Data, [AnyHashable: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        return (http.statusCode, data, http.allHeaderFields)
    }

    private func start(_ harness: Harness, _ device: MockDevice) async throws -> URL {
        _ = try await harness.wait("phone ready") { $0.devices[device.key.description]?.state == .ready }
        guard case .drive(let url) = try await harness.client.send(.startDrive(deviceID: device.key.description)) else { throw PulliError(.unknown, "no drive") }
        return URL(string: url)!
    }

    @Test func browsesAndReadsRanges() async throws {
        let device = Self.phone()
        let harness = try await Harness(devices: [device])
        _ = try await harness.client.send(.setWatchingDevices(true))
        let root = try await start(harness, device)

        let (status, body, _) = try await request(root.appendingPathComponent("DCIM/Camera/"), "PROPFIND", headers: ["Depth": "1"])
        #expect(status == 207)
        let xml = String(decoding: body, as: UTF8.self)
        #expect(xml.contains("<D:displayname>a.jpg</D:displayname>"))
        #expect(xml.contains("<D:getcontentlength>5000000</D:getcontentlength>"))
        #expect(xml.contains("<D:collection/>"))

        let expected = try #require(device.expectedContent("DCIM/Camera/clip.mp4"))
        let (partial, bytes, headers) = try await request(root.appendingPathComponent("DCIM/Camera/clip.mp4"), "GET", headers: ["Range": "bytes=1000-1999"])
        #expect(partial == 206)
        #expect(bytes == expected[1000..<2000])
        #expect(headers["Content-Range"] as? String == "bytes 1000-1999/5000000")
        let (whole, all, _) = try await request(root.appendingPathComponent("DCIM/Camera/a.jpg"), "GET")
        #expect(whole == 200)
        #expect(all == device.expectedContent("DCIM/Camera/a.jpg"))

        let (outside, _, _) = try await request(URL(string: "http://127.0.0.1:\(root.port!)/wrongtoken/x/")!, "PROPFIND")
        #expect(outside == 404)
    }

    @Test func writesLikeFinderAndGuardsDeletes() async throws {
        let device = Self.phone()
        let harness = try await Harness(devices: [device])
        _ = try await harness.client.send(.setWatchingDevices(true))
        let root = try await start(harness, device)
        let target = root.appendingPathComponent("Download/new.txt")

        // Finder: an empty PUT, a lock, the content, an unlock; and its own ._ file.
        #expect(try await request(target, "PUT", body: Data()).0 == 201)
        #expect(try await request(target, "LOCK", body: Data("<lockinfo/>".utf8)).0 == 200)
        #expect(try await request(target, "PUT", body: Data(repeating: 65, count: 12_345)).0 == 204)
        #expect(try await request(target, "UNLOCK").0 == 204)
        #expect(try await request(root.appendingPathComponent("Download/._new.txt"), "PUT", body: Data([1, 2, 3])).0 == 201)
        #expect(device.file("Download/new.txt")?.size == 12_345)
        #expect(device.file("Download/._new.txt") == nil, "Finder's own files never reach the phone")

        #expect(try await request(root.appendingPathComponent("Download/Trip/"), "MKCOL").0 == 201)
        #expect(try await request(root.appendingPathComponent("Download/Trip/one.jpg"), "PUT", body: Data(count: 10)).0 == 201)
        #expect(device.file("Download/Trip/one.jpg")?.size == 10)

        // The phone's own files cannot be deleted or renamed until the setting allows it.
        let doc = root.appendingPathComponent("Download/doc.pdf")
        #expect(try await request(doc, "DELETE").0 == 403)
        #expect(device.file("Download/doc.pdf") != nil)
        var settings = HelperSettings()
        settings.allowDriveChanges = true
        _ = try await harness.client.send(.setSettings(settings))
        #expect(try await request(doc, "MOVE", headers: ["Destination": root.appendingPathComponent("Download/report.pdf").absoluteString]).0 == 201)
        #expect(device.file("Download/report.pdf")?.size == 50_000)
        #expect(try await request(root.appendingPathComponent("Download/report.pdf"), "DELETE").0 == 204)
        #expect(device.file("Download/report.pdf") == nil)
    }

    /// Mounts the drive with macOS's WebDAV client (what Finder uses) and works with it as files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULLI_MOUNT_TEST"] == "1"))
    func mountsWithTheSystemWebDAVClient() async throws {
        let device = Self.phone()
        let harness = try await Harness(devices: [device])
        _ = try await harness.client.send(.setWatchingDevices(true))
        let root = try await start(harness, device)
        let mountPoint = harness.root.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let mount = Process()
        mount.executableURL = URL(fileURLWithPath: "/sbin/mount_webdav")
        mount.arguments = ["-S", "-v", "Phone", root.absoluteString, mountPoint.path]
        try mount.run()
        mount.waitUntilExit()
        #expect(mount.terminationStatus == 0)
        defer {
            let unmount = Process()
            unmount.executableURL = URL(fileURLWithPath: "/sbin/umount")
            unmount.arguments = [mountPoint.path]
            try? unmount.run()
            unmount.waitUntilExit()
        }
        let camera = try FileManager.default.contentsOfDirectory(atPath: mountPoint.appendingPathComponent("DCIM/Camera").path).sorted()
        #expect(camera == ["a.jpg", "clip.mp4"])
        let read = try Data(contentsOf: mountPoint.appendingPathComponent("DCIM/Camera/a.jpg"))
        #expect(read == device.expectedContent("DCIM/Camera/a.jpg"))
        try Data(repeating: 66, count: 70_000).write(to: mountPoint.appendingPathComponent("Download/from-mac.bin"))
        try await Task.sleep(for: .seconds(2))
        #expect(device.file("Download/from-mac.bin")?.size == 70_000)
    }
}
