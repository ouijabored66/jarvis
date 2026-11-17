import Combine
import SwiftUI
import UserNotifications

@main
struct LumenAppApp: App {
    @StateObject private var model: LumenModel

    init() {
        let model = LumenModel()
        _model = StateObject(wrappedValue: model)
        #if canImport(WatchConnectivity) && os(iOS)
        UNUserNotificationCenter.current().delegate = ActionAlertDelegate.shared
        WatchSync.shared.answer = { [weak model] text in
            guard let model else { return (say: nil, error: "Open Lumen Voice on your iPhone.", title: "Lumen") }
            return await model.respond(text, speak: false)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                #if canImport(WatchConnectivity) && os(iOS)
                // Keep the Watch app's server addresses and tokens in step with Settings.
                .onAppear { WatchSync.shared.push(from: model) }
                .onReceive(model.objectWillChange.debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in
                    WatchSync.shared.push(from: model)
                }
                #endif
        }
    }
}
