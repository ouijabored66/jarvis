import AVFoundation
import Foundation
import Speech

/// Listens for the word "Jarvis" while the app is open and idle.
///
/// Recognition is forced on-device (`requiresOnDeviceRecognition`), so nothing leaves the phone until the wake
/// word is heard and the normal recording starts. iOS does not allow this with the app in the background or the
/// phone locked, so the model only runs it while the app is on screen.
@MainActor
final class WakeWordListener {
    var onWake: (() -> Void)?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var tapInstalled = false
    private var generation = 0            // ignores callbacks from a recognition session we already tore down
    private(set) var running = false

    /// Whether this phone can recognise speech without sending it anywhere.
    var onDeviceAvailable: Bool { recognizer?.supportsOnDeviceRecognition == true }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    func start() {
        guard !running, SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
            try session.setActive(true)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.requiresOnDeviceRecognition = true
            req.shouldReportPartialResults = true
            request = req

            let input = engine.inputNode
            if tapInstalled { input.removeTap(onBus: 0) }
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                req.append(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()

            generation += 1
            let gen = generation
            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let failed = error != nil
                Task { @MainActor in self?.handle(text: text, failed: failed, generation: gen) }
            }
            running = true
            // A single recognition request is cut off after about a minute, so renew it before that happens.
            restartTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.restart() }
            }
        } catch {
            stop()
        }
    }

    func stop() {
        generation += 1                    // anything still in flight from the old session is now ignored
        restartTimer?.invalidate(); restartTimer = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        running = false
    }

    private func restart() {
        stop()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)    // brief pause so a failing session can't spin
            self.onNeedRestart?()
        }
    }

    /// Set by the model: asks it to start listening again if it still wants the wake word on.
    var onNeedRestart: (() -> Void)?

    private func handle(text: String?, failed: Bool, generation gen: Int) {
        guard running, gen == generation else { return }
        if let text, Self.heardWakeWord(in: text) {
            stop()
            onWake?()
        } else if failed {
            restart()
        }
    }

    /// True when "Jarvis" is among the last few words heard (so an old mention doesn't fire it again).
    static func heardWakeWord(in text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).suffix(4)
        return words.contains { $0.hasPrefix("jarvis") }
    }
}
