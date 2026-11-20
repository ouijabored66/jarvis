import AVFoundation
import Foundation
#if canImport(Speech)
import Speech
#endif
import SwiftUI
import WatchConnectivity
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
    @Published private(set) var actionQueue: [WatchAction] = []
    @Published var actionNote = ""
    @Published private(set) var actionBusy = false
    @Published var assistantTitle = "Lumen"
    @Published var dictateNow = false
    @Published var wantsKeyboard = false
    @Published var speechVoiceID = ""
    @Published var speechRate = Double(AVSpeechUtteranceDefaultSpeechRate)
    /// "agree" after Agree, "later" after Not now, empty until the screen is shown.
    @Published private(set) var aiConsent: String = UserDefaults.standard.string(forKey: WatchModel.aiConsentKey) ?? ""
    @Published var showAIConsent = false
    static let aiConsentKey = "lumen.aiConsent"
    var aiSendAllowed: Bool { aiConsent == "agree" }

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
    private var inbox = WatchInbox()
    private var waitStarted: Date?

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
        link.onClipReply = { [weak self] _, reply in Task { @MainActor in self?.present(reply) } }
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
        if let raw = ctx["actions"] { applyActions(raw) }
    }

    private func applyActions(_ raw: String) {
        let rows = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: String]]) ?? []
        let incoming: [WatchAction] = rows.compactMap { row in
            guard let id = row["id"], !id.isEmpty else { return nil }
            return WatchAction(id: id, title: row["title"] ?? "Needs your approval", detail: row["detail"] ?? "")
        }
        let ids = Set(incoming.map(\.id))
        let previous = actionQueue.first?.id
        actionQueue.removeAll { !ids.contains($0.id) }
        for item in incoming where !actionQueue.contains(where: { $0.id == item.id }) {
            actionQueue.append(item)
        }
        if actionQueue.first?.id != previous {
            actionNote = ""
            if actionQueue.first != nil {
                WKInterfaceDevice.current().play(.notification)
            }
        }
    }

    func decideAction(approve: Bool) async {
        guard let item = actionQueue.first, !actionBusy else { return }
        guard link.reachable else {
            actionNote = "Open Lumen on iPhone to approve"
            return
        }
        actionBusy = true
        defer { actionBusy = false }
        let result = await link.decideAction(id: item.id, approve: approve)
        guard result.finished else {
            actionNote = result.text
            return
        }
        let summary = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if approve, !summary.isEmpty, summary != "Approved" {
            append(.lumen, summary)
            if speakReplies { voice.speak(summary, identifier: speechVoiceID, rate: speechRate) }
        } else if !summary.isEmpty {
            actionNote = summary
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        actionQueue.removeAll { $0.id == item.id }
        actionNote = ""
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

    func agreeToAI() {
        aiConsent = "agree"
        UserDefaults.standard.set("agree", forKey: Self.aiConsentKey)
        showAIConsent = false
    }

    func declineAI() {
        aiConsent = "later"
        UserDefaults.standard.set("later", forKey: Self.aiConsentKey)
        showAIConsent = false
    }

    func blockAISend() -> Bool {
        if aiSendAllowed { return false }
        showAIConsent = true
        return true
    }

    // MARK: - Asking

    @discardableResult
    func ask(_ raw: String) async -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let skipPhone = forceDirect
        forceDirect = false
        guard !text.isEmpty, !busy else { return "" }
        if !demoMode && blockAISend() {
            return "Nothing was sent. Tap Agree first."
        }
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
            let result = await holdOpen { await link.askPhone(text, timeout: RelayWait.cap) }
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

    /// Keeps the screen in the thinking state until the phone reply arrives.
    private func holdOpen<T>(_ work: () async -> T) async -> T {
        let alive = WatchKeepAlive()
        keepAlive = alive
        alive.begin()
        let value = await work()
        alive.end()
        keepAlive = nil
        return value
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

    /// Complication or listen URL, including when the app is already open. Always uses the microphone.
    func beginFromComplication() {
        dictateNow = false
        UserDefaults.standard.set(false, forKey: "lumen.listenOnOpen")
        if speaking { stopSpeaking() }
        guard !listening, !busy else { return }
        startListening()
    }

    func consumeLaunchRequest() {
        let flagged = dictateNow || UserDefaults.standard.bool(forKey: "lumen.listenOnOpen")
        guard flagged else { return }
        beginFromComplication()
    }

    /// Record on this Watch. The text field is only for a tap on that field.
    func talk() {
        if listening { finishListening(); return }
        if speaking { stopSpeaking() }
        guard !busy else { return }
        startListening()
    }

    /// Starts the microphone. The face complication calls this as the app opens.
    func startListening() {
        guard !busy, !listening else { return }
        if blockAISend() { return }
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
        guard aiSendAllowed else {
            showAIConsent = true
            try? FileManager.default.removeItem(at: url)
            return
        }
        busy = true
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-hear-\(UUID().uuidString).m4a")
        let kept = (try? FileManager.default.copyItem(at: url, to: keep)) != nil
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: keep)
        }
        phoneReachable = link.reachable
        var clipID = ""
        if phoneReachable {
            waitStarted = Date()
            let result = await holdOpen { await link.sendClip(at: url, timeout: RelayWait.cap) }
            clipID = result.id
            if result.timedOut {
                if inbox.showedReply(result.id) || inbox.knowsTranscript(result.id) { return }
            } else {
                let turn = present(result)
                if turn.replyLine != nil || inbox.knowsTranscript(result.id) { return }
                if !Self.phoneMissed(result.error ?? "No reply") {
                    busy = false
                    return
                }
            }
        }
        let source = kept ? keep : url
        let heard = (await WatchHear.transcribe(source, cloudURL: cloudURL, key: Keychain.get(Self.cloudAccount)))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        busy = false
        guard !heard.isEmpty else {
            if inbox.knowsTranscript(clipID) || inbox.showedReply(clipID) { return }
            append(.system, RelayWait.miss)
            return
        }
        forceDirect = !link.reachable
        _ = await ask(heard)
    }

    // MARK: - History

    @discardableResult
    private func present(_ reply: ClipReply) -> WatchTurn {
        if let title = reply.title, !title.isEmpty { assistantTitle = title }
        let elapsed = waitStarted.map { Date().timeIntervalSince($0) } ?? 0
        let turn = inbox.receive(RelayReply(id: reply.id, transcript: reply.transcript, say: reply.say, error: reply.error, title: reply.title), elapsed: elapsed)
        if let user = turn.userLine { append(.me, user) }
        if let line = turn.replyLine {
            if reply.say?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                append(.lumen, line)
                if speakReplies { voice.speak(line, identifier: speechVoiceID, rate: speechRate) }
                WKInterfaceDevice.current().play(.success)
            } else {
                append(.system, line)
            }
        }
        busy = turn.thinking
        return turn
    }

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

private final class HearOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

/// Turns a recording into text on this Watch when it can, otherwise asks the saved server.
enum WatchHear {
    static func transcribe(_ url: URL, cloudURL: String, key: String) async -> String? {
        if let local = await onDevice(url) {
            let trimmed = local.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return await remote(url, cloudURL: cloudURL, key: key)
    }

    private static func onDevice(_ url: URL) async -> String? {
        #if canImport(Speech)
        let status: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            status = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
        } else {
            status = SFSpeechRecognizer.authorizationStatus()
        }
        guard status == .authorized else { return nil }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer(),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { cont in
            let once = HearOnce()
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.run { cont.resume(returning: result.bestTranscription.formattedString) }
                } else if error != nil {
                    once.run { cont.resume(returning: nil) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + RelayWait.cap) {
                task.cancel()
                once.run { cont.resume(returning: nil) }
            }
        }
        #else
        _ = url
        return nil
        #endif
    }

    private static func remote(_ url: URL, cloudURL: String, key: String) async -> String? {
        guard let target = WatchDirect.endpoint(cloudURL, "api/transcribe"),
              WatchHTTP.allowed(target),
              let body = try? Data(contentsOf: url), !body.isEmpty else { return nil }
        var request = URLRequest(url: target, timeoutInterval: RelayWait.cap)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = RelayWait.cap
        config.timeoutIntervalForResource = RelayWait.cap
        config.waitsForConnectivity = false
        do {
            let (data, response) = try await URLSession(configuration: config).data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if CloudRoutes.skipTranscribe(status: http.statusCode) { return nil }
            guard (200..<300).contains(http.statusCode) else { return nil }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let text = (obj["text"] as? String) ?? (obj["say"] as? String) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }
}

/// System dictation. The microphone path does not use this.
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
        config.timeoutIntervalForRequest = RelayWait.cap
        config.timeoutIntervalForResource = RelayWait.cap
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
        var request = URLRequest(url: target, timeoutInterval: RelayWait.cap)
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

    static func endpoint(_ raw: String, _ path: String) -> URL? {
        CloudRoutes.url(base: raw, path: path)
    }

    private static func baseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parts.host != nil else { return nil }
        if parts.path.count > 1, parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url
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
