import SwiftUI
import AVFoundation

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

final class AppDelegate: NSObject, UIApplicationDelegate {
    private weak var shell: WebShellState?

    func bind(shell: WebShellState) {
        self.shell = shell
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CrashLog.install()
        CrashLog.note("==== app launch ====")
        AudioSessionController.shared.configure()
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
