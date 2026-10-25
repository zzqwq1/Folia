import SwiftUI

/// 全局会话状态：登录账号、首页歌单、各个数据页的加载态。
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var account: Account?
    @Published private(set) var collections: [MusicCollection] = []
    @Published private(set) var isLoading = false
    @Published var message: String?

    var isSignedIn: Bool { account != nil }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        account = try? await NeteaseAPI.shared.currentAccount()
        guard let account else {
            collections = (try? await NeteaseAPI.shared.recommendedPlaylists()) ?? []
            return
        }
        let playlists = (try? await NeteaseAPI.shared.userPlaylists(userId: account.userId)) ?? []
        let albums = (try? await NeteaseAPI.shared.userAlbums()) ?? []
        collections = playlists + albums
    }

    func signOut() async {
        await NeteaseAPI.shared.signOut()
        account = nil
        await refresh()
    }

    func signIn(session account: Account) {
        self.account = account
        Task { await refresh() }
    }
}
