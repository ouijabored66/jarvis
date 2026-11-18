#if canImport(WatchConnectivity) && os(iOS)
import Foundation
import Speech
import UserNotifications
import WatchConnectivity

/// Tells the Watch the assistant name, settings, and Cloud address.
/// The Cloud key is copied into the Watch keychain for direct mode and is not logged.
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
    func push(from model: LumenModel) {
        let cloudURL = model.activeCustom?.cloudURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ctx: [String: String] = ["speakReplies": model.speakReplies ? "1" : "0",
                                     "demoMode": model.demoMode ? "1" : "0",
                                     "title": model.assistantTitle,
                                     "speechVoice": model.speechVoiceID,
                                     "speechRate": String(model.speechRate),
                                     "cloudURL": cloudURL,
                                     "cloudKey": cloudURL.isEmpty ? "" : model.sharedProviderKey(),
                                     "actions": model.pendingWatchActions()]
        send(ctx)
        ActionAlerts.sync(model.pendingWatchActions())
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

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard (userInfo["op"] as? String) == "action" else { return }
        let id = userInfo["id"] as? String ?? ""
        let yes = (userInfo["decision"] as? String) == "approve"
        Task { @MainActor in
            _ = await LumenHub.model?.respondToWatch(id: id, approve: yes)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let text = message["ask"] as? String ?? ""
        let op = message["op"] as? String ?? ""
        let reset = op == "reset"
        let once = ReplyOnce(replyHandler)
        Task { @MainActor in
            if op == "action" {
                let id = message["id"] as? String ?? ""
                let yes = (message["decision"] as? String) == "approve"
                let reply = await LumenHub.model?.respondToWatch(id: id, approve: yes) ?? "Open Lumen on iPhone to approve"
                let waiting = reply == "Open Lumen on iPhone to approve" || reply == "Couldn't approve that." || reply.hasPrefix("Couldn't reach")
                once.send(["ok": waiting ? "0" : "1", "text": reply])
                return
            }
            if reset {
                await LumenHub.model?.resetConversation()
                once.send(["ok": "1", "title": LumenHub.model?.assistantTitle ?? "Lumen"])
                return
            }
            let result = await self.answer?(text) ?? (say: nil, error: "Open Lumen Voice on your iPhone.", title: "Lumen")
            var payload: [String: Any] = ["title": result.title]
            if let say = result.say { payload["say"] = say }
            if let error = result.error { payload["error"] = error }
            once.send(payload)
        }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        guard let (id, audio) = ClipWire.unpack(messageData),
              let file = Self.write(audio, id: id) else {
            replyHandler(ClipWire.json(["error": "I didn't catch that."]))
            return
        }
        replyHandler(ClipWire.json(["id": id, "ok": "1"]))
        Task { await self.consume(session, id: id, file: file) }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let id = (file.metadata?["id"] as? String) ?? UUID().uuidString
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-clip-\(id).m4a")
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: file.fileURL, to: dest)
        } catch {
            reply(session, id: id, transcript: nil, say: nil, error: "I didn't catch that.", title: nil)
            return
        }
        Task { await self.consume(session, id: id, file: dest) }
    }

    private func consume(_ session: WCSession, id: String, file: URL) async {
        defer { try? FileManager.default.removeItem(at: file) }
        let fallback = await MainActor.run { LumenHub.model?.assistantTitle ?? "Lumen" }
        do {
            let text = try await Self.transcribe(file).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                reply(session, id: id, transcript: nil, say: nil, error: "I didn't catch that.", title: fallback)
                return
            }
            let answer = self.answer
            let result = await Task { @MainActor in
                await answer?(text) ?? (say: nil, error: "Open Lumen Voice on your iPhone.", title: fallback)
            }.value
            reply(session, id: id, transcript: text, say: result.say, error: result.error, title: result.title)
        } catch HearError.denied {
            reply(session, id: id, transcript: nil, say: nil, error: "Speech recognition is off on the iPhone.", title: fallback)
        } catch {
            reply(session, id: id, transcript: nil, say: nil, error: "I didn't catch that.", title: fallback)
        }
    }

    private func reply(_ session: WCSession, id: String, transcript: String?, say: String?, error: String?, title: String?) {
        var payload: [String: Any] = ["id": id, "title": title ?? "Lumen"]
        if let transcript, !transcript.isEmpty { payload["transcript"] = transcript }
        if let say, !say.isEmpty { payload["say"] = say }
        if let error, !error.isEmpty { payload["error"] = error }
        DispatchQueue.main.async {
            guard session.activationState == .activated, session.isReachable else { return }
            session.sendMessage(payload, replyHandler: nil, errorHandler: { _ in })
        }
    }

    private static func write(_ audio: Data, id: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-clip-\(id).m4a")
        do { try audio.write(to: url, options: .atomic); return url } catch { return nil }
    }

    /// On-device when this iPhone supports it. Authorization is requested here.
    private static func transcribe(_ url: URL) async throws -> String {
        let status: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            status = await withCheckedContinuation { cont in
                DispatchQueue.main.async {
                    SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
                }
            }
        } else {
            status = SFSpeechRecognizer.authorizationStatus()
        }
        guard status == .authorized else { throw HearError.denied }
        guard let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { throw HearError.failed }
        let request = SFSpeechURLRecognitionRequest(url: url)
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let once = ResumeOnce()
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.run { cont.resume(returning: result.bestTranscription.formattedString) }
                } else if error != nil {
                    once.run { cont.resume(throwing: HearError.failed) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                task.cancel()
                once.run { cont.resume(throwing: HearError.failed) }
            }
        }
    }
}

private enum HearError: Error { case denied, failed }

/// Bytes on the wire: 4-byte header length, JSON `{"id"}`, then the m4a.
private enum ClipWire {
    static func unpack(_ data: Data) -> (id: String, audio: Data)? {
        guard data.count >= 4 else { return nil }
        let length = Int(data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard length > 0, data.count >= 4 + length else { return nil }
        let header = data.subdata(in: 4..<(4 + length))
        guard let obj = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty else { return nil }
        return (id, data.subdata(in: (4 + length)..<data.count))
    }

    static func json(_ payload: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }
}

/// Resumes a speech continuation once.
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

/// Local alerts for a pending task. No push entitlement: a free sideload can show them, and the phone mirrors them.
enum ActionAlerts {
    private static let categoryID = "lumen.action"

    static func sync(_ json: String) {
        let rows = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]]) ?? []
        let center = UNUserNotificationCenter.current()
        let approve = UNNotificationAction(identifier: "approve", title: "Approve", options: [])
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])
        let category = UNNotificationCategory(identifier: categoryID, actions: [approve, deny], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
                    if ok { deliver(rows, center) }
                }
            case .authorized, .provisional, .ephemeral:
                deliver(rows, center)
            default:
                break
            }
        }
    }

    private static func deliver(_ rows: [[String: String]], _ center: UNUserNotificationCenter) {
        let ids = Set(rows.compactMap { $0["id"] })
        center.getDeliveredNotifications { notes in
            let existing = Set(notes.map(\.request.identifier))
            let drop = existing.filter { id in
                guard id.hasPrefix("act-") else { return false }
                return !ids.contains(String(id.dropFirst(4)))
            }
            if !drop.isEmpty { center.removeDeliveredNotifications(withIdentifiers: Array(drop)) }
            for row in rows {
                guard let id = row["id"], !id.isEmpty else { continue }
                let ident = "act-\(id)"
                if existing.contains(ident) { continue }
                let content = UNMutableNotificationContent()
                content.title = row["title"] ?? "Needs your approval"
                content.body = row["detail"] ?? ""
                content.sound = .default
                content.categoryIdentifier = categoryID
                content.userInfo = ["id": id]
                center.add(UNNotificationRequest(identifier: ident, content: content, trigger: nil))
            }
        }
    }
}

final class ActionAlertDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ActionAlertDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let approve = response.actionIdentifier == "approve"
        let deny = response.actionIdentifier == "deny"
        guard approve || deny else { return }
        let id = (response.notification.request.content.userInfo["id"] as? String) ?? ""
        guard !id.isEmpty, let model = await LumenHub.model else { return }
        await model.respondToWatch(id: id, approve: approve)
    }
}
#endif
