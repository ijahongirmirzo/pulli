public import Foundation

/// What the desktop widget shows, written by the app whenever copies change. The widget is
/// sandboxed and cannot ask the engine, so the app writes this file into the widget's container.
public struct WidgetSnapshot: Codable, Sendable, Hashable {
    public struct Copy: Codable, Sendable, Hashable, Identifiable {
        public enum Tint: String, Codable, Sendable { case copying, paused, waiting, done }
        public var id: Int64
        public var device: String
        public var title: String
        public var fraction: Double
        /// "23 s left", "paused", "next".
        public var detail: String
        public var tint: Tint

        public var bytesDone: UInt64?
        public var bytesTotal: UInt64?

        public init(
            id: Int64,
            device: String,
            title: String,
            fraction: Double,
            detail: String,
            tint: Tint,
            bytesDone: UInt64? = nil,
            bytesTotal: UInt64? = nil
        ) {
            self.id = id
            self.device = device
            self.title = title
            self.fraction = fraction
            self.detail = detail
            self.tint = tint
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
        }
    }

    /// The most recent finished copy, shown on the widget when no phone is connected.
    public struct LastCopy: Codable, Sendable, Hashable {
        public var title: String
        public var date: Date
        public var files: Int

        public init(title: String, date: Date, files: Int) {
            self.title = title
            self.date = date
            self.files = files
        }
    }

    public var updated: Date
    public var phone: String?
    /// "USB 2 · 3× faster with USB 3", when a better cable would help.
    public var hint: String?
    public var copies: [Copy]
    /// Total camera items on the phone.
    public var photos: Int?
    /// Items newer than the last copy mark, or nil if Pulli has never copied this phone.
    public var newPhotos: Int?
    /// The most recent finished copy.
    public var lastCopy: LastCopy?

    public init(
        updated: Date,
        phone: String?,
        hint: String?,
        copies: [Copy],
        photos: Int? = nil,
        newPhotos: Int? = nil,
        lastCopy: LastCopy? = nil
    ) {
        self.updated = updated
        self.phone = phone
        self.hint = hint
        self.copies = copies
        self.photos = photos
        self.newPhotos = newPhotos
        self.lastCopy = lastCopy
    }

    public static let widgetBundleID = "app.pulli.mac.widget"

    /// The file inside the widget's sandbox container (what the widget sees as its own
    /// Application Support folder).
    public static var containerFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(widgetBundleID)/Data/Library/Application Support/pulli-widget.json")
    }
}
