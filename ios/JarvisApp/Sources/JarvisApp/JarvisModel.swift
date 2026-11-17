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
    let date: Date

    init(role: Role, text: String, date: Date = Date(), isPrivate: Bool = false, savedNote: Bool = false, action: PCAction? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.spokenAudio = []
        self.isPrivate = isPrivate
        self.savedNote = savedNote
        self.action = action
        self.date = date
    }
}

enum JarvisState: Equatable { case idle, listening, thinking, speaking, offline }

enum ProviderLinkStatus: Equatable {
    case idle, checking, connected(String), rejected, unrecognized, unreachable
}

enum ServerLinkStatus: Equatable {
    case idle, checking, connected(String), rejected, unreachable
}

/// How a request went, so failover knows when it's safe to try the other server.
private enum Outcome { case ok, unreachable, refused }   // refused = 401/429/other HTTP answer: never retry elsewhere

@MainActor
final class JarvisModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var state: JarvisState = .idle { didSet { updateWake() } }
    @Published var level: Float = 0
    @Published var voices: [String] = []
    @Published var active: ServerID?                       // the connection in use right now
    @Published var online: [ServerID: Bool] = [:]          // last check result per connection

    // Voice lock: the active server's voiceprint status, and the enrollment flow in Settings.
    @Published var enrolled = 0
    @Published var enrollNeeded = 3
    @Published var speakerLock = false
    @Published var enrollRecording = false
    @Published var enrollNote = ""

    @AppStorage("url.linux") var linuxURL = ServerID.linux.defaultURL
    @AppStorage("url.windows") var windowsURL = ServerID.windows.defaultURL
    @AppStorage("lastGood") private var lastGood = ServerID.linux.rawValue
    @AppStorage("speakReplies") var speakReplies = true
    @AppStorage("voice") var voice = "bm_george"
    @AppStorage("wakeWord") var wakeWordEnabled = false
    /// Demo Mode: simulated replies on the device, no server needed (for trying the app and for App Review).
    @AppStorage("demoMode") private(set) var demoMode = false
    /// "provider", "server", or "" until the person chooses. A saved server token keeps own-server mode.
    @Published var linkChoice: String = UserDefaults.standard.string(forKey: "linkMode") ?? "" {
        didSet { UserDefaults.standard.set(linkChoice, forKey: "linkMode"); refreshTitle() }
    }
    @Published private(set) var assistantTitle = "Lumen"
    @Published private(set) var providerStatus: ProviderLinkStatus = .idle
    @Published private(set) var providerKeySaved = false
    @Published private(set) var providerKeySuffix = ""
    @Published private(set) var serverSaved: [String: Bool] = [:]
    @Published private(set) var serverSuffix: [String: String] = [:]
    @Published private(set) var serverLink: [String: ServerLinkStatus] = [:]
    @Published var customProviders: [CustomProvider] = CustomProvider.load()
    @Published var customActiveID: String = UserDefaults.standard.string(forKey: "custom.active") ?? ""
    @Published var customConnectedName: String?
    @Published var customNote = ""
    @Published var customModels: [String] = []
    @Published var customBusy = false
    /// True after /api/status was read in own-server mode. `voiceLock` is the server's speaker-ID capability.
    @Published var voiceLockKnown = false
    @Published var voiceLockSupported = false

    /// Secrets stay off @Published so the view never holds the full key.
    private var linuxToken: String = JarvisModel.loadToken(.linux) {
        didSet { Keychain.set(linuxToken, for: "token.linux"); publishSecrets() }
    }
    private var windowsToken: String = Keychain.get("token.windows") {
        didSet { Keychain.set(windowsToken, for: "token.windows"); publishSecrets() }
    }
    private var providerKey: String = Keychain.get("provider.apiKey") {
        didSet { Keychain.set(providerKey, for: "provider.apiKey"); publishSecrets() }
    }

    var connectionMode: String {
        if linkChoice == "provider" || linkChoice == "server" || linkChoice == "custom" { return linkChoice }
        if !linuxToken.isEmpty || !windowsToken.isEmpty { return "server" }
        return "provider"
    }
    var usesProvider: Bool { connectionMode == "provider" }
    var usesCustom: Bool { connectionMode == "custom" }
    func setConnectionMode(_ mode: String) {
        linkChoice = mode
        refreshTitle()
        Task { await refreshStatus() }
    }
    var needsOnboarding: Bool {
        if demoMode { return false }
        if linkChoice == "provider" || linkChoice == "server" || linkChoice == "custom" { return false }
        if !providerKey.isEmpty || !linuxToken.isEmpty || !windowsToken.isEmpty || !customProviders.isEmpty { return false }
        return true
    }
    var connected: Bool {
        if demoMode { return true }
        if usesProvider { return !providerKey.isEmpty }
        if usesCustom { return activeCustom?.endpoint(for: .auto) != nil }
        return active != nil
    }

    private let audio = AudioEngine()
    let demoVoice = DemoSpeaker()
    private let wake = WakeWordListener()
    private var appActive = false
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private var probeTask: Task<Void, Never>?
    private var replying = false

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
        LumenHub.model = self
        migratePlaintextSecrets()
        publishSecrets()
        refreshTitle()
        audio.onLevel = { [weak self] l in Task { @MainActor in self?.level = l } }
        audio.onPlayingChanged = { [weak self] playing in
            Task { @MainActor in
                guard let self else { return }
                if playing { self.state = .speaking }
                else if self.state == .speaking { self.state = .idle }
            }
        }
        demoVoice.onSpeakingChanged = audio.onPlayingChanged
        audio.onAutoStop = { [weak self] heard in
            Task { @MainActor in
                guard let self, self.state == .listening, !self.enrollRecording else { return }
                if heard { self.endTalking() } else { self.cancelTalking() }
            }
        }
        wake.onWake = { [weak self] in self?.heardWakeWord() }
        wake.onNeedRestart = { [weak self] in self?.updateWake() }
        // Carry over the version 1 address if it was customised.
        if let old = UserDefaults.standard.string(forKey: "serverURL"), !old.isEmpty, old != linuxURL {
            linuxURL = old
            UserDefaults.standard.removeObject(forKey: "serverURL")
        }
        if let saved = Self.loadTranscript(), !saved.isEmpty {
            messages = saved
        } else if demoMode {
            messages = JarvisModel.demoMessages()
        } else {
            messages.append(ChatMessage(role: .system, text: "Hold the button to talk, or type below."))
        }
    }

    @AppStorage("speech.voice") var speechVoiceID = ""
    @AppStorage("speech.rate") var speechRate = 0.5

    func previewVoice() {
        demoVoice.speak("Hello, I'm Lumen.")
    }

    func clearHistory() {
        stopSpeaking()
        messages = [ChatMessage(role: .system, text: "History cleared. Hold the button to talk, or type below.")]
        saveTranscript()
    }

    func url(_ s: ServerID) -> String { s == .linux ? linuxURL : windowsURL }
    private func token(_ s: ServerID) -> String { s == .linux ? linuxToken : windowsToken }
    func isConfigured(_ s: ServerID) -> Bool { !token(s).isEmpty && URL(string: url(s)) != nil }
    var isConfigured: Bool {
        if demoMode { return true }
        if usesProvider { return !providerKey.isEmpty }
        if usesCustom { return activeCustom?.endpoint(for: .auto) != nil }
        return ServerID.allCases.contains(where: isConfigured)
    }

    func setLinkMode(provider: Bool) {
        linkChoice = provider ? "provider" : "server"
        refreshTitle()
        Task { await refreshStatus() }
    }

    func setServerToken(_ raw: String, for s: ServerID) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if s == .linux { linuxToken = t } else { windowsToken = t }
    }

    func clearServerToken(_ s: ServerID) {
        if s == .linux { linuxToken = "" } else { windowsToken = "" }
        setServerLink(s, .idle)
    }

    func saveProviderKey(_ raw: String) async {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? providerKey : typed
        guard !key.isEmpty else {
            providerStatus = .idle
            refreshTitle()
            return
        }
        guard let provider = AIProvider.detect(key) else {
            providerStatus = .unrecognized
            refreshTitle()
            return
        }
        providerKey = key
        providerStatus = .checking
        switch await ProviderClient().verify(key: key) {
        case .success: providerStatus = .connected(provider.title)
        case .failure(.rejected): providerStatus = .rejected
        case .failure(.unrecognized): providerStatus = .unrecognized
        case .failure: providerStatus = .unreachable
        }
        refreshTitle()
    }

    func clearProviderKey() {
        providerKey = ""
        providerStatus = .idle
        refreshTitle()
    }

    func verifyServer(_ s: ServerID) async {
        setServerLink(s, .checking)
        switch await probe(s) {
        case .ok(let obj):
            let name = Self.assistantName(from: obj, url: url(s))
            online[s] = true
            if active == nil { active = s }
            setServerLink(s, .connected(name))
        case .rejected:
            online[s] = false
            setServerLink(s, .rejected)
        case .unreachable:
            online[s] = false
            setServerLink(s, .unreachable)
        }
    }

    private func setServerLink(_ s: ServerID, _ status: ServerLinkStatus) {
        var next = serverLink
        next[s.rawValue] = status
        serverLink = next
        refreshTitle()
    }

    func refreshTitle() {
        if usesCustom {
            assistantTitle = customConnectedName ?? activeCustom?.name ?? "Lumen"
            return
        }
        if usesProvider {
            if case .connected(let name) = providerStatus { assistantTitle = name }
            else { assistantTitle = "Lumen" }
            return
        }
        if let active, case .some(.connected(let name)) = serverLink[active.rawValue] {
            assistantTitle = name
            return
        }
        for s in ServerID.allCases {
            if case .some(.connected(let name)) = serverLink[s.rawValue] {
                assistantTitle = name
                return
            }
        }
        assistantTitle = "Lumen"
    }

    /// Last 4 characters only, and only when the secret is longer than that.
    static func publicSuffix(_ secret: String) -> String {
        let t = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 4 else { return "" }
        return String(t.suffix(4))
    }

    private func publishSecrets() {
        providerKeySaved = !providerKey.isEmpty
        providerKeySuffix = Self.publicSuffix(providerKey)
        var saved: [String: Bool] = [:]
        var suffix: [String: String] = [:]
        for s in ServerID.allCases {
            let t = token(s)
            saved[s.rawValue] = !t.isEmpty
            suffix[s.rawValue] = Self.publicSuffix(t)
        }
        serverSaved = saved
        serverSuffix = suffix
    }

    /// Move any token that was left in UserDefaults into the Keychain, then delete the plaintext copy.
    private func migratePlaintextSecrets() {
        let d = UserDefaults.standard
        func take(_ key: String) -> String {
            let v = (d.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if d.object(forKey: key) != nil { d.removeObject(forKey: key) }
            return v
        }
        if linuxToken.isEmpty {
            let found = [take("token.linux"), take("linuxToken"), take("token")].first { !$0.isEmpty } ?? ""
            if !found.isEmpty { linuxToken = found }
        } else {
            _ = take("token.linux"); _ = take("linuxToken"); _ = take("token")
        }
        if windowsToken.isEmpty {
            let found = [take("token.windows"), take("windowsToken")].first { !$0.isEmpty } ?? ""
            if !found.isEmpty { windowsToken = found }
        } else {
            _ = take("token.windows"); _ = take("windowsToken")
        }
        if providerKey.isEmpty {
            let found = [take("provider.apiKey"), take("providerKey"), take("apiKey")].first { !$0.isEmpty } ?? ""
            if !found.isEmpty { providerKey = found }
        } else {
            _ = take("provider.apiKey"); _ = take("providerKey"); _ = take("apiKey")
        }
    }

    static func assistantName(from obj: [String: Any], url: String) -> String {
        for key in ["name", "assistant", "agent"] {
            if let s = obj[key] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
            if let d = obj[key] as? [String: Any], let s = d["name"] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        if let host = URL(string: url)?.host, !host.isEmpty { return host }
        return "Lumen"
    }

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

    private enum Probe { case ok([String: Any]), rejected, unreachable }

    /// Distinguishes a rejected token from a server that can't be reached.
    private func probe(_ s: ServerID) async -> Probe {
        guard let r = request(s, "/api/status", timeout: 8) else { return .unreachable }
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return .rejected }
            guard code == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unreachable
            }
            if (obj["ok"] as? Bool) == false { return .unreachable }
            return .ok(obj)
        } catch {
            return .unreachable
        }
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
        if demoMode {                                      // no server in Demo Mode
            active = nil; online = [:]
            if state == .offline { state = .idle }
            return
        }
        if usesProvider || usesCustom {
            active = nil; online = [:]
            voiceLockKnown = false
            voiceLockSupported = false
            if state == .offline { state = .idle }
            refreshTitle()
            return
        }
        var results: [ServerID: [String: Any]] = [:]
        await withTaskGroup(of: (ServerID, [String: Any]?).self) { group in
            for s in ServerID.allCases { group.addTask { await (s, self.check(s)) } }
            for await (s, r) in group { if let r { results[s] = r } }
        }
        for s in ServerID.allCases { online[s] = results[s] != nil }
        for (s, obj) in results {
            setServerLink(s, .connected(Self.assistantName(from: obj, url: url(s))))
        }
        let preferred = ServerID(rawValue: lastGood) ?? .linux
        let pick: ServerID? = results[preferred] != nil ? preferred : (results[preferred.other] != nil ? preferred.other : nil)
        let changed = pick != active && active != nil && pick != nil
        active = pick
        voiceLockKnown = !results.isEmpty
        voiceLockSupported = false
        if let pick, let obj = results[pick] {
            lastGood = pick.rawValue
            voices = (obj["voices"] as? [String]) ?? voices
            enrolled = (obj["enrolled"] as? Int) ?? 0
            enrollNeeded = (obj["enroll_needed"] as? Int) ?? 3
            speakerLock = (obj["speaker_lock"] as? Bool) ?? false
            voiceLockSupported = (obj["voiceLock"] as? Bool) == true
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
        appActive = true
        updateWake()
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                let wait: UInt64 = (self?.active == nil) ? 20 : 60
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            }
        }
    }

    func stopMonitoring() {
        probeTask?.cancel(); probeTask = nil
        appActive = false
        updateWake()
    }

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
        stopSpeaking()
        if !usesProvider && !usesCustom, let s = active, let r = request(s, "/api/reset", method: "POST") {
            _ = try? await URLSession.shared.data(for: r)
        }
        messages = [ChatMessage(role: .system, text: demoMode ? "New demo conversation. Hold the button to talk, or type below."
                                                           : "New conversation. Hold the button to talk, or type below.")]
        saveTranscript()
        state = connected ? .idle : .offline
    }

    // MARK: - Typing

    func send(text: String) async {
        await respond(text, speak: speakReplies)
    }

    /// One reply. Speech is on-device; `speak` uses the iPhone voice and is false when Siri or the Watch speaks.
    @discardableResult
    func respond(_ text: String, speak: Bool) async -> (say: String?, error: String?, title: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return (nil, nil, assistantTitle) }
        guard !replying else { return (nil, "Lumen is still answering.", assistantTitle) }
        replying = true
        defer {
            replying = false
            saveTranscript()
        }
        stopSpeaking()
        messages.append(ChatMessage(role: .me, text: t))
        if demoMode {
            try? await Task.sleep(nanoseconds: 700_000_000)
            let reply = DemoBrain.reply(to: t)
            messages.append(ChatMessage(role: .jarvis, text: reply))
            state = .idle
            if speak { demoVoice.speak(reply) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return (reply, nil, "Lumen")
        }
        state = .thinking
        let result: (say: String?, error: String?)
        if usesCustom { result = await customReply(speak: speak) }
        else if usesProvider { result = await providerReply(speak: speak) }
        else { result = await serverReply(speak: speak) }
        if result.say != nil {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        return (result.say, result.error, assistantTitle)
    }

    private struct StoredLine: Codable {
        var role: String
        var text: String
        var date: Date
    }

    private static func transcriptURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("lumen-transcript.json")
    }

    private func saveTranscript() {
        let lines = messages.map { message -> StoredLine in
            let role: String
            switch message.role {
            case .me: role = "me"
            case .jarvis: role = "jarvis"
            case .system: role = "system"
            }
            return StoredLine(role: role, text: message.text, date: message.date)
        }
        guard let data = try? JSONEncoder().encode(lines) else { return }
        try? data.write(to: Self.transcriptURL(), options: .atomic)
    }

    private static func loadTranscript() -> [ChatMessage]? {
        guard let data = try? Data(contentsOf: transcriptURL()),
              let lines = try? JSONDecoder().decode([StoredLine].self, from: data) else { return nil }
        return lines.map { line in
            let role: ChatMessage.Role = line.role == "me" ? .me : (line.role == "jarvis" ? .jarvis : .system)
            return ChatMessage(role: role, text: line.text, date: line.date)
        }
    }

    private func providerReply(speak: Bool) async -> (say: String?, error: String?) {
        guard AIProvider.detect(providerKey) != nil else {
            let err = "Add an API key in Settings."
            fail(err)
            return (nil, err)
        }
        let turns = messages.compactMap { m -> ProviderClient.Turn? in
            switch m.role {
            case .me: return .init(fromMe: true, text: m.text)
            case .jarvis: return .init(fromMe: false, text: m.text)
            case .system: return nil
            }
        }
        switch await ProviderClient().reply(key: providerKey, history: turns) {
        case .success(let say):
            let text = say.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                let err = "The assistant sent an empty reply."
                fail(err)
                return (nil, err)
            }
            messages.append(ChatMessage(role: .jarvis, text: text))
            state = .idle
            if speak { demoVoice.speak(text) }
            return (text, nil)
        case .failure(let error):
            let err: String
            switch error {
            case .rejected: err = "That API key was rejected. Check it in Settings."
            case .unreachable: err = "Can't reach the assistant. Check your connection and try again."
            case .unrecognized: err = "That API key isn't a recognized provider."
            case .empty: err = "The assistant sent an empty reply."
            }
            fail(err)
            return (nil, err)
        }
    }

    /// Text only. The reply is spoken here with the system voice, not with audio from the server.
    private func serverReply(speak: Bool) async -> (say: String?, error: String?) {
        let userText = messages.last(where: { $0.role == .me })?.text ?? ""
        let body = try? JSONSerialization.data(withJSONObject: ["text": userText])
        var refusedCode = 0
        var spoken: String?
        let ok = await withFailover { s in
            guard let r = self.request(s, "/api/text", method: "POST", body: body, contentType: "application/json") else { return .unreachable }
            do {
                let (data, resp) = try await URLSession.shared.data(for: r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    refusedCode = code
                    return .refused
                }
                let say = (obj["say"] as? String) ?? ""
                var msg = ChatMessage(role: .jarvis, text: say)
                msg.isPrivate = (obj["private"] as? Bool) ?? false
                msg.savedNote = (obj["saved"] as? Bool) ?? false
                msg.action = JarvisModel.action(from: obj["action"], server: s)
                self.messages.append(msg)
                self.state = .idle
                spoken = say
                if speak && !msg.isPrivate && !say.isEmpty { self.demoVoice.speak(say) }
                return .ok
            } catch {
                return JarvisModel.isUnreachable(error) ? .unreachable : .refused
            }
        }
        if ok, let spoken { return (spoken, nil) }
        let err = refusedText(refusedCode)
        fail(err)
        return (nil, err)
    }

    // MARK: - Talking

    func beginTalking(handsFree: Bool = false) {
        wake.stop()                                   // the recorder needs the microphone to itself
        Task {
            guard await audio.requestPermission() else {
                fail("Microphone access is off. Turn it on in Settings, then Lumen."); return
            }
            do {
                try audio.startRecording(autoStop: handsFree)
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

    /// Hands-free recording heard nothing: drop it quietly instead of uploading silence.
    private func cancelTalking() {
        _ = audio.stopRecording()
        state = .idle
    }

    private func upload(_ clip: Data) async {
        if demoMode { await demoUpload(clip); return }
        let heard = (await demoVoice.transcribe(clip) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else {
            fail("I didn't catch that. Try again a little closer.")
            return
        }
        await respond(heard, speak: speakReplies)
    }

    // MARK: - Wake word ("Lumen", on-device, only while the app is open)

    func setWakeWord(_ on: Bool) async {
        guard on else { wakeWordEnabled = false; updateWake(); return }
        guard await audio.requestPermission(), await WakeWordListener.requestPermission() else {
            wakeWordEnabled = false
            fail("Turn on Microphone and Speech Recognition for Lumen Voice in the iPhone's Settings first.")
            return
        }
        guard wake.onDeviceAvailable else {
            wakeWordEnabled = false
            fail("This iPhone can't recognise speech on-device yet, so the wake word stays off to keep your voice private.")
            return
        }
        wakeWordEnabled = true
        updateWake()
    }

    /// Listen for the wake word only when it is wanted, the app is on screen, and nothing else is using the mic.
    private func updateWake() {
        let wanted = wakeWordEnabled && appActive
        UIApplication.shared.isIdleTimerDisabled = wanted          // the screen has to stay on for this to work
        if wanted && state == .idle && connected && !enrollRecording { wake.start() } else { wake.stop() }
    }

    private func heardWakeWord() {
        guard state == .idle else { return }
        haptic.impactOccurred(intensity: 1)
        beginTalking(handsFree: true)
    }

    // MARK: - Voice lock enrollment (talks to whichever server is in use)

    func startEnrollSample() async {
        guard !demoMode else { enrollNote = "Voice lock needs your own Lumen server. It isn't available in Demo Mode."; return }
        guard !usesProvider && !usesCustom else { enrollNote = "Voice lock needs Own server mode"; return }
        guard voiceLockSupported else { enrollNote = "Your server doesn't support voice lock"; return }
        guard state == .idle, active != nil else { enrollNote = "Connect to your server first."; return }
        guard await audio.requestPermission() else { enrollNote = "Microphone access is off."; return }
        wake.stop()
        do {
            try audio.startRecording()
            enrollRecording = true
            state = .listening
            enrollNote = "Recording. Speak a couple of full sentences, then tap Stop."
        } catch {
            enrollNote = "Couldn't start the microphone."
        }
    }

    func finishEnrollSample() async {
        guard enrollRecording else { return }
        enrollRecording = false
        let clip = audio.stopRecording()
        state = .idle
        guard let clip, let s = active,
              let r = request(s, "/api/enroll", method: "POST", body: clip, contentType: "audio/m4a", timeout: 60) else {
            enrollNote = "That was too short. Try again with a couple of full sentences."
            return
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if code == 200 {
                enrolled = (obj["enrolled"] as? Int) ?? enrolled
                enrollNeeded = (obj["enroll_needed"] as? Int) ?? enrollNeeded
                speakerLock = (obj["speaker_lock"] as? Bool) ?? false
                enrollNote = speakerLock ? "Voice lock is on for \(s.label)."
                                         : "Sample \(enrolled) of \(enrollNeeded) saved. Record another."
            } else if code == 403 {
                enrollNote = "Enrolling only works from this app over Tailscale."
            } else {
                enrollNote = (obj["error"] as? String) ?? "Couldn't use that sample (\(code))."
            }
        } catch {
            enrollNote = "Couldn't reach \(s.label)."
        }
    }

    func clearVoiceprint() async {
        guard let s = active, let r = request(s, "/api/enroll/reset", method: "POST", timeout: 15) else { return }
        if let (_, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 {
            enrolled = 0; speakerLock = false
            enrollNote = "Voiceprint cleared on \(s.label). Anyone can talk to it again."
        } else {
            enrollNote = "Couldn't clear it. Is \(s.label) online?"
        }
    }

    // MARK: - PC actions (Lumen proposes, you approve, the PC does it)

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

    func stopSpeaking() { audio.stopPlayback(); demoVoice.stop() }

    // MARK: - Demo Mode

    static func demoMessages() -> [ChatMessage] {
        [ChatMessage(role: .system, text: DemoBrain.banner)]
            + DemoBrain.sampleConversation.map { ChatMessage(role: $0.fromMe ? .me : .jarvis, text: $0.text) }
    }

    func setDemoMode(_ on: Bool) async {
        guard on != demoMode else { return }
        stopSpeaking()
        if enrollRecording { enrollRecording = false; _ = audio.stopRecording() }
        demoMode = on
        if on {
            active = nil; online = [:]
            messages = JarvisModel.demoMessages()
            state = .idle
        } else {
            messages = [ChatMessage(role: .system, text: "Demo Mode is off. Hold the button to talk, or type below.")]
            state = .idle
            await refreshStatus()
        }
        updateWake()
    }

    private func demoAnswer(_ text: String) {
        let reply = DemoBrain.reply(to: text)
        messages.append(ChatMessage(role: .jarvis, text: reply))
        state = .idle
        if speakReplies { demoVoice.speak(reply) }
    }

    private func demoUpload(_ clip: Data) async {
        let heard = await demoVoice.transcribe(clip) ?? ""
        messages.append(ChatMessage(role: .me, text: heard.isEmpty ? "(voice message)" : heard))
        try? await Task.sleep(nanoseconds: 500_000_000)
        demoAnswer(heard)
    }

    private func refusedText(_ code: Int) -> String {
        switch code {
        case 401: return "\(active?.label ?? "Lumen") didn't accept the token. Check it in Settings."
        case 429: return "Lumen says slow down a moment, sir. Try again in a minute."
        case 0: return connected ? "Lumen didn't answer that time." : "Can't reach Lumen on Linux or Windows. Is the desktop on?"
        default: return "Lumen had a problem (\(code)). Try again."
        }
    }

    func fail(_ text: String) {
        messages.append(ChatMessage(role: .system, text: text))
        state = connected ? .idle : .offline
    }
}
