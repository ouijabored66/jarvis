import Combine
import SwiftUI

@main
struct JarvisAppApp: App {
    @StateObject private var model = JarvisModel()

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
