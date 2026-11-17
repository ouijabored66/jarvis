import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: JarvisModel
    @Environment(\.dismiss) private var dismiss
    @State private var urls: [ServerID: String] = [:]
    @State private var drafts: [ServerID: String] = [:]
    @State private var providerDraft = ""
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
                Section {
                    Toggle("Demo Mode", isOn: Binding(get: { model.demoMode },
                                                      set: { v in Task { await model.setDemoMode(v) } }))
                        .tint(.orange)
                } header: {
                    Text("Try it without a server")
                } footer: {
                    Text("Demo Mode simulates Lumen on this iPhone with sample replies and a sample conversation. No server or account is needed and nothing is sent anywhere. Turn it off to use your own Lumen server below.")
                }

                Section {
                    Picker("Connection", selection: Binding(get: { model.usesProvider }, set: { model.setLinkMode(provider: $0) })) {
                        Text("Use your API key").tag(true)
                        Text("Run your own server").tag(false)
                    }
                } footer: {
                    Text(model.usesProvider
                         ? "One provider key. Speech and the voice stay on this iPhone."
                         : "The small desktop server keeps the provider key on your computer. Run python3 desktop/server.py and enter the URL and token it prints.")
                }

                if model.usesProvider {
                    Section {
                        SecureField("API Key", text: $providerDraft)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(nil).privacySensitive()
                        if model.providerKeySaved {
                            HStack {
                                Text(model.providerKeySuffix.isEmpty ? "Saved" : "Saved · ••••\(model.providerKeySuffix)")
                                    .foregroundStyle(.secondary).privacySensitive()
                                Spacer()
                                Button("Clear", role: .destructive) { model.clearProviderKey() }
                            }
                        }
                        providerStatus
                        Button {
                            let typed = providerDraft
                            checking = true
                            Task {
                                await model.saveProviderKey(typed)
                                if model.providerStatus != .unrecognized { providerDraft = "" }
                                checking = false
                            }
                        } label: {
                            HStack { Text("Save and connect"); Spacer(); if checking { ProgressView() } }
                        }
                        .disabled(checking)
                    } header: {
                        Text("API Key")
                    } footer: {
                        Text("Detected from the key: Grok, Claude, Gemini, Groq, OpenRouter, or OpenAI. It is stored only in the Keychain on this iPhone.")
                    }
                } else {
                    ForEach(ServerID.allCases) { s in
                        Section {
                            TextField("https://…", text: binding(for: s, in: $urls))
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            SecureField("Server token", text: draftBinding(s))
                                .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(nil).privacySensitive()
                            if model.serverSaved[s.rawValue] == true {
                                HStack {
                                    Text((model.serverSuffix[s.rawValue] ?? "").isEmpty ? "Saved" : "Saved · ••••\(model.serverSuffix[s.rawValue] ?? "")")
                                        .foregroundStyle(.secondary).privacySensitive()
                                    Spacer()
                                    Button("Clear", role: .destructive) { model.clearServerToken(s) }
                                }
                            }
                            serverStatus(s)
                        } header: {
                            HStack {
                                Text(s.label)
                                Spacer()
                                status(for: s)
                            }
                        }
                    }
                    Section {
                        Button {
                            checking = true
                            Task {
                                for s in ServerID.allCases {
                                    let u = (urls[s] ?? "").trimmingCharacters(in: .whitespaces)
                                    if s == .linux { model.linuxURL = u } else { model.windowsURL = u }
                                    let typed = (drafts[s] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !typed.isEmpty {
                                        model.setServerToken(typed, for: s)
                                        drafts[s] = ""
                                    }
                                    if model.serverSaved[s.rawValue] == true && !u.isEmpty {
                                        await model.verifyServer(s)
                                    }
                                }
                                checking = false
                            }
                        } label: {
                            HStack { Text("Save and connect"); Spacer(); if checking { ProgressView() } }
                        }
                    } footer: {
                        Text("Lumen uses whichever computer is online. Away from home, use Tailscale or another HTTPS address.")
                    }
                }

                Section("Voice") {
                    Toggle("Speak replies", isOn: $model.speakReplies).tint(Theme.accent)
                    Picker("Spoken voice", selection: $model.speechVoiceID) {
                        Text("Best available").tag("")
                        ForEach(appleVoices, id: \.identifier) { voice in
                            Text("\(voice.name) · \(voice.language)").tag(voice.identifier)
                        }
                    }
                    HStack {
                        Text("Rate")
                        Slider(value: $model.speechRate, in: 0.35...0.6)
                    }
                    Button("Preview") { model.previewVoice() }
                    if !model.usesProvider {
                        Picker("Server voice", selection: Binding(get: { model.voice },
                                                                  set: { v in Task { await model.setVoice(v) } })) {
                            ForEach(voiceList, id: \.self) { v in Text(voiceNames[v] ?? v).tag(v) }
                        }
                    }
                } footer: {
                    Text("Spoken replies use a voice already on this iPhone. Nothing else is billed for speech.")
                }

                Section {
                    Toggle("Say “Lumen” to talk", isOn: Binding(get: { model.wakeWordEnabled },
                                                                  set: { v in Task { await model.setWakeWord(v) } }))
                        .tint(Theme.accent)
                } header: {
                    Text("Hands-free")
                } footer: {
                    Text("Listens on this iPhone only; nothing is sent until it hears “Lumen”. Say “Lumen”, wait for the buzz, then speak. It works only while the app is open on screen (iOS doesn't allow it with the phone locked), keeps the screen awake, and uses more battery.")
                }

                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(lockStatus).foregroundStyle(.secondary)
                    }
                    Button(model.enrollRecording ? "Stop and save sample" : "Record a voice sample") {
                        Task {
                            if model.enrollRecording { await model.finishEnrollSample() }
                            else { await model.startEnrollSample() }
                        }
                    }
                    .disabled(model.active == nil)
                    if model.enrolled > 0 {
                        Button("Clear voiceprint", role: .destructive) { Task { await model.clearVoiceprint() } }
                    }
                    if !model.enrollNote.isEmpty {
                        Text(model.enrollNote).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Voice lock")
                } footer: {
                    Text("Record \(model.enrollNeeded) samples of a couple of sentences each. After that Lumen ignores voices that don't match yours. Each system keeps its own voiceprint, so do this on whichever one is “In use”, then again after switching. It's a convenience lock, not strong security: a recording of your voice could fool it. PC tasks still need your Approve tap.")
                }

                Section {
                    Button("Start a new conversation", role: .destructive) {
                        Task { await model.resetConversation(); dismiss() }
                    }
                    Button("Clear saved history", role: .destructive) { model.clearHistory() }
                } footer: {
                    Text("History stays on this iPhone. Lumen can answer and save notes. It can't change anything on your PC or accounts.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                for s in ServerID.allCases { urls[s] = model.url(s) }
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

    @ViewBuilder private var providerStatus: some View {
        switch model.providerStatus {
        case .idle: EmptyView()
        case .checking: ProgressView()
        case .connected(let name): ConnectedLine(name: name)
        case .rejected: Text("That API key was rejected.").foregroundStyle(.red)
        case .unrecognized: Text("Use a Grok, Claude, Gemini, Groq, OpenRouter, or OpenAI key.").foregroundStyle(.red)
        case .unreachable: Text("Can't reach the provider. Check your connection and try again.").foregroundStyle(.red)
        }
    }

    @ViewBuilder private func serverStatus(_ s: ServerID) -> some View {
        switch model.serverLink[s.rawValue] ?? .idle {
        case .idle: EmptyView()
        case .checking: ProgressView()
        case .connected(let name): ConnectedLine(name: name)
        case .rejected: Text("That token was rejected.").foregroundStyle(.red)
        case .unreachable: Text("Can't reach \(s.label).").foregroundStyle(.red)
        }
    }

    private func draftBinding(_ s: ServerID) -> Binding<String> {
        Binding(get: { drafts[s] ?? "" }, set: { drafts[s] = $0 })
    }

    private func binding(for s: ServerID, in dict: Binding<[ServerID: String]>) -> Binding<String> {
        Binding(get: { dict.wrappedValue[s] ?? "" }, set: { dict.wrappedValue[s] = $0 })
    }

    private var lockStatus: String {
        if model.speakerLock { return "On" }
        return model.enrolled == 0 ? "Not set up" : "\(model.enrolled) of \(model.enrollNeeded) samples"
    }

    private var appleVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var voiceList: [String] {
        let preferred = ["bm_george", "bm_lewis", "bm_daniel", "bm_fable", "bf_emma", "bf_alice", "bf_isabella", "bf_lily"]
        let available = Set(model.voices)
        let list = available.isEmpty ? preferred : preferred.filter(available.contains) + model.voices.filter { !preferred.contains($0) }
        return list.contains(model.voice) ? list : [model.voice] + list
    }
}
