import Foundation

/// The computer running Lumen's own server. One address, one token.
enum ServerID: String, CaseIterable, Identifiable {
    case home
    var id: String { rawValue }
    var label: String { "Your server" }
    var defaultURL: String { "" }
}
