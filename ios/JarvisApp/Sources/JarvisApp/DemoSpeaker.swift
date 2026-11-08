import AVFoundation
import Foundation
import Speech

/// Demo Mode voice: speaks simulated replies with the built-in iOS voice (the real server sends its own audio),
/// and transcribes a held-to-talk clip on-device so the demo can show what was said.
final class DemoSpeaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    var onSpeakingChanged: ((Bool) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-GB")
        synth.speak(u)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onSpeakingChanged?(true)
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onSpeakingChanged?(false)
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onSpeakingChanged?(false)
    }

    /// On-device only (never sends audio to a server). Returns nil if the iPhone can't do that or permission is off.
    func transcribe(_ clip: Data) async -> String? {
        guard await WakeWordListener.requestPermission(),
              let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-demo-clip.m4a")
        guard (try? clip.write(to: url)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let once = ResumeOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.run { cont.resume(returning: result.bestTranscription.formattedString) }
                } else if error != nil {
                    once.run { cont.resume(returning: nil) }
                }
            }
        }
    }
}

/// Makes sure a continuation is resumed exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
