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

    /// Asks the iPhone. The reply is text only; secrets stay on the phone.
    func askPhone(_ text: String) async -> (say: String?, error: String?, title: String?) {
        guard WCSession.isSupported() else { return (nil, "This Watch can't reach the iPhone.", nil) }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            return (nil, "Open Lumen Voice on your iPhone so I can ask.", nil)
        }
        return await withCheckedContinuation { cont in
            let once = ResumeBox()
            session.sendMessage(["ask": text], replyHandler: { reply in
                once.run {
                    cont.resume(returning: (reply["say"] as? String, reply["error"] as? String, reply["title"] as? String))
                }
            }, errorHandler: { _ in
                once.run { cont.resume(returning: (nil, "Open Lumen Voice on your iPhone so I can ask.", nil)) }
            })
        }
    }

    func resetPhone() async {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = ResumeBox()
            session.sendMessage(["op": "reset"], replyHandler: { _ in
                once.run { cont.resume() }
            }, errorHandler: { _ in
                once.run { cont.resume() }
            })
        }
    }

    #if os(iOS)
    // Required on iOS only; lets this file also be type-checked against the iOS SDK.
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {}
    #endif
}

/// Resumes a continuation once, whether the reply or the error arrives first.
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
