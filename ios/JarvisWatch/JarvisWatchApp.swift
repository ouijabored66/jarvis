import AppIntents
import SwiftUI

@main
struct JarvisWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(model)
        }
    }
}

struct AskLumenWatchIntent: AppIntent {
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
            intent: AskLumenWatchIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Talk to \(.applicationName)",
            ],
            shortTitle: "Ask Lumen",
            systemImageName: "mic.fill"
        )
    }
}
