import AppIntents
import SwiftUI
import WidgetKit

@main
struct LumenControlsBundle: WidgetBundle {
    var body: some Widget {
        ListenControl()
    }
}

struct ListenControl: ControlWidget {
    static let kind = "com.dylanpreed.lumenvoice.listen"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartListeningIntent()) {
                Label("Listen", systemImage: "mic.fill")
            }
        }
        .displayName("Lumen")
        .description("Start listening.")
    }
}
