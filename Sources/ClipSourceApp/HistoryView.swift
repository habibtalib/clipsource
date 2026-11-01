import AppKit
import ClipCore
import SwiftUI

enum HistoryMode: String, CaseIterable, Identifiable {
    case recent = "Recent"
    case byApp = "By app"
    var id: String { rawValue }
}

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("historyMode") private var mode: HistoryMode = .recent
    @FocusState private var searchFocused: Bool
    @State private var confirmClear = false
    /// Called after an entry is copied or Esc is pressed on an empty search (closes the panel or menu).
    var onPicked: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 460, height: 580)
        .background(.regularMaterial)
        .tint(BrandIcons.accent)
        .onAppear {
            model.reload()
            searchFocused = true
        }
        .confirmationDialog("Delete all clipboard history?", isPresented: $confirmClear) {
            Button("Delete all", role: .destructive) { model.clearAll() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: BrandIcons.appIcon)
                    .resizable()
                    .frame(width: 26, height: 26)
                Text("ClipSource")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(model.total) \(model.total == 1 ? "copy" : "copies")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search text, app or label", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { pick { model.copySelected() } }
                    .onKeyPress(.downArrow) { model.select(offset: 1); return .handled }
                    .onKeyPress(.upArrow) { model.select(offset: -1); return .handled }
                    .onKeyPress(.escape) {
                        if model.query.isEmpty { onPicked() } else { model.query = "" }
                        return .handled
                    }
                    .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                        guard press.modifiers.contains(.command), let n = Int(String(press.characters)), n >= 1 else { return .ignored }
                        pick { model.copy(at: n - 1) }
                        return .handled
                    }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                } else {
                    Text("⌥⌘V")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

            Picker("", selection: $mode) {
                ForEach(HistoryMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty {
            VStack(spacing: 10) {
                Image(nsImage: BrandIcons.appIcon).resizable().frame(width: 48, height: 48).opacity(0.8)
                Text(model.query.isEmpty ? "Copy something to start" : "No matches for “\(model.query)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        switch mode {
                        case .recent:
                            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                                row(entry, shortcut: index < 9 ? index + 1 : nil)
                            }
                        case .byApp:
                            ForEach(model.groupsByApp) { group in
                                Section {
                                    ForEach(group.entries) { row($0, shortcut: nil) }
                                } header: {
                                    GroupHeader(group: group)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .onChange(of: model.selectedId) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    private func row(_ entry: ClipEntry, shortcut: Int?) -> some View {
        EntryRow(entry: entry,
                 shortcut: shortcut,
                 isSelected: model.selectedId == entry.id,
                 isCurrent: model.currentEntryId == entry.id,
                 onCopy: { pick { model.copy(entry) } },
                 onDelete: { model.delete(entry) })
            .id(entry.id)
    }

    private func pick(_ action: () -> Void) {
        action()
        onPicked()
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                model.paused.toggle()
            } label: {
                Label(model.paused ? "Paused" : "Recording", systemImage: model.paused ? "pause.circle.fill" : "record.circle")
                    .foregroundStyle(model.paused ? Color.orange : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(model.paused ? "Resume recording" : "Pause recording")

            if !model.axTrusted {
                Button { model.requestAccessibility() } label: {
                    Label("Grant Accessibility", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help("Needed to record window and chat titles")
            }

            Spacer()

            if let error = model.errorMessage {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red).help(error)
            }

            Menu {
                SettingsLink { Text("Settings…") }
                Button("Clear History…") { confirmClear = true }
                Divider()
                Button("Quit ClipSource") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Rows

struct EntryRow: View {
    let entry: ClipEntry
    let shortcut: Int?
    let isSelected: Bool
    let isCurrent: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(bundleId: entry.source.bundleId, name: entry.source.app)
                .frame(width: 28, height: 28)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.source.app ?? "Unknown app")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let label = entry.source.label {
                        Text(label)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(BrandIcons.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(BrandIcons.accent.opacity(0.16), in: Capsule())
                            .lineLimit(1)
                    }
                    if entry.origin != .watch {
                        Text(entry.origin.rawValue.uppercased())
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.tertiary, lineWidth: 1))
                    }
                    Spacer(minLength: 4)
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help("On the clipboard now")
                    }
                    if hovering {
                        HStack(spacing: 6) {
                            iconButton("doc.on.doc", help: "Copy", action: onCopy)
                            iconButton("trash", help: "Delete", action: onDelete)
                        }
                    } else {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(ClipFormatter.shortAge(entry.createdAt, now: context.date))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        if let shortcut {
                            Text("⌘\(shortcut)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Text(entry.preview(220))
                    .font(.system(size: 12.5))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                if let context = contextLine {
                    Text(context)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? BrandIcons.accent.opacity(0.16) : (hovering ? Color.primary.opacity(0.06) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(isSelected ? BrandIcons.accent.opacity(0.7) : .clear, lineWidth: 1.2)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onCopy)
        .contextMenu {
            Button("Copy", action: onCopy)
            Button("Delete", role: .destructive, action: onDelete)
        }
        .help(helpText)
    }

    /// Window or chat title, plus the folder and session for CLI/MCP copies.
    private var contextLine: String? {
        let s = entry.source
        var parts: [String] = []
        let title = s.cleanWindowTitle
        if let title { parts.append(title) }
        if entry.origin != .watch, let cwd = s.cwd {
            let folder = (cwd as NSString).lastPathComponent
            if !(title?.contains(folder) ?? false) { parts.append(folder) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var helpText: String {
        var lines = [entry.source.originLine]
        if let session = entry.source.session { lines.append("Session \(session)") }
        return lines.joined(separator: "\n")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct GroupHeader: View {
    let group: SourceGroup

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(bundleId: group.bundleId, name: group.title).frame(width: 16, height: 16)
            Text(group.title).font(.system(size: 11, weight: .bold))
            Text("\(group.entries.count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .background(.quaternary, in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// App icon from the bundle ID, or a coloured initial when the app isn't installed.
struct AppIcon: View {
    let bundleId: String?
    var name: String?
    private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let image = Self.icon(for: bundleId) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: geo.size.width * 0.24)
                    .fill(Self.color(for: bundleId ?? name ?? "?").gradient)
                    .overlay(
                        Text(String((name ?? "?").prefix(1)).uppercased())
                            .font(.system(size: geo.size.width * 0.5, weight: .bold))
                            .foregroundStyle(.white)
                    )
            }
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

    private static func color(for key: String) -> Color {
        let hue = Double(key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }) / 65535.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }
}
