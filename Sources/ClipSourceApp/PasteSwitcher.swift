import AppKit
import Carbon.HIToolbox
import ClipCore
import SwiftUI

/// Hold ⌘V to choose what to paste, like ⌘Tab for the clipboard.
///
/// A quick ⌘V tap pastes as usual. Holding V (with ⌘) for a moment opens the switcher; while ⌘ stays down,
/// V or ↓ moves down, ⇧V or ↑ moves up, 1–9 jump, Esc cancels. Releasing ⌘ pastes the selected entry
/// into the app that was in front. Needs Accessibility (a session event tap).
@MainActor
final class PasteSwitcher {
    enum Phase { case idle, pending, switching }

    /// Marks the ⌘V events this class posts, so the tap lets them through.
    static let syntheticMarker: Int64 = 0x434C_5053  // "CLPS"
    static let holdDelay: TimeInterval = 0.28

    private(set) var phase: Phase = .idle
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdTimer: Timer?
    private let overlay = SwitcherOverlay()
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var isRunning: Bool { tap != nil }

    /// Installs the event tap. Returns false when Accessibility is not granted yet.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let switcher = Unmanaged<PasteSwitcher>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { switcher.handle(type, event) }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        cancel()
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        runLoopSource = nil
    }

    // MARK: Event handling

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return pass }

        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let command = flags.contains(.maskCommand)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        switch phase {
        case .idle:
            guard type == .keyDown, key == kVK_ANSI_V, command, !isRepeat,
                  flags.intersection([.maskAlternate, .maskControl, .maskShift]).isEmpty else { return pass }
            phase = .pending
            holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDelay, repeats: false) { _ in
                MainActor.assumeIsolated { AppModel.shared.pasteSwitcher?.beginSwitching() }
            }
            return nil  // held back until we know whether this is a tap or a hold

        case .pending:
            if key == kVK_ANSI_V && type == .keyDown { return nil }  // auto-repeat while deciding
            if key == kVK_ANSI_V && type == .keyUp {
                endPending()
                postPaste()
                return nil
            }
            // ⌘ released or another key pressed before the hold delay: it was a normal paste.
            endPending()
            postPaste()
            return pass

        case .switching:
            if type == .flagsChanged {
                if !command { commit() }
                return pass
            }
            guard type == .keyDown else { return nil }  // swallow key-ups while the switcher is open
            switch key {
            case kVK_ANSI_V:
                if !isRepeat { overlay.move(flags.contains(.maskShift) ? -1 : 1) }
            case kVK_DownArrow, kVK_Tab:
                overlay.move(flags.contains(.maskShift) ? -1 : 1)
            case kVK_UpArrow:
                overlay.move(-1)
            case kVK_Escape:
                cancel()
            case kVK_Return, kVK_ANSI_KeypadEnter:
                commit()
            default:
                if let index = Self.digitKeys.firstIndex(of: key) { overlay.select(index) }
            }
            return nil
        }
    }

    private static let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                    kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    private func endPending() {
        holdTimer?.invalidate()
        holdTimer = nil
        phase = .idle
    }

    fileprivate func beginSwitching() {
        guard phase == .pending else { return }
        holdTimer = nil
        let entries = model.switcherEntries()
        guard !entries.isEmpty else {
            phase = .idle
            postPaste()
            return
        }
        phase = .switching
        overlay.show(entries: entries, model: model)
    }

    private func commit() {
        guard phase == .switching else { return }
        phase = .idle
        let entry = overlay.selectedEntry
        overlay.hide()
        guard let entry else { return }
        model.copy(entry)
        // Give the pasteboard a moment, then paste into the app that is still in front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            MainActor.assumeIsolated { self?.postPaste() }
        }
    }

    private func cancel() {
        holdTimer?.invalidate()
        holdTimer = nil
        if phase == .switching { overlay.hide() }
        phase = .idle
    }

    /// Posts ⌘V marked as ours so the tap does not catch it again.
    private func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Overlay

@MainActor
final class SwitcherOverlay {
    final class State: ObservableObject {
        @Published var entries: [ClipEntry] = []
        @Published var selected = 0
        @Published var visible = false
    }

    private let state = State()
    private var panel: NSPanel?
    private static let size = NSSize(width: 560, height: 520)

    var selectedEntry: ClipEntry? {
        state.entries.indices.contains(state.selected) ? state.entries[state.selected] : nil
    }

    func show(entries: [ClipEntry], model: AppModel) {
        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        state.entries = entries
        state.selected = 0
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.midY - Self.size.height / 2 + 40))
        }
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { state.visible = true }
    }

    func hide() {
        withAnimation(.easeIn(duration: 0.14)) { state.visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.state.visible else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    func move(_ offset: Int) {
        guard !state.entries.isEmpty else { return }
        let count = state.entries.count
        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
            state.selected = (state.selected + offset + count) % count
        }
    }

    func select(_ index: Int) {
        guard state.entries.indices.contains(index) else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) { state.selected = index }
    }

    private func makePanel(model: AppModel) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: SwitcherView(state: state).environmentObject(model))
        return panel
    }
}

struct SwitcherView: View {
    @ObservedObject var state: SwitcherOverlay.State
    @EnvironmentObject private var model: AppModel
    @Namespace private var highlight

    var body: some View {
        VStack {
            if state.visible {
                card
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: BrandIcons.appIcon).resizable().frame(width: 20, height: 20)
                Text("Paste").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("V / ↑↓ move · release ⌘ to paste · esc")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            VStack(spacing: 2) {
                ForEach(Array(state.entries.enumerated()), id: \.element.id) { index, entry in
                    SwitcherRow(entry: entry, index: index, isSelected: index == state.selected,
                                isCurrent: entry.id == model.currentEntryId, details: model.details[entry.id])
                        .background {
                            if index == state.selected {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(BrandIcons.accent.opacity(0.18))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(BrandIcons.accent.opacity(0.75), lineWidth: 1.2))
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .frame(width: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        .padding(10)
    }
}

struct SwitcherRow: View {
    let entry: ClipEntry
    let index: Int
    let isSelected: Bool
    let isCurrent: Bool
    let details: SourceDetails?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(bundleId: entry.source.bundleId, name: entry.source.app)
                .frame(width: isSelected ? 30 : 24, height: isSelected ? 30 : 24)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.source.app ?? "Unknown app")
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    if let label = entry.source.label {
                        Text(label)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(BrandIcons.accent)
                            .lineLimit(1)
                    }
                    if isCurrent {
                        Text("ON CLIPBOARD")
                            .font(.system(size: 8.5, weight: .heavy))
                            .foregroundStyle(.green)
                    }
                    Spacer(minLength: 4)
                    Text(ClipFormatter.shortAge(entry.createdAt))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? .white : .secondary)
                        .frame(width: 16, height: 16)
                        .background(isSelected ? BrandIcons.accent : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }

                Text(isSelected ? String(entry.text.prefix(600)) : entry.preview(140))
                    .font(.system(size: 12, design: isSelected ? .monospaced : .default))
                    .lineLimit(isSelected ? 4 : 1)
                    .foregroundStyle(.primary.opacity(isSelected ? 1 : 0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let details {
                    if !details.isEmpty { SourceChips(details: details, compact: true) }
                } else {
                    ShimmerBar().frame(width: 140, height: 8)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isSelected ? 9 : 6)
        .contentShape(Rectangle())
    }
}
