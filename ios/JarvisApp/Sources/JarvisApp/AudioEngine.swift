import AVFoundation
import Foundation

/// Records a clip while the mic button is held, and plays Jarvis's spoken sentences in order.
final class AudioEngine: NSObject, AVAudioPlayerDelegate {
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var queue: [Data] = []
    var onLevel: ((Float) -> Void)?
    var onPlayingChanged: ((Bool) -> Void)?
    private var meterTimer: Timer?

    /// Hands-free mode (after the wake word): stops by itself once you finish speaking.
    /// Called with whether any speech was heard, so silence can be dropped instead of uploaded.
    var onAutoStop: ((_ heardSpeech: Bool) -> Void)?
    private var autoStop = false
    private var heardSpeech = false
    private var quietSince: Date?
    private var startedAt = Date()

    private var clipURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-clip.m4a")
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
    }

    func startRecording(autoStop: Bool = false) throws {
        self.autoStop = autoStop
        heardSpeech = false; quietSince = nil; startedAt = Date()
        stopPlayback()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
        try session.setActive(true)
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                                       AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                       AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        try? FileManager.default.removeItem(at: clipURL)
        let rec = try AVAudioRecorder(url: clipURL, settings: settings)
        rec.isMeteringEnabled = true
        rec.record()
        recorder = rec
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let r = self?.recorder else { return }
            r.updateMeters()
            let db = r.averagePower(forChannel: 0)            // -160...0
            let level = max(0, min(1, (db + 50) / 50))
            self?.onLevel?(level)
            self?.checkAutoStop(level)
        }
    }

    private func checkAutoStop(_ level: Float) {
        guard autoStop else { return }
        let now = Date()
        if level > 0.35 { heardSpeech = true; quietSince = nil }
        else if quietSince == nil { quietSince = now }
        let quiet = quietSince.map { now.timeIntervalSince($0) } ?? 0
        let elapsed = now.timeIntervalSince(startedAt)
        // Done: spoke then went quiet for a moment; nothing said at all for 6 s; or a hard 30 s limit.
        if (heardSpeech && quiet > 1.3) || (!heardSpeech && elapsed > 6) || elapsed > 30 {
            autoStop = false
            onAutoStop?(heardSpeech)
        }
    }

    /// Stops recording and returns the clip (nil if it was too short to send).
    func stopRecording() -> Data? {
        meterTimer?.invalidate(); meterTimer = nil
        autoStop = false
        onLevel?(0)
        guard let rec = recorder else { return nil }
        let duration = rec.currentTime
        rec.stop(); recorder = nil
        guard duration > 0.4, let data = try? Data(contentsOf: clipURL) else { return nil }
        try? FileManager.default.removeItem(at: clipURL)   // never keep the recording on the phone
        return data
    }

    func enqueue(_ wav: Data) {
        queue.append(wav)
        if player == nil || player?.isPlaying == false { playNext() }
    }

    func stopPlayback() {
        queue.removeAll()
        player?.stop(); player = nil
        onPlayingChanged?(false)
    }

    private func playNext() {
        guard !queue.isEmpty else { player = nil; onPlayingChanged?(false); return }
        let next = queue.removeFirst()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            let p = try AVAudioPlayer(data: next)
            p.delegate = self
            player = p
            onPlayingChanged?(true)
            p.play()
        } catch {
            playNext()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.playNext() }
    }
}
