import SwiftUI

/// First launch: API key, or the desktop server. The key is never shown again after it is saved.
struct OnboardingView: View {
    @EnvironmentObject var model: JarvisModel
    var onDone: () -> Void

    @State private var choice: Choice?
    @State private var providerDraft = ""
    @State private var urls: [ServerID: String] = [:]
    @State private var drafts: [ServerID: String] = [:]
    @State private var busy = false

    private enum Choice { case provider, server }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("How should Lumen think?")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Speech stays on this iPhone. One key is enough, or you can run the small server on your computer.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        choiceButton("Use your API key", "Grok, Claude, Gemini, Groq, OpenRouter, or OpenAI. The key stays in the iPhone Keychain.", .provider)
                        choiceButton("Run your own server", "A URL and token from python3 desktop/server.py. The provider key stays on that computer.", .server)
                        if choice == .provider { providerForm }
                        if choice == .server { serverForm }
                    }
                    .padding(22)
                }
            }
            .navigationTitle("Lumen Voice")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Theme.accent)
        .onAppear {
            for s in ServerID.allCases { urls[s] = model.url(s) }
        }
    }

    private func choiceButton(_ title: String, _ detail: String, _ value: Choice) -> some View {
        Button {
            choice = value
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(choice == value ? .black : .white)
                Text(detail).font(.footnote).foregroundStyle(choice == value ? .black.opacity(0.75) : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(choice == value ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.card),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.stroke))
        }
        .buttonStyle(.plain)
    }

    private var providerForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecretEntry(title: "API Key", saved: model.providerKeySaved, suffix: model.providerKeySuffix,
                        draft: $providerDraft) { model.clearProviderKey() }
            statusBlock
            Button {
                let typed = providerDraft
                busy = true
                Task {
                    model.setLinkMode(provider: true)
                    await model.saveProviderKey(typed)
                    if model.providerStatus != .unrecognized { providerDraft = "" }
                    busy = false
                    if case .connected = model.providerStatus { onDone() }
                }
            } label: {
                HStack { Text("Save and connect"); Spacer(); if busy { ProgressView() } }
            }
            .disabled(busy)
        }
    }

    private var serverForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ServerID.allCases) { s in
                Text(s.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("https://…", text: urlBinding(s))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .padding(10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                SecretEntry(title: "Server token", saved: model.serverSaved[s.rawValue] == true,
                            suffix: model.serverSuffix[s.rawValue] ?? "", draft: draftBinding(s)) {
                    model.clearServerToken(s)
                }
                serverStatus(s)
            }
            Button {
                busy = true
                Task {
                    model.setLinkMode(provider: false)
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
                    busy = false
                    if ServerID.allCases.contains(where: { if case .some(.connected) = model.serverLink[$0.rawValue] { return true }; return false }) {
                        onDone()
                    }
                }
            } label: {
                HStack { Text("Save and connect"); Spacer(); if busy { ProgressView() } }
            }
            .disabled(busy)
        }
    }

    @ViewBuilder private var statusBlock: some View {
        switch model.providerStatus {
        case .idle: EmptyView()
        case .checking: ProgressView()
        case .connected(let name): ConnectedLine(name: name)
        case .rejected: Text("That API key was rejected.").font(.footnote).foregroundStyle(.red)
        case .unrecognized: Text("Use a Grok, Claude, Gemini, Groq, OpenRouter, or OpenAI key.").font(.footnote).foregroundStyle(.red)
        case .unreachable: Text("Can't reach the provider. Check your connection and try again.").font(.footnote).foregroundStyle(.red)
        }
    }

    @ViewBuilder private func serverStatus(_ s: ServerID) -> some View {
        switch model.serverLink[s.rawValue] ?? .idle {
        case .idle: EmptyView()
        case .checking: ProgressView()
        case .connected(let name): ConnectedLine(name: name)
        case .rejected: Text("That token was rejected.").font(.footnote).foregroundStyle(.red)
        case .unreachable: Text("Can't reach \(s.label). Check the URL and that the computer is on.").font(.footnote).foregroundStyle(.red)
        }
    }

    private func urlBinding(_ s: ServerID) -> Binding<String> {
        Binding(get: { urls[s] ?? "" }, set: { urls[s] = $0 })
    }

    private func draftBinding(_ s: ServerID) -> Binding<String> {
        Binding(get: { drafts[s] ?? "" }, set: { drafts[s] = $0 })
    }
}

struct SecretEntry: View {
    let title: String
    let saved: Bool
    let suffix: String
    @Binding var draft: String
    var onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(title, text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(nil)
                .privacySensitive()
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if saved {
                HStack {
                    Text(suffix.isEmpty ? "Saved" : "Saved · ••••\(suffix)")
                        .font(.footnote).foregroundStyle(.secondary)
                        .privacySensitive()
                    Spacer()
                    Button("Clear", role: .destructive, action: onClear).font(.footnote)
                }
            }
        }
    }
}

struct ConnectedLine: View {
    let name: String
    var body: some View {
        Label("Connected to \(name)", systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .accessibilityLabel("Connected to \(name)")
    }
}
