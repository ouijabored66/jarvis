import Foundation
import SwiftUI
import UIKit

struct PCAction: Equatable {
    enum Status: String { case pending, running, done, failed, cancelled, expired }
    let id: String
    let task: String
    let server: ServerID
    var status: Status
    var result: String = ""
}

struct ChatMessage: Identifiable, Equatable {
    enum Role { case me, jarvis, system }
    let id = UUID()
    let role: Role
    var text: String
    var spokenAudio: [Data] = []     // kept so a private reply can be played on demand
    var isPrivate = false
    var savedNote = false
    var action: PCAction? = nil
    let date = Date()
}

enum JarvisState: Equatable { case idle, listening, thinking, speaking, offline }

/// The two places Jarvis can run. The desktop dual-boots, so usually only one is online.
enum ServerID: String, CaseIterable, Identifiable {
    case linux, windows
    var id: String { rawValue }
    var label: String { self == .linux ? "Linux" : "Windows" }
    var defaultURL: String {
        self == .linux ? "https://linux-pc.your-tailnet.ts.net" : "https://windows-pc.your-tailnet.ts.net"
    }
    var other: ServerID { self == .linux ? .windows : .linux }
}

/// How a request went, so failover knows when it's safe to try the other server.
private enum Outcome { case ok, unreachable, refused }   // refused = 401/429/other HTTP answer: never retry elsewhere

@MainActor
final class JarvisModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var state: JarvisState = .idle
    @Published var level: Float = 0
    @Published var voices: [String] = []
    @Published var active: ServerID?                       // the connection in use right now
    @Published var online: [ServerID: Bool] = [:]          // last check result per connection

    @AppStorage("url.linux") var linuxURL = ServerID.linux.defaultURL
    @AppStorage("url.windows") var windowsURL = ServerID.windows.defaultURL
    @AppStorage("lastGood") private var lastGood = ServerID.linux.rawValue
    @AppStorage("speakReplies") var speakReplies = true
    @AppStorage("voice") var voice = "bm_george"
    @Published var linuxToken: String = JarvisModel.loadToken(.linux) { didSet { Keychain.set(linuxToken, for: "token.linux") } }
    @Published var windowsToken: String = Keychain.get("token.windows") { didSet { Keychain.set(windowsToken, for: "token.windows") } }

    var connected: Bool { active != nil }

    private let audio = AudioEngine()
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private var probeTask: Task<Void, Never>?

    /// Version 1 stored a single token under "token"; it was the Linux one.
    private static func loadToken(_ s: ServerID) -> String {
        let t = Keychain.get("token.\(s.rawValue)")
        if t.isEmpty, s == .linux {
            let old = Keychain.get("token")
            if !old.isEmpty { Keychain.set(old, for: "token.linux") }
            return old
        }
        return t
    }

    init() {
        audio.onLevel = { [weak self] l in Task { @MainActor in self?.level = l } }
        audio.onPlayingChanged = { [weak self] playing in
            Task { @MainActor in
                guard let self else { return }
                if playing { self.state = .speaking }
                else if self.state == .speaking { self.state = .idle }
            }
        }
        // Carry over the version 1 address if it was customised.
        if let old = UserDefaults.standard.string(forKey: "serverURL"), !old.isEmpty, old != linuxURL {
            linuxURL = old
            UserDefaults.standard.removeObject(forKey: "serverURL")
        }
        messages.append(ChatMessage(role: .system, text: "Hold the button to talk, or type below."))
    }

    func url(_ s: ServerID) -> String { s == .linux ? linuxURL : windowsURL }
    func token(_ s: ServerID) -> String { s == .linux ? linuxToken : windowsToken }
    func isConfigured(_ s: ServerID) -> Bool { !token(s).isEmpty && URL(string: url(s)) != nil }
    var isConfigured: Bool { ServerID.allCases.contains(where: isConfigured) }

    // MARK: - Requests

    private func request(_ s: ServerID, _ path: String, method: String = "GET", body: Data? = nil,
                         contentType: String? = nil, timeout: TimeInterval = 90) -> URLRequest? {
        guard isConfigured(s), let base = URL(string: url(s)), let u = URL(string: path, relativeTo: base) else { return nil }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("Bearer \(token(s))", forHTTPHeaderField: "Authorization")
        if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        r.httpBody = body
        return r
    }

    /// Is this connection up? 3-second check of /api/status.
    private func check(_ s: ServerID) async -> [String: Any]? {
        guard let r = request(s, "/api/status", timeout: 3) else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["ok"] as? Bool) == true else { return nil }
        return obj
    }

    /// Check both connections at once and switch to whichever is online (last good one wins a tie).
    func refreshStatus() async {
        var results: [ServerID: [String: Any]] = [:]
        await withTaskGroup(of: (ServerID, [String: Any]?).self) { group in
            for s in ServerID.allCases { group.addTask { await (s, self.check(s)) } }
            for await (s, r) in group { if let r { results[s] = r } }
        }
        for s in ServerID.allCases { online[s] = results[s] != nil }
        let preferred = ServerID(rawValue: lastGood) ?? .linux
        let pick: ServerID? = results[preferred] != nil ? preferred : (results[preferred.other] != nil ? preferred.other : nil)
        let changed = pick != active && active != nil && pick != nil
        active = pick
        if let pick, let obj = results[pick] {
            lastGood = pick.rawValue
            voices = (obj["voices"] as? [String]) ?? voices
            if let v = obj["voice"] as? String { voice = v }
            if state == .offline { state = .idle }
            if changed { messages.append(ChatMessage(role: .system, text: "Switched to \(pick.label).")) }
            await loadPendingActions()
        } else if state != .listening && state != .thinking {
            state = .offline
        }
    }

    /// Keep checking while the app is open: every 20 s when offline, every 60 s when online.
    func startMonitoring() {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                let wait: UInt64 = (self?.active == nil) ? 20 : 60
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            }
        }
    }

    func stopMonitoring() { probeTask?.cancel(); probeTask = nil }

    /// Run a request on the active connection; if that machine is unreachable, re-check and try the other once.
    /// Never retries on a refusal (wrong token / rate limit), so it can't trip the lockout.
    private func withFailover(_ attempt: (ServerID) async -> Outcome) async -> Bool {
        if active == nil { await refreshStatus() }
        guard let first = active else { return false }
        switch await attempt(first) {
        case .ok: return true
        case .refused: return false
        case .unreachable:
            online[first] = false
            await refreshStatus()
            guard let second = active, second != first else { return false }
            return await attempt(second) == .ok
        }
    }

    private static func isUnreachable(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed].contains(e.code)
    }

    func setVoice(_ v: String) async {
        voice = v
        let body = try? JSONSerialization.data(withJSONObject: ["voice": v])
        for s in ServerID.allCases where online[s] == true {     // keep both machines on the same voice
            if let r = request(s, "/api/voice", method: "POST", body: body, contentType: "application/json") {
                _ = try? await URLSession.shared.data(for: r)
            }
        }
    }

    func resetConversation() async {
        audio.stopPlayback()
        if let s = active, let r = request(s, "/api/reset", method: "POST") { _ = try? await URLSession.shared.data(for: r) }
        messages = [ChatMessage(role: .system, text: "New conversation. Hold the button to talk, or type below.")]
        state = connected ? .idle : .offline
    }

    // MARK: - Typing

    func send(text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        audio.stopPlayback()
        messages.append(ChatMessage(role: .me, text: t))
        state = .thinking
        let body = try? JSONSerialization.data(withJSONObject: ["text": t])
        let path = speakReplies ? "/api/text?audio=1" : "/api/text"
        var refusedCode = 0
        let ok = await withFailover { s in
            guard let r = self.request(s, path, method: "POST", body: body, contentType: "application/json") else { return .unreachable }
            do {
                let (data, resp) = try await URLSession.shared.data(for: r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    refusedCode = code; return .refused
                }
                var msg = ChatMessage(role: .jarvis, text: (obj["say"] as? String) ?? "")
                msg.isPrivate = (obj["private"] as? Bool) ?? false
                msg.savedNote = (obj["saved"] as? Bool) ?? false
                msg.action = JarvisModel.action(from: obj["action"], server: s)
                if let b64 = obj["audio"] as? String, let wav = Data(base64Encoded: b64) { msg.spokenAudio = [wav] }
                self.messages.append(msg)
                self.state = .idle
                if self.speakReplies && !msg.isPrivate { msg.spokenAudio.forEach { self.audio.enqueue($0) } }
                return .ok
            } catch {
                return JarvisModel.isUnreachable(error) ? .unreachable : .refused
            }
        }
        if !ok { fail(refusedText(refusedCode)) }
    }

    // MARK: - Talking

    func beginTalking() {
        Task {
            guard await audio.requestPermission() else {
                fail("Microphone access is off. Turn it on in Settings, then Jarvis."); return
            }
            do {
                try audio.startRecording()
                haptic.impactOccurred()
                state = .listening
            } catch {
                fail("Couldn't start the microphone.")
            }
        }
    }

    func endTalking() {
        guard state == .listening else { return }
        haptic.impactOccurred(intensity: 0.6)
        guard let clip = audio.stopRecording() else { state = .idle; return }
        state = .thinking
        Task { await upload(clip) }
    }

    private func upload(_ clip: Data) async {
        var refusedCode = 0
        let ok = await withFailover { s in
            guard let r = self.request(s, "/api/ask", method: "POST", body: clip, contentType: "audio/m4a", timeout: 120) else { return .unreachable }
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { refusedCode = code; return .refused }
                var replyIndex: Int?
                for try await line in bytes.lines {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                    if let heard = obj["heard"] as? String {
                        self.messages.append(heard.isEmpty
                            ? ChatMessage(role: .system, text: "I didn't catch that. Try again a little closer.")
                            : ChatMessage(role: .me, text: heard))
                    } else if let reply = obj["reply"] as? String {
                        var m = ChatMessage(role: .jarvis, text: reply)
                        m.isPrivate = (obj["private"] as? Bool) ?? false
                        m.savedNote = (obj["saved"] as? Bool) ?? false
                        m.action = JarvisModel.action(from: obj["action"], server: s)
                        self.messages.append(m)
                        replyIndex = self.messages.count - 1
                    } else if obj["say"] != nil, let b64 = obj["audio"] as? String, let wav = Data(base64Encoded: b64) {
                        if let i = replyIndex {
                            self.messages[i].spokenAudio.append(wav)
                            if self.speakReplies && !self.messages[i].isPrivate { self.audio.enqueue(wav) }
                        }
                    } else if obj["done"] != nil {
                        break
                    }
                }
                if self.state == .thinking { self.state = .idle }
                return .ok
            } catch {
                return JarvisModel.isUnreachable(error) ? .unreachable : .refused
            }
        }
        if !ok { fail(refusedText(refusedCode)) }
    }

    // MARK: - PC actions (Jarvis proposes, you approve, the PC does it)

    static func action(from any: Any?, server: ServerID) -> PCAction? {
        guard let d = any as? [String: Any], let id = d["id"] as? String, let task = d["task"] as? String else { return nil }
        return PCAction(id: id, task: task, server: server, status: .pending)
    }

    private func updateAction(_ id: String, _ change: (inout PCAction) -> Void) {
        for i in messages.indices where messages[i].action?.id == id {
            if var a = messages[i].action { change(&a); messages[i].action = a }
        }
    }

    func approve(_ action: PCAction) async {
        guard let r = request(action.server, "/api/action/\(action.id)/approve", method: "POST", timeout: 15) else { return }
        haptic.impactOccurred()
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                fail(msg ?? (code == 403 ? "PC control only works from this app over Tailscale." : "Couldn't approve that (\(code))."))
                return
            }
            updateAction(action.id) { $0.status = .running }
            await watch(action)
        } catch {
            fail("Couldn't reach \(action.server.label) to approve that.")
        }
    }

    func cancel(_ action: PCAction) async {
        if let r = request(action.server, "/api/action/\(action.id)/cancel", method: "POST", timeout: 15) {
            _ = try? await URLSession.shared.data(for: r)
        }
        updateAction(action.id) { $0.status = .cancelled }
    }

    /// Poll a running task until the PC reports back, then show and speak the result.
    private func watch(_ action: PCAction) async {
        for _ in 0..<720 {                                   // up to an hour
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let r = request(action.server, "/api/action/\(action.id)?audio=1", timeout: 30),
                  let (data, _) = try? await URLSession.shared.data(for: r),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let st = PCAction.Status(rawValue: (obj["status"] as? String) ?? "") else { continue }
            if st == .running { continue }
            let result = (obj["result"] as? String) ?? ""
            updateAction(action.id) { $0.status = st; $0.result = result }
            var msg = ChatMessage(role: .jarvis, text: (obj["spoken"] as? String) ?? (st == .done ? "Done, sir." : "That didn't work, sir."))
            if let b64 = obj["audio"] as? String, let wav = Data(base64Encoded: b64) { msg.spokenAudio = [wav] }
            messages.append(msg)
            if speakReplies { msg.spokenAudio.forEach { audio.enqueue($0) } }
            return
        }
    }

    /// Show tasks that are still waiting (for example ones asked for from the Watch).
    func loadPendingActions() async {
        guard let s = active, let r = request(s, "/api/actions", timeout: 10),
              let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["actions"] as? [[String: Any]] else { return }
        for a in list where (a["status"] as? String) == "pending" {
            guard let id = a["id"] as? String, !messages.contains(where: { $0.action?.id == id }) else { continue }
            var m = ChatMessage(role: .jarvis, text: "Waiting for your approval: \((a["asked"] as? String) ?? "a task").")
            m.action = PCAction(id: id, task: (a["task"] as? String) ?? "", server: s, status: .pending)
            messages.append(m)
        }
    }

    func play(_ message: ChatMessage) {
        audio.stopPlayback()
        message.spokenAudio.forEach { audio.enqueue($0) }
    }

    func stopSpeaking() { audio.stopPlayback() }

    private func refusedText(_ code: Int) -> String {
        switch code {
        case 401: return "\(active?.label ?? "Jarvis") didn't accept the token. Check it in Settings."
        case 429: return "Jarvis says slow down a moment, sir. Try again in a minute."
        case 0: return connected ? "Jarvis didn't answer that time." : "Can't reach Jarvis on Linux or Windows. Is the desktop on?"
        default: return "Jarvis had a problem (\(code)). Try again."
        }
    }

    private func fail(_ text: String) {
        messages.append(ChatMessage(role: .system, text: text))
        state = connected ? .idle : .offline
    }
}
