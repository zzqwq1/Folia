import SwiftUI

@main
struct FoliaNativeApp: App {
    init() {
        // 后台播放：把 AVAudioSession 配置成 playback，锁屏/切后台时音频继续。
        AudioSessionConfigurator.configure()
    }

    var body: some Scene {
        WindowGroup {
            // 必须 ignoresSafeArea：SwiftUI 默认会把内容塞进安全区，WebView 于是只剩中间一块，
            // 状态栏与 Home 条处是窗口底色 —— 上下就是两条大黑带。
            // 铺满整屏后，安全区数值仍能从 view.safeAreaInsets 读到（见 FoliaWebShell.injectSafeInsets），
            // 由页面用 padding 让位，留白处露出的也是页面自己的底色。
            FoliaWebShell()
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
        }
    }
}
