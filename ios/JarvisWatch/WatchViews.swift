import SwiftUI

private let accent = Color(red: 0.20, green: 0.95, blue: 0.70)   // same reactor green as the iPhone app

/// Ask at the top (tap, then dictate), newest reply first, scroll down for older history.
struct WatchContentView: View {
    @EnvironmentObject var model: WatchModel
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            List {
                if model.demoMode {
                    Text("DEMO MODE")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.orange, in: Capsule())
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .accessibilityLabel("Demo Mode is on. Replies are simulated.")
                }

                TextField("Ask Jarvis", text: $draft)
                    .onSubmit(send)
                    .disabled(model.busy)

                if model.busy {
                    HStack(spacing: 8) {
                        ProgressView().frame(width: 20, height: 20)
                        Text("Thinking…").foregroundStyle(accent)
                    }
                    .listRowBackground(Color.clear)
                }

                if !model.demoMode && !model.isConfigured {
                    Text("Open Jarvis on your iPhone to set up your server, or turn on Demo Mode in Settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                ForEach(model.history.reversed()) { entry in
                    WatchEntryRow(entry: entry)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Jarvis")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        WatchSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .tint(accent)
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await model.ask(text) }
    }
}

struct WatchEntryRow: View {
    let entry: WatchEntry

    var body: some View {
        switch entry.role {
        case .system:
            Text(entry.text)
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        case .me:
            Text(entry.text)
                .font(.body)
                .foregroundStyle(.black)
                .padding(8)
                .background(accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .jarvis:
            Text(entry.text)
                .font(.body)
                .padding(8)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct WatchSettingsView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        List {
            Section {
                Toggle("Demo Mode", isOn: Binding(get: { model.demoMode }, set: { model.setDemoMode($0) }))
            } footer: {
                Text("Simulated replies on the Watch. No server needed; nothing is sent anywhere.")
            }

            Section {
                Toggle("Speak replies", isOn: $model.speakReplies)
                Button("Stop speaking") { model.stopSpeaking() }
            }

            Section {
                ForEach(ServerID.allCases) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.label)
                        Text(model.isConfigured(s) ? model.url(s) : "Not set up")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } header: {
                Text("Servers")
            } footer: {
                Text("Addresses and tokens come from the Jarvis app on your iPhone.")
            }

            Section {
                Button("Clear history", role: .destructive) { model.clearHistory() }
            }
        }
        .navigationTitle("Settings")
    }
}
