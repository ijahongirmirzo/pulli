import FinderLocations
import Foundation
import Testing

/// Tests for FinderLocationHealth: checking responsiveness of Finder location roots and subfolders.
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

    @Test func healthyListingReturnsTrue() async throws {
        let root = URL(fileURLWithPath: "/fake/root")
        let subfolder = root.appendingPathComponent("Folder", isDirectory: true)
        let file = subfolder.appendingPathComponent("photo.jpg")

        let healthy = await FinderLocationHealth.check(root: root) { url in
            if url == root {
                return [subfolder]
            } else if url == subfolder {
                return [file]
            }
            return []
        }
        #expect(healthy)
    }

    @Test func rootThrowsReturnsFalse() async throws {
        let root = URL(fileURLWithPath: "/fake/root")
        struct FakeError: Error {}

        let healthy = await FinderLocationHealth.check(root: root) { _ in
            throw FakeError()
        }
        #expect(!healthy)
    }

    @Test func subfolderThrowsReturnsFalse() async throws {
        let root = URL(fileURLWithPath: "/fake/root")
        let subfolder = root.appendingPathComponent("Folder", isDirectory: true)
        struct FakeError: Error {}

        let healthy = await FinderLocationHealth.check(root: root) { url in
            if url == root {
                return [subfolder]
            }
            throw FakeError()
        }
        #expect(!healthy)
    }

    @Test func blockingListClosureTimesOutQuickly() async throws {
        let root = URL(fileURLWithPath: "/fake/root")
        let start = ContinuousClock.now

        let healthy = await FinderLocationHealth.check(root: root, timeout: .milliseconds(200)) { _ in
            Thread.sleep(forTimeInterval: 2)
            return []
        }
        let elapsed = ContinuousClock.now - start
        #expect(!healthy)
        #expect(elapsed < .milliseconds(600), "returned close to the 200 ms timeout, took \(elapsed)")
    }

    @Test func emptyRootIsHealthy() async throws {
        let root = URL(fileURLWithPath: "/fake/root")
        let healthy = await FinderLocationHealth.check(root: root) { _ in [] }
        #expect(healthy)
    }

    @Test func preferredSubfolderPreferredOverOtherSubfolders() async throws {
        let root = URL(fileURLWithPath: "/fake/root")
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)

        let recorder = Recorder()
        let healthy = await FinderLocationHealth.check(root: root, preferredSubfolder: "Media") { url in
            recorder.add(url)
            if url == root {
                return [docs, media, downloads]
            }
            return [url.appendingPathComponent("file.txt")]
        }
        #expect(healthy)
        #expect(recorder.listed == [root, media])
    }

    @Test func firstSubfolderChosenWhenPreferredSubfolderNotPresent() async throws {
        let root = URL(fileURLWithPath: "/fake/root")
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)

        let recorder = Recorder()
        let healthy = await FinderLocationHealth.check(root: root, preferredSubfolder: "Media") { url in
            recorder.add(url)
            if url == root {
                return [docs, downloads]
            }
            return []
        }
        #expect(healthy)
        #expect(recorder.listed == [root, docs])
    }
}
