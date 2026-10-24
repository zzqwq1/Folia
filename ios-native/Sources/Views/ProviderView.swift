import SwiftUI

struct ProviderView: View {
    let provider: Provider
    @EnvironmentObject var session: AppSession
    @State private var userPlaylists: [Playlist] = []
    @State private var recommendPlaylists: [Playlist] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showLogin = false

    var body: some View {
        List {
            if let profile = session.profile(for: provider) {
                Section {
                    HStack(spacing: 12) {
                        AsyncImage(url: URL(string: profile.avatarUrl ?? "")) { phase in
                            switch phase {
                            case .success(let img): img.resizable().scaledToFill()
                            default: Color.gray.opacity(0.2)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(profile.nickname).font(.headline)
                            Text("ID: \(profile.userId)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("退出") {
                            session.logout(provider)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                }
            } else {
                Section {
                    Button {
                        showLogin = true
                    } label: {
                        Label("扫码登录", systemImage: "qrcode")
                    }
                }
            }

            if !userPlaylists.isEmpty {
                Section(header: Text("我的歌单")) {
                    ForEach(userPlaylists) { p in
                        NavigationLink {
                            PlaylistDetailView(playlist: p)
                        } label: {
                            PlaylistRow(playlist: p)
                        }
                    }
                }
            }

            Section(header: Text("推荐")) {
                if isLoading {
                    ProgressView()
                } else if let err = errorMessage {
                    Text(err).foregroundStyle(.secondary)
                } else {
                    ForEach(recommendPlaylists) { p in
                        NavigationLink {
                            PlaylistDetailView(playlist: p)
                        } label: {
                            PlaylistRow(playlist: p)
                        }
                    }
                }
            }
        }
        .navigationTitle(provider.shortName)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showLogin) {
            NeteaseLoginView(onDone: { cookie in
                Task { @MainActor in
                    await session.setCookie(cookie, for: provider)
                    showLogin = false
                    await load()
                }
            })
        }
    }

    private func load() async {
        guard provider == .netease else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let cookie = session.cookie(for: provider) ?? ""
        let profile = session.profile(for: provider)

        do {
            recommendPlaylists = try await FoliaAPI.neteaseRecommendPlaylists(cookie: cookie.isEmpty ? nil : cookie)
        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
        }

        if let profile {
            userPlaylists = (try? await FoliaAPI.neteaseUserPlaylists(userId: profile.userId, cookie: cookie)) ?? []
        } else {
            userPlaylists = []
        }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: playlist.coverUrl ?? "")) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: Color.gray.opacity(0.2)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title).font(.subheadline).lineLimit(2)
                Text("\(playlist.trackCount) 首").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
