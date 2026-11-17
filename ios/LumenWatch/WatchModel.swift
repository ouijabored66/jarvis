import AVFoundation
import Foundation
import SwiftUI
import WatchKit

@MainActor
enum WatchHub {
    static weak var model: WatchModel?
}

/// One line of the Watch conversation history.
struct WatchEntry: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case me, lumen, system }
    var id = UUID()
    let role: Role
    let text: String
    var date = Date()
}

/// The Watch app asks the iPhone, which holds the key. Replies are spoken on the Watch.
@MainActor
final class WatchModel: ObservableObject {
    @Published private(set) var history: [WatchEntry] = []
    @Published private(set) var busy = false
    @Published var assistantTitle = "Lumen"
    @Published var dictateNow = false
    @Published var speechVoiceID = ""
    @Published var speechRate = Double(AVSpeechUtteranceDefaultSpeechRate)

    @AppStorage("speakReplies") var speakReplies = true
    @AppStorage("demoMode") private(set) var demoMode = false

    private let link = WatchLink()
    private let voice = WatchVoice()
    private static let historyKey = "history.v1"
    private static let historyLimit = 40

    init() {
        WatchHub.model = self
        discardSecrets()
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([WatchEntry].self, from: data) {
            history = saved
        }
        if history.isEmpty && demoMode { history = Self.demoHistory() }
        link.onContext = { [weak self] ctx in Task { @MainActor in self?.apply(ctx) } }
        link.start()
    }

    /// Anything previously copied onto the Watch is removed. New requests go through the iPhone.
    private func discardSecrets() {
        for s in ServerID.allCases { Keychain.set("", for: "token.\(s.rawValue)") }
        Keychain.set("", for: "provider.apiKey")
        Keychain.set("", for: "token")
    }

    private func apply(_ ctx: [String: String]) {
        if let v = ctx["speakReplies"] { speakReplies = v == "1" }
        if let v = ctx["demoMode"] { setDemoMode(v == "1") }
        if let title = ctx["title"], !title.isEmpty { assistantTitle = title }
        if let voice = ctx["speechVoice"] { speechVoiceID = voice }
        if let rate = ctx["speechRate"], let value = Double(rate), value > 0 { speechRate = value }
    }

    // MARK: - Demo Mode

    private static func demoHistory() -> [WatchEntry] {
        [WatchEntry(role: .system, text: DemoBrain.banner)]
            + DemoBrain.sampleConversation.map { WatchEntry(role: $0.fromMe ? .me : .lumen, text: $0.text) }
    }

    func setDemoMode(_ on: Bool) {
        guard on != demoMode else { return }
        voice.stop()
        demoMode = on
        history = on ? Self.demoHistory() : [WatchEntry(role: .system, text: "Demo Mode is off.")]
        save()
    }

    // MARK: - Asking

    @discardableResult
    func ask(_ raw: String) async -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return "" }
        voice.stop()
        append(.me, text)
        busy = true
        defer { busy = false }

        if demoMode {
            try? await Task.sleep(nanoseconds: 700_000_000)
            let reply = DemoBrain.reply(to: text)
            append(.lumen, reply)
            if speakReplies { voice.speak(reply, identifier: speechVoiceID, rate: speechRate) }
            WKInterfaceDevice.current().play(.success)
            return reply
        }
        let result = await link.askPhone(text)
        if let title = result.title, !title.isEmpty { assistantTitle = title }
        if let say = result.say?.trimmingCharacters(in: .whitespacesAndNewlines), !say.isEmpty {
            append(.lumen, say)
            if speakReplies { voice.speak(say, identifier: speechVoiceID, rate: speechRate) }
            WKInterfaceDevice.current().play(.success)
            return say
        }
        let err = result.error ?? "Open Lumen Voice on your iPhone so I can ask."
        append(.system, err)
        return err
    }

    func clearHistory() {
        history = demoMode ? Self.demoHistory() : []
        save()
    }

    func resetConversation() async {
        clearHistory()
        await link.resetPhone()
    }

    func stopSpeaking() { voice.stop() }

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

/// Speaks with the best English voice on the Watch. No audio is fetched from a server.
final class WatchVoice {
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String, identifier: String, rate: Double) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .default, options: [])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(identifier: identifier) ?? AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .max { score($0) < score($1) }
        u.rate = rate > 0 ? Float(rate) : AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
    }

    private func score(_ voice: AVSpeechSynthesisVoice) -> Int {
        let quality: Int
        switch voice.quality {
        case .premium: quality = 300
        case .enhanced: quality = 200
        default: quality = 100
        }
        return quality + (voice.language == "en-US" ? 2 : voice.language == "en-GB" ? 1 : 0)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}
