import SwiftUI
import WatchKit

private let accent = Color(red: 1.00, green: 0.761, blue: 0.290)   // #FFC24A, same warm gold as the iPhone app
private let accent2 = Color(red: 1.00, green: 0.541, blue: 0.239)  // #FF8A3D amber
private let talkSide: CGFloat = 96   // about 60% of the width on a 45mm screen

/// Talk at the top. One tap records, the field stays underneath, newest reply first.
struct WatchContentView: View {
    @EnvironmentObject var model: WatchModel
    @State private var draft = ""
    @FocusState private var typing: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                toolbarButtons
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))

                talkButton
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 2, trailing: 0))

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
                    .disabled(model.busy || model.listening)

                ForEach(model.history.suffix(8).reversed()) { entry in
                    WatchEntryRow(entry: entry)
                        .listRowBackground(Color.clear)
                }

                HStack {
                    ForEach(["What can you do?", "Joke"], id: \.self) { prompt in
                        Button(prompt) {
                            Task { await model.ask(prompt == "Joke" ? "Tell me a joke" : prompt) }
                        }
                        .font(.caption2)
                        .disabled(model.busy || model.listening)
                    }
                }
                .listRowBackground(Color.clear)

                if !model.demoMode {
                    Text(model.routeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(model.assistantTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                model.refreshReachable()
                model.consumeLaunchRequest()
            }
            .onChange(of: model.dictateNow) { _, ready in
                if ready { model.consumeLaunchRequest() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.consumeLaunchRequest() }
            }
            .sheet(isPresented: Binding(get: { model.actionQueue.first != nil }, set: { _ in })) {
                if let item = model.actionQueue.first {
                    WatchActionSheet(title: item.title, detail: item.detail, note: model.actionNote, busy: model.actionBusy) {
                        Task { await model.decideAction(approve: true) }
                    } onDeny: {
                        Task { await model.decideAction(approve: false) }
                    }
                    .interactiveDismissDisabled(true)
                }
            }
        }
        .tint(accent)
    }

    private var toolbarButtons: some View {
        HStack {
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .accessibilityLabel("Refresh")

            Spacer()

            NavigationLink {
                WatchSettingsView()
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .accessibilityLabel("Settings")
        }
    }

    private var talkButton: some View {
        Button(action: talkTapped) {
            ZStack {
                Circle().fill(talkFill)
                talkLabel
                    .padding(.horizontal, 8)
            }
            .frame(width: talkSide, height: talkSide)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(talkAccessLabel)
    }

    private var talkFill: AnyShapeStyle {
        if model.listening {
            return AnyShapeStyle(Color.red)
        }
        return AnyShapeStyle(LinearGradient(colors: [accent, accent2], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder
    private var talkLabel: some View {
        if model.listening {
            Text("Listening… tap to send")
                .font(.system(size: 12, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white)
        } else if model.speaking {
            Image(systemName: "stop.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.black)
        } else if model.answering {
            Text("Lumen is answering…")
                .font(.system(size: 12, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.black)
        } else if model.busy {
            Text("Thinking...")
                .font(.caption.weight(.bold))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.black)
        } else {
            VStack(spacing: 1) {
                Image(systemName: "mic.fill")
                    .font(.title3.weight(.bold))
                Text("Talk")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(.black)
        }
    }

    private var talkAccessLabel: String {
        if model.listening { return "Listening. Tap to send." }
        if model.speaking { return "Stop speaking" }
        if model.answering { return "Lumen is answering" }
        if model.busy { return "Thinking" }
        return "Talk"
    }

    private func talkTapped() {
        if model.listening {
            model.finishListening()
            return
        }
        if model.speaking {
            model.stopSpeaking()
            return
        }
        model.talk()
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await model.ask(text) }
    }
}

struct WatchAction: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
}

struct WatchActionSheet: View {
    let title: String
    let detail: String
    let note: String
    let busy: Bool
    var onApprove: () -> Void
    var onDeny: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                if !detail.isEmpty, detail != title {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if !note.isEmpty {
                    Text(note)
                        .font(.caption2.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                Button(action: onApprove) {
                    Text("Approve").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(busy)
                Button(action: onDeny) {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(busy)
            }
            .padding(.horizontal, 4)
        }
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Button {
                    Task {
                        await model.refresh()
                        dismiss()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accent)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Refresh")
            } footer: {
                Text("Stops a stuck reply, clears this conversation, and reloads settings from the iPhone.")
            }

            Section {
                Toggle("Demo Mode", isOn: Binding(get: { model.demoMode }, set: { model.setDemoMode($0) }))
            } footer: {
                Text("Typed questions get a simulated reply. Talk still sends the recording to the iPhone to turn it into text.")
            }

            Section {
                Toggle("Speak replies", isOn: $model.speakReplies)
                Button("Stop speaking") { model.stopSpeaking() }
            }

            Section {
                Text(model.assistantTitle)
            } footer: {
                Text("Nearby, Talk records here and the iPhone turns it into text. Direct uses the Cloud settings saved on the iPhone.")
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
