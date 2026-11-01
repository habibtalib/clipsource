import ClipCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Capture") {
                LabeledContent("Accessibility") {
                    if model.axTrusted {
                        Text("Granted: window titles are recorded").foregroundStyle(.secondary)
                    } else {
                        Button("Grant…") { model.requestAccessibility() }
                    }
                }
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }

            Section {
                TextEditor(text: $model.excludedBundleIdsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 110)
            } header: {
                Text("Never record copies from these apps (bundle IDs, one per line)")
            } footer: {
                Text("Copies marked concealed by password managers are always skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("History") {
                Stepper("Keep for \(model.retentionDays) days", value: $model.retentionDays, in: 1...365)
                Stepper("Keep at most \(model.maxEntries) entries", value: $model.maxEntries, in: 100...50000, step: 100)
                HStack {
                    Button("Apply retention now") { model.prune() }
                    Spacer()
                    Button("Clear history…", role: .destructive) { confirmClear = true }
                }
                if let path = model.store?.url.path {
                    Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .confirmationDialog("Delete all clipboard history?", isPresented: $confirmClear) {
            Button("Delete all", role: .destructive) { model.clearAll() }
        }
    }
}
