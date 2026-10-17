import Foundation
@testable import Pulli
import Testing

/// Tests for Pulli's FinderLocationHealth wrapper: verifies DCIM preference and the dev switch.
@Suite struct FinderLocationHealthTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        var listed: [URL] = []

        func add(_ url: URL) {
            lock.lock()
            listed.append(url)
            lock.unlock()
        }
    }

    @Test func dcimPreferredInPulli() async throws {
        let root = URL(fileURLWithPath: "/fake/root")
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        let dcim = root.appendingPathComponent("DCIM", isDirectory: true)
        let download = root.appendingPathComponent("Download", isDirectory: true)

        let recorder = Recorder()
        let healthy = await FinderLocationHealth.check(root: root) { url in
            recorder.add(url)
            if url == root {
                return [docs, dcim, download]
            }
            return [url.appendingPathComponent("file.txt")]
        }
        #expect(healthy)
        #expect(recorder.listed == [root, dcim])
    }

    @Test func devSwitchFakesErrorOnlyInDefaultPath() async throws {
        setenv("PULLI_FAKE_FINDER_ERROR", "always", 1)
        defer { unsetenv("PULLI_FAKE_FINDER_ERROR") }

        let root = URL(fileURLWithPath: "/fake/root")
        let healthyWithList = await FinderLocationHealth.check(root: root) { _ in [] }
        #expect(healthyWithList, "testable core must ignore PULLI_FAKE_FINDER_ERROR")

        let healthyDefault = await FinderLocationHealth.check(root: root)
        #expect(!healthyDefault, "default path must respect PULLI_FAKE_FINDER_ERROR")
    }
}
