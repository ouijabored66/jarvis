#if canImport(WatchConnectivity) && os(iOS)
import Foundation
import WatchConnectivity

/// Hands the server addresses and tokens to the Jarvis Watch app, so they don't have to be typed on the Watch.
/// Uses the application context (latest value wins, delivered whenever the Watch app next wakes).
/// Does nothing if no Watch is paired or the Watch app isn't installed.
final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()
    private var lastSent: [String: String] = [:]

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    @MainActor
    func push(from model: JarvisModel) {
        var ctx: [String: String] = ["speakReplies": model.speakReplies ? "1" : "0",
                                     "demoMode": model.demoMode ? "1" : "0"]
        for s in ServerID.allCases {
            ctx["url.\(s.rawValue)"] = model.url(s)
            ctx["token.\(s.rawValue)"] = model.token(s)
        }
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
}
#endif
