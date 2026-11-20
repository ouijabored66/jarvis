import Foundation
import WatchConnectivity

/// Receives the server addresses, tokens and settings that the iPhone app sends with
/// `updateApplicationContext` (latest value wins). Delivers them as plain strings.
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    var onContext: (([String: String]) -> Void)?
    var onReachable: ((Bool) -> Void)?
    private let lock = NSLock()
    private var waiters: [String: ClipWaiter] = [:]

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

    var reachable: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if state == .activated {
            deliver(session.receivedApplicationContext)
            onReachable?(session.isReachable)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliver(applicationContext)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        onReachable?(session.isReachable)
    }

    /// Asks the iPhone. The reply is text only.
    func askPhone(_ text: String, timeout: TimeInterval = 100) async -> (say: String?, error: String?, title: String?, timedOut: Bool) {
        guard WCSession.isSupported() else { return (nil, "This Watch can't reach the iPhone.", nil, false) }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            return (nil, "Open Lumen Voice on your iPhone so I can ask.", nil, false)
        }
        return await withCheckedContinuation { cont in
            let once = ResumeBox()
            session.sendMessage(["ask": text], replyHandler: { reply in
                once.run {
                    cont.resume(returning: (reply["say"] as? String, reply["error"] as? String, reply["title"] as? String, false))
                }
            }, errorHandler: { _ in
                once.run { cont.resume(returning: (nil, "Open Lumen Voice on your iPhone so I can ask.", nil, false)) }
            })
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run { cont.resume(returning: (nil, nil, nil, true)) }
            }
        }
    }

    /// Sends a recorded question. Small clips use `sendMessageData`; larger ones use `transferFile`.
    /// The iPhone replies later with the transcript and the answer, matched by `id`.
    func sendClip(at url: URL, timeout: TimeInterval = 100) async -> ClipReply {
        guard WCSession.isSupported() else { return ClipReply(error: "iPhone isn't reachable.") }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            try? FileManager.default.removeItem(at: url)
            return ClipReply(error: "iPhone isn't reachable.")
        }
        let audio: Data
        do { audio = try Data(contentsOf: url) } catch {
            try? FileManager.default.removeItem(at: url)
            return ClipReply(error: "I didn't catch that.")
        }
        guard audio.count > 256 else {
            try? FileManager.default.removeItem(at: url)
            return ClipReply(error: "I didn't catch that.")
        }
        let id = UUID().uuidString
        return await withCheckedContinuation { cont in
            let waiter = ClipWaiter(cont)
            lock.lock()
            waiters[id] = waiter
            lock.unlock()
            if audio.count <= 50_000 {
                try? FileManager.default.removeItem(at: url)
                session.sendMessageData(ClipWire.pack(id: id, audio: audio), replyHandler: { data in
                    guard let reply = ClipWire.reply(from: data), reply.isAnswer else { return }
                    self.finish(id, reply)
                }, errorHandler: { _ in
                    self.finish(id, ClipReply(error: "iPhone isn't reachable."))
                })
            } else {
                waiter.file = url
                session.transferFile(url, metadata: ["id": id, "op": "clip"])
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                self.finish(id, ClipReply(error: "No reply from the iPhone.", timedOut: true))
            }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let id = message["id"] as? String else { return }
        let reply = ClipReply(transcript: message["transcript"] as? String,
                              say: message["say"] as? String,
                              error: message["error"] as? String,
                              title: message["title"] as? String)
        guard reply.isAnswer else { return }
        finish(id, reply)
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let id = fileTransfer.file.metadata?["id"] as? String else { return }
        if error != nil { finish(id, ClipReply(error: "iPhone isn't reachable.")) }
    }

    private func finish(_ id: String, _ reply: ClipReply) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        if let url = waiter?.take(reply) { try? FileManager.default.removeItem(at: url) }
    }

    func decideAction(id: String, approve: Bool) async -> (text: String, finished: Bool) {
        guard WCSession.isSupported() else { return ("Open Lumen on iPhone to approve", false) }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            return ("Open Lumen on iPhone to approve", false)
        }
        let payload: [String: Any] = ["op": "action", "id": id, "decision": approve ? "approve" : "deny"]
        return await withCheckedContinuation { cont in
            let once = ResumeBox()
            session.sendMessage(payload, replyHandler: { reply in
                let text = (reply["text"] as? String) ?? (approve ? "Approved" : "Denied")
                let ok = (reply["ok"] as? String) == "1"
                once.run { cont.resume(returning: (text, ok)) }
            }, errorHandler: { _ in
                session.transferUserInfo(payload)
                once.run { cont.resume(returning: ("Open Lumen on iPhone to approve", false)) }
            })
            DispatchQueue.global().asyncAfter(deadline: .now() + 18) {
                once.run { cont.resume(returning: ("Open Lumen on iPhone to approve", false)) }
            }
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

struct ClipReply {
    var transcript: String?
    var say: String?
    var error: String?
    var title: String?
    var timedOut = false
    var isAnswer: Bool { transcript != nil || say != nil || error != nil }
}

/// Bytes on the wire: 4-byte header length, JSON `{"id"}`, then the m4a.
private enum ClipWire {
    static func pack(id: String, audio: Data) -> Data {
        let header = (try? JSONSerialization.data(withJSONObject: ["id": id])) ?? Data()
        var out = Data()
        var length = UInt32(header.count).bigEndian
        withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
        out.append(header)
        out.append(audio)
        return out
    }

    static func unpack(_ data: Data) -> (id: String, audio: Data)? {
        guard data.count >= 4 else { return nil }
        let length = Int(data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard length > 0, data.count >= 4 + length else { return nil }
        let header = data.subdata(in: 4..<(4 + length))
        guard let obj = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty else { return nil }
        return (id, data.subdata(in: (4 + length)..<data.count))
    }

    static func reply(from data: Data) -> ClipReply? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ClipReply(transcript: obj["transcript"] as? String,
                         say: obj["say"] as? String,
                         error: obj["error"] as? String,
                         title: obj["title"] as? String)
    }

    static func json(_ payload: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }
}

private final class ClipWaiter {
    private let lock = NSLock()
    private var cont: CheckedContinuation<ClipReply, Never>?
    var file: URL?
    init(_ cont: CheckedContinuation<ClipReply, Never>) { self.cont = cont }
    func take(_ reply: ClipReply) -> URL? {
        lock.lock(); defer { lock.unlock() }
        let resume = cont
        cont = nil
        resume?.resume(returning: reply)
        let url = file
        file = nil
        return url
    }
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
