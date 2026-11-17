import Foundation
import SwiftUI

/// Where a saved OpenAI-compatible provider is reached.
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

/// Non-secret settings for one provider. The API key and Cloudflare Access headers stay in the Keychain.
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
            return .make(name: "OpenRouter", cloudURL: "https://openrouter.ai/api/v1", route: .cloud, model: "openai/gpt-4o-mini")
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

/// OpenAI-compatible chat. Secrets are request headers only and are never logged.
struct CustomClient {
    static let rejectedMessage = "Key rejected, check your API key"

    func test(provider: CustomProvider, apiKey: String, cfID: String, cfSecret: String) async -> Result<String, CustomFailure> {
        let bases = provider.bases()
        guard !bases.isEmpty else { return .failure(.noURL) }
        var sawBlocked = false
        for base in bases {
            switch await fetch(url: Self.join(base, "models"), apiKey: apiKey, cfID: cfID, cfSecret: cfSecret) {
            case .ok: return .success(provider.name)
            case .rejected: return .failure(.rejected)
            case .blocked: sawBlocked = true
            case .unreachable: continue
            }
            let turns = [ProviderClient.Turn(fromMe: true, text: "Hi")]
            switch await chat(base: base, provider: provider, turns: turns, apiKey: apiKey, cfID: cfID, cfSecret: cfSecret, maxTokens: 1) {
            case .success: return .success(provider.name)
            case .failure(.rejected): return .failure(.rejected)
            case .failure(.blocked): sawBlocked = true
            case .failure: continue
            }
        }
        return .failure(sawBlocked && bases.allSatisfy { !CustomHTTP.allowed($0) } ? .blocked : .unreachable)
    }

    func discover(provider: CustomProvider, apiKey: String, cfID: String, cfSecret: String) async -> Result<[String], CustomFailure> {
        let bases = provider.bases()
        guard !bases.isEmpty else { return .failure(.noURL) }
        var names: [String] = []
        var rejected = false
        var blocked = true
        for base in bases {
            if CustomHTTP.allowed(base) { blocked = false }
            switch await fetch(url: Self.join(base, "models"), apiKey: apiKey, cfID: cfID, cfSecret: cfSecret) {
            case .ok(let data): names.append(contentsOf: Self.openAIModels(data))
            case .rejected: rejected = true
            case .blocked, .unreachable: break
            }
            if let tags = Self.tagsURL(base) {
                switch await fetch(url: tags, apiKey: apiKey, cfID: cfID, cfSecret: cfSecret) {
                case .ok(let data): names.append(contentsOf: Self.ollamaModels(data))
                case .rejected: rejected = true
                case .blocked, .unreachable: break
                }
            }
            if !names.isEmpty { return .success(Self.unique(names)) }
        }
        if rejected && names.isEmpty { return .failure(.rejected) }
        if blocked { return .failure(.blocked) }
        return names.isEmpty ? .failure(.unreachable) : .success(Self.unique(names))
    }

    func reply(provider: CustomProvider, turns: [ProviderClient.Turn], apiKey: String, cfID: String, cfSecret: String) async -> Result<String, CustomFailure> {
        let bases = provider.bases()
        guard !bases.isEmpty else { return .failure(.noURL) }
        guard !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.noModel) }
        var last: CustomFailure = .unreachable
        for (index, base) in bases.enumerated() {
            switch await chat(base: base, provider: provider, turns: turns, apiKey: apiKey, cfID: cfID, cfSecret: cfSecret, maxTokens: provider.maxTokens) {
            case .success(let text): return .success(text)
            case .failure(.rejected): return .failure(.rejected)
            case .failure(.empty): return .failure(.empty)
            case .failure(let error):
                last = error
                let more = index + 1 < bases.count
                if error == .unreachable && more { continue }
                if error == .blocked && more { continue }
                return .failure(error)
            }
        }
        return .failure(last)
    }

    private func chat(base: URL, provider: CustomProvider, turns: [ProviderClient.Turn], apiKey: String, cfID: String, cfSecret: String, maxTokens: Int) async -> Result<String, CustomFailure> {
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
        Self.headers(on: &request, apiKey: apiKey, cfID: cfID, cfSecret: cfSecret, json: true)
        switch await fetch(request) {
        case .ok(let data):
            let text = Self.replyText(data).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .failure(.empty) : .success(text)
        case .rejected: return .failure(.rejected)
        case .unreachable: return .failure(.unreachable)
        case .blocked: return .failure(.blocked)
        }
    }

    private enum Call { case ok(Data), rejected, unreachable, blocked }

    private func fetch(url: URL, apiKey: String, cfID: String, cfSecret: String) async -> Call {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        Self.headers(on: &request, apiKey: apiKey, cfID: cfID, cfSecret: cfSecret, json: false)
        return await fetch(request)
    }

    private func fetch(_ request: URLRequest) async -> Call {
        guard let url = request.url, CustomHTTP.allowed(url) else { return .blocked }
        var timed = request
        timed.timeoutInterval = 30
        do {
            let (data, response) = try await URLSession.shared.data(for: timed)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return .rejected }
            if (200..<300).contains(code) { return .ok(data) }
            return .unreachable
        } catch {
            return .unreachable
        }
    }

    private static func headers(on request: inout URLRequest, apiKey: String, cfID: String, cfSecret: String, json: Bool) {
        if json { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let id = cfID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = cfSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { request.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id") }
        if !secret.isEmpty { request.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret") }
    }

    private static func join(_ base: URL, _ path: String) -> URL {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        let root = parts.path == "/" ? "" : parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let leaf = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = "/" + [root, leaf].filter { !$0.isEmpty }.joined(separator: "/")
        return parts.url ?? base
    }

    private static func tagsURL(_ base: URL) -> URL? {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        parts?.path = "/api/tags"
        parts?.query = nil
        return parts?.url
    }

    private static func openAIModels(_ data: Data) -> [String] {
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
        Keychain.set("", for: "custom.\(id).apiKey")
        Keychain.set("", for: "custom.\(id).cfId")
        Keychain.set("", for: "custom.\(id).cfSecret")
        customProviders.removeAll { $0.id == id }
        customActiveID = customProviders.first?.id ?? ""
        customConnectedName = nil
        customNote = ""
        customModels = []
        persistCustom()
        refreshTitle()
    }

    func customAPIKey(_ id: String) -> String { Keychain.get("custom.\(id).apiKey") }
    func customCFID(_ id: String) -> String { Keychain.get("custom.\(id).cfId") }
    func customCFSecret(_ id: String) -> String { Keychain.get("custom.\(id).cfSecret") }

    func setCustomAPIKey(_ raw: String, id: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Keychain.set(value, for: "custom.\(id).apiKey")
    }

    func clearCustomAPIKey(_ id: String) {
        Keychain.set("", for: "custom.\(id).apiKey")
        if activeCustom?.id == id { customConnectedName = nil; refreshTitle() }
    }

    func setCustomCF(id: String, clientID: String, secret: String) {
        let cid = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sec = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cid.isEmpty { Keychain.set(cid, for: "custom.\(id).cfId") }
        if !sec.isEmpty { Keychain.set(sec, for: "custom.\(id).cfSecret") }
    }

    func clearCustomCF(_ id: String) {
        Keychain.set("", for: "custom.\(id).cfId")
        Keychain.set("", for: "custom.\(id).cfSecret")
    }

    func testActiveCustom() async {
        guard let provider = activeCustom else { customNote = "Add a provider first."; return }
        customBusy = true
        defer { customBusy = false }
        let result = await CustomClient().test(provider: provider, apiKey: customAPIKey(provider.id),
                                                cfID: customCFID(provider.id), cfSecret: customCFSecret(provider.id))
        switch result {
        case .success(let name):
            customConnectedName = name
            customNote = ""
        case .failure(.rejected):
            customConnectedName = nil
            customNote = CustomClient.rejectedMessage
        case .failure(.blocked):
            customConnectedName = nil
            customNote = "Plain http is only allowed for a local address, 100.x, .local, or .ts.net."
        case .failure(.noURL):
            customConnectedName = nil
            customNote = "Add a local or cloud URL."
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
        let result = await CustomClient().discover(provider: provider, apiKey: customAPIKey(provider.id),
                                                    cfID: customCFID(provider.id), cfSecret: customCFSecret(provider.id))
        switch result {
        case .success(let names):
            customModels = names
            if provider.model.isEmpty, let first = names.first {
                updateActiveCustom { $0.model = first }
            }
            customNote = names.isEmpty ? "No models were listed." : ""
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
        switch await CustomClient().reply(provider: provider, turns: turns, apiKey: customAPIKey(provider.id),
                                           cfID: customCFID(provider.id), cfSecret: customCFSecret(provider.id)) {
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
    @State private var cfIDDraft = ""
    @State private var cfSecretDraft = ""
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
                Text("Add a preset, or the fields below after you add one.")
                    .font(.footnote).foregroundStyle(.secondary)
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
            Button("Test local") { Task { await test(provider, route: .local) } }
            Spacer()
            Button("Test cloud") { Task { await test(provider, route: .cloud) } }
        }
        .disabled(model.customBusy)
        field("Cloud URL", text: Binding(get: { provider.cloudURL }, set: { value in model.updateActiveCustom { $0.cloudURL = value } }), url: true)
        Picker("Connection", selection: Binding(get: { provider.route }, set: { value in model.updateActiveCustom { $0.route = value } })) {
            ForEach(CustomRoute.allCases) { route in Text(route.title).tag(route) }
        }
        Text("Auto tries the local URL first, then the cloud URL.").font(.footnote).foregroundStyle(.secondary)
        secret("API key", draft: $keyDraft, saved: !model.customAPIKey(provider.id).isEmpty,
               suffix: LumenModel.publicSuffix(model.customAPIKey(provider.id))) {
            let typed = keyDraft
            keyDraft = ""
            model.setCustomAPIKey(typed, id: provider.id)
        } onClear: { model.clearCustomAPIKey(provider.id) }
        secret("Cloudflare Access client ID", draft: $cfIDDraft, saved: !model.customCFID(provider.id).isEmpty, suffix: "") {
            model.setCustomCF(id: provider.id, clientID: cfIDDraft, secret: "")
            cfIDDraft = ""
        } onClear: { model.clearCustomCF(provider.id); cfIDDraft = ""; cfSecretDraft = "" }
        secret("Cloudflare Access client secret", draft: $cfSecretDraft, saved: !model.customCFSecret(provider.id).isEmpty, suffix: "") {
            model.setCustomCF(id: provider.id, clientID: "", secret: cfSecretDraft)
            cfSecretDraft = ""
        } onClear: { model.clearCustomCF(provider.id); cfIDDraft = ""; cfSecretDraft = "" }
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

    private func test(_ provider: CustomProvider, route: CustomRoute) async {
        var copy = provider
        copy.route = route
        model.customBusy = true
        defer { model.customBusy = false }
        let result = await CustomClient().test(provider: copy, apiKey: model.customAPIKey(provider.id),
                                                cfID: model.customCFID(provider.id), cfSecret: model.customCFSecret(provider.id))
        switch result {
        case .success(let name):
            model.customConnectedName = name
            model.customNote = ""
            model.refreshTitle()
        case .failure(.rejected):
            model.customConnectedName = nil
            model.customNote = CustomClient.rejectedMessage
        case .failure(.noURL):
            model.customNote = route == .local ? "Add a local URL." : "Add a cloud URL."
        case .failure(.blocked):
            model.customNote = "Plain http is only allowed for a local address, 100.x, .local, or .ts.net."
        case .failure:
            model.customNote = "Can't reach \(provider.name). Check the URL and try again."
        }
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
            HStack {
                if saved {
                    Text(suffix.isEmpty ? "Saved" : "Saved · ••••\(suffix)")
                        .font(.footnote).foregroundStyle(.secondary)
                        .privacySensitive()
                }
                Spacer()
                if !draft.wrappedValue.isEmpty { Button("Save", action: onSave).font(.footnote) }
                if saved { Button("Clear", role: .destructive, action: onClear).font(.footnote) }
            }
        }
    }

    private func clearDrafts() {
        keyDraft = ""
        cfIDDraft = ""
        cfSecretDraft = ""
    }
}
