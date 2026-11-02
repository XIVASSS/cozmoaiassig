import SwiftUI
import TipKit

@main
struct SweepApp: App {
    @StateObject private var model = AppModel()

    init() {
        try? Tips.configure([.displayFrequency(.immediate)])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(.blue)
                .preferredColorScheme(.dark)
        }
    }
}
