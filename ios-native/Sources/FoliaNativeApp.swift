import SwiftUI

@main
struct FoliaNativeApp: App {
    init() {
        // 后台播放：把 AVAudioSession 配置成 playback，锁屏/切后台时音频继续。
        AudioSessionConfigurator.configure()
    }

    var body: some Scene {
        WindowGroup {
            FoliaWebShell()
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
        }
    }
}
