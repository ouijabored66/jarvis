import Foundation

/// The two places Jarvis can run. The desktop dual-boots, so usually only one is online.
enum ServerID: String, CaseIterable, Identifiable {
    case linux, windows
    var id: String { rawValue }
    var label: String { self == .linux ? "Linux" : "Windows" }
    var defaultURL: String {
        self == .linux ? "https://linux-pc.your-tailnet.ts.net" : "https://windows-pc.your-tailnet.ts.net"
    }
    var other: ServerID { self == .linux ? .windows : .linux }
}
