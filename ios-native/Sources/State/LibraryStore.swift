import SwiftUI

/// 全局会话状态：各平台登录账号、首页歌单、各个数据页的加载态。
///
/// 原版允许多个平台同时在线（每个 provider 各自一份 cookie），首页的墙面
/// 就由这些平台最近的集合拼起来。`account` 仍代表「当前正在看的平台」。
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var accounts: [MusicProvider: Account] = [:]
    @Published private(set) var collections: [MusicCollection] = []
    @Published private(set) var isLoading = false
    @Published var message: String?

    var account: Account? { accounts[selectedProvider] }
    var isSignedIn: Bool { account != nil }

    /// 当前浏览的平台（工具面板 / 首页 / 集合页都读它）
    @Published var selectedProvider: MusicProvider = .netease

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        // 四个平台并行恢复登录态；没登录的返回 nil
        async let netease = try? NeteaseAPI.shared.currentAccount()
        async let qq = try? QQMusicAPI.shared.currentAccount()
        async let kugou = try? KugouAPI.shared.currentAccount()
        async let bodian = try? BodianAPI.shared.currentAccount()
        var restored: [MusicProvider: Account] = [:]
        if let account = await netease { restored[.netease] = account }
        if let account = await qq { restored[.qq] = account }
        if let account = await kugou { restored[.kugou] = account }
        if let account = await bodian { restored[.bodian] = account }
        accounts = restored

        var list: [MusicCollection] = []
        for provider in MusicProvider.allCases {
            guard let account = restored[provider] else { continue }
            list += (try? await MusicAPI.shared.userPlaylists(for: account)) ?? []
        }
        if list.isEmpty {
            collections = (try? await NeteaseAPI.shared.recommendedPlaylists()) ?? []
        } else {
            collections = list
        }
    }

    func signOut(provider: MusicProvider) async {
        switch provider {
        case .netease: await NeteaseAPI.shared.signOut()
        case .qq: await QQMusicAPI.shared.signOut()
        case .kugou: await KugouAPI.shared.signOut()
        case .bodian: await BodianAPI.shared.signOut()
        }
        accounts[provider] = nil
        await refresh()
    }

    /// 只登出当前平台（设置面板里的「退出登录」）
    func signOut() async {
        await signOut(provider: selectedProvider)
    }

    func signIn(provider: MusicProvider, session account: Account) {
        accounts[provider] = account
        selectedProvider = provider
        Task { await refresh() }
    }

    /// 兼容旧调用点：默认当作网易云登录
    func signIn(session account: Account) {
        signIn(provider: account.provider, session: account)
    }
}
