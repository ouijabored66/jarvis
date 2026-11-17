import AppIntents
import Foundation
import UIKit

/// Shared with the UI so a Shortcut can open straight into listening.
@MainActor
enum LumenHub {
    static weak var model: JarvisModel?
    static var listenOnOpen = false
}

struct AskLumenIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Lumen"
    static var description = IntentDescription("Ask Lumen a question. With no question, Lumen starts listening.")
    static var openAppWhenRun = false

    @Parameter(title: "Question")
    var question: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let asked = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if asked.isEmpty {
            LumenHub.listenOnOpen = true
            UserDefaults.standard.set(true, forKey: "lumen.listenOnOpen")
            if let url = URL(string: "lumenvoice://listen") {
                await UIApplication.shared.open(url)
            }
            return .result(dialog: "Listening.")
        }
        guard let model = LumenHub.model else {
            return .result(dialog: "Open Lumen Voice and try again.")
        }
        let result = await model.respond(asked, speak: false)
        let spoken = result.say ?? result.error ?? "Lumen didn't answer."
        return .result(dialog: IntentDialog(stringLiteral: spoken))
    }
}

struct LumenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskLumenIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Talk to \(.applicationName)",
            ],
            shortTitle: "Ask Lumen",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StartListeningIntent(),
            phrases: [
                "Start listening with \(.applicationName)",
                "Listen with \(.applicationName)",
            ],
            shortTitle: "Start listening",
            systemImageName: "waveform"
        )
    }
}
