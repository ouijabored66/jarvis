import Foundation

/// How long a phone reply may take before the screen stops waiting.
enum RelayWait {
    static let cap: TimeInterval = 100
    static let thinking = "Thinking…"
    static let miss = "Didn't catch that"

    /// True while the wait is still inside the cap. 15s, 60s, and 95s all count.
    static func accepts(elapsed: TimeInterval) -> Bool {
        elapsed >= 0 && elapsed < cap
    }
}

enum RelayChannel: String, Equatable {
    case original
    case sendMessage
    case userInfo
    case context
}

struct RelayReply: Equatable {
    var id: String
    var transcript: String?
    var say: String?
    var error: String?
    var title: String?
    var channel: RelayChannel = .original
}

enum PhoneDelivery {
    enum Step: String, Equatable {
        case originalHandler
        case sendMessage
        case sendMessageRetry
        case userInfo
        case context
    }

    /// The original handler carries the answer when the session is up.
    /// Otherwise a message is tried twice, then a queued user-info update and
    /// an application context update, both keyed by the request id.
    static func plan(reachable: Bool, handlerOpen: Bool) -> [Step] {
        var steps: [Step] = []
        if reachable && handlerOpen {
            steps.append(.originalHandler)
        } else {
            steps.append(.sendMessage)
            steps.append(.sendMessageRetry)
        }
        steps.append(.userInfo)
        steps.append(.context)
        return steps
    }
}

struct WatchTurn: Equatable {
    var userLine: String?
    var replyLine: String?
    var thinking: Bool
}

/// One screen for every channel. The same id is shown once.
struct WatchInbox {
    private var heard = Set<String>()
    private var userShown = Set<String>()
    private var sayShown = Set<String>()
    private var noticeShown = Set<String>()
    private(set) var lines: [String] = []

    func knowsTranscript(_ id: String) -> Bool { heard.contains(id) }
    func showedReply(_ id: String) -> Bool { sayShown.contains(id) }

    mutating func receive(_ reply: RelayReply, elapsed: TimeInterval) -> WatchTurn {
        let transcript = Self.trim(reply.transcript)
        let say = Self.trim(reply.say)
        let error = Self.trim(reply.error)
        if !transcript.isEmpty { heard.insert(reply.id) }
        if error == RelayWait.miss && heard.contains(reply.id) {
            return WatchTurn(userLine: nil, replyLine: nil, thinking: !sayShown.contains(reply.id))
        }
        if !say.isEmpty {
            let user = (!transcript.isEmpty && userShown.insert(reply.id).inserted) ? transcript : nil
            guard sayShown.insert(reply.id).inserted else {
                return WatchTurn(userLine: nil, replyLine: nil, thinking: false)
            }
            lines.append(say)
            return WatchTurn(userLine: user, replyLine: say, thinking: false)
        }
        if !transcript.isEmpty {
            let user = userShown.insert(reply.id).inserted ? transcript : nil
            return WatchTurn(userLine: user, replyLine: nil, thinking: true)
        }
        if !error.isEmpty {
            guard noticeShown.insert(reply.id).inserted, !sayShown.contains(reply.id) else {
                return WatchTurn(userLine: nil, replyLine: nil, thinking: false)
            }
            lines.append(error)
            return WatchTurn(userLine: nil, replyLine: error, thinking: false)
        }
        return WatchTurn(userLine: nil, replyLine: nil, thinking: RelayWait.accepts(elapsed: elapsed))
    }

    private static func trim(_ text: String?) -> String {
        text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum CloudRoutes {
    /// `api/*` on a base that ends in `/v1` uses the host root. `/api` is not appended to `/v1`.
    static func url(base raw: String, path: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parts.host != nil else { return nil }
        if parts.path.count > 1, parts.path.hasSuffix("/") { parts.path.removeLast() }
        let root = parts.path == "/" ? "" : parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let leaf = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rooted = root == "v1" || root.hasSuffix("/v1")
        let api = leaf == "api" || leaf.hasPrefix("api/")
        if rooted && api {
            parts.path = "/" + leaf
        } else {
            parts.path = "/" + [root, leaf].filter { !$0.isEmpty }.joined(separator: "/")
        }
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    /// A 404 means this route is not there. Skip it instead of treating the body as text.
    static func skipTranscribe(status: Int) -> Bool { status == 404 }
}
