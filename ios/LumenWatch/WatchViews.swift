import SwiftUI
import WatchKit

private let accent = Color(red: 1.00, green: 0.761, blue: 0.290)   // #FFC24A, same warm gold as the iPhone app
private let accent2 = Color(red: 1.00, green: 0.541, blue: 0.239)  // #FF8A3D amber

/// Talk at the top (one tap starts dictation), newest reply first, scroll for older history.
struct WatchContentView: View {
    @EnvironmentObject var model: WatchModel
    @State private var draft = ""
    @State private var dictating = false
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            List {
                talkButton
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 8, trailing: 4))

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
            .onAppear { consumeDictateNow() }
            .onChange(of: model.dictateNow) { _, ready in
                if ready { consumeDictateNow() }
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

    private var talkButton: some View {
        Button(action: talkTapped) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [accent, accent2], startPoint: .top, endPoint: .bottom))
                talkLabel
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(talkAccessLabel)
        .accessibilityHint(model.speaking || model.busy ? "" : "Starts dictation")
    }

    @ViewBuilder
    private var talkLabel: some View {
        if model.speaking {
            Image(systemName: "stop.fill")
                .font(.system(size: 34, weight: .bold))
        } else if model.busy {
            Text("Thinking...")
                .font(.headline.weight(.bold))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
        } else {
            VStack(spacing: 2) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 32, weight: .bold))
                Text("Talk")
                    .font(.headline.weight(.bold))
            }
        }
    }

    private var talkAccessLabel: String {
        if model.speaking { return "Stop speaking" }
        if model.busy { return "Thinking" }
        return "Talk"
    }

    private func talkTapped() {
        if model.speaking {
            model.stopSpeaking()
            return
        }
        openDictation()
    }

    /// The face complication sets `dictateNow` so the microphone opens with the app.
    private func consumeDictateNow() {
        guard model.dictateNow else { return }
        model.dictateNow = false
        if model.speaking { model.stopSpeaking() }
        openDictation()
    }

    private func openDictation() {
        guard !model.busy, !dictating else { return }
        dictating = true
        Task { await presentDictation() }
    }

    private func presentDictation() async {
        for _ in 0..<20 {
            if WatchDictation.present({ text in
                dictating = false
                guard let text else { return }
                draft = text
                send()
            }) {
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        dictating = false
        typing = true
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await model.ask(text) }
    }
}

/// Built-in dictation. A nil suggestion list opens the microphone and skips the keyboard.
private enum WatchDictation {
    static func present(_ done: @escaping (String?) -> Void) -> Bool {
        guard let controller = WKApplication.shared().visibleInterfaceController else { return false }
        controller.presentTextInputController(withSuggestions: nil, allowedInputMode: .plain) { results in
            let text = (results?.first as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let spoken = (text?.isEmpty == false) ? text : nil
            DispatchQueue.main.async { done(spoken) }
        }
        return true
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
        case .lumen:
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
