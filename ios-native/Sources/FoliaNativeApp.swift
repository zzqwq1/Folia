import SwiftUI

@main
struct FoliaNativeApp: App {
    @StateObject private var session = AppSession()
    @StateObject private var player = PlayerModel()

    init() {
        // 后台播放：把 AVAudioSession 配置成 playback，锁屏/切后台时音频继续。
        AudioSessionConfigurator.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(player)
        }
    }
}
