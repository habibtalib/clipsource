import ClipCore
import SwiftUI
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // The app reloads timelines on every clipboard change; refresh hourly as a fallback.
        completion(Timeline(entries: [current()], policy: .after(Date().addingTimeInterval(3600))))
    }

    private func current() -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: WidgetBridge.snapshotURL.flatMap(WidgetSnapshot.read(from:)))
    }
}

@main
struct ClipSourceWidgets: WidgetBundle {
    var body: some Widget {
        LatestClipWidget()
        RecentClipsWidget()
    }
}

struct LatestClipWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.habibtalib.clipsource.latest", provider: SnapshotProvider()) { entry in
            LatestClipView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WidgetBridge.panelURL)
        }
        .configurationDisplayName("Latest Copy")
        .description("The newest clipboard entry and where it came from.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct RecentClipsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.habibtalib.clipsource.recent", provider: SnapshotProvider()) { entry in
            RecentClipsView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WidgetBridge.panelURL)
        }
        .configurationDisplayName("Recent Copies")
        .description("Recent clipboard entries by source. Click one to copy it again.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Views

struct LatestClipView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot?

    var body: some View {
        if let snapshot, let item = snapshot.items.first {
            VStack(alignment: .leading, spacing: 6) {
                StatusHeader(snapshot: snapshot)
                SourceLine(item: item, font: .caption.weight(.semibold))
                Text(item.preview ?? "Content hidden")
                    .font(family == .systemSmall ? .callout : .body)
                    .foregroundStyle(item.preview == nil ? .secondary : .primary)
                    .lineLimit(family == .systemSmall ? 3 : 4)
                Spacer(minLength: 0)
                Text(item.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            EmptyState(snapshot: snapshot)
        }
    }
}

struct RecentClipsView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot?

    var body: some View {
        if let snapshot, !snapshot.items.isEmpty {
            VStack(alignment: .leading, spacing: family == .systemLarge ? 8 : 5) {
                StatusHeader(snapshot: snapshot)
                ForEach(snapshot.items.prefix(family == .systemLarge ? 6 : 3)) { item in
                    Link(destination: WidgetBridge.restoreURL(id: item.id)) {
                        ClipRow(item: item, large: family == .systemLarge)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            EmptyState(snapshot: snapshot)
        }
    }
}

struct StatusHeader: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: snapshot.paused ? "pause.circle.fill" : "doc.on.clipboard.fill")
                .foregroundStyle(snapshot.paused ? .orange : .accentColor)
            Text(snapshot.paused ? "Paused" : "Clipboard")
                .font(.caption.weight(.bold))
            Spacer()
            Text("\(snapshot.total)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct SourceLine: View {
    let item: WidgetSnapshot.Item
    var font: Font = .caption2

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: item.origin.symbol)
                .foregroundStyle(.secondary)
            if let label = item.label {
                Text(label)
                    .padding(.horizontal, 5)
                    .background(Color.accentColor.opacity(0.25), in: Capsule())
            } else {
                Text(item.title)
                    .foregroundStyle(.secondary)
            }
        }
        .font(font)
        .lineLimit(1)
    }
}

struct ClipRow: View {
    let item: WidgetSnapshot.Item
    let large: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                SourceLine(item: item)
                Spacer(minLength: 4)
                Text(item.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Text(item.preview ?? "Content hidden")
                .font(.caption)
                .foregroundStyle(item.preview == nil ? .secondary : .primary)
                .lineLimit(large ? 2 : 1)
        }
    }
}

struct EmptyState: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(snapshot == nil ? "Open ClipSource to start" : "No copies yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ClipOrigin {
    var symbol: String {
        switch self {
        case .watch: return "hand.point.up.left"
        case .cli: return "terminal"
        case .mcp: return "sparkles"
        }
    }
}
