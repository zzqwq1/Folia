import Foundation

/// 用户登录态：每个平台一份 Cookie，存在 UserDefaults 里（原型期够用，之后挪到 Keychain）。
final class AppSession: ObservableObject {
    static let shared = AppSession()

    @Published private(set) var cookies: [Provider: String] = [:]
    @Published private(set) var profiles: [Provider: UserProfile] = [:]

    private let cookieStoreKey = "folia.cookies.v1"

    private init() {
        load()
    }

    func cookie(for provider: Provider) -> String? {
        cookies[provider]
    }

    func profile(for provider: Provider) -> UserProfile? {
        profiles[provider]
    }

    func isLoggedIn(_ provider: Provider) -> Bool {
        profiles[provider] != nil
    }

    /// 登录成功后调用：保存 Cookie，并把用户信息拉下来。
    @MainActor
    func setCookie(_ cookie: String, for provider: Provider) async {
        cookies[provider] = cookie
        persist()
        do {
            switch provider {
            case .netease:
                let p = try await FoliaAPI.neteaseAccount(cookie: cookie)
                profiles[provider] = p
            default:
                break
            }
        } catch {
            NSLog("[Folia] fetch profile for \(provider.rawValue) failed: \(error)")
        }
    }

    @MainActor
    func logout(_ provider: Provider) {
        cookies[provider] = nil
        profiles[provider] = nil
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let raw = UserDefaults.standard.dictionary(forKey: cookieStoreKey) as? [String: String] else { return }
        for (k, v) in raw {
            if let p = Provider(rawValue: k) {
                cookies[p] = v
            }
        }
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: cookies.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(raw, forKey: cookieStoreKey)
    }
}
