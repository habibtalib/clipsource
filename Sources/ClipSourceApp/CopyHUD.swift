import AppKit
import ClipCore
import SwiftUI

/// The toast shown after ⌘C: "Copied" with a spinner while the source is looked up,
/// then a checkmark and where the copy came from (app, Claude session or chat, repo and branch).
@MainActor
final class CopyHUD {
    static let shared = CopyHUD()

    final class State: ObservableObject {
        @Published var entry: ClipEntry?
        @Published var details: SourceDetails?
        @Published var visible = false
        var resolved: Bool { details != nil }
    }

    private let state = State()
    private lazy var panel: NSPanel = makePanel()
    private var hideWork: DispatchWorkItem?
    private static let size = NSSize(width: 420, height: 92)

    func show(_ entry: ClipEntry) {
        hideWork?.cancel()
        state.entry = entry
        state.details = nil
        position()
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { state.visible = true }
        scheduleHide(after: 2.5)  // fallback if the lookup never finishes
    }

    func resolve(entryId: Int64, details: SourceDetails) {
        guard state.entry?.id == entryId else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { state.details = details }
        scheduleHide(after: 1.6)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(.easeIn(duration: 0.22)) { self.state.visible = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    MainActor.assumeIsolated { if !self.state.visible { self.panel.orderOut(nil) } }
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Top centre of the screen that has the mouse, just under the menu bar.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.maxY - Self.size.height - 6))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: CopyHUDView(state: state))
        return panel
    }
}

struct CopyHUDView: View {
    @ObservedObject var state: CopyHUD.State

    var body: some View {
        VStack {
            if state.visible, let entry = state.entry {
                card(entry)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.92)),
                                            removal: .opacity.combined(with: .scale(scale: 0.96))))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
    }

    private func card(_ entry: ClipEntry) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AppIcon(bundleId: entry.source.bundleId, name: entry.source.app)
                    .frame(width: 34, height: 34)
                status
                    .offset(x: 5, y: 5)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(state.resolved ? "Copied" : "Copying…")
                        .font(.system(size: 12.5, weight: .semibold))
                        .contentTransition(.opacity)
                    Text("from \(entry.source.app ?? "unknown app")")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(entry.preview(90))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                sourceLine
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(BrandIcons.accent.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
    }

    @ViewBuilder private var status: some View {
        ZStack {
            Circle().fill(.background).frame(width: 17, height: 17)
            if state.resolved {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
                    .symbolEffect(.bounce, value: state.resolved)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var sourceLine: some View {
        if let details = state.details {
            if !details.isEmpty {
                SourceChips(details: details)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        } else {
            ShimmerBar()
                .frame(width: 170, height: 9)
                .transition(.opacity)
        }
    }
}

/// Session (or chat) and repo chips, shared by the toast, the switcher and the history rows.
struct SourceChips: View {
    let details: SourceDetails
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            if let session = details.sessionTitle {
                chip(session, symbol: "sparkles", tint: BrandIcons.accent)
            } else if let chat = details.chat {
                chip(chat, symbol: "bubble.left", tint: .secondary)
            }
            if let repo = details.repo {
                chip(repo.display, symbol: "arrow.triangle.branch", tint: .teal)
            }
        }
    }

    private func chip(_ text: String, symbol: String, tint: some ShapeStyle) -> some View {
        Label {
            Text(text).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.system(size: compact ? 10 : 10.5, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

/// Placeholder bar that sweeps a highlight across while the source is loading.
struct ShimmerBar: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    LinearGradient(colors: [.clear, Color.primary.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: phase * geo.size.width)
                )
                .clipShape(Capsule())
        }
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { phase = 1.2 }
        }
    }
}
