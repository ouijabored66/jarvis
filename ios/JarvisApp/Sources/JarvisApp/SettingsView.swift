import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: JarvisModel
    @Environment(\.dismiss) private var dismiss
    @State private var urls: [ServerID: String] = [:]
    @State private var tokens: [ServerID: String] = [:]
    @State private var checking = false

    private let voiceNames: [String: String] = [
        "bm_george": "George (British)", "bm_lewis": "Lewis (British)", "bm_daniel": "Daniel (British)",
        "bm_fable": "Fable (British)", "bf_emma": "Emma (British)", "bf_alice": "Alice (British)",
        "bf_isabella": "Isabella (British)", "bf_lily": "Lily (British)",
        "am_adam": "Adam (American)", "am_michael": "Michael (American)", "af_heart": "Heart (American)",
    ]

    var body: some View {
        NavigationStack {
            Form {
                ForEach(ServerID.allCases) { s in
                    Section {
                        TextField("https://…", text: binding(for: s, in: $urls))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        SecureField("Access token", text: binding(for: s, in: $tokens))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: {
                        HStack {
                            Text(s.label)
                            Spacer()
                            status(for: s)
                        }
                    } footer: {
                        Text(s == .linux
                             ? "Jarvis on the Linux side. Use that server's app token."
                             : "Jarvis on the Windows side. Use that server's app token.")
                    }
                }

                Section {
                    Button {
                        for s in ServerID.allCases {
                            let u = (urls[s] ?? "").trimmingCharacters(in: .whitespaces)
                            let t = (tokens[s] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            if s == .linux { model.linuxURL = u; model.linuxToken = t }
                            else { model.windowsURL = u; model.windowsToken = t }
                        }
                        checking = true
                        Task { await model.refreshStatus(); checking = false }
                    } label: {
                        HStack {
                            Text("Save & check both")
                            Spacer()
                            if checking { ProgressView() }
                        }
                    }
                } footer: {
                    Text("Jarvis uses whichever one is online and switches by itself when you boot the desktop into the other system.")
                }

                Section("Voice") {
                    Toggle("Speak replies", isOn: $model.speakReplies).tint(Theme.accent)
                    Picker("Voice", selection: Binding(get: { model.voice },
                                                       set: { v in Task { await model.setVoice(v) } })) {
                        ForEach(voiceList, id: \.self) { v in Text(voiceNames[v] ?? v).tag(v) }
                    }
                }

                Section {
                    Button("Start a new conversation", role: .destructive) {
                        Task { await model.resetConversation(); dismiss() }
                    }
                } footer: {
                    Text("Jarvis can answer and save notes. It can't change anything on your PC or accounts.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                for s in ServerID.allCases { urls[s] = model.url(s); tokens[s] = model.token(s) }
            }
        }
        .tint(Theme.accent)
    }

    @ViewBuilder private func status(for s: ServerID) -> some View {
        let up = model.online[s] == true
        HStack(spacing: 5) {
            Circle().fill(up ? Theme.accent : Color.gray.opacity(0.6)).frame(width: 7, height: 7)
            Text(model.active == s ? "In use" : (up ? "Online" : (model.isConfigured(s) ? "Offline" : "Not set up")))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(model.active == s ? Theme.accent : .secondary)
                .textCase(nil)
        }
    }

    private func binding(for s: ServerID, in dict: Binding<[ServerID: String]>) -> Binding<String> {
        Binding(get: { dict.wrappedValue[s] ?? "" }, set: { dict.wrappedValue[s] = $0 })
    }

    private var voiceList: [String] {
        let preferred = ["bm_george", "bm_lewis", "bm_daniel", "bm_fable", "bf_emma", "bf_alice", "bf_isabella", "bf_lily"]
        let available = Set(model.voices)
        let list = available.isEmpty ? preferred : preferred.filter(available.contains) + model.voices.filter { !preferred.contains($0) }
        return list.contains(model.voice) ? list : [model.voice] + list
    }
}
