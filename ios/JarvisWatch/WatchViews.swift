import SwiftUI

private let accent = Color(red: 1.00, green: 0.761, blue: 0.290)   // #FFC24A, same warm gold as the iPhone app
private let accent2 = Color(red: 1.00, green: 0.541, blue: 0.239)  // #FF8A3D amber

/// Ask at the top (tap, then dictate), newest reply first, scroll down for older history.
struct WatchContentView: View {
    @EnvironmentObject var model: WatchModel
    @State private var draft = ""
    @FocusState private var typing: Bool

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

                TextField("Type or dictate", text: $draft)
                    .focused($typing)
                    .onSubmit(send)
                    .disabled(model.busy)

                HStack {
                    ForEach(["What can you do?", "Joke"], id: \.self) { prompt in
                        Button(prompt) {
                            Task { await model.ask(prompt == "Joke" ? "Tell me a joke" : prompt) }
                        }
                        .font(.caption2)
                    }
                }
                .listRowBackground(Color.clear)

                if model.busy {
                    HStack(spacing: 8) {
                        ProgressView().frame(width: 20, height: 20)
                        Text("Thinking…").foregroundStyle(accent)
                    }
                    .listRowBackground(Color.clear)
                }

                if !model.demoMode {
                    Text("Questions go through your iPhone. The key stays there.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                ForEach(model.history.suffix(8).reversed()) { entry in
                    WatchEntryRow(entry: entry)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(model.assistantTitle)
            .onChange(of: model.dictateNow) { _, ready in
                if ready {
                    typing = true
                    model.dictateNow = false
                }
            }
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
                .background(LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                Text(model.assistantTitle)
            } footer: {
                Text("Questions go through the Lumen Voice app on your iPhone. The API key stays on the iPhone.")
            }

            Section {
                Button("New conversation", role: .destructive) {
                    Task { await model.resetConversation() }
                }
                Button("Clear history", role: .destructive) { model.clearHistory() }
            }
        }
        .navigationTitle("Settings")
    }
}
