public import Foundation

/// The versioned vocabulary between Pulli.app and the background helper (docs/DECISIONS.md, D-010).
///
/// Versioning rules:
/// - `major` must match exactly; on mismatch the app restarts the helper it ships with.
/// - `minor` is additive only: new cases and new optional fields. Receivers ignore what they do
///   not know (unknown enum cases decode as `.unknown` where marked).
/// - `ClientHello` / `HelperHello` never change shape.
public enum PulliProtocolVersion {
    public static let major: UInt16 = 1
    public static let minor: UInt16 = 6

    /// The short marketing version ("0.4.0").
    public static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.4.0"
    }

    /// The build timestamp ("20261015095845").
    public static var buildVersion: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "dev"
    }

    /// The git commit hash for this build, stored in PulliCommit in Info.plist.
    public static var commit: String? {
        Bundle.main.infoDictionary?["PulliCommit"] as? String
    }

    /// This build of Pulli ("0.4.0 (20261015095845)"), the same for the app and its
    /// helper when they come from one bundle. A helper reporting anything else is from another
    /// build and is replaced.
    public static var build: String {
        "\(shortVersion) (\(buildVersion))"
    }
}

// MARK: - Handshake

public struct ClientHello: Codable, Sendable, Hashable {
    public var major: UInt16
    public var minor: UInt16
    public var clientName: String

    public init(clientName: String) {
        major = PulliProtocolVersion.major
        minor = PulliProtocolVersion.minor
        self.clientName = clientName
    }
}

public struct HelperHello: Codable, Sendable, Hashable {
    public var major: UInt16
    public var minor: UInt16
    public var helperVersion: String
    /// Changes every time the helper starts. With `EventCursor`, lets a reconnecting client tell a
    /// restarted helper (take a fresh snapshot) from a brief disconnect (replay missed events).
    public var instanceID: UUID

    public init(helperVersion: String, instanceID: UUID) {
        major = PulliProtocolVersion.major
        minor = PulliProtocolVersion.minor
        self.helperVersion = helperVersion
        self.instanceID = instanceID
    }
}

// MARK: - State the UI shows

public enum LinkSpeed: String, Codable, Sendable, Hashable {
    case usb1, usb2, usb3, unknown
}

/// What a phone is doing, as the Connect screens show it.
public enum DeviceState: Codable, Sendable, Hashable {
    case connecting
    case ready
    /// No storage visible: locked, or "Allow access" not tapped yet.
    case locked
    /// Plugged in, but in "Charging only" (or another non-file) USB mode.
    case notInFileTransferMode
    /// Another app has the phone (Photos, Smart Switch, …); the UI asks the user to quit it.
    case heldBy(appName: String)
    /// The phone stopped responding and needs to be unplugged and plugged back in.
    case needsReplug
    case unknown
}

public struct StorageSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: UInt32
    public var name: String
    public var capacityBytes: UInt64?
    public var freeBytes: UInt64?

    public init(id: UInt32, name: String, capacityBytes: UInt64?, freeBytes: UInt64?) {
        self.id = id
        self.name = name
        self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes
    }
}

/// An offered step-down in read chunk size for a phone that keeps failing partial reads (1.2).
public struct ChunkSuggestion: Codable, Sendable, Hashable {
    public var deviceID: String
    public var currentMiB: Int
    public var suggestedMiB: Int
    public var failures: Int

    public init(deviceID: String, currentMiB: Int, suggestedMiB: Int, failures: Int) {
        self.deviceID = deviceID
        self.currentMiB = currentMiB
        self.suggestedMiB = suggestedMiB
        self.failures = failures
    }
}

public struct DeviceSnapshot: Codable, Sendable, Hashable, Identifiable {
    /// `DeviceKey.description`: stable across cables, ports and reboots.
    public var id: String
    public var name: String
    public var model: String?
    public var manufacturer: String?
    public var link: LinkSpeed
    public var linkBitsPerSecond: UInt64?
    public var state: DeviceState
    public var storages: [StorageSnapshot]
    /// False for phones that can only copy whole files (resume restarts such files).
    public var resumable: Bool
    /// How fast this connection is, and whether a better cable or port would help.
    public var cable: CableAdvice?
    /// Offered step-down when large reads keep failing on this phone (1.2).
    public var chunkSuggestion: ChunkSuggestion?
    /// Raised when the phone reports that its contents or catalogue changed (1.5).
    public var contentRevision: UInt64?
    /// How much of the photo list Image Capture has delivered while the phone opens, 0-100 (1.6).
    public var catalogueProgress: Int?

    public init(id: String, name: String, model: String?, manufacturer: String?, link: LinkSpeed, linkBitsPerSecond: UInt64?,
                state: DeviceState, storages: [StorageSnapshot], resumable: Bool, cable: CableAdvice? = nil,
                chunkSuggestion: ChunkSuggestion? = nil, contentRevision: UInt64? = nil, catalogueProgress: Int? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.manufacturer = manufacturer
        self.link = link
        self.linkBitsPerSecond = linkBitsPerSecond
        self.state = state
        self.storages = storages
        self.resumable = resumable
        self.cable = cable
        self.chunkSuggestion = chunkSuggestion
        self.contentRevision = contentRevision
        self.catalogueProgress = catalogueProgress
    }
}

/// What the connection allows now, and what a better cable or port would give (owner request,
/// 2026-09-27: show the cable's USB version, encourage a better one, predict the speed).
public struct CableAdvice: Codable, Sendable, Hashable {
    public enum Suggestion: String, Codable, Sendable, Hashable {
        /// Already as fast as this phone goes.
        case none
        /// Connected through a hub, monitor or dock: plug directly into the Mac.
        case plugDirectly
        /// The phone supports USB 3 but connected at USB 2: use a USB 3 or Thunderbolt cable.
        case useUSB3Cable
        /// Connected at USB 2; the phone may support USB 3 (model not known to Pulli).
        case mayBeFaster
    }

    public var link: LinkSpeed
    /// The fastest link this phone model supports, when Pulli knows the model.
    public var phoneSupports: LinkSpeed?
    public var throughHub: Bool
    public var suggestion: Suggestion
    /// Expected copy speed on the current link: measured on this phone when available.
    public var bytesPerSecond: Double
    /// Expected speed with a USB 3 cable plugged directly into the Mac, if that would be faster.
    public var fasterBytesPerSecond: Double?
    /// Whether `bytesPerSecond` was measured on this phone (vs a typical value).
    public var measured: Bool

    public init(link: LinkSpeed, phoneSupports: LinkSpeed?, throughHub: Bool, suggestion: Suggestion,
                bytesPerSecond: Double, fasterBytesPerSecond: Double?, measured: Bool) {
        self.link = link
        self.phoneSupports = phoneSupports
        self.throughHub = throughHub
        self.suggestion = suggestion
        self.bytesPerSecond = bytesPerSecond
        self.fasterBytesPerSecond = fasterBytesPerSecond
        self.measured = measured
    }

    /// Seconds to copy `bytes` now, and with the faster setup (nil if it would not be faster).
    public func duration(ofBytes bytes: UInt64) -> (now: Double, faster: Double?) {
        let now = Double(bytes) / max(bytesPerSecond, 1)
        return (now, fasterBytesPerSecond.map { Double(bytes) / max($0, 1) })
    }
}

/// Why a batch is not moving. Never a failure: each clears itself (or by the user's action).
public enum PauseReason: Codable, Sendable, Hashable {
    case byUser
    case phoneDisconnected
    case phoneLocked
    case notInFileTransferMode
    case heldBy(appName: String)
    case destinationFull
    case destinationUnavailable(detail: String)
    case retrying(secondsLeft: Int, detail: String)
    /// Waiting for another batch on the same phone to finish.
    case queued
    case unknown
}

public enum BatchPhase: Codable, Sendable, Hashable {
    case scanning
    case copying
    case paused(PauseReason)
    case completed
    case cancelled
    case unknown
}

public struct FileSnapshot: Codable, Sendable, Hashable {
    public var jobID: Int64
    public var name: String
    public var sizeBytes: UInt64
    public var bytesDone: UInt64
    public var state: FileState

    public enum FileState: String, Codable, Sendable, Hashable {
        case waiting, copying, done, skipped, needsAttention, cancelled
    }

    public init(jobID: Int64, name: String, sizeBytes: UInt64, bytesDone: UInt64, state: FileState) {
        self.jobID = jobID
        self.name = name
        self.sizeBytes = sizeBytes
        self.bytesDone = bytesDone
        self.state = state
    }
}

/// One copy, as the Copy, Paused and Done screens and the menu bar show it.
public struct BatchSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64
    public var deviceID: String
    public var deviceName: String
    /// Short description of what is copied, e.g. "Camera" or "DCIM, Download".
    public var title: String
    public var destinationPath: String
    public var phase: BatchPhase
    public var filesTotal: Int
    public var filesDone: Int
    public var filesSkipped: Int
    public var filesNeedingAttention: Int
    public var bytesTotal: UInt64
    public var bytesDone: UInt64
    public var bytesPerSecond: Double
    public var secondsRemaining: Double?
    public var current: FileSnapshot?
    /// Most recent first, at most `BatchSnapshot.recentLimit`.
    public var recent: [FileSnapshot]
    public var createdAt: Date
    public var finishedAt: Date?

    public static let recentLimit = 8

    public init(id: Int64, deviceID: String, deviceName: String, title: String, destinationPath: String, phase: BatchPhase,
                filesTotal: Int, filesDone: Int, filesSkipped: Int, filesNeedingAttention: Int, bytesTotal: UInt64,
                bytesDone: UInt64, bytesPerSecond: Double, secondsRemaining: Double?, current: FileSnapshot?,
                recent: [FileSnapshot], createdAt: Date, finishedAt: Date?) {
        self.id = id
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.title = title
        self.destinationPath = destinationPath
        self.phase = phase
        self.filesTotal = filesTotal
        self.filesDone = filesDone
        self.filesSkipped = filesSkipped
        self.filesNeedingAttention = filesNeedingAttention
        self.bytesTotal = bytesTotal
        self.bytesDone = bytesDone
        self.bytesPerSecond = bytesPerSecond
        self.secondsRemaining = secondsRemaining
        self.current = current
        self.recent = recent
        self.createdAt = createdAt
        self.finishedAt = finishedAt
    }

    public var fractionDone: Double {
        bytesTotal == 0 ? (phase == .completed ? 1 : 0) : Double(bytesDone) / Double(bytesTotal)
    }
}

/// Everything the UI needs at once: every phone and every copy (the menu bar lists them all).
public struct Snapshot: Codable, Sendable, Hashable {
    public var devices: [DeviceSnapshot]
    public var batches: [BatchSnapshot]
    public var settings: HelperSettings

    public init(devices: [DeviceSnapshot], batches: [BatchSnapshot], settings: HelperSettings) {
        self.devices = devices
        self.batches = batches
        self.settings = settings
    }
}

public struct HelperSettings: Codable, Sendable, Hashable {
    public var defaultDestination: String?
    /// `DuplicatePolicy` raw value: auto, skip, overwrite, keep_both.
    public var duplicatePolicy: String
    public var chunkMiB: Int
    public var releaseSystemCameraService: Bool
    public var keepMacAwake: Bool
    /// "year_month" or nil (keep the phone's folders) (1.1).
    public var organize: String?
    /// Finder may delete and rename on the phone drive (1.1); off by default.
    public var allowDriveChanges: Bool?
    /// Override chunk size in MiB per phone ID (1.2).
    public var chunkMiBByDevice: [String: Int]?

    public init(defaultDestination: String? = nil, duplicatePolicy: String = "auto", chunkMiB: Int = 8,
                releaseSystemCameraService: Bool = true, keepMacAwake: Bool = true, organize: String? = nil,
                chunkMiBByDevice: [String: Int]? = nil) {
        self.organize = organize
        self.defaultDestination = defaultDestination
        self.duplicatePolicy = duplicatePolicy
        self.chunkMiB = chunkMiB
        self.releaseSystemCameraService = releaseSystemCameraService
        self.keepMacAwake = keepMacAwake
        self.chunkMiBByDevice = chunkMiBByDevice
    }

    /// Effective chunk size for a phone: its override if set, else the global default.
    public func chunkMiB(for deviceID: String) -> Int {
        chunkMiBByDevice?[deviceID] ?? chunkMiB
    }
}

// MARK: - Requests and replies

public struct FolderEntry: Codable, Sendable, Hashable {
    public var name: String
    public var isFolder: Bool
    public var sizeBytes: UInt64
    /// The phone's wall-clock modification time, encoded as UTC.
    public var modifiedWallClock: Int64

    public init(name: String, isFolder: Bool, sizeBytes: UInt64, modifiedWallClock: Int64) {
        self.name = name
        self.isFolder = isFolder
        self.sizeBytes = sizeBytes
        self.modifiedWallClock = modifiedWallClock
    }
}

public struct CreateBatchRequest: Codable, Sendable, Hashable {
    public var deviceID: String
    public var storageID: UInt32
    /// Slash-separated paths on the phone; files and folders.
    public var paths: [String]
    public var destinationPath: String
    /// nil: the helper's default.
    public var duplicatePolicy: String?
    /// "year_month" puts files in YYYY/MM folders by date; nil: the helper's default (1.1).
    public var organize: String?

    public init(deviceID: String, storageID: UInt32, paths: [String], destinationPath: String, duplicatePolicy: String? = nil,
                organize: String? = nil) {
        self.deviceID = deviceID
        self.storageID = storageID
        self.paths = paths
        self.destinationPath = destinationPath
        self.duplicatePolicy = duplicatePolicy
        self.organize = organize
    }
}

public enum BatchCommand: Codable, Sendable, Hashable {
    case pause
    case resume
    case cancel(discardPartialFiles: Bool)
    case retryNeedsAttention
    /// Forget a finished or cancelled batch (its files stay on disk).
    case remove
}

public struct LogEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64
    public var date: Date
    /// 1 info, 2 notice, 3 warning, 4 error.
    public var level: Int
    public var kind: String
    public var message: String
    public var batchID: Int64?

    public init(id: Int64, date: Date, level: Int, kind: String, message: String, batchID: Int64?) {
        self.id = id
        self.date = date
        self.level = level
        self.kind = kind
        self.message = message
        self.batchID = batchID
    }
}

public enum ClientRequest: Codable, Sendable, Hashable {
    case hello(ClientHello)
    /// Start receiving events. With a cursor from the same helper instance, missed events are
    /// replayed when still buffered; otherwise the reply is a fresh snapshot.
    case subscribe(since: EventCursor?)
    /// Lists one folder; entries arrive as `.folderPage` events tagged with `browseID`.
    case listFolder(deviceID: String, storageID: UInt32, path: String, browseID: UUID)
    case cancelBrowse(browseID: UUID)
    case createBatch(CreateBatchRequest)
    case control(batchID: Int64, BatchCommand)
    case needsAttention(batchID: Int64)
    case log(afterID: Int64?, limit: Int)
    case setSettings(HelperSettings)
    /// The app is showing phones (window open): attached phones are opened to show their state.
    /// While false, a phone is only opened when a copy needs it, so Pulli does not take phones
    /// away from other apps in the background.
    case setWatchingDevices(Bool)
    /// Stop gracefully before an update replaces the helper.
    case prepareForUpdate
    /// The phone's small preview of a file (1.1). Reply: `.thumbnail`, nil when there is none.
    case thumbnail(deviceID: String, storageID: UInt32, path: String)
    /// Totals of whole folder trees (1.1). Reply: `.measured`.
    case measure(deviceID: String, storageID: UInt32, paths: [String])
    /// Maps what fills the phone (1.1); progress arrives as `.storageScan` events.
    case scanStorage(deviceID: String, storageID: UInt32, scanID: UUID)
    case cancelScan(scanID: UUID)
    /// Copies one file to a local path, for Quick Look (1.1). Reply: `.ok` when it is there.
    case fetchFile(deviceID: String, storageID: UInt32, path: String, destination: String)
    /// Which of these phone files are already on the Mac, by content (1.1). Reply: `.duplicates`.
    case findDuplicates(deviceID: String, storageID: UInt32, paths: [String], macFolders: [String])
    /// Copies Mac files and folders into a phone folder (1.1); progress arrives as `.upload` events.
    case upload(deviceID: String, storageID: UInt32, localPaths: [String], destination: String, uploadID: UUID)
    /// Re-reads a finished copy's files from the phone and compares them with the Mac copies
    /// (1.1); progress arrives as `.verification` events.
    case verify(batchID: Int64, verifyID: UUID)
    /// Deletes from the phone the files the last `verify` of this batch found identical (1.1).
    /// Reply: `.deleted`.
    case deleteVerified(batchID: Int64)
    /// Serves the phone as a local WebDAV drive for Finder (1.1). Reply: `.drive(url:)`.
    case startDrive(deviceID: String)
    case stopDrive(deviceID: String)
    /// Accept or decline a suggested smaller chunk size for a struggling phone (1.2).
    case applyChunkSuggestion(deviceID: String, accept: Bool)
    /// Records a message in the activity log (minor 3: an older helper answers with an error,
    /// which the app ignores).
    case recordLog(level: Int, kind: String, message: String)
    /// Forgets past copies, activity log entries, and temporary previews and thumbnails (1.4).
    case clearHistory
}

public struct AttentionItem: Codable, Sendable, Hashable {
    public var jobID: Int64
    public var path: String
    public var reason: String

    public init(jobID: Int64, path: String, reason: String) {
        self.jobID = jobID
        self.path = path
        self.reason = reason
    }
}

public enum HelperReply: Codable, Sendable, Hashable {
    case hello(HelperHello)
    case snapshot(Snapshot, cursor: EventCursor)
    /// Missed events since the client's cursor, then live events follow.
    case replay([SequencedEvent])
    case ok
    case batchCreated(batchID: Int64)
    case needsAttention([AttentionItem])
    case log([LogEntry])
    /// A JPEG preview, or nil (1.1).
    case thumbnail(Data?)
    case measured([FolderMeasure])
    case duplicates([DuplicateMatch])
    case deleted(DeleteSummary)
    /// The drive's address, for Finder to mount (http://127.0.0.1:port/token/Name/).
    case drive(url: String)
    case error(PulliError)
}

public struct PulliError: Codable, Sendable, Hashable, Error, CustomStringConvertible {
    public enum Code: String, Codable, Sendable, Hashable {
        case versionMismatch, notFound, invalidRequest, deviceUnavailable, internalError, unknown
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code.rawValue): \(message)" }
}

// MARK: - Events (helper to app)

public struct EventCursor: Codable, Sendable, Hashable {
    public var instanceID: UUID
    public var sequence: UInt64

    public init(instanceID: UUID, sequence: UInt64) {
        self.instanceID = instanceID
        self.sequence = sequence
    }
}

public enum HelperEvent: Codable, Sendable, Hashable {
    case deviceChanged(DeviceSnapshot)
    case deviceRemoved(id: String)
    case batchChanged(BatchSnapshot)
    case batchRemoved(id: Int64)
    case settingsChanged(HelperSettings)
    /// Lossy, never sequenced: a page of a folder listing.
    case folderPage(browseID: UUID, entries: [FolderEntry], done: Bool, error: String?)
    /// Lossy (1.1): progress of the operations started by `scanStorage`, `upload` and `verify`.
    case storageScan(StorageScan)
    case upload(UploadProgress)
    case verification(VerifyProgress)
    case helperWillExit(reason: String)
}

/// Sequenced events can be replayed after a brief disconnect; lossy ones (`folderPage`) carry no
/// sequence number.
public struct SequencedEvent: Codable, Sendable, Hashable {
    public var sequence: UInt64?
    public var event: HelperEvent

    public init(sequence: UInt64?, event: HelperEvent) {
        self.sequence = sequence
        self.event = event
    }
}

// MARK: - Phone tools (1.1)

public struct FolderMeasure: Codable, Sendable, Hashable {
    public var path: String
    public var exists: Bool
    public var files: Int
    public var bytes: UInt64

    public init(path: String, exists: Bool, files: Int, bytes: UInt64) {
        self.path = path
        self.exists = exists
        self.files = files
        self.bytes = bytes
    }
}

/// One folder of the storage map, with its biggest subfolders.
public struct StorageNode: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String
    public var bytes: UInt64
    public var files: Int
    /// Bytes by kind, for the map's detail panel.
    public var images: UInt64
    public var videos: UInt64
    public var audio: UInt64
    public var children: [StorageNode]

    public var id: String { path }

    public init(name: String, path: String, bytes: UInt64, files: Int, images: UInt64, videos: UInt64, audio: UInt64, children: [StorageNode]) {
        self.name = name
        self.path = path
        self.bytes = bytes
        self.files = files
        self.images = images
        self.videos = videos
        self.audio = audio
        self.children = children
    }
}

public struct StorageScan: Codable, Sendable, Hashable {
    public var scanID: UUID
    public var root: StorageNode
    public var foldersScanned: Int
    public var done: Bool
    public var error: String?

    public init(scanID: UUID, root: StorageNode, foldersScanned: Int, done: Bool, error: String?) {
        self.scanID = scanID
        self.root = root
        self.foldersScanned = foldersScanned
        self.done = done
        self.error = error
    }
}

public struct DuplicateMatch: Codable, Sendable, Hashable {
    /// On the phone.
    public var path: String
    /// The same content on the Mac.
    public var macPath: String

    public init(path: String, macPath: String) {
        self.path = path
        self.macPath = macPath
    }
}

public struct UploadProgress: Codable, Sendable, Hashable {
    public var uploadID: UUID
    public var deviceID: String
    public var destination: String
    public var filesDone: Int
    public var filesTotal: Int
    public var bytesDone: UInt64
    public var bytesTotal: UInt64
    public var current: String?
    public var done: Bool
    public var error: String?

    public init(uploadID: UUID, deviceID: String, destination: String, filesDone: Int, filesTotal: Int, bytesDone: UInt64, bytesTotal: UInt64,
                current: String?, done: Bool, error: String?) {
        self.uploadID = uploadID
        self.deviceID = deviceID
        self.destination = destination
        self.filesDone = filesDone
        self.filesTotal = filesTotal
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.current = current
        self.done = done
        self.error = error
    }
}

public struct VerifyProgress: Codable, Sendable, Hashable {
    public struct Item: Codable, Sendable, Hashable {
        public enum Result: String, Codable, Sendable { case identical, different, missingOnPhone, missingOnMac }
        public var name: String
        public var sizeBytes: UInt64
        public var result: Result

        public init(name: String, sizeBytes: UInt64, result: Result) {
            self.name = name
            self.sizeBytes = sizeBytes
            self.result = result
        }
    }

    public var verifyID: UUID
    public var batchID: Int64
    public var filesTotal: Int
    public var bytesTotal: UInt64
    public var bytesChecked: UInt64
    public var identical: Int
    public var identicalBytes: UInt64
    /// Files that cannot be freed (not identical, or missing on one side), for the summary.
    public var problems: [Item]
    /// The last few files checked, most recent first.
    public var recent: [Item]
    public var current: String?
    public var done: Bool
    public var error: String?

    public init(verifyID: UUID, batchID: Int64, filesTotal: Int, bytesTotal: UInt64, bytesChecked: UInt64, identical: Int, identicalBytes: UInt64,
                problems: [Item], recent: [Item], current: String?, done: Bool, error: String?) {
        self.verifyID = verifyID
        self.batchID = batchID
        self.filesTotal = filesTotal
        self.bytesTotal = bytesTotal
        self.bytesChecked = bytesChecked
        self.identical = identical
        self.identicalBytes = identicalBytes
        self.problems = problems
        self.recent = recent
        self.current = current
        self.done = done
        self.error = error
    }
}

public struct DeleteSummary: Codable, Sendable, Hashable {
    public var deleted: Int
    public var bytesFreed: UInt64
    /// Files that were verified but could not be deleted, or changed since.
    public var kept: [String]

    public init(deleted: Int, bytesFreed: UInt64, kept: [String]) {
        self.deleted = deleted
        self.bytesFreed = bytesFreed
        self.kept = kept
    }
}
