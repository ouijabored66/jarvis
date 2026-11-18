import AppIntents
import Foundation

/// Opens Lumen into listening. Shared by the app and the Control Center extension.
struct StartListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Start listening"
    static var description = IntentDescription("Open Lumen and start listening.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "lumen.listenOnOpen")
        return .result()
    }
}
