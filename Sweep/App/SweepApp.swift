import SwiftUI

@main
struct SweepApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(Theme.pure)
                .preferredColorScheme(.dark)
        }
    }
}
