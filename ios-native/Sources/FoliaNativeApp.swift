import SwiftUI

@main
struct FoliaNativeApp: App {
    init() {
        // 后台播放：把 AVAudioSession 配置成 playback，锁屏/切后台时音频继续。
        AudioSessionConfigurator.configure()
    }

    var body: some Scene {
        WindowGroup {
            // 不 ignoresSafeArea：留出真实的安全区，壳才能用 view.safeAreaInsets 拿到
            // 状态栏与 Home 条的高度交给页面（见 FoliaWebShell.injectSafeInsets）。
            // WKWebView 自己仍铺满整块区域，底色也是界面底色，所以安全区里不会出现黑带。
            FoliaWebShell()
                .preferredColorScheme(.dark)
        }
    }
}
