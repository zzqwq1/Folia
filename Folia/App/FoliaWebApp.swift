import SwiftUI
import AVFoundation
import Network

@main
struct FoliaWebApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var shell = WebShellState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(shell)
                .preferredColorScheme(.dark)
                .ignoresSafeArea()
                .onAppear { appDelegate.bind(shell: shell) }
        }
    }
}

/// 盯着网络可用性：从「不可用」变回「可用」时广播一次，
/// 让停在失败提示上的页面自己爬起来。
final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private var wasSatisfied: Bool?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            let previous = self.wasSatisfied
            self.wasSatisfied = satisfied
            // 只在「坏 → 好」的翻转上触发：启动初期先记录下来，不重载。
            guard previous == false, satisfied else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .foliaNetworkRestored, object: nil)
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.folia.network"))
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    private weak var shell: WebShellState?
    private let network = NetworkWatcher()

    func bind(shell: WebShellState) {
        self.shell = shell
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CrashLog.install()
        CrashLog.note("==== app launch ====")
        // 冷启动先把上一轮 WebContent 进程留下的内存/磁盘缓存清掉再建 WebView：
        // 「大退后进歌单闪退」就是新进程在同一份缓存上重建页面被再次压死。
        CacheSweeper.sweepOnColdLaunch()
        AudioSessionController.shared.configure()
        network.start()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        AudioSessionController.shared.configure()
    }
}
