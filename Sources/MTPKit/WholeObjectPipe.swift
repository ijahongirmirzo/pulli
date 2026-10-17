import Foundation

/// Carries a whole-object transfer from libmtp's put callback (on the MTP thread) to an async
/// consumer, with backpressure.
///
/// libmtp pushes small pieces as they arrive over USB; they are gathered into `pieceSize` chunks.
/// When `capacity` chunks are waiting, the producer blocks the MTP thread (which does nothing else
/// during the transfer) until the consumer catches up, so a slow destination cannot make memory
/// grow with the file size.
final class WholeObjectPipe: @unchecked Sendable {
    private let condition = NSCondition()
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data?, any Error>?
    private var ending: Result<Void, any Error>?
    private var cancelled = false
    /// Producer-only: bytes gathered into the next chunk.
    private var pending = Data()

    let capacity: Int
    let pieceSize: Int

    init(capacity: Int = 8, pieceSize: Int = 4 << 20) {
        self.capacity = capacity
        self.pieceSize = pieceSize
    }

    var isCancelled: Bool { condition.withLock { cancelled } }

    // MARK: Producer (MTP thread)

    func append(_ bytes: UnsafeRawBufferPointer) {
        pending.append(contentsOf: bytes)
        if pending.count >= pieceSize {
            push(pending)
            pending = Data()
        }
    }

    func finish(throwing error: (any Error)? = nil) {
        if error == nil, !pending.isEmpty {
            push(pending)
            pending = Data()
        }
        condition.withLock {
            ending = error.map { .failure($0) } ?? .success(())
            if let waiter {
                self.waiter = nil
                if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: nil) }
            }
        }
    }

    private func push(_ piece: Data) {
        condition.lock()
        defer { condition.unlock() }
        while queue.count >= capacity, !cancelled {
            condition.wait()
        }
        guard !cancelled else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: piece)
        } else {
            queue.append(piece)
        }
    }

    // MARK: Consumer

    func next() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                condition.lock()
                defer { condition.unlock() }
                if !queue.isEmpty {
                    continuation.resume(returning: queue.removeFirst())
                    condition.signal()
                } else if let ending {
                    switch ending {
                    case .success: continuation.resume(returning: nil)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                } else if cancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        condition.withLock {
            cancelled = true
            condition.broadcast()
            if let waiter {
                self.waiter = nil
                waiter.resume(throwing: CancellationError())
            }
        }
    }

    /// An async sequence over the pipe. When the consumer drops it, the transfer is cancelled.
    func stream() -> AsyncThrowingStream<Data, any Error> {
        let token = CancelOnRelease(self)
        return AsyncThrowingStream {
            _ = token
            return try await self.next()
        }
    }

    private final class CancelOnRelease: Sendable {
        let pipe: WholeObjectPipe
        init(_ pipe: WholeObjectPipe) { self.pipe = pipe }
        deinit { pipe.cancel() }
    }
}
