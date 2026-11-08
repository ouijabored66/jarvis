import Foundation
import WatchConnectivity

/// Receives the server addresses, tokens and settings that the iPhone app sends with
/// `updateApplicationContext` (latest value wins). Delivers them as plain strings.
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    var onContext: (([String: String]) -> Void)?

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func deliver(_ ctx: [String: Any]) {
        let strings = ctx.compactMapValues { $0 as? String }
        guard !strings.isEmpty else { return }
        onContext?(strings)
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if state == .activated { deliver(session.receivedApplicationContext) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliver(applicationContext)
    }

    #if os(iOS)
    // Required on iOS only; lets this file also be type-checked against the iOS SDK.
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {}
    #endif
}
