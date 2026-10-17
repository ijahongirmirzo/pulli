import Foundation

/// Runs jobs one at a time on a single, dedicated thread.
///
/// libmtp and its libusb context are not thread safe, and some of libusb's Darwin code keeps
/// per-thread run-loop state, so "serial" is not enough: every call must be on the same thread.
final class DedicatedThreadExecutor: SerialExecutor, @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [UnownedJob] = []
    private var thread: Thread?

    init(name: String) {
        let thread = Thread { [unowned self] in self.runLoop() }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.stackSize = 8 << 20
        self.thread = thread
        thread.start()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    func checkIsolated() {
        precondition(Thread.current === thread, "not on the MTP thread")
    }

    private func runLoop() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let batch = jobs
            jobs.removeAll(keepingCapacity: true)
            condition.unlock()
            for job in batch {
                job.runSynchronously(on: asUnownedSerialExecutor())
            }
        }
    }
}

/// Global actor for all libmtp calls. Everything that touches a libmtp pointer is `@MTPActor`.
@globalActor
public actor MTPActor {
    public static let shared = MTPActor()

    private static let executor = DedicatedThreadExecutor(name: "pulli.mtp")

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self.executor.asUnownedSerialExecutor()
    }
}
