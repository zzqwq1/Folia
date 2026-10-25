import SwiftUI

@main
struct FoliaNativeApp: App {
    @StateObject private var player = PlayerEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .preferredColorScheme(.dark)
        }
    }
}
