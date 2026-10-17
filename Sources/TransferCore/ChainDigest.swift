public import Foundation
import CryptoKit

/// Chained block digest of a file's bytes (docs/DECISIONS.md, D-005/D-006).
///
/// `H_0 = 32 zero bytes`, `H_n = SHA256(H_(n-1) || SHA256(block_n))` over fixed 4 MiB blocks,
/// with a final partial block folded in the same way. Only the 32-byte chain value is stored at
/// each commit (commits are block-aligned), so resuming never needs to re-read committed bytes,
/// and the result does not depend on how reads were chunked.
public struct ChainDigest: Sendable {
    public static let blockSize: UInt64 = 4 << 20
    // A stored format name, written into every journal: it keeps its original (Relay-era)
    // spelling, as renaming it would make existing journals look foreign.
    public static let algorithm = "relay-chain-v1:4MiB:sha256"

    /// Chain value after the last complete block.
    public private(set) var chain: Data
    /// Offset of the end of the last complete block.
    public private(set) var alignedOffset: UInt64

    private var blockHasher = SHA256()
    private var bytesInBlock: UInt64 = 0

    public init() {
        chain = Data(count: 32)
        alignedOffset = 0
    }

    /// Resumes from a committed chain value at a block-aligned offset.
    public init(resumingAt offset: UInt64, chain: Data) {
        precondition(offset % Self.blockSize == 0, "resume offset must be block aligned")
        precondition(chain.count == 32, "chain value must be 32 bytes")
        self.chain = chain
        self.alignedOffset = offset
    }

    /// Total bytes consumed, including the current partial block.
    public var offset: UInt64 { alignedOffset + bytesInBlock }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { buffer in
            var remaining = UnsafeRawBufferPointer(buffer)
            while !remaining.isEmpty {
                let room = Int(Self.blockSize - bytesInBlock)
                let take = min(room, remaining.count)
                blockHasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: remaining.prefix(take)))
                bytesInBlock += UInt64(take)
                remaining = UnsafeRawBufferPointer(rebasing: remaining.dropFirst(take))
                if bytesInBlock == Self.blockSize { closeBlock() }
            }
        }
    }

    /// Digest of everything consumed so far, including a trailing partial block.
    public func finalized() -> Data {
        guard bytesInBlock > 0 else { return chain }
        var copy = self
        copy.closeBlock()
        return copy.chain
    }

    private mutating func closeBlock() {
        let blockDigest = blockHasher.finalize()
        var link = SHA256()
        link.update(data: chain)
        link.update(data: Data(blockDigest))
        chain = Data(link.finalize())
        alignedOffset += bytesInBlock
        bytesInBlock = 0
        blockHasher = SHA256()
    }
}
