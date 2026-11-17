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
    @Published private(set) var speaking = false
    @Published private(set) var listening = false
    @Published var assistantTitle = "Lumen"
    @Published var dictateNow = false
    @Published var speechVoiceID = ""
    @Published var speechRate = Double(AVSpeechUtteranceDefaultSpeechRate)

    @AppStorage("speakReplies") var speakReplies = true
    @AppStorage("demoMode") private(set) var demoMode = false

    private let link = WatchLink()
    private let voice = WatchVoice()
    private let capture = ClipCapture()
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
        voice.onSpeakingChanged = { speaking in
            Task { @MainActor in WatchHub.model?.speaking = speaking }
        }
        capture.onAutoStop = { [weak self] in
            Task { @MainActor in self?.finishListening() }
        }
        link.start()
    }

    /// Anything previously copied onto the Watch is removed. New requests go through the iPhone.
    private func discardSecrets() {
        Keychain.keepOnly([])
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

    // MARK: - Talk

    /// Starts the microphone. The face complication calls this as the app opens.
    func startListening() {
        guard !busy, !listening else { return }
        listening = true
        voice.stop()
        Task { await armMicrophone() }
    }

    /// Tap again, two seconds of silence, or the 30 second cap.
    func finishListening() {
        guard listening else { return }
        listening = false
        guard let url = capture.stop() else { return }
        Task { await deliverClip(url) }
    }

    private func armMicrophone() async {
        guard listening else { return }
        guard await Self.micAllowed() else {
            listening = false
            append(.system, "Microphone access is off.")
            return
        }
        guard listening else { return }
        do {
            try capture.start()
            guard listening else {
                if let url = capture.stop() { try? FileManager.default.removeItem(at: url) }
                return
            }
            WKInterfaceDevice.current().play(.click)
        } catch {
            listening = false
            append(.system, "Couldn't start the microphone.")
        }
    }

    private static func micAllowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default:
            return await withCheckedContinuation { cont in
                AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
            }
        }
    }

    private func deliverClip(_ url: URL) async {
        busy = true
        defer { busy = false }
        let result = await link.sendClip(at: url)
        if let title = result.title, !title.isEmpty { assistantTitle = title }
        let transcript = result.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !transcript.isEmpty else {
            append(.system, result.error ?? "I didn't catch that.")
            return
        }
        append(.me, transcript)
        if let say = result.say?.trimmingCharacters(in: .whitespacesAndNewlines), !say.isEmpty {
            append(.lumen, say)
            if speakReplies { voice.speak(say, identifier: speechVoiceID, rate: speechRate) }
            WKInterfaceDevice.current().play(.success)
        } else {
            append(.system, result.error ?? "No reply.")
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

/// Speaks with the best English voice on the Watch. No audio is fetched from a server.
final class WatchVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    var onSpeakingChanged: ((Bool) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, identifier: String, rate: Double) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .default, options: [])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(identifier: identifier) ?? AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .max { score($0) < score($1) }
        u.rate = rate > 0 ? Float(rate) : AVSpeechUtteranceDefaultSpeechRate
        report(true)
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
        report(false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        report(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        report(false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        report(false)
    }

    private func report(_ speaking: Bool) {
        let notify = onSpeakingChanged
        DispatchQueue.main.async { notify?(speaking) }
    }
}

/// Records one question as AAC, 16 kHz, mono. Stops after two quiet seconds or at 30 seconds.
final class ClipCapture: NSObject, AVAudioRecorderDelegate {
    var onAutoStop: (() -> Void)?
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var timer: Timer?
    private var startedAt: Date?
    private var quietSince: Date?
    private var closed = false

    func start() throws {
        closed = false
        quietSince = nil
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record(forDuration: 30) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.recorder = recorder
        fileURL = url
        startedAt = Date()
        quietSince = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() -> URL? {
        timer?.invalidate()
        timer = nil
        closed = true
        recorder?.stop()
        recorder = nil
        let url = fileURL
        fileURL = nil
        return url
    }

    private func poll() {
        guard !closed, let recorder, recorder.isRecording else { return }
        if let startedAt, Date().timeIntervalSince(startedAt) >= 30 {
            autoStop()
            return
        }
        recorder.updateMeters()
        if recorder.averagePower(forChannel: 0) < -40 {
            if quietSince == nil { quietSince = Date() }
            if let quietSince, Date().timeIntervalSince(quietSince) >= 2 { autoStop() }
        } else {
            quietSince = nil
        }
    }

    private func autoStop() {
        guard !closed else { return }
        closed = true
        let notify = onAutoStop
        DispatchQueue.main.async { notify?() }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        autoStop()
    }
}
