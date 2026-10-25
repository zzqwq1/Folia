import SwiftUI

@main
struct FoliaNativeApp: App {
    @StateObject private var player = PlayerEngine()
    @StateObject private var covers = WallCoverLoader.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(covers)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
