import AppIntents
import SwiftUI

@main
struct LumenWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(model)
                .onOpenURL { url in
                    if Self.isListenURL(url) { model.beginFromComplication() }
                }
        }
    }
}

struct StartWatchTalkIntent: AppIntent {
    static var title: LocalizedStringResource = "Start listening"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "lumen.listenOnOpen")
        WatchHub.model?.beginFromComplication()
        return .result()
    }
}

private extension LumenWatchApp {
    static func isListenURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        let raw = url.absoluteString.lowercased()
        return host == "listen" || path.contains("listen") || raw.contains("://listen")
    }
}

struct LumenWatchIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Lumen"
    static var openAppWhenRun = false

    @Parameter(title: "Question")
    var question: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let asked = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !asked.isEmpty, let model = WatchHub.model else {
            return .result(dialog: "Open Lumen on your Watch and say it there, with your iPhone nearby.")
        }
        let reply = await model.ask(asked)
        return .result(dialog: IntentDialog(stringLiteral: reply.isEmpty ? "Lumen didn't answer." : reply))
    }
}

struct LumenWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LumenWatchIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Talk to \(.applicationName)",
            ],
            shortTitle: "Ask Lumen",
            systemImageName: "mic.fill"
        )
    }
}
