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

/// The Watch asks the iPhone when it is nearby. Otherwise it uses the Cloud address saved on the phone.
@MainActor
final class WatchModel: ObservableObject {
    @Published private(set) var history: [WatchEntry] = []
    @Published private(set) var busy = false
    @Published private(set) var speaking = false
    @Published private(set) var listening = false
    @Published private(set) var phoneReachable = false
    @Published private(set) var directReady = false
    @Published private(set) var answering = false
    @Published var assistantTitle = "Lumen"
    @Published var dictateNow = false
    @Published var wantsKeyboard = false
    @Published var speechVoiceID = ""
    @Published var speechRate = Double(AVSpeechUtteranceDefaultSpeechRate)

    @AppStorage("speakReplies") var speakReplies = true
    @AppStorage("demoMode") private(set) var demoMode = false

    private let link = WatchLink()
    private let voice = WatchVoice()
    private let capture = ClipCapture()
    private static let historyKey = "history.v1"
    private static let historyLimit = 40
    private static let cloudAccount = "cloud.key"
    private static let cloudURLKey = "cloud.url"
    private var cloudURL = ""
    private var keepAlive: WatchKeepAlive?
    private var forceDirect = false

    var routeLabel: String {
        if phoneReachable { return "Via iPhone" }
        if directReady { return "Direct" }
        return "Set up Cloud on iPhone"
    }

    init() {
        WatchHub.model = self
        cloudURL = UserDefaults.standard.string(forKey: Self.cloudURLKey) ?? ""
        discardSecrets()
        refreshDirect()
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([WatchEntry].self, from: data) {
            history = saved
        }
        if history.isEmpty && demoMode { history = Self.demoHistory() }
        link.onContext = { [weak self] ctx in Task { @MainActor in self?.apply(ctx) } }
        link.onReachable = { [weak self] up in Task { @MainActor in self?.phoneReachable = up } }
        voice.onSpeakingChanged = { speaking in
            Task { @MainActor in WatchHub.model?.speaking = speaking }
        }
        capture.onAutoStop = { [weak self] in
            Task { @MainActor in self?.finishListening() }
        }
        link.start()
    }

    /// Drop secrets that are not the Cloud key for this Watch.
    private func discardSecrets() {
        Keychain.keepOnly([Self.cloudAccount])
    }

    private func refreshDirect() {
        directReady = !cloudURL.isEmpty && !Keychain.get(Self.cloudAccount).isEmpty
    }

    func refreshReachable() {
        phoneReachable = link.reachable
    }

    private func apply(_ ctx: [String: String]) {
        if let v = ctx["speakReplies"] { speakReplies = v == "1" }
        if let v = ctx["demoMode"] { setDemoMode(v == "1") }
        if let title = ctx["title"], !title.isEmpty { assistantTitle = title }
        if let voice = ctx["speechVoice"] { speechVoiceID = voice }
        if let rate = ctx["speechRate"], let value = Double(rate), value > 0 { speechRate = value }
        if let url = ctx["cloudURL"] {
            cloudURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(cloudURL, forKey: Self.cloudURLKey)
        }
        if let key = ctx["cloudKey"] {
            Keychain.set(key, for: Self.cloudAccount)
        }
        if ctx["cloudURL"] != nil || ctx["cloudKey"] != nil { refreshDirect() }
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
        let skipPhone = forceDirect
        forceDirect = false
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
        phoneReachable = link.reachable
        if phoneReachable && !skipPhone {
            let result = await link.askPhone(text, timeout: 5)
            if !result.timedOut {
                if let title = result.title, !title.isEmpty { assistantTitle = title }
                if let say = result.say?.trimmingCharacters(in: .whitespacesAndNewlines), !say.isEmpty {
                    append(.lumen, say)
                    if speakReplies { voice.speak(say, identifier: speechVoiceID, rate: speechRate) }
                    WKInterfaceDevice.current().play(.success)
                    return say
                }
                if let err = result.error, !Self.phoneMissed(err) {
                    append(.system, err)
                    return err
                }
            }
        }
        guard directReady else {
            let err = "Set up Cloud on iPhone"
            append(.system, err)
            return err
        }
        return await directAnswer(text)
    }

    /// The iPhone did not answer. Talk to the saved Cloud address instead.
    private func directAnswer(_ text: String) async -> String {
        answering = true
        let alive = WatchKeepAlive()
        keepAlive = alive
        alive.begin()
        defer {
            answering = false
            alive.end()
            keepAlive = nil
        }
        let direct = await WatchDirect.send(url: cloudURL, key: Keychain.get(Self.cloudAccount), text: text)
        if let say = direct.say {
            append(.lumen, say)
            if speakReplies { voice.speak(say, identifier: speechVoiceID, rate: speechRate) }
            WKInterfaceDevice.current().play(.success)
            return say
        }
        let err = direct.error ?? "Can't reach the server."
        append(.system, err)
        return err
    }

    private static func phoneMissed(_ error: String) -> Bool {
        error.contains("isn't reachable") || error.contains("No reply") || error.contains("Open Lumen")
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

    /// Nearby: record here and let the iPhone transcribe. Away: dictate, then call the Cloud address.
    func talk() {
        if listening { finishListening(); return }
        if speaking { stopSpeaking(); return }
        guard !busy else { return }
        phoneReachable = link.reachable
        if phoneReachable {
            startListening()
            return
        }
        guard directReady else {
            append(.system, "Set up Cloud on iPhone")
            return
        }
        let presented = WatchDictation.present { text in
            Task { @MainActor in await WatchHub.model?.ask(text) }
        }
        if !presented { wantsKeyboard = true }
    }

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
        let result = await link.sendClip(at: url, timeout: 5)
        if result.timedOut || (result.transcript == nil && (result.say ?? "").isEmpty && Self.phoneMissed(result.error ?? "No reply")) {
            if directReady {
                forceDirect = true
                let presented = WatchDictation.present { text in
                    Task { @MainActor in await WatchHub.model?.ask(text) }
                }
                if !presented { wantsKeyboard = true }
                return
            }
        }
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

/// System dictation. Falls back to the text field when the controller is not available.
@MainActor
enum WatchDictation {
    static func present(_ done: @escaping (String) -> Void) -> Bool {
        guard let controller = WKApplication.shared().visibleInterfaceController else { return false }
        controller.presentTextInputController(withSuggestions: nil, allowedInputMode: .plain) { results in
            let text = (results?.first as? String) ?? ""
            done(text)
        }
        return true
    }
}

/// Plain http is limited the same way as on the iPhone: this machine, private LAN, 100.x, .local, and .ts.net.
private enum WatchHTTP {
    static func allowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http", let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host == "local" || host.hasSuffix(".local") || host.hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        let a = parts[0], b = parts[1]
        if a == 10 || a == 127 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 100 && (64...127).contains(b) { return true }
        return false
    }
}

/// Posts to the Cloud address. The key is a header and is never logged.
private enum WatchDirect {
    private enum Outcome { case success(String), rejected, empty, blocked, unreachable, transport }

    private static let relay: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 150
        config.timeoutIntervalForResource = 150
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func send(url: String, key: String, text: String) async -> (say: String?, error: String?) {
        guard baseURL(url) != nil else { return (nil, "Set up Cloud on iPhone") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, "The assistant sent an empty reply.") }
        switch await postRetry(url: url, path: "api/text", key: key, body: ["text": trimmed]) {
        case .success(let say): return (say, nil)
        case .rejected: return (nil, "That key was rejected.")
        case .blocked: return (nil, "Plain http is only allowed for a local address, 100.x, or .ts.net.")
        case .empty, .unreachable, .transport: break
        }
        let chat: [String: Any] = ["messages": [["role": "user", "content": trimmed]]]
        switch await postRetry(url: url, path: "chat/completions", key: key, body: chat) {
        case .success(let say): return (say, nil)
        case .rejected: return (nil, "That key was rejected.")
        case .blocked: return (nil, "Plain http is only allowed for a local address, 100.x, or .ts.net.")
        case .empty: return (nil, "The assistant sent an empty reply.")
        case .unreachable, .transport: return (nil, "Can't reach the server.")
        }
    }

    /// One extra try when the connection drops or the wait runs out.
    private static func postRetry(url: String, path: String, key: String, body: [String: Any]) async -> Outcome {
        let first = await post(url: url, path: path, key: key, body: body)
        if case .transport = first {
            return await post(url: url, path: path, key: key, body: body)
        }
        return first
    }

    private static func post(url: String, path: String, key: String, body: [String: Any]) async -> Outcome {
        guard let target = endpoint(url, path) else { return .unreachable }
        guard WatchHTTP.allowed(target) else { return .blocked }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return .unreachable }
        var request = URLRequest(url: target, timeoutInterval: 150)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await relay.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return .rejected }
            guard (200..<300).contains(code) else { return .unreachable }
            let say = spoken(data)
            return say.isEmpty ? .empty : .success(say)
        } catch {
            return isTransport(error) ? .transport : .unreachable
        }
    }

    private static func isTransport(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return true }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed,
             .cannotLoadFromNetwork, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return true
        default:
            return false
        }
    }

    private static func endpoint(_ raw: String, _ path: String) -> URL? {
        guard let base = baseURL(raw) else { return nil }
        return join(base, path)
    }

    private static func baseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parts.host != nil else { return nil }
        if parts.path.count > 1, parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url
    }

    private static func join(_ base: URL, _ path: String) -> URL {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        let root = parts.path == "/" ? "" : parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let leaf = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = "/" + [root, leaf].filter { !$0.isEmpty }.joined(separator: "/")
        return parts.url ?? base
    }

    private static func spoken(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let line = spokenLine(obj) {
            return line
        }
        let raw = String(decoding: data, as: UTF8.self)
        for line in raw.split(whereSeparator: \.isNewline) {
            let piece = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty, let row = piece.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: row) as? [String: Any],
                  let spoken = spokenLine(obj) else { continue }
            return spoken
        }
        return ""
    }

    private static func spokenLine(_ obj: [String: Any]) -> String? {
        for name in ["say", "reply"] {
            guard let value = obj[name] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Keeps the Watch awake while a Cloud reply is in flight. A free sideload can use self-care; if that is refused, the request still runs.
final class WatchKeepAlive: NSObject, WKExtendedRuntimeSessionDelegate {
    private let lock = NSLock()
    private var session: WKExtendedRuntimeSession?
    private var allowed = true

    func begin() {
        lock.lock()
        let ok = allowed && session == nil
        lock.unlock()
        guard ok else { return }
        let next = WKExtendedRuntimeSession()
        next.delegate = self
        lock.lock()
        session = next
        lock.unlock()
        next.start()
    }

    func end() {
        lock.lock()
        let current = session
        session = nil
        lock.unlock()
        current?.invalidate()
    }

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        lock.lock()
        session = nil
        if reason == .error { allowed = false }
        lock.unlock()
    }
}
