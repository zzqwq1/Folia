import Foundation

/// 用户登录态：每个平台一份 Cookie + 用户信息，存在 UserDefaults 里（原型期够用，之后挪到 Keychain）。
@MainActor
final class AppSession: ObservableObject {
    @Published private(set) var cookies: [Provider: String] = [:]
    @Published private(set) var profiles: [Provider: UserProfile] = [:]

    private let cookieStoreKey = "folia.cookies.v1"
    private let profileStoreKey = "folia.profiles.v1"

    init() {
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
        persist()
    }

    func logout(_ provider: Provider) {
        cookies[provider] = nil
        profiles[provider] = nil
        persist()
    }

    // MARK: - Persistence

    private struct StoredProfile: Codable {
        let userId: String
        let nickname: String
        let avatarUrl: String?
    }

    private func load() {
        if let raw = UserDefaults.standard.dictionary(forKey: cookieStoreKey) as? [String: String] {
            for (k, v) in raw {
                if let p = Provider(rawValue: k) {
                    cookies[p] = v
                }
            }
        }
        if let data = UserDefaults.standard.data(forKey: profileStoreKey),
           let raw = try? JSONDecoder().decode([String: StoredProfile].self, from: data) {
            for (k, v) in raw {
                if let p = Provider(rawValue: k) {
                    profiles[p] = UserProfile(provider: p, userId: v.userId, nickname: v.nickname, avatarUrl: v.avatarUrl)
                }
            }
        }
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: cookies.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(raw, forKey: cookieStoreKey)

        let stored = Dictionary(uniqueKeysWithValues: profiles.map {
            ($0.key.rawValue, StoredProfile(userId: $0.value.userId, nickname: $0.value.nickname, avatarUrl: $0.value.avatarUrl))
        })
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: profileStoreKey)
        }
    }
}
