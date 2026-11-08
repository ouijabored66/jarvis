import AVFoundation
import Foundation
import SwiftUI

/// One line of the Watch conversation history.
struct WatchEntry: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case me, jarvis, system }
    var id = UUID()
    let role: Role
    let text: String
    var date = Date()
}

/// The Watch app's brain: asks the same Jarvis server the iPhone app uses (POST /api/text, same token, same
/// Linux/Windows failover), speaks the reply, and keeps a scrollable history on the Watch.
/// Server addresses and tokens arrive from the iPhone app over WatchConnectivity (see WatchSync on the phone).
@MainActor
final class WatchModel: ObservableObject {
    @Published private(set) var history: [WatchEntry] = []
    @Published private(set) var busy = false
    @Published private(set) var tokens: [ServerID: String] = [:]

    @AppStorage("url.linux") var linuxURL = ServerID.linux.defaultURL
    @AppStorage("url.windows") var windowsURL = ServerID.windows.defaultURL
    @AppStorage("lastGood") private var lastGood = ServerID.linux.rawValue
    @AppStorage("speakReplies") var speakReplies = true
    @AppStorage("demoMode") private(set) var demoMode = false

    private let link = WatchLink()
    private let voice = WatchVoice()
    private static let historyKey = "history.v1"
    private static let historyLimit = 100

    init() {
        for s in ServerID.allCases { tokens[s] = Keychain.get("token.\(s.rawValue)") }
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([WatchEntry].self, from: data) {
            history = saved
        }
        if history.isEmpty && demoMode { history = Self.demoHistory() }
        link.onContext = { [weak self] ctx in Task { @MainActor in self?.apply(ctx) } }
        link.start()
    }

    // MARK: - Settings from the iPhone

    func url(_ s: ServerID) -> String { s == .linux ? linuxURL : windowsURL }
    func token(_ s: ServerID) -> String { tokens[s] ?? "" }
    func isConfigured(_ s: ServerID) -> Bool { !token(s).isEmpty && URL(string: url(s)) != nil }
    var isConfigured: Bool { ServerID.allCases.contains(where: isConfigured) }

    private func apply(_ ctx: [String: String]) {
        for s in ServerID.allCases {
            if let u = ctx["url.\(s.rawValue)"] {
                if s == .linux { linuxURL = u } else { windowsURL = u }
            }
            if let t = ctx["token.\(s.rawValue)"], t != tokens[s] {
                tokens[s] = t
                Keychain.set(t, for: "token.\(s.rawValue)")
            }
        }
        if let v = ctx["speakReplies"] { speakReplies = v == "1" }
        if let v = ctx["demoMode"] { setDemoMode(v == "1") }
    }

    // MARK: - Demo Mode

    private static func demoHistory() -> [WatchEntry] {
        [WatchEntry(role: .system, text: DemoBrain.banner)]
            + DemoBrain.sampleConversation.map { WatchEntry(role: $0.fromMe ? .me : .jarvis, text: $0.text) }
    }

    func setDemoMode(_ on: Bool) {
        guard on != demoMode else { return }
        voice.stop()
        demoMode = on
        history = on ? Self.demoHistory() : [WatchEntry(role: .system, text: "Demo Mode is off.")]
        save()
    }

    // MARK: - Asking

    func ask(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        voice.stop()
        append(.me, text)
        busy = true
        defer { busy = false }

        if demoMode {
            try? await Task.sleep(nanoseconds: 700_000_000)
            let reply = DemoBrain.reply(to: text)
            append(.jarvis, reply)
            if speakReplies { voice.speak(reply, audio: nil) }
            return
        }
        guard isConfigured else {
            append(.system, "Open Jarvis on your iPhone and set up a server there (or turn on Demo Mode).")
            return
        }

        // Same rule as the phone: try the last server that worked, fall back to the other only if it's unreachable.
        let first = ServerID(rawValue: lastGood) ?? .linux
        var refusedCode: Int?
        for s in [first, first.other] where isConfigured(s) {
            let outcome = await post(text, to: s)
            if case .answered(let reply) = outcome {
                lastGood = s.rawValue
                append(.jarvis, reply.say)
                if speakReplies && !reply.isPrivate { voice.speak(reply.say, audio: reply.audio) }
                return
            }
            if case .refused(let code) = outcome { refusedCode = code; break }   // never retry a refusal elsewhere
        }
        append(.system, Self.failureText(refusedCode))
    }

    func clearHistory() {
        history = demoMode ? Self.demoHistory() : []
        save()
    }

    func stopSpeaking() { voice.stop() }

    private struct Reply { let say: String; let isPrivate: Bool; let audio: Data? }
    private enum Outcome { case answered(Reply), refused(Int), unreachable }

    private func post(_ text: String, to s: ServerID) async -> Outcome {
        let path = speakReplies ? "/api/text?audio=1" : "/api/text"
        guard let base = URL(string: url(s)), let u = URL(string: path, relativeTo: base) else { return .unreachable }
        var r = URLRequest(url: u, timeoutInterval: 90)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token(s))", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .refused(code)
            }
            let audio = (obj["audio"] as? String).flatMap { Data(base64Encoded: $0) }
            return .answered(Reply(say: (obj["say"] as? String) ?? "",
                                   isPrivate: (obj["private"] as? Bool) ?? false,
                                   audio: audio))
        } catch let e as URLError where Self.unreachableCodes.contains(e.code) {
            return .unreachable
        } catch {
            return .refused(0)
        }
    }

    private static let unreachableCodes: [URLError.Code] = [
        .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
        .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed,
    ]

    private static func failureText(_ code: Int?) -> String {
        switch code {
        case 401?: return "Jarvis didn't accept the token. Check Settings in the iPhone app."
        case 429?: return "Jarvis says slow down a moment. Try again in a minute."
        case nil: return "Can't reach Jarvis on Linux or Windows. Is the desktop on?"
        case let c?: return c == 0 ? "Jarvis didn't answer that time." : "Jarvis had a problem (\(c)). Try again."
        }
    }

    // MARK: - History

    private func append(_ role: WatchEntry.Role, _ text: String) {
        history.append(WatchEntry(role: role, text: text))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: Self.historyKey) }
    }
}

/// Plays the server's spoken reply (Jarvis's own voice) or, without one, the system voice.
final class WatchVoice {
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?

    func speak(_ text: String, audio: Data?) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .default, options: [])
        try? session.setActive(true)
        if let audio, let p = try? AVAudioPlayer(data: audio) {
            player = p
            p.play()
            return
        }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-GB")
        synth.speak(u)
    }

    func stop() {
        player?.stop(); player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}
