import ArgumentParser
import Foundation
import ImageCaptureCore
import UniformTypeIdentifiers

// MARK: - Subcommand Group

/// Spike commands for Apple's ImageCaptureCore framework to evaluate Mac App Store feasibility.
struct ICCCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "icc",
        abstract: "ImageCaptureCore spike commands (App Store feasibility).",
        discussion: """
            Experiments with Apple's ImageCaptureCore framework on Android phones: \
            content cataloguing, ranged reads, throughput benchmarks, and cable-pull resilience \
            without libmtp and without terminating macOS's camera services.
            """,
        subcommands: [
            ICCList.self,
            ICCRead.self,
            ICCBench.self,
            ICCPull.self,
        ]
    )
}

// MARK: - Subcommand: List

/// Lists connected cameras and their content catalogue up to a given depth.
struct ICCList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List connected cameras, request authorisation, and print the item tree."
    )

    @Option(help: "Maximum directory depth to print (defaults to unlimited).")
    var depth: Int?

    @Option(help: "Seconds to wait for camera discovery.")
    var timeout: Double = 10

    func run() async throws {
        let browser = ICCBrowser()
        defer { browser.stop() }

        // Authorisation enquiry
        print("Authorisation:")
        print(browser.authorisationReport())
        print("")

        print("Searching for local cameras (timeout \(Int(timeout)) s)...")
        let cameras = try await browser.discover(timeout: timeout)

        for (index, camera) in cameras.enumerated() {
            if index > 0 { print("\n" + String(repeating: "-", count: 60) + "\n") }

            let name = camera.name ?? "Unnamed camera"
            let kind = camera.productKind ?? "Unknown"
            let transport = camera.transportType ?? "Unknown"
            let capabilities = camera.capabilities.isEmpty ? "none" : camera.capabilities.joined(separator: ", ")

            print("Camera: \(name)")
            print("  product kind: \(kind)")
            print("  transport:    \(transport)")
            print("  capabilities: \(capabilities)")

            print("\nOpening session and enumerating content catalogue...")
            let session = ICCameraSession(device: camera)
            let catalogueDuration: Duration
            do {
                catalogueDuration = try await session.open(catalogTimeout: 60)
            } catch {
                print("Failed to open catalogue: \(error.localizedDescription)")
                await session.close()
                continue
            }

            print("Catalogue ready in \(catalogueDuration.formatted(.units(allowed: [.seconds, .milliseconds]))):\n")

            var totals = ItemTotals()
            var seenFiles = Set<ObjectIdentifier>()

            if let contents = camera.contents, !contents.isEmpty {
                printTree(
                    items: contents,
                    currentDepth: 1,
                    maxDepth: depth,
                    totals: &totals,
                    seenFiles: &seenFiles
                )
            } else if let mediaFiles = camera.mediaFiles, !mediaFiles.isEmpty {
                print("  (flat media catalogue: \(mediaFiles.count) items)")
                printTree(
                    items: mediaFiles,
                    currentDepth: 1,
                    maxDepth: depth,
                    totals: &totals,
                    seenFiles: &seenFiles
                )
            } else {
                print("  (no files or folders found)")
            }

            // Also check mediaFiles for any items missed by hierarchical contents
            if let mediaFiles = camera.mediaFiles {
                for item in mediaFiles {
                    if let file = item as? ICCameraFile, seenFiles.insert(ObjectIdentifier(file)).inserted {
                        totals.files += 1
                        totals.bytes += UInt64(max(0, file.fileSize))
                        let (isImg, isVid) = classify(item: file)
                        if isImg { totals.images += 1 }
                        else if isVid { totals.videos += 1 }
                        else { totals.other += 1 }
                    }
                }
            }

            print("\nTotals for \(name):")
            print("  \(totals.files) files, \(Format.bytes(totals.bytes))")
            print("  \(totals.images) images, \(totals.videos) videos, \(totals.other) other")
            print("  Catalogue took \(catalogueDuration.formatted(.units(allowed: [.seconds, .milliseconds])))")

            await session.close()
            print("Session closed cleanly.")
        }
    }
}

// MARK: - Subcommand: Read

/// Reads a byte range from a remote file and prints the hex dump of the first 32 bytes.
struct ICCRead: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read a byte range from a file on the camera with ranged reads."
    )

    @Argument(help: "Path of the file on the camera (e.g. DCIM/Camera/IMG_0001.JPG).")
    var path: String

    @Option(help: "Byte offset to start reading from.")
    var offset: Int64 = 0

    @Option(help: "Number of bytes to read (defaults to 64 KiB or remainder of file).")
    var length: Int64?

    @Option(name: .customLong("device"), help: "Camera name, when multiple are connected.")
    var deviceName: String?

    @Option(help: "Seconds to wait for camera discovery.")
    var timeout: Double = 10

    func validate() throws {
        guard offset >= 0 else { throw ValidationError("--offset must be non-negative.") }
        if let length {
            guard length > 0 else { throw ValidationError("--length must be greater than zero.") }
        }
    }

    func run() async throws {
        let (browser, camera) = try await selectCamera(deviceName: deviceName, timeout: timeout)
        defer { browser.stop() }

        let session = ICCameraSession(device: camera)
        _ = try await session.open(catalogTimeout: 60)
        defer {
            Task { await session.close() }
        }

        guard let file = findFile(in: camera, path: path) else {
            throw CLIError("File '\(path)' not found in catalogue. Run `pulli-cli icc list` to see available files.")
        }

        let fileSize = file.fileSize
        guard offset < fileSize else {
            throw CLIError("Offset \(offset) is at or beyond file size (\(Format.bytes(UInt64(fileSize)))).")
        }

        let bytesToRead = length ?? min(64 * 1024, fileSize - offset)
        guard bytesToRead > 0 else {
            throw CLIError("No bytes to read.")
        }

        let filePath = canonicalPath(of: file)
        print("File:     \(filePath) (\(Format.bytes(UInt64(fileSize))))")
        print("Range:    offset \(offset), requesting \(Format.bytes(UInt64(bytesToRead)))")

        let start = ContinuousClock.now
        let data = try await readData(from: file, offset: off_t(offset), length: off_t(bytesToRead))
        let elapsed = ContinuousClock.now - start

        let hexDump = data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("Returned: \(Format.bytes(UInt64(data.count))) in \(elapsed.formatted(.units(allowed: [.milliseconds, .seconds])))")
        print("Hex (32): \(hexDump.isEmpty ? "none" : hexDump)")
    }
}

// MARK: - Subcommand: Bench

/// Measures read throughput per chunk size across the entire file using ranged reads.
struct ICCBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Benchmark ranged reads across different chunk sizes (1, 4, 8, 16 MiB)."
    )

    @Argument(help: "Path of a file on the camera (e.g. DCIM/Camera/video.mp4).")
    var path: String

    @Option(name: .customLong("chunk-mib"), help: "Chunk sizes in MiB to test (e.g. 1,4,8,16).")
    var chunkMiB: String = "1,4,8,16"

    @Option(name: .customLong("device"), help: "Camera name, when multiple are connected.")
    var deviceName: String?

    @Option(help: "Seconds to wait for camera discovery.")
    var timeout: Double = 10

    var chunkSizes: [Int] {
        let parsed = chunkMiB
            .split { $0 == "," || $0 == " " }
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 }
        return parsed.isEmpty ? [1, 4, 8, 16] : parsed
    }

    func run() async throws {
        let (browser, camera) = try await selectCamera(deviceName: deviceName, timeout: timeout)
        defer { browser.stop() }

        let session = ICCameraSession(device: camera)
        _ = try await session.open(catalogTimeout: 60)
        defer {
            Task { await session.close() }
        }

        guard let file = findFile(in: camera, path: path) else {
            throw CLIError("File '\(path)' not found in catalogue. Run `pulli-cli icc list` to see available files.")
        }

        let fileSize = UInt64(max(0, file.fileSize))
        guard fileSize > 0 else {
            throw CLIError("File '\(path)' has size 0; cannot benchmark.")
        }

        let filePath = canonicalPath(of: file)
        print("File: \(filePath) (\(Format.bytes(fileSize)))")
        print("Benchmarking ranged reads with chunk sizes: \(chunkSizes.map { "\($0) MiB" }.joined(separator: ", "))\n")

        print("chunk size   throughput     duration   bytes read")
        print(String(repeating: "-", count: 50))

        for chunk in chunkSizes {
            let chunkBytes = UInt64(chunk) << 20
            var offset: UInt64 = 0
            let start = ContinuousClock.now

            while offset < fileSize {
                let toRead = min(chunkBytes, fileSize - offset)
                let chunkData = try await readData(from: file, offset: off_t(offset), length: off_t(toRead))
                guard !chunkData.isEmpty else {
                    print("\nWarning: premature EOF at offset \(offset)")
                    break
                }
                offset += UInt64(chunkData.count)
            }

            let elapsedSeconds = (ContinuousClock.now - start).seconds
            let rate = elapsedSeconds > 0 ? Double(offset) / elapsedSeconds : 0
            print(String(
                format: "%2d MiB       %@   %6.2f s   %@",
                chunk,
                Format.rate(rate).padding(toLength: 12, withPad: " ", startingAt: 0),
                elapsedSeconds,
                Format.bytes(offset)
            ))
        }
    }
}

// MARK: - Subcommand: Pull

/// Resumably copies a file from the camera to the Mac using ranged reads.
struct ICCPull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Resumably copy a file from the camera into a Mac folder."
    )

    @Argument(help: "Path of the file on the camera (e.g. DCIM/Camera/video.mp4).")
    var path: String

    @Argument(help: "Destination folder on the Mac.")
    var destination: String

    @Option(name: .customLong("chunk-mib"), help: "Chunk size in MiB (default: 4).")
    var chunkMiB: Int = 4

    @Option(name: .customLong("device"), help: "Camera name, when multiple are connected.")
    var deviceName: String?

    @Option(help: "Seconds to wait for camera discovery.")
    var timeout: Double = 10

    func validate() throws {
        guard chunkMiB > 0 else { throw ValidationError("--chunk-mib must be greater than zero.") }
    }

    func run() async throws {
        let destURL = URL(fileURLWithPath: (destination as NSString).expandingTildeInPath).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: destURL.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw ValidationError("Destination '\(destination)' is a file, not a directory.")
            }
        } else {
            try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        }

        let (browser, camera) = try await selectCamera(deviceName: deviceName, timeout: timeout)
        defer { browser.stop() }

        let session = ICCameraSession(device: camera)
        _ = try await session.open(catalogTimeout: 60)
        defer {
            Task { await session.close() }
        }

        guard let file = findFile(in: camera, path: path) else {
            throw CLIError("File '\(path)' not found in catalogue. Run `pulli-cli icc list` to inspect available files.")
        }

        let fileName = file.name ?? (path as NSString).lastPathComponent
        let totalSize = UInt64(max(0, file.fileSize))
        let partURL = destURL.appendingPathComponent(fileName + ".part")
        let finalURL = destURL.appendingPathComponent(fileName)

        // If the complete file already exists and matches the catalogue size, nothing to do
        if FileManager.default.fileExists(atPath: finalURL.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: finalURL.path)
            let existingSize = attrs[.size] as? UInt64 ?? 0
            if existingSize == totalSize {
                print("\(fileName) already completely downloaded (\(Format.bytes(totalSize))) at \(finalURL.path).")
                return
            }
        }

        var resumeOffset: UInt64 = 0
        if FileManager.default.fileExists(atPath: partURL.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: partURL.path)
            let partSize = attrs[.size] as? UInt64 ?? 0
            if partSize > totalSize {
                // The existing partial file is larger than the source; start fresh
                try FileManager.default.removeItem(at: partURL)
                resumeOffset = 0
            } else {
                resumeOffset = partSize
            }
        }

        if resumeOffset == totalSize && totalSize > 0 {
            // Already finished downloading, only needs rename
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: partURL, to: finalURL)
            print("Verified \(fileName) (\(Format.bytes(totalSize))) → \(finalURL.path)")
            return
        }

        let fileHandle: FileHandle
        if resumeOffset == 0 {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            fileHandle = try FileHandle(forWritingTo: partURL)
        } else {
            fileHandle = try FileHandle(forUpdating: partURL)
            try fileHandle.seek(toOffset: resumeOffset)
            let pct = totalSize > 0 ? Int((Double(resumeOffset) / Double(totalSize)) * 100) : 0
            print("Resuming \(fileName) from \(Format.bytes(resumeOffset)) (\(pct)%)...")
        }

        if resumeOffset == 0 {
            print("Pulling \(fileName) (\(Format.bytes(totalSize)))...")
        }

        let chunkSize = UInt64(chunkMiB) << 20
        var currentOffset = resumeOffset
        var lastProgressTime = ContinuousClock.now
        let transferStart = ContinuousClock.now

        while currentOffset < totalSize {
            let toRead = min(chunkSize, totalSize - currentOffset)
            let chunkData: Data
            do {
                chunkData = try await readData(from: file, offset: off_t(currentOffset), length: off_t(toRead))
            } catch {
                try? fileHandle.synchronize()
                try? fileHandle.close()
                print("\nError reading at offset \(currentOffset) (\(Format.bytes(currentOffset)) of \(Format.bytes(totalSize))): \(error.localizedDescription)")
                print("Partial file preserved: \(partURL.path)")
                print("Run the same command again to resume.")
                throw ExitCode.failure
            }

            guard !chunkData.isEmpty else {
                try? fileHandle.synchronize()
                try? fileHandle.close()
                print("\nPremature end of data at offset \(currentOffset) (\(Format.bytes(currentOffset)) of \(Format.bytes(totalSize))).")
                print("Partial file preserved: \(partURL.path)")
                print("Run the same command again to resume.")
                throw ExitCode.failure
            }

            try fileHandle.write(contentsOf: chunkData)
            currentOffset += UInt64(chunkData.count)

            let now = ContinuousClock.now
            if now - lastProgressTime >= .seconds(1) || currentOffset == totalSize {
                let elapsed = (now - transferStart).seconds
                let bytesTransferred = currentOffset - resumeOffset
                let rate = elapsed > 0 ? Double(bytesTransferred) / elapsed : 0
                let pct = totalSize > 0 ? Int((Double(currentOffset) / Double(totalSize)) * 100) : 100
                let remaining = totalSize - currentOffset
                let eta = rate > 0 ? Format.duration(Double(remaining) / rate) : "--"
                print(String(
                    format: "\r\u{1B}[K%3d%%  %@ / %@  %@  ETA %@",
                    pct,
                    Format.bytes(currentOffset),
                    Format.bytes(totalSize),
                    Format.rate(rate),
                    eta
                ), terminator: "")
                fflush(stdout)
                lastProgressTime = now
            }
        }

        try fileHandle.synchronize()
        try fileHandle.close()

        // Verification against catalogue size
        let finalAttrs = try FileManager.default.attributesOfItem(atPath: partURL.path)
        let actualSize = finalAttrs[.size] as? UInt64 ?? 0
        guard actualSize == totalSize else {
            print("\nVerification failed: downloaded \(actualSize) bytes, catalogue reports \(totalSize) bytes.")
            print("Partial file preserved: \(partURL.path)")
            throw ExitCode.failure
        }

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: partURL, to: finalURL)
        print("\nVerified and copied \(fileName) (\(Format.bytes(totalSize))) → \(finalURL.path)")
    }
}

// MARK: - Supporting Helpers

/// Selects a single camera device using the browser.
private func selectCamera(deviceName: String?, timeout: Double) async throws -> (ICCBrowser, ICCameraDevice) {
    let browser = ICCBrowser()
    let cameras = try await browser.discover(timeout: timeout)

    if let deviceName {
        guard let match = cameras.first(where: {
            ($0.name ?? "").localizedCaseInsensitiveContains(deviceName) ||
            ($0.serialNumberString ?? "").localizedCaseInsensitiveContains(deviceName)
        }) else {
            browser.stop()
            throw ValidationError("No camera matches '\(deviceName)'. Available: " + cameras.compactMap(\.name).joined(separator: ", "))
        }
        return (browser, match)
    }

    if cameras.count > 1 {
        let first = cameras[0]
        Log.note("Multiple cameras connected; using '\(first.name ?? "device")' (choose with --device).")
        return (browser, first)
    }

    return (browser, cameras[0])
}

extension ICDevice: @unchecked @retroactive Sendable {}
extension ICCameraItem: @unchecked @retroactive Sendable {}

/// Protects an async continuation so it is resumed exactly once.
final class OnceContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: sending T) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Browser wrapper for discovering local camera devices on the main run loop.
final class ICCBrowser: NSObject, ICDeviceBrowserDelegate, @unchecked Sendable {
    private let browser = ICDeviceBrowser()
    private let lock = NSLock()
    private var cameras: [ICCameraDevice] = []
    private var once: OnceContinuation<[ICCameraDevice]>?
    private var timer: (any DispatchSourceTimer)?
    private var enumerationCompleted = false

    func authorisationReport() -> String {
        var lines: [String] = []
        let contentsSel = NSSelectorFromString("requestContentsAuthorizationWithCompletion:")
        let controlSel = NSSelectorFromString("requestControlAuthorizationWithCompletion:")
        if browser.responds(to: contentsSel) {
            lines.append("  requestContentsAuthorization: supported")
        } else {
            lines.append("  requestContentsAuthorization: unavailable on macOS (iOS-only API)")
        }
        if browser.responds(to: controlSel) {
            lines.append("  requestControlAuthorization:  supported")
        } else {
            lines.append("  requestControlAuthorization:  unavailable on macOS (iOS-only API)")
        }
        if let val = browser.value(forKey: "contentsAuthorizationStatus") {
            lines.append("  contentsAuthorizationStatus:  \(val)")
        } else {
            lines.append("  contentsAuthorizationStatus:  none")
        }
        if let val = browser.value(forKey: "controlAuthorizationStatus") {
            lines.append("  controlAuthorizationStatus:   \(val)")
        } else {
            lines.append("  controlAuthorizationStatus:   none")
        }
        return lines.joined(separator: "\n")
    }

    func discover(timeout: TimeInterval) async throws -> [ICCameraDevice] {
        try await withCheckedThrowingContinuation { cont in
            let onceGate = OnceContinuation(cont)
            lock.lock()
            self.cameras.removeAll()
            self.enumerationCompleted = false
            self.once = onceGate
            lock.unlock()

            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let found = self.cameras
                self.lock.unlock()
                if found.isEmpty {
                    onceGate.resume(throwing: CLIError(
                        "No camera device found within \(Int(timeout)) s. Unlock the phone, plug it in with a data cable, and choose \"File transfer\" or \"Transferring images\"."
                    ))
                } else {
                    onceGate.resume(returning: found)
                }
            }
            self.timer = timer
            timer.resume()

            DispatchQueue.main.async {
                self.browser.delegate = self
                let mask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
                self.browser.browsedDeviceTypeMask = mask
                self.browser.start()
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        DispatchQueue.main.async {
            self.browser.stop()
            self.browser.delegate = nil
        }
    }

    // MARK: - ICDeviceBrowserDelegate

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        lock.lock()
        if let camera = device as? ICCameraDevice {
            if !cameras.contains(where: { $0 === camera }) {
                cameras.append(camera)
            }
        }
        let shouldFinish = (!moreComing && enumerationCompleted && !cameras.isEmpty)
        let found = cameras
        lock.unlock()

        if shouldFinish {
            timer?.cancel()
            timer = nil
            once?.resume(returning: found)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        lock.lock()
        if let camera = device as? ICCameraDevice {
            cameras.removeAll(where: { $0 === camera })
        }
        lock.unlock()
    }

    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        lock.lock()
        enumerationCompleted = true
        let hasCameras = !cameras.isEmpty
        let found = cameras
        lock.unlock()

        if hasCameras {
            timer?.cancel()
            timer = nil
            once?.resume(returning: found)
        }
    }
}

/// Manages an ICCameraDevice session and awaits complete content catalogue enumeration.
final class ICCameraSession: NSObject, ICCameraDeviceDelegate, @unchecked Sendable {
    let device: ICCameraDevice
    private let lock = NSLock()
    private var openContinuation: OnceContinuation<Duration>?
    private var sessionOpenStart: ContinuousClock.Instant?

    init(device: ICCameraDevice) {
        self.device = device
        super.init()
    }

    func open(catalogTimeout: TimeInterval = 60) async throws -> Duration {
        try await withCheckedThrowingContinuation { cont in
            let once = OnceContinuation(cont)
            lock.lock()
            self.openContinuation = once
            self.sessionOpenStart = ContinuousClock.now
            lock.unlock()

            DispatchQueue.main.async {
                self.device.delegate = self
                self.device.requestOpenSession()
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + catalogTimeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let waiting = (self.openContinuation != nil)
                self.lock.unlock()
                if waiting {
                    once.resume(throwing: CLIError("Timed out waiting for content catalogue after \(Int(catalogTimeout)) s."))
                }
            }
        }
    }

    func close() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            guard device.hasOpenSession else {
                lock.unlock()
                cont.resume()
                return
            }
            lock.unlock()

            device.requestCloseSession(options: nil) { [weak self] _ in
                guard let self else {
                    cont.resume()
                    return
                }
                DispatchQueue.main.async {
                    self.device.delegate = nil
                }
                cont.resume()
            }
        }
    }

    // MARK: - ICCameraDeviceDelegate & ICDeviceDelegate

    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error {
            lock.lock()
            let once = openContinuation
            openContinuation = nil
            lock.unlock()
            once?.resume(throwing: error)
        }
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        lock.lock()
        let start = sessionOpenStart ?? ContinuousClock.now
        let duration = ContinuousClock.now - start
        let once = openContinuation
        openContinuation = nil
        lock.unlock()
        once?.resume(returning: duration)
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        lock.lock()
        let once = openContinuation
        openContinuation = nil
        lock.unlock()
        if let once {
            let err = error ?? CLIError("Camera session closed before catalogue enumeration completed.")
            once.resume(throwing: err)
        }
    }

    func didRemove(_ device: ICDevice) {
        lock.lock()
        let once = openContinuation
        openContinuation = nil
        lock.unlock()
        once?.resume(throwing: CLIError("Camera device was disconnected."))
    }

    func device(_ device: ICDevice, didEncounterError error: (any Error)?) {
        if let error {
            lock.lock()
            let once = openContinuation
            openContinuation = nil
            lock.unlock()
            once?.resume(throwing: error)
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable : Any]?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

/// Reads a byte range from a camera file with single-resumption guarantee.
private func readData(from file: ICCameraFile, offset: off_t, length: off_t) async throws -> Data {
    try await withCheckedThrowingContinuation { cont in
        let once = OnceContinuation(cont)
        file.requestReadData(atOffset: offset, length: length) { data, error in
            if let error {
                once.resume(throwing: error)
            } else if let data {
                once.resume(returning: data)
            } else {
                once.resume(throwing: CLIError("Read returned neither data nor error at offset \(offset)."))
            }
        }
    }
}

/// Returns the canonical path of an item built by walking up its parent folders.
private func canonicalPath(of item: ICCameraItem) -> String {
    var parts: [String] = []
    if let name = item.name, !name.isEmpty {
        parts.append(name)
    }
    var parent = item.parentFolder
    while let p = parent {
        if let pName = p.name, !pName.isEmpty {
            parts.append(pName)
        }
        parent = p.parentFolder
    }
    return parts.reversed().joined(separator: "/")
}

/// Recursively collects all unique files present in the camera device.
private func allFiles(in device: ICCameraDevice) -> [ICCameraFile] {
    var result: [ICCameraFile] = []
    var seen = Set<ObjectIdentifier>()

    func collect(from items: [ICCameraItem]) {
        for item in items {
            if let file = item as? ICCameraFile {
                if seen.insert(ObjectIdentifier(file)).inserted {
                    result.append(file)
                }
            } else if let folder = item as? ICCameraFolder {
                if let contents = folder.contents {
                    collect(from: contents)
                }
            }
        }
    }

    if let contents = device.contents {
        collect(from: contents)
    }
    if let mediaFiles = device.mediaFiles {
        for item in mediaFiles {
            if let file = item as? ICCameraFile {
                if seen.insert(ObjectIdentifier(file)).inserted {
                    result.append(file)
                }
            }
        }
    }
    return result
}

/// Searches for a file in the camera catalogue matching a user-provided path.
private func findFile(in device: ICCameraDevice, path: String) -> ICCameraFile? {
    let files = allFiles(in: device)
    let cleaned = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    // 1. Exact canonical path match
    if let exact = files.first(where: { canonicalPath(of: $0) == cleaned }) {
        return exact
    }
    // 2. Suffix match (e.g. user omitted top-level storage folder)
    if let suffix = files.first(where: { canonicalPath(of: $0).hasSuffix("/" + cleaned) }) {
        return suffix
    }
    // 3. Case-insensitive match
    if let caseInsensitive = files.first(where: {
        canonicalPath(of: $0).localizedCaseInsensitiveCompare(cleaned) == .orderedSame
    }) {
        return caseInsensitive
    }
    // 4. Unique filename match if only a name was passed
    let nameOnly = (cleaned as NSString).lastPathComponent
    let nameMatches = files.filter { $0.name == nameOnly }
    if nameMatches.count == 1 {
        return nameMatches[0]
    }

    return nil
}

/// Classifies an item as an image, video, or other media type.
private func classify(item: ICCameraItem) -> (isImage: Bool, isVideo: Bool) {
    if let uti = item.uti, let ut = UTType(uti) {
        if ut.conforms(to: .image) { return (true, false) }
        if ut.conforms(to: .movie) || ut.conforms(to: .audiovisualContent) { return (false, true) }
    }
    let ext = (item.name as NSString?)?.pathExtension.lowercased() ?? ""
    let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "dng", "raw", "cr2", "nef", "webp"]
    let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "3gp", "webm"]
    if imageExts.contains(ext) { return (true, false) }
    if videoExts.contains(ext) { return (false, true) }
    return (false, false)
}

/// Totals accumulated during catalogue inspection.
private struct ItemTotals {
    var files: Int = 0
    var bytes: UInt64 = 0
    var images: Int = 0
    var videos: Int = 0
    var other: Int = 0
}

/// Recursively prints an item hierarchy and accumulates catalogue totals.
private func printTree(
    items: [ICCameraItem],
    currentDepth: Int,
    maxDepth: Int?,
    totals: inout ItemTotals,
    seenFiles: inout Set<ObjectIdentifier>
) {
    let indent = String(repeating: "  ", count: currentDepth)
    for item in items {
        if let folder = item as? ICCameraFolder {
            let folderName = folder.name ?? "unnamed"
            if maxDepth == nil || currentDepth <= maxDepth! {
                print("\(indent)\(folderName)/")
            }
            if let children = folder.contents, !children.isEmpty {
                printTree(
                    items: children,
                    currentDepth: currentDepth + 1,
                    maxDepth: maxDepth,
                    totals: &totals,
                    seenFiles: &seenFiles
                )
            }
        } else if let file = item as? ICCameraFile {
            let fileID = ObjectIdentifier(file)
            if seenFiles.insert(fileID).inserted {
                totals.files += 1
                totals.bytes += UInt64(max(0, file.fileSize))
                let (isImg, isVid) = classify(item: file)
                if isImg {
                    totals.images += 1
                } else if isVid {
                    totals.videos += 1
                } else {
                    totals.other += 1
                }
            }
            if maxDepth == nil || currentDepth <= maxDepth! {
                let name = file.name ?? "unnamed"
                let sizeStr = Format.bytes(UInt64(max(0, file.fileSize)))
                let uti = file.uti ?? "data"
                let dateStr = file.creationDate?.formatted(
                    .iso8601.year().month().day().time(includingFractionalSeconds: false)
                ) ?? "--"
                print("\(indent)\(name)  \(sizeStr)  \(uti)  \(dateStr)")
            }
        }
    }
}
