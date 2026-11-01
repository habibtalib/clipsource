import AppKit
import ClipCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("groupBySource") private var groupBySource = false
    /// Called after an entry is picked (the panel closes itself).
    var onPicked: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard", text: $model.query)
                    .textFieldStyle(.plain)
                Toggle(isOn: $groupBySource) {
                    Image(systemName: "rectangle.3.group")
                }
                .toggleStyle(.button)
                .help("Group by source")
            }
            .padding(10)

            if !model.axTrusted {
                Button {
                    model.requestAccessibility()
                } label: {
                    Label("Grant Accessibility to capture window titles", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .padding(.bottom, 6)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(.bottom, 6)
            }

            Divider()

            if model.entries.isEmpty {
                Text(model.query.isEmpty ? "No clipboard history yet" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if groupBySource {
                        ForEach(model.groups) { group in
                            Section(group.title) {
                                ForEach(group.entries) { row($0) }
                            }
                        }
                    } else {
                        ForEach(model.entries) { row($0) }
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                Toggle("Pause", isOn: $model.paused).toggleStyle(.checkbox)
                Spacer()
                SettingsLink { Text("Settings…") }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
            .padding(8)
        }
        .frame(width: 440, height: 540)
        .onAppear { model.reload() }
    }

    private func row(_ entry: ClipEntry) -> some View {
        EntryRow(entry: entry)
            .contentShape(Rectangle())
            .onTapGesture {
                model.copy(entry)
                onPicked()
            }
            .contextMenu {
                Button("Copy") {
                    model.copy(entry)
                    onPicked()
                }
                Button("Delete", role: .destructive) { model.delete(entry) }
            }
            .help(entry.source.session.map { "Session \($0)" } ?? entry.source.originLine)
    }
}

struct EntryRow: View {
    let entry: ClipEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AppIcon(bundleId: entry.source.bundleId)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.preview(180))
                    .font(.system(size: 12))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    if let label = entry.source.label {
                        Text(label)
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                    Text(entry.source.originLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(entry.createdAt, format: .relative(presentation: .numeric))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct AppIcon: View {
    let bundleId: String?
    private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let image = Self.icon(for: bundleId) {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
        }
    }

    private static func icon(for bundleId: String?) -> NSImage? {
        guard let bundleId else { return nil }
        if let cached = cache[bundleId] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleId] = image
        return image
    }
}
