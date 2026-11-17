#if canImport(WatchConnectivity) && os(iOS)
import Foundation
import WatchConnectivity

/// Tells the Watch the assistant name and settings. The API key and server token never leave the iPhone.
/// Questions from the Watch arrive as messages and are answered here.
final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()
    var answer: (@MainActor (String) async -> (say: String?, error: String?, title: String))?
    private var lastSent: [String: String] = [:]

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    @MainActor
    func push(from model: JarvisModel) {
        let ctx: [String: String] = ["speakReplies": model.speakReplies ? "1" : "0",
                                     "demoMode": model.demoMode ? "1" : "0",
                                     "title": model.assistantTitle]
        send(ctx)
    }

    private func send(_ ctx: [String: String]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            pending = ctx; return
        }
        guard ctx != lastSent else { return }
        do { try session.updateApplicationContext(ctx); lastSent = ctx; pending = nil } catch { pending = ctx }
    }

    private var pending: [String: String]?

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if state == .activated, let p = pending { DispatchQueue.main.async { self.send(p) } }
    }
    func sessionWatchStateDidChange(_ session: WCSession) {
        if let p = pending { DispatchQueue.main.async { self.send(p) } }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let text = message["ask"] as? String ?? ""
        let once = ReplyOnce(replyHandler)
        Task { @MainActor in
            let result = await self.answer?(text) ?? (say: nil, error: "Open Lumen Voice on your iPhone.", title: "Lumen")
            var payload: [String: Any] = ["title": result.title]
            if let say = result.say { payload["say"] = say }
            if let error = result.error { payload["error"] = error }
            once.send(payload)
        }
    }
}

/// Calls the Watch reply handler exactly once.
private final class ReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var sent = false
    private let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func send(_ payload: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        guard !sent else { return }
        sent = true
        handler(payload)
    }
}
#endif
