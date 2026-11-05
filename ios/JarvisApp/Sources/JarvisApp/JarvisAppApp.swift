import SwiftUI

@main
struct JarvisAppApp: App {
    @StateObject private var model = JarvisModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
