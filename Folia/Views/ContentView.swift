import SwiftUI
import Combine

struct ContentView: View {
    @EnvironmentObject private var state: WebShellState

    var body: some View {
        ZStack {
            Color(red: 0x09 / 255, green: 0x09 / 255, blue: 0x0b / 255)
                .ignoresSafeArea()
            WebShellView()
                .ignoresSafeArea()
        }
        .statusBarHidden(false)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            AudioSessionController.shared.configure()
        }
    }
}
