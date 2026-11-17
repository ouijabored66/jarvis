import Foundation

/// Which hosted assistant a key belongs to. Detection is by prefix only.
enum AIProvider: String {
    case grok, claude, gemini, groq, openRouter, openAI

    var title: String {
        switch self {
        case .grok: return "Grok"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .groq: return "Groq"
        case .openRouter: return "OpenRouter"
        case .openAI: return "OpenAI"
        }
    }

    /// `xai-` Grok, `sk-ant-` Claude, `AIza` Gemini, `gsk_` Groq, `sk-or-` OpenRouter, other `sk-` OpenAI.
    static func detect(_ key: String) -> AIProvider? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.hasPrefix("xai-") { return .grok }
        if k.hasPrefix("sk-ant-") { return .claude }
        if k.hasPrefix("AIza") { return .gemini }
        if k.hasPrefix("gsk_") { return .groq }
        if k.hasPrefix("sk-or-") { return .openRouter }
        if k.hasPrefix("sk-") { return .openAI }
        return nil
    }
}

enum ProviderFailure: Error {
    case unrecognized, rejected, unreachable, empty
}

/// Talks to a provider with URLSession only. The key is placed in a header for that call and nowhere else.
struct ProviderClient {
    static let systemPrompt = "You are Lumen, a helpful voice assistant."

    struct Turn {
        let fromMe: Bool
        let text: String
    }

    func verify(key: String) async -> Result<AIProvider, ProviderFailure> {
        guard let provider = AIProvider.detect(key) else { return .failure(.unrecognized) }
        switch await fetch(provider.modelsRequest(key: key)) {
        case .success: return .success(provider)
        case .failure(.rejected): return .failure(.rejected)
        case .failure: break
        }
        let ping = await reply(key: key, history: [Turn(fromMe: true, text: "Hi")], maxTokens: 1)
        switch ping {
        case .success: return .success(provider)
        case .failure(let error): return .failure(error == .empty ? .unreachable : error)
        }
    }

    func reply(key: String, history: [Turn], maxTokens: Int = 400) async -> Result<String, ProviderFailure> {
        guard let provider = AIProvider.detect(key) else { return .failure(.unrecognized) }
        let turns = Self.cleaned(history)
        guard !turns.isEmpty else { return .failure(.empty) }
        switch await fetch(provider.chatRequest(key: key, turns: turns, maxTokens: maxTokens)) {
        case .failure(let error): return .failure(error)
        case .success(let data):
            let text = provider.parseReply(data).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .failure(.empty) : .success(text)
        }
    }

    private static func cleaned(_ history: [Turn]) -> [Turn] {
        var out: [Turn] = []
        for turn in history {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = out.last, last.fromMe == turn.fromMe {
                out[out.count - 1] = Turn(fromMe: turn.fromMe, text: last.text + "\n" + text)
            } else {
                out.append(Turn(fromMe: turn.fromMe, text: text))
            }
        }
        if out.first?.fromMe == false { out.removeFirst() }
        return out
    }

    private enum HTTPResult { case success(Data), failure(ProviderFailure) }

    private func fetch(_ request: URLRequest) async -> HTTPResult {
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return .failure(.rejected) }
            if (200...299).contains(code) { return .success(data) }
            return .failure(.unreachable)
        } catch {
            return .failure(.unreachable)
        }
    }
}

private extension AIProvider {
    func modelsRequest(key: String) -> URLRequest {
        var request = URLRequest(url: modelsURL, timeoutInterval: 20)
        request.httpMethod = "GET"
        authorize(&request, key: key)
        return request
    }

    func chatRequest(key: String, turns: [ProviderClient.Turn], maxTokens: Int) -> URLRequest {
        var request = URLRequest(url: chatURL, timeoutInterval: 60)
        request.httpMethod = "POST"
        authorize(&request, key: key)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = chatBody(turns: turns, maxTokens: maxTokens)
        return request
    }

    /// Header only. The key is never written into the URL.
    private func authorize(_ request: inout URLRequest, key: String) {
        request.setValue("LumenVoice", forHTTPHeaderField: "User-Agent")
        switch self {
        case .claude:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        default:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private var modelsURL: URL {
        switch self {
        case .grok: return URL(string: "https://api.x.ai/v1/models")!
        case .claude: return URL(string: "https://api.anthropic.com/v1/models")!
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        case .groq: return URL(string: "https://api.groq.com/openai/v1/models")!
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/models")!
        case .openAI: return URL(string: "https://api.openai.com/v1/models")!
        }
    }

    private var chatURL: URL {
        switch self {
        case .grok: return URL(string: "https://api.x.ai/v1/chat/completions")!
        case .claude: return URL(string: "https://api.anthropic.com/v1/messages")!
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")!
        case .groq: return URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .openAI: return URL(string: "https://api.openai.com/v1/chat/completions")!
        }
    }

    private var modelName: String {
        switch self {
        case .grok: return "grok-4"
        case .claude: return "claude-sonnet-4-5"
        case .gemini: return "gemini-2.5-flash"
        case .groq: return "llama-3.3-70b-versatile"
        case .openRouter: return "openai/gpt-4o-mini"
        case .openAI: return "gpt-4o-mini"
        }
    }

    private func chatBody(turns: [ProviderClient.Turn], maxTokens: Int) -> Data? {
        switch self {
        case .claude:
            let messages = turns.map { ["role": $0.fromMe ? "user" : "assistant", "content": $0.text] }
            return json(["model": modelName, "max_tokens": maxTokens, "system": ProviderClient.systemPrompt, "messages": messages])
        case .gemini:
            let contents = turns.map { turn -> [String: Any] in
                ["role": turn.fromMe ? "user" : "model", "parts": [["text": turn.text]]]
            }
            return json([
                "systemInstruction": ["parts": [["text": ProviderClient.systemPrompt]]],
                "contents": contents,
                "generationConfig": ["maxOutputTokens": maxTokens],
            ])
        default:
            var messages: [[String: String]] = [["role": "system", "content": ProviderClient.systemPrompt]]
            messages += turns.map { ["role": $0.fromMe ? "user" : "assistant", "content": $0.text] }
            return json(["model": modelName, "messages": messages, "max_tokens": maxTokens])
        }
    }

    func parseReply(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        switch self {
        case .claude:
            let parts = obj["content"] as? [[String: Any]] ?? []
            return parts.compactMap { $0["text"] as? String }.joined()
        case .gemini:
            let candidates = obj["candidates"] as? [[String: Any]] ?? []
            let content = candidates.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]] ?? []
            return parts.compactMap { $0["text"] as? String }.joined()
        default:
            let choices = obj["choices"] as? [[String: Any]] ?? []
            let message = choices.first?["message"] as? [String: Any]
            if let text = message?["content"] as? String { return text }
            return ""
        }
    }

    private func json(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }
}
