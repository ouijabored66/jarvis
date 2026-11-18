import Foundation

/// The computer running Lumen's own server. One address, one token.
enum ServerID: String, CaseIterable, Identifiable {
    case home
    var id: String { rawValue }
    var label: String { "Your server" }
    var defaultURL: String { "" }
}

/// Linux or Windows, only when the server reports it. Never chosen by hand.
enum ServerOS: String, Equatable {
    case linux, windows

    var title: String { self == .linux ? "Linux" : "Windows" }

    static func parse(_ raw: String?) -> ServerOS? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "linux": return .linux
        case "windows", "win32": return .windows
        default: return nil
        }
    }

    /// Header `X-Server-OS`, then a top-level or metadata `os` field.
    static func read(response: HTTPURLResponse?, data: Data) -> ServerOS? {
        if let header = response?.value(forHTTPHeaderField: "X-Server-OS"), let os = parse(header) {
            return os
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let os = parse(obj["os"] as? String) { return os }
        if let meta = obj["metadata"] as? [String: Any], let os = parse(meta["os"] as? String) { return os }
        if let meta = obj["meta"] as? [String: Any], let os = parse(meta["os"] as? String) { return os }
        return nil
    }
}
