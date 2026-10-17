import Foundation
@testable import Pulli
import PulliProtocol
import PulliWidgetViews
import SwiftUI
import Testing
import WidgetKit

@Suite("Widget Tests")
struct WidgetTests {
    @Test("Decodes legacy snapshot JSON without new optional fields")
    func decodesLegacySnapshot() throws {
        let legacyJSON = """
        {
            "updated": 1729000000,
            "phone": "myGalaxy",
            "hint": "USB 2 · 3× faster with USB 3",
            "copies": [
                {
                    "id": 1,
                    "device": "myGalaxy",
                    "title": "Camera",
                    "fraction": 0.62,
                    "detail": "23 s left",
                    "tint": "copying"
                }
            ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: legacyJSON)

        #expect(snapshot.phone == "myGalaxy")
        #expect(snapshot.copies.count == 1)
        #expect(snapshot.copies[0].bytesDone == nil)
        #expect(snapshot.copies[0].bytesTotal == nil)
        #expect(snapshot.photos == nil)
        #expect(snapshot.newPhotos == nil)
        #expect(snapshot.lastCopy == nil)
    }

    @Test("Encodes and decodes new snapshot fields")
    func roundTripsNewSnapshotFields() throws {
        let now = Date(timeIntervalSince1970: 1729000000)
        let lastDate = Date(timeIntervalSince1970: 1728900000)
        let original = WidgetSnapshot(
            updated: now,
            phone: "myGalaxy",
            hint: "USB 2 · 3× faster with USB 3",
            copies: [
                WidgetSnapshot.Copy(
                    id: 1,
                    device: "myGalaxy",
                    title: "Camera",
                    fraction: 0.62,
                    detail: "23 s left",
                    tint: .copying,
                    bytesDone: 3_400_000_000,
                    bytesTotal: 5_600_000_000
                )
            ],
            photos: 166,
            newPhotos: 9,
            lastCopy: WidgetSnapshot.LastCopy(title: "Camera", date: lastDate, files: 166)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)

        #expect(decoded.photos == 166)
        #expect(decoded.newPhotos == 9)
        #expect(decoded.lastCopy?.title == "Camera")
        #expect(decoded.lastCopy?.files == 166)
        #expect(decoded.copies.first?.bytesDone == 3_400_000_000)
        #expect(decoded.copies.first?.bytesTotal == 5_600_000_000)
    }

    @Test("Formats relative day correctly")
    func formatsRelativeDay() {
        let calendar = Calendar.current
        let today = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        #expect(WidgetTheme.relativeDay(for: today, calendar: calendar) == "today")
        #expect(WidgetTheme.relativeDay(for: yesterday, calendar: calendar) == "yesterday")
    }

    @Test("Formats bytes progress and copy details")
    func formatsBytesProgressAndDetails() {
        let copyActive = WidgetSnapshot.Copy(
            id: 1,
            device: "myGalaxy",
            title: "Camera",
            fraction: 0.62,
            detail: "23 s left",
            tint: .copying,
            bytesDone: 3_400_000_000,
            bytesTotal: 5_600_000_000
        )
        #expect(WidgetTheme.copyDetail(copyActive) == "3.4 of 5.6 GB · 23 s left")

        let copyPaused = WidgetSnapshot.Copy(
            id: 2,
            device: "myGalaxy",
            title: "Downloads",
            fraction: 0.15,
            detail: "paused",
            tint: .paused,
            bytesDone: 150_000_000,
            bytesTotal: 1_000_000_000
        )
        #expect(WidgetTheme.copyDetail(copyPaused) == "paused")

        let copyNext = WidgetSnapshot.Copy(
            id: 3,
            device: "myGalaxy",
            title: "Screenshots",
            fraction: 0,
            detail: "next",
            tint: .waiting
        )
        #expect(WidgetTheme.copyDetail(copyNext) == "next")
    }
}
