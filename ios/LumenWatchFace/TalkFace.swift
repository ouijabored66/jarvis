import SwiftUI
import WidgetKit

struct TalkEntry: TimelineEntry {
    let date: Date
}

struct TalkProvider: TimelineProvider {
    func placeholder(in context: Context) -> TalkEntry { TalkEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (TalkEntry) -> Void) {
        completion(TalkEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TalkEntry>) -> Void) {
        completion(Timeline(entries: [TalkEntry(date: .now)], policy: .never))
    }
}

struct TalkFace: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("Lumen", systemImage: "mic.fill")
        case .accessoryCircular, .accessoryCorner:
            Image(systemName: "mic.fill")
        default:
            VStack(alignment: .leading, spacing: 2) {
                Label("Lumen", systemImage: "mic.fill").font(.headline)
                Text("Tap to talk").font(.caption2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TalkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "lumen.talk", provider: TalkProvider()) { _ in
            TalkFace()
                .containerBackground(.black, for: .widget)
                .widgetURL(URL(string: "lumenvoice://listen"))
        }
        .configurationDisplayName("Lumen")
        .description("Open Lumen ready to dictate.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

@main
struct TalkWidgets: WidgetBundle {
    var body: some Widget { TalkWidget() }
}
