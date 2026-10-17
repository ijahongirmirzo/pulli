import Foundation

/// Turns phone file names into safe macOS names and resolves collisions within a folder.
///
/// Android file systems are case-sensitive and accept almost any byte sequence; APFS volumes are
/// usually case-insensitive and treat different Unicode normalisations of a name as the same
/// name. So `IMG.jpg` and `img.jpg`, or an NFC and an NFD "é", can coexist on the phone but not on
/// the Mac. Every change is reported with a reason so it can be recorded in the journal.
public struct NameMapper: Sendable {
    public enum Reason: String, Sendable, Codable {
        case invalidCharacters = "invalid_chars"
        case reserved
        case tooLong = "too_long"
        case caseCollision = "case_collision"
        case unicodeCollision = "unicode_norm"
    }

    /// Room for ".part" and a " (999)" suffix within APFS's 255-byte name limit.
    public static let maxNameBytes = 255 - ".part".utf8.count - " (999)".utf8.count

    public let caseSensitive: Bool

    public init(caseSensitive: Bool = false) {
        self.caseSensitive = caseSensitive
    }

    /// A safe single path component. Returns the reason if the name had to change.
    public static func sanitize(_ name: String) -> (name: String, reason: Reason?) {
        if name.isEmpty { return ("unnamed", .invalidCharacters) }
        if name == "." || name == ".." { return ("_" + name, .reserved) }

        var reason: Reason?
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            // "/" cannot appear in a POSIX name; NUL and control characters break tools and Finder.
            if scalar == "/" || scalar.value < 0x20 || scalar.value == 0x7F {
                scalars.append("_")
                reason = .invalidCharacters
            } else {
                scalars.append(scalar)
            }
        }
        var result = String(scalars)

        if result.utf8.count > maxNameBytes {
            result = truncate(result, toBytes: maxNameBytes)
            reason = reason ?? .tooLong
        }
        return (result, reason)
    }

    /// The identity of a name at the destination: two names with the same key cannot coexist.
    public func key(_ name: String) -> String {
        let normalized = name.decomposedStringWithCanonicalMapping
        return caseSensitive ? normalized : normalized.folding(options: [.caseInsensitive], locale: nil)
    }

    /// Names already taken in one destination folder.
    public struct Scope: Sendable {
        let mapper: NameMapper
        private var taken: [String: String] = [:]

        public init(mapper: NameMapper, existing: [String] = []) {
            self.mapper = mapper
            for name in existing { taken[mapper.key(name)] = name }
        }

        /// Reserves a destination name for `sourceName`, renaming it if it is unsafe or taken.
        public mutating func claim(_ sourceName: String) -> (name: String, key: String, reason: Reason?) {
            var (candidate, reason) = NameMapper.sanitize(sourceName)
            var key = mapper.key(candidate)
            if let clash = taken[key] {
                // Case-insensitively equal after composing: a case clash; otherwise Unicode forms.
                let caseClash = clash.precomposedStringWithCanonicalMapping != candidate.precomposedStringWithCanonicalMapping
                    && clash.precomposedStringWithCanonicalMapping.lowercased() == candidate.precomposedStringWithCanonicalMapping.lowercased()
                reason = reason ?? (caseClash ? .caseCollision : .unicodeCollision)
                var number = 1
                let base = candidate
                repeat {
                    candidate = NameMapper.numbered(base, number)
                    key = mapper.key(candidate)
                    number += 1
                } while taken[key] != nil
            }
            taken[key] = candidate
            return (candidate, key, reason)
        }
    }

    /// "name (n).ext", keeping the extension.
    public static func numbered(_ name: String, _ number: Int) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        // Leading-dot names like ".nomedia" have no base; treat the whole name as the base.
        if base.isEmpty || ext.isEmpty { return "\(name) (\(number))" }
        return "\(base) (\(number)).\(ext)"
    }

    /// Shortens the base name (keeping the extension) to fit in `limit` UTF-8 bytes, cutting only
    /// between whole characters.
    static func truncate(_ name: String, toBytes limit: Int) -> String {
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 32 ? "" : "." + ext
        var base = suffix.isEmpty ? name : (name as NSString).deletingPathExtension
        while base.utf8.count + suffix.utf8.count > limit, !base.isEmpty {
            base.removeLast()
        }
        return base + suffix
    }
}
