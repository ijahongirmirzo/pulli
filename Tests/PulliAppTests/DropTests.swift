import AppKit
import Foundation
@testable import Pulli
import Testing
import UniformTypeIdentifiers

/// What Pulli makes of things dropped (or pasted) from other apps.
@MainActor
struct DropTests {
    @Test func takesFilesAsTheyAre() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = try #require(NSItemProvider(contentsOf: file))
        let received = await AppModel.file(from: provider, into: AppModel.incomingFolder())
        #expect(received?.standardizedFileURL.path == file.standardizedFileURL.path)
    }

    @Test func savesAPictureAppsHandOverAsData() async throws {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        provider.suggestedName = "Sunset"
        let folder = AppModel.incomingFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let received = try #require(await AppModel.file(from: provider, into: folder))
        #expect(received.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(received.pathExtension == "png")
        #expect(try Data(contentsOf: received) == png)
    }
}
