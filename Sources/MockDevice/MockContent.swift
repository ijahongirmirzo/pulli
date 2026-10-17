public import Foundation

/// Deterministic file contents: byte `i` of a file is a pure function of (seed, i).
///
/// Any range of a multi-gigabyte file can be produced without storing it, and tests can compare a
/// copied file against the expected bytes or digest without keeping a reference copy.
public enum MockContent {
    public static func bytes(seed: UInt64, offset: UInt64, count: Int) -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            let out = buffer.bindMemory(to: UInt8.self)
            var position = offset
            var index = 0
            while index < count {
                let word = splitMix(seed &+ (position / 8) &* 0x9E37_79B9_7F4A_7C15)
                var shift = (position % 8) * 8
                while shift < 64, index < count {
                    out[index] = UInt8(truncatingIfNeeded: word >> shift)
                    shift += 8
                    index += 1
                    position += 1
                }
            }
        }
        return data
    }

    static func splitMix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
