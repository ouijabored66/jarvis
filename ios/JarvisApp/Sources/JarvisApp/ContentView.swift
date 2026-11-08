import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: JarvisModel
    @State private var draft = ""
    @State private var showSettings = false
    @State private var pressing = false
    @FocusState private var typing: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 0) {
                header
                ReactorView(state: model.state, level: model.level)
                    .frame(height: typing ? 110 : 210)
                    .padding(.vertical, 6)
                    .animation(.spring(duration: 0.35), value: typing)
                statusLine
                transcript
                inputBar
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
        .task {
            if !model.isConfigured { showSettings = true }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Re-check both connections whenever the app comes to the front.
            if phase == .active { model.startMonitoring() } else { model.stopMonitoring() }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("J.A.R.V.I.S.")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing))
                HStack(spacing: 10) {
                    if model.demoMode {
                        Text("DEMO MODE")
                            .font(.caption2.weight(.heavy)).tracking(1)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.orange, in: Capsule())
                            .accessibilityLabel("Demo Mode is on. Replies are simulated.")
                    } else {
                        ForEach(ServerID.allCases) { s in
                            ServerPill(label: s.label, online: model.online[s] == true, inUse: model.active == s)
                        }
                    }
                }
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Theme.card, in: Circle())
                    .overlay(Circle().stroke(Theme.stroke))
            }
            .tint(.white)
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    private var statusLine: some View {
        Text(statusText)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.accent.opacity(0.85))
            .contentTransition(.opacity)
            .animation(.easeInOut, value: model.state)
            .padding(.bottom, 6)
    }

    private var statusText: String {
        switch model.state {
        case .idle: return model.demoMode ? "At your service (demo)" : "At your service"
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking"
        case .offline: return "Can't reach Jarvis on Linux or Windows"
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.messages) { m in
                        MessageBubble(message: m,
                                      onPlay: { model.play(m) },
                                      onApprove: { a in Task { await model.approve(a) } },
                                      onCancel: { a in Task { await model.cancel(a) } })
                            .id(m.id)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count) {
                if let last = model.messages.last {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Message Jarvis", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($typing)
                .submitLabel(.send)
                .onSubmit(sendDraft)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))

            if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 46, height: 46)
                        .background(Theme.accent, in: Circle())
                }
                .transition(.scale.combined(with: .opacity))
            } else if model.state == .speaking {
                Button { model.stopSpeaking() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 58, height: 58)
                        .background(Theme.card, in: Circle())
                        .overlay(Circle().stroke(Theme.accent, lineWidth: 2))
                }
                .tint(.white)
            } else {
                micButton
            }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .animation(.spring(duration: 0.25), value: draft.isEmpty)
    }

    private var micButton: some View {
        ZStack {
            Circle()
                .fill(pressing ? Theme.accent : Theme.card)
                .overlay(Circle().stroke(Theme.accent.opacity(pressing ? 0 : 0.8), lineWidth: 2))
                .shadow(color: Theme.accent.opacity(pressing ? 0.7 : 0.25), radius: pressing ? 18 : 8)
                .scaleEffect(pressing ? 1.12 + CGFloat(model.level) * 0.15 : 1)
            Image(systemName: model.state == .thinking ? "ellipsis" : "mic.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(pressing ? .black : Theme.accent)
                .symbolEffect(.pulse, isActive: model.state == .thinking)
        }
        .frame(width: 58, height: 58)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing, model.state != .thinking else { return }
                    pressing = true
                    typing = false
                    model.beginTalking()
                }
                .onEnded { _ in
                    guard pressing else { return }
                    pressing = false
                    model.endTalking()
                }
        )
        .animation(.spring(duration: 0.2), value: pressing)
        .accessibilityLabel("Hold to talk")
    }

    private func sendDraft() {
        let t = draft
        draft = ""
        Task { await model.send(text: t) }
    }
}

/// A task Jarvis wants to run on the PC. Nothing happens until you tap Approve.
struct ActionCard: View {
    let action: PCAction
    var onApprove: () -> Void
    var onCancel: () -> Void
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.caption.weight(.bold)).foregroundStyle(tint)
                Spacer()
                Text(action.server.label).font(.caption2).foregroundStyle(.secondary)
            }
            Text(action.task)
                .font(.footnote).foregroundStyle(.white.opacity(0.85))
                .lineLimit(showDetails ? nil : 3)
                .onTapGesture { showDetails.toggle() }
            switch action.status {
            case .pending:
                HStack(spacing: 10) {
                    Button(action: onApprove) {
                        Label("Approve", systemImage: "checkmark")
                            .font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 9)
                            .foregroundStyle(.black)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 9)
                            .foregroundStyle(.white)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke))
                    }
                }
            case .running:
                HStack(spacing: 8) { ProgressView().tint(Theme.accent); Text("Working on your PC…").font(.caption).foregroundStyle(.secondary) }
            case .done, .failed:
                if !action.result.isEmpty {
                    DisclosureGroup(isExpanded: $showDetails) {
                        Text(action.result).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } label: { Text("Details").font(.caption.weight(.semibold)) }
                    .tint(Theme.accent)
                }
            case .cancelled, .expired:
                EmptyView()
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tint.opacity(0.5)))
        .animation(.easeInOut(duration: 0.2), value: action.status)
    }

    private var title: String {
        switch action.status {
        case .pending: return "Needs your approval"
        case .running: return "Running"
        case .done: return "Done"
        case .failed: return "Didn't work"
        case .cancelled: return "Cancelled"
        case .expired: return "Expired"
        }
    }
    private var icon: String {
        switch action.status {
        case .pending: return "hand.raised.fill"
        case .running: return "gearshape.2.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled, .expired: return "xmark.circle"
        }
    }
    private var tint: Color {
        switch action.status {
        case .pending: return .orange
        case .running: return Theme.accent2
        case .done: return Theme.accent
        case .failed: return .red
        case .cancelled, .expired: return .gray
        }
    }
}

/// Small "Linux" / "Windows" status pill: green dot when online, filled when it's the one in use.
struct ServerPill: View {
    let label: String
    let online: Bool
    let inUse: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(online ? Theme.accent : Color.gray.opacity(0.5))
                .frame(width: 7, height: 7)
                .shadow(color: online ? Theme.accent.opacity(0.8) : .clear, radius: 3)
            Text(label)
                .font(.caption2.weight(inUse ? .bold : .medium))
                .foregroundStyle(inUse ? Color.black : (online ? Color.white : Color.secondary))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(inUse ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.card), in: Capsule())
        .overlay(Capsule().stroke(inUse ? Color.clear : Theme.stroke))
        .animation(.easeInOut(duration: 0.25), value: inUse)
        .accessibilityLabel("\(label) \(inUse ? "in use" : (online ? "online" : "offline"))")
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var onPlay: () -> Void
    var onApprove: (PCAction) -> Void = { _ in }
    var onCancel: (PCAction) -> Void = { _ in }

    var body: some View {
        switch message.role {
        case .system:
            Text(message.text)
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        case .me:
            HStack {
                Spacer(minLength: 50)
                Text(message.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(.black)
                    .background(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case .jarvis:
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.text).foregroundStyle(.white)
                    if let a = message.action {
                        ActionCard(action: a, onApprove: { onApprove(a) }, onCancel: { onCancel(a) })
                    }
                    HStack(spacing: 12) {
                        if !message.spokenAudio.isEmpty {
                            Button(action: onPlay) {
                                Label(message.isPrivate ? "Private · tap to play" : "Play", systemImage: "speaker.wave.2.fill")
                                    .font(.caption.weight(.semibold))
                            }
                            .tint(Theme.accent)
                        }
                        if message.savedNote {
                            Label("Note saved", systemImage: "tray.and.arrow.down.fill")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke))
                Spacer(minLength: 40)
            }
        }
    }
}
