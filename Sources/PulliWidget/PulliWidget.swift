import PulliProtocol
import PulliWidgetViews
import SwiftUI
import WidgetKit

// Pulli's desktop widgets: a small card for quick actions and progress, and a medium card with
// full copy bars or ready status. Data is read from the widget container's Application Support folder.

struct Entry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
        return Entry(
            date: .now,
            snapshot: WidgetSnapshot(
                updated: .now,
                phone: "myGalaxy",
                hint: nil,
                copies: [],
                photos: 166,
                newPhotos: 9,
                lastCopy: WidgetSnapshot.LastCopy(title: "Camera", date: yesterday, files: 166)
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : Entry(date: .now, snapshot: Self.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app asks for a reload whenever copies change; this timeline is only the fallback.
        completion(Timeline(entries: [Entry(date: .now, snapshot: Self.read())], policy: .after(.now.addingTimeInterval(60))))
    }

    static func read() -> WidgetSnapshot? {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("pulli-widget.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

struct PulliProgressWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PulliProgress", provider: Provider()) { entry in
            WidgetBody(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Pulli")
        .description("Your phone, new photos and running copies at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct PulliWidgets: WidgetBundle {
    var body: some Widget {
        PulliProgressWidget()
    }
}
