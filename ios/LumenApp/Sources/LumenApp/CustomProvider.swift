import Foundation
import SwiftUI

/// Where a saved cloud or local chat provider is reached.
enum CustomRoute: String, Codable, CaseIterable, Identifiable {
    case local, cloud, auto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: return "Local only"
        case .cloud: return "Cloud only"
        case .auto: return "Auto"
        }
    }
}

/// Non-secret settings for one provider. A cloud address uses the single key in the Keychain.
struct CustomProvider: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var localURL: String
    var cloudURL: String
    var route: CustomRoute
    var model: String
    var temperature: Double
    var maxTokens: Int

    static func make(name: String, localURL: String = "", cloudURL: String = "", route: CustomRoute, model: String = "") -> CustomProvider {
        CustomProvider(id: UUID().uuidString, name: name, localURL: localURL, cloudURL: cloudURL,
                       route: route, model: model, temperature: 0.7, maxTokens: 400)
    }

    static func load() -> [CustomProvider] {
        guard let data = UserDefaults.standard.data(forKey: "custom.providers"),
              let list = try? JSONDecoder().decode([CustomProvider].self, from: data) else { return [] }
        return list
    }

    /// Bases to try, local first when the mode is Auto.
    func bases() -> [URL] {
        let local = Self.base(localURL)
        let cloud = Self.base(cloudURL)
        switch route {
        case .local: return local.map { [$0] } ?? []
        case .cloud: return cloud.map { [$0] } ?? []
        case .auto:
            var list: [URL] = []
            if let local { list.append(local) }
            if let cloud, cloud != local { list.append(cloud) }
            return list
        }
    }

    func endpoint(for route: CustomRoute) -> URL? {
        switch route {
        case .local: return Self.base(localURL)
        case .cloud: return Self.base(cloudURL)
        case .auto: return Self.base(localURL) ?? Self.base(cloudURL)
        }
    }

    private static func base(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parts.host != nil else { return nil }
        if parts.path.count > 1, parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url
    }
}

enum CustomPreset: String, CaseIterable, Identifiable {
    case grok, openRouter, groq, ollama, lmStudio
    var id: String { rawValue }
    var title: String {
        switch self {
        case .grok: return "Grok"
        case .openRouter: return "OpenRouter"
        case .groq: return "Groq"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        }
    }
    var provider: CustomProvider {
        switch self {
        case .grok:
            return .make(name: "Grok", cloudURL: "https://api.x.ai/v1", route: .cloud, model: "grok-4")
        case .openRouter:
            return .make(name: "OpenRouter", cloudURL: "https://openrouter.ai/api/v1", route: .cloud, model: "meta-llama/llama-3.3-70b-instruct")
        case .groq:
            return .make(name: "Groq", cloudURL: "https://api.groq.com/openai/v1", route: .cloud, model: "llama-3.3-70b-versatile")
        case .ollama:
            return .make(name: "Ollama", localURL: "http://127.0.0.1:11434/v1", route: .local, model: "llama3.2")
        case .lmStudio:
            return .make(name: "LM Studio", localURL: "http://127.0.0.1:1234/v1", route: .local)
        }
    }
}

enum CustomFailure: Error, Equatable {
    case rejected, unreachable, empty, blocked, noURL, noModel
}

enum CustomHTTP {
    /// Plain http is limited to this machine, private LAN, Tailscale 100.64/10, .local, and .ts.net.
    static func allowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http", let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host == "local" || host.hasSuffix(".local") || host.hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        let a = parts[0], b = parts[1]
        if a == 10 || a == 127 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 100 && (64...127).contains(b) { return true }
        return false
    }
}

/// Any non-empty custom key. Prefix checks do not apply here.
enum CustomKey {
    static func trimmed(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func accepted(_ raw: String) -> Bool {
        !trimmed(raw).isEmpty
    }

    /// `Authorization` value. Empty and whitespace-only keys send no header.
    static func bearer(_ raw: String) -> String? {
        let key = trimmed(raw)
        guard !key.isEmpty else { return nil }
        return "Bearer \(key)"
    }
}

struct CustomReach {
    var name: String
    var os: ServerOS?
}

struct CustomCatalog {
    var names: [String]
    var os: ServerOS?
}

/// Chat with a cloud or local endpoint. The key is a request header and is never logged.
struct CustomClient {
    static let rejectedMessage = "Key rejected, check your API key"

    func test(provider: CustomProvider, apiKey: String) async -> Result<CustomReach, CustomFailure> {
        let bases = provider.bases()
        guard !bases.isEmpty else { return .failure(.noURL) }
        var sawBlocked = false
        var sawRejected = false
        for base in bases {
            switch await fetchLumen(base: base, path: "api/status", apiKey: apiKey) {
            case .ok(let reply):
                return .success(Self.reach(provider.name, reply: reply))
            case .rejected: sawRejected = true
            case .blocked: sawBlocked = true
            case .unreachable: break
            }
            let models = await fetch(url: Self.join(base, "models"), apiKey: apiKey)
            switch models {
            case .ok:
                let os = await resolveOS(base: base, apiKey: apiKey, primary: models)
                return .success(CustomReach(name: provider.name, os: os))
            case .rejected: return .failure(.rejected)
            case .blocked: sawBlocked = true
            case .unreachable: break
            }
            let turns = [ProviderClient.Turn(fromMe: true, text: "Hi")]
            switch await chat(base: base, provider: provider, turns: turns, apiKey: apiKey, maxTokens: 1, timeout: 30) {
            case .success(let payload):
                let os = await resolveOS(base: base, apiKey: apiKey, primary: .ok(payload.reply))
                return .success(CustomReach(name: provider.name, os: os))
            case .failure(.rejected): return .failure(.rejected)
            case .failure(.blocked): sawBlocked = true
            case .failure: break
            }
            switch await lumenPing(base: base, name: provider.name, apiKey: apiKey) {
            case .success(let reach): return .success(reach)
            case .failure(.rejected): return .failure(.rejected)
            case .failure(.blocked): sawBlocked = true
            case .failure: break
            }
        }
        if sawRejected { return .failure(.rejected) }
        return .failure(sawBlocked && bases.allSatisfy { !CustomHTTP.allowed($0) } ? .blocked : .unreachable)
    }

    func discover(provider: CustomProvider, apiKey: String) async -> Result<CustomCatalog, CustomFailure> {
        let bases = provider.bases()
        guard !bases.isEmpty else { return .failure(.noURL) }
        var names: [String] = []
        var detected: ServerOS?
        var rejected = false
        var blocked = true
        for base in bases {
            if CustomHTTP.allowed(base) { blocked = false }
            let models = await fetch(url: Self.join(base, "models"), apiKey: apiKey)
            switch models {
            case .ok(let reply):
                names.append(contentsOf: Self.listedModels(reply.data))
                detected = detected ?? ServerOS.read(response: reply.http, data: reply.data)
            case .rejected: rejected = true
            case .blocked, .unreachable: break
            }
            if let tags = Self.tagsURL(base) {
                switch await fetch(url: tags, apiKey: apiKey) {
                case .ok(let reply):
                    names.append(contentsOf: Self.ollamaModels(reply.data))
                    detected = detected ?? ServerOS.read(response: reply.http, data: reply.data)
                case .rejected: rejected = true
                case .blocked, .unreachable: break
                }
            }
            if !names.isEmpty {
                if detected == nil {
                    detected = await resolveOS(base: base, apiKey: apiKey, primary: models)
                }
                return .success(CustomCatalog(names: Self.unique(names), os: detected))
            }
        }
        if rejected && names.isEmpty { return .failure(.rejected) }
        if blocked { return .failure(.blocked) }
        return names.isEmpty ? .failure(.unreachable) : .success(CustomCatalog(names: Self.unique(names), os: detected))
    }

    func reply(provider: CustomProvider, turns: [ProviderClient.Turn], apiKey: String) async -> Result<String, CustomFailure> {
        let bases = provider.bases()
        guard !bases.isEmpty else { return .failure(.noURL) }
        let modelName = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let userText = turns.last(where: { $0.fromMe })?.text ?? ""
        var last: CustomFailure = modelName.isEmpty ? .unreachable : .noModel
        for (index, base) in bases.enumerated() {
            let more = index + 1 < bases.count
            if !modelName.isEmpty {
                switch await chat(base: base, provider: provider, turns: turns, apiKey: apiKey, maxTokens: provider.maxTokens) {
                case .success(let payload): return .success(payload.text)
                case .failure(.rejected): return .failure(.rejected)
                case .failure(.empty): return .failure(.empty)
                case .failure(let error):
                    last = error
                    if error != .unreachable && error != .blocked { return .failure(error) }
                }
            }
            switch await lumenSpeak(base: base, apiKey: apiKey, text: userText) {
            case .success(let text): return .success(text)
            case .failure(.rejected): return .failure(.rejected)
            case .failure(.empty): return .failure(.empty)
            case .failure(let error):
                last = error
                if (error == .unreachable || error == .blocked) && more { continue }
                return .failure(error)
            }
        }
        return .failure(last)
    }

    private struct ChatPayload {
        var text: String
        var reply: Reply
    }

    private func chat(base: URL, provider: CustomProvider, turns: [ProviderClient.Turn], apiKey: String, maxTokens: Int, timeout: TimeInterval = 120) async -> Result<ChatPayload, CustomFailure> {
        var messages: [[String: Any]] = [["role": "system", "content": ProviderClient.systemPrompt]]
        for turn in turns where !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": turn.fromMe ? "user" : "assistant", "content": turn.text])
        }
        let payload: [String: Any] = [
            "model": provider.model,
            "temperature": min(2, max(0, provider.temperature)),
            "max_tokens": max(1, maxTokens),
            "messages": messages
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return .failure(.unreachable) }
        var request = URLRequest(url: Self.join(base, "chat/completions"))
        request.httpMethod = "POST"
        request.httpBody = body
        Self.headers(on: &request, apiKey: apiKey, json: true)
        switch await fetch(request, timeout: timeout) {
        case .ok(let reply):
            let text = Self.replyText(reply.data).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .failure(.empty) : .success(ChatPayload(text: text, reply: reply))
        case .rejected: return .failure(.rejected)
        case .unreachable: return .failure(.unreachable)
        case .blocked: return .failure(.blocked)
        }
    }

    private struct Reply {
        var data: Data
        var http: HTTPURLResponse?
    }

    private enum Call { case ok(Reply), rejected, unreachable, blocked }

    private func fetch(url: URL, apiKey: String) async -> Call {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        Self.headers(on: &request, apiKey: apiKey, json: false)
        return await fetch(request)
    }

    private func fetch(_ request: URLRequest, timeout: TimeInterval = 30) async -> Call {
        guard let url = request.url, CustomHTTP.allowed(url) else { return .blocked }
        var timed = request
        timed.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: timed)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 401 || code == 403 { return .rejected }
            if (200..<300).contains(code) { return .ok(Reply(data: data, http: http)) }
            return .unreachable
        } catch {
            return .unreachable
        }
    }

    /// Saved keys are sent as `Authorization: Bearer` on `/api/status`, `/api/text`, `/api/ask`, and the chat route.
    private static func headers(on request: inout URLRequest, apiKey: String, json: Bool) {
        if json { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let bearer = CustomKey.bearer(apiKey) {
            request.setValue(bearer, forHTTPHeaderField: "Authorization")
        }
    }

    private func fetchLumen(base: URL, path: String, apiKey: String) async -> Call {
        var sawRejected = false
        var sawBlocked = false
        for url in Self.lumenURLs(base, path) {
            switch await fetch(url: url, apiKey: apiKey) {
            case .ok(let reply): return .ok(reply)
            case .rejected: sawRejected = true
            case .blocked: sawBlocked = true
            case .unreachable: break
            }
        }
        if sawRejected { return .rejected }
        if sawBlocked { return .blocked }
        return .unreachable
    }

    private func postLumen(base: URL, path: String, apiKey: String, text: String, timeout: TimeInterval = 30) async -> Result<Reply, CustomFailure> {
        guard let body = try? JSONSerialization.data(withJSONObject: ["text": text]) else { return .failure(.unreachable) }
        var sawRejected = false
        var sawBlocked = false
        for url in Self.lumenURLs(base, path) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            Self.headers(on: &request, apiKey: apiKey, json: true)
            switch await fetch(request, timeout: timeout) {
            case .ok(let reply): return .success(reply)
            case .rejected: sawRejected = true
            case .blocked: sawBlocked = true
            case .unreachable: break
            }
        }
        if sawRejected { return .failure(.rejected) }
        if sawBlocked { return .failure(.blocked) }
        return .failure(.unreachable)
    }

    /// Text first, then the other relay route. A saved key is attached to both.
    private func lumenSpeak(base: URL, apiKey: String, text: String) async -> Result<String, CustomFailure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        var sawBlocked = false
        for path in ["api/text", "api/ask"] {
            switch await postLumen(base: base, path: path, apiKey: apiKey, text: trimmed, timeout: 120) {
            case .success(let reply):
                let say = (path == "api/ask" ? Self.askText(reply.data) : Self.sayText(reply.data))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return say.isEmpty ? .failure(.empty) : .success(say)
            case .failure(.rejected): return .failure(.rejected)
            case .failure(.blocked): sawBlocked = true
            case .failure: break
            }
        }
        return .failure(sawBlocked ? .blocked : .unreachable)
    }

    private func lumenPing(base: URL, name: String, apiKey: String) async -> Result<CustomReach, CustomFailure> {
        var sawBlocked = false
        for path in ["api/text", "api/ask"] {
            switch await postLumen(base: base, path: path, apiKey: apiKey, text: "Hi") {
            case .success(let reply): return .success(Self.reach(name, reply: reply))
            case .failure(.rejected): return .failure(.rejected)
            case .failure(.blocked): sawBlocked = true
            case .failure: break
            }
        }
        return .failure(sawBlocked ? .blocked : .unreachable)
    }

    private static func lumenURLs(_ base: URL, _ path: String) -> [URL] {
        var urls = [join(base, path)]
        if let origin = origin(base) {
            let root = join(origin, path)
            if root.absoluteString != urls[0].absoluteString { urls.append(root) }
        }
        return urls
    }

    private static func reach(_ name: String, reply: Reply) -> CustomReach {
        CustomReach(name: statusName(reply.data) ?? name, os: ServerOS.read(response: reply.http, data: reply.data))
    }

    private static func statusName(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sayText(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let say = obj["say"] as? String, !say.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return say }
        return replyText(data)
    }

    /// One JSON object, or newline-delimited objects. The first `say` or `reply` string wins.
    private static func askText(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let spoken = spokenLine(obj) { return spoken }
            return replyText(data)
        }
        let raw = String(decoding: data, as: UTF8.self)
        for line in raw.split(whereSeparator: \.isNewline) {
            let piece = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty, let row = piece.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: row) as? [String: Any],
                  let spoken = spokenLine(obj) else { continue }
            return spoken
        }
        return ""
    }

    private static func spokenLine(_ obj: [String: Any]) -> String? {
        for key in ["say", "reply"] {
            guard let value = obj[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Models, then `/info` and `/health`, including the host root when the base ends in `/v1`.
    private func resolveOS(base: URL, apiKey: String, primary: Call) async -> ServerOS? {
        if let found = Self.os(in: primary) { return found }
        var urls = [Self.join(base, "info"), Self.join(base, "health")]
        if let origin = Self.origin(base) {
            urls.append(Self.join(origin, "health"))
            urls.append(Self.join(origin, "info"))
            urls.append(Self.join(origin, "v1/info"))
        }
        var seen = Set<String>()
        for url in urls {
            guard seen.insert(url.absoluteString).inserted else { continue }
            if let found = Self.os(in: await fetch(url: url, apiKey: apiKey)) { return found }
        }
        return nil
    }

    private static func os(in call: Call) -> ServerOS? {
        guard case .ok(let reply) = call else { return nil }
        return ServerOS.read(response: reply.http, data: reply.data)
    }

    private static func join(_ base: URL, _ path: String) -> URL {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        let root = parts.path == "/" ? "" : parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let leaf = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = "/" + [root, leaf].filter { !$0.isEmpty }.joined(separator: "/")
        return parts.url ?? base
    }

    private static func origin(_ base: URL) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    private static func tagsURL(_ base: URL) -> URL? {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        parts?.path = "/api/tags"
        parts?.query = nil
        return parts?.url
    }

    private static func listedModels(_ data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { $0["id"] as? String }
    }

    private static func ollamaModels(_ data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["models"] as? [[String: Any]] else { return [] }
        return rows.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
    }

    private static func replyText(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return "" }
        return (message["content"] as? String) ?? ""
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen: [String] = []
        for name in names where !name.isEmpty && !seen.contains(name) { seen.append(name) }
        return seen
    }
}

extension LumenModel {
    var activeCustom: CustomProvider? {
        customProviders.first { $0.id == customActiveID } ?? customProviders.first
    }

    func addCustom(_ preset: CustomPreset) {
        let created = preset.provider
        customProviders.append(created)
        customActiveID = created.id
        customConnectedName = nil
        customNote = ""
        customModels = []
        persistCustom()
        refreshTitle()
    }

    func selectCustom(_ id: String) {
        customActiveID = id
        customConnectedName = nil
        customNote = ""
        customModels = []
        persistCustom()
        refreshTitle()
    }

    func updateActiveCustom(_ change: (inout CustomProvider) -> Void) {
        guard let id = activeCustom?.id, let index = customProviders.firstIndex(where: { $0.id == id }) else { return }
        change(&customProviders[index])
        customProviders[index].temperature = min(2, max(0, customProviders[index].temperature))
        customProviders[index].maxTokens = max(1, customProviders[index].maxTokens)
        persistCustom()
        refreshTitle()
    }

    func deleteActiveCustom() {
        guard let id = activeCustom?.id else { return }
        customProviders.removeAll { $0.id == id }
        customActiveID = customProviders.first?.id ?? ""
        customConnectedName = nil
        customNote = ""
        customModels = []
        persistCustom()
        refreshTitle()
    }

    func testActiveCustom() async {
        guard let route = activeCustom?.route else { customNote = "Add a provider first."; return }
        await testProviderRoute(route)
    }

    func testProviderRoute(_ route: CustomRoute) async {
        guard var provider = activeCustom else { customNote = "Add a provider first."; return }
        provider.route = route
        customBusy = true
        customConnectedName = nil
        customNote = ""
        defer { customBusy = false }
        let result = await CustomClient().test(provider: provider, apiKey: sharedProviderKey())
        switch result {
        case .success(let reach):
            customConnectedName = reach.name
            customNote = ""
            noteServerOS(reach.os)
        case .failure(.rejected):
            customConnectedName = nil
            customNote = CustomClient.rejectedMessage
        case .failure(.blocked):
            customConnectedName = nil
            customNote = "Plain http is only allowed for a local address, 100.x, .local, or .ts.net."
        case .failure(.noURL):
            customConnectedName = nil
            if route == .local { customNote = "Add a local URL." }
            else if route == .cloud { customNote = "Add a cloud URL." }
            else { customNote = "Add a local or cloud URL." }
        case .failure:
            customConnectedName = nil
            customNote = "Can't reach \(provider.name). Check the URL and try again."
        }
        refreshTitle()
    }

    func discoverActiveModels() async {
        guard let provider = activeCustom else { return }
        customBusy = true
        defer { customBusy = false }
        let result = await CustomClient().discover(provider: provider, apiKey: sharedProviderKey())
        switch result {
        case .success(let catalog):
            customModels = catalog.names
            noteServerOS(catalog.os)
            if provider.model.isEmpty, let first = catalog.names.first {
                updateActiveCustom { $0.model = first }
            }
            customNote = catalog.names.isEmpty ? "No models were listed." : ""
        case .failure(.rejected):
            customNote = CustomClient.rejectedMessage
        case .failure(.blocked):
            customNote = "Plain http is only allowed for a local address, 100.x, .local, or .ts.net."
        case .failure(.noURL):
            customNote = "Add a local or cloud URL."
        case .failure:
            customNote = "Couldn't list models."
        }
    }

    func customReply(speak: Bool) async -> (say: String?, error: String?) {
        guard let provider = activeCustom else {
            let err = "Add a cloud or custom provider in Settings."
            fail(err)
            return (nil, err)
        }
        let turns = messages.compactMap { message -> ProviderClient.Turn? in
            switch message.role {
            case .me: return .init(fromMe: true, text: message.text)
            case .lumen: return .init(fromMe: false, text: message.text)
            case .system: return nil
            }
        }
        switch await CustomClient().reply(provider: provider, turns: turns, apiKey: sharedProviderKey()) {
        case .success(let say):
            let text = say.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                let err = "The assistant sent an empty reply."
                fail(err)
                return (nil, err)
            }
            messages.append(ChatMessage(role: .lumen, text: text))
            state = .idle
            customConnectedName = provider.name
            refreshTitle()
            if speak { demoVoice.speak(text) }
            return (text, nil)
        case .failure(let error):
            let err: String
            switch error {
            case .rejected: err = CustomClient.rejectedMessage
            case .blocked: err = "Plain http is only allowed for a local address, 100.x, .local, or .ts.net."
            case .noURL: err = "Add a local or cloud URL in Settings."
            case .noModel: err = "Choose a model in Settings."
            case .empty: err = "The assistant sent an empty reply."
            case .unreachable: err = "Can't reach \(provider.name). Check the URL and try again."
            }
            fail(err)
            return (nil, err)
        }
    }

    func persistCustom() {
        if let data = try? JSONEncoder().encode(customProviders) {
            UserDefaults.standard.set(data, forKey: "custom.providers")
        }
        UserDefaults.standard.set(customActiveID, forKey: "custom.active")
    }
}

/// Provider editor shared by Settings and onboarding. Secrets are SecureFields and are saved only into the Keychain.
struct CustomProviderSettings: View {
    @EnvironmentObject var model: LumenModel
    @State private var keyDraft = ""
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(CustomPreset.allCases) { preset in
                        Button(preset.title) { model.addCustom(preset) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            if model.customProviders.isEmpty {
                keySecret()
            } else {
                Picker("Provider", selection: Binding(get: { model.activeCustom?.id ?? "" }, set: { model.selectCustom($0); clearDrafts() })) {
                    ForEach(model.customProviders) { provider in
                        Text(provider.name.isEmpty ? "Untitled" : provider.name).tag(provider.id)
                    }
                }
                if let provider = model.activeCustom {
                    editor(provider)
                }
            }
            if let name = model.customConnectedName, model.customNote.isEmpty {
                ConnectedLine(name: name)
            }
            if !model.customNote.isEmpty {
                Text(model.customNote).font(.footnote).foregroundStyle(model.customNote == CustomClient.rejectedMessage ? Color.red : Color.secondary)
            }
        }
        .onChange(of: model.customActiveID) { _, _ in clearDrafts() }
    }

    @ViewBuilder private func editor(_ provider: CustomProvider) -> some View {
        field("Name", text: Binding(get: { provider.name }, set: { value in model.updateActiveCustom { $0.name = value } }))
        field("Local URL", text: Binding(get: { provider.localURL }, set: { value in model.updateActiveCustom { $0.localURL = value } }), url: true)
        HStack {
            Button("Test local") { Task { await model.testProviderRoute(.local) } }
            Spacer()
            Button("Test cloud") { Task { await model.testProviderRoute(.cloud) } }
        }
        .disabled(model.customBusy)
        field("Cloud URL", text: Binding(get: { provider.cloudURL }, set: { value in model.updateActiveCustom { $0.cloudURL = value } }), url: true)
        Picker("Connection", selection: Binding(get: { provider.route }, set: { value in model.updateActiveCustom { $0.route = value } })) {
            ForEach(CustomRoute.allCases) { route in Text(route.title).tag(route) }
        }
        Text("Auto tries the local URL first, then the cloud URL. Any saved key is sent as Bearer to that address.").font(.footnote).foregroundStyle(.secondary)
        ServerOSIndicators(os: model.litServerOS)
        keySecret()
        field("Model", text: Binding(get: { provider.model }, set: { value in model.updateActiveCustom { $0.model = value } }))
        if !model.customModels.isEmpty {
            Picker("Discovered models", selection: Binding(get: { provider.model }, set: { value in model.updateActiveCustom { $0.model = value } })) {
                Text("Choose").tag("")
                ForEach(model.customModels, id: \.self) { name in Text(name).tag(name) }
            }
        }
        Button(model.customBusy ? "Working…" : "Discover models") { Task { await model.discoverActiveModels() } }
            .disabled(model.customBusy)
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            HStack {
                Text("Temperature")
                Slider(value: Binding(get: { provider.temperature }, set: { value in model.updateActiveCustom { $0.temperature = value } }), in: 0...2)
                Text(String(format: "%.1f", provider.temperature)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                Text("Max tokens")
                TextField("400", value: Binding(get: { provider.maxTokens }, set: { value in model.updateActiveCustom { $0.maxTokens = value } }), format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
        }
        HStack {
            Button(model.customBusy ? "Working…" : "Test") { Task { await model.testActiveCustom() } }
                .disabled(model.customBusy)
            Spacer()
            Button("Remove", role: .destructive) { model.deleteActiveCustom(); clearDrafts() }
        }
    }

    private func keySecret() -> some View {
        secret("API key", draft: $keyDraft, saved: model.providerKeySaved, suffix: model.providerKeySuffix) {
            let typed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else { return }
            keyDraft = ""
            Task { await model.saveCustomKey(typed) }
        } onClear: { model.clearProviderKey() }
    }

    private func field(_ title: String, text: Binding<String>, url: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(url ? .URL : .default)
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func secret(_ title: String, draft: Binding<String>, saved: Bool, suffix: String, onSave: @escaping () -> Void, onClear: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            SecureField(title, text: draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(nil)
                .privacySensitive()
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onSubmit {
                    if !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onSave() }
                }
            Button(action: onSave) {
                Text("Save key")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if saved {
                HStack {
                    Text(suffix.isEmpty ? "Key saved" : "Key saved · ••••\(suffix)")
                        .font(.footnote).foregroundStyle(.secondary)
                        .privacySensitive()
                    Spacer()
                    Button("Clear", role: .destructive, action: onClear).font(.footnote)
                }
            }
        }
    }

    private func clearDrafts() {
        keyDraft = ""
    }
}
