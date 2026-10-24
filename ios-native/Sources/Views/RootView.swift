import SwiftUI

/// 根视图：bravais 卡片墙首页 + 底部浮动播放胶囊 + 全屏播放页。
struct RootView: View {
    @EnvironmentObject var session: AppSession
    @EnvironmentObject var player: PlayerModel
    @State private var currentProvider: Provider = .netease
    @State private var showPlayer = false
    @State private var showLogin = false
    @State private var playlists: [Playlist] = []
    @State private var isLoading = false
    @State private var selectedPlaylist: Playlist?
    @State private var isShowingDetail = false
    @State private var showSettings = false
    @State private var showSearch = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            FoliaTheme.bg.ignoresSafeArea()

            NavigationStack {
                BravaisHomeView(
                    provider: currentProvider,
                    playlists: playlists,
                    isLoading: isLoading,
                    onConnect: { showLogin = true },
                    onOpenPlaylist: { p in
                        selectedPlaylist = p
                        isShowingDetail = true
                    },
                    onSettings: { showSettings = true },
                    onSearch: { showSearch = true }
                )
                .navigationBarHidden(true)
                .background(
                    NavigationLink(
                        destination: Group {
                            if let p = selectedPlaylist {
                                PlaylistDetailView(playlist: p)
                            } else {
                                EmptyView()
                            }
                        },
                        isActive: $isShowingDetail
                    ) { EmptyView() }
                    .hidden()
                )
            }

            if let current = player.current, !showPlayer {
                FloatingPlayerCapsule(track: current, showPlayer: $showPlayer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .onChange(of: session.isLoggedIn(currentProvider)) { _ in
            Task { await load() }
        }
        .sheet(isPresented: $showLogin) {
            NeteaseLoginView(onDone: { cookie in
                Task { @MainActor in
                    await session.setCookie(cookie, for: currentProvider)
                    showLogin = false
                    await load()
                }
            })
        }
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerView(isPresented: $showPlayer)
        }
        .fullScreenCover(isPresented: $showSettings) {
            FoliaSettingsView(provider: currentProvider, onConnect: { showLogin = true })
        }
        .fullScreenCover(isPresented: $showSearch) {
            FoliaSearchView(playlists: playlists) { p in
                showSearch = false
                selectedPlaylist = p
                isShowingDetail = true
            }
        }
    }

    private func load() async {
        guard currentProvider == .netease else { return }
        isLoading = true
        defer { isLoading = false }

        let cookie = session.cookie(for: currentProvider) ?? ""
        let profile = session.profile(for: currentProvider)

        var result: [Playlist] = []
        if let profile {
            if let mine = try? await FoliaAPI.neteaseUserPlaylists(userId: profile.userId, cookie: cookie) {
                result.append(contentsOf: mine)
            }
        }
        if let rec = try? await FoliaAPI.neteaseRecommendPlaylists(cookie: cookie.isEmpty ? nil : cookie) {
            result.append(contentsOf: rec)
        }
        playlists = result
    }
}

/// 底部浮动播放胶囊：对齐 FloatingPlayerControls.tsx 的胶囊形态
struct FloatingPlayerCapsule: View {
    let track: Track
    @Binding var showPlayer: Bool
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        Button { showPlayer = true } label: {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: track.coverUrl ?? "")) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: FoliaTheme.fill
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(FoliaFont.sans(14, .semibold))
                        .foregroundStyle(FoliaTheme.t1)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(FoliaFont.sans(10))
                        .foregroundStyle(FoliaTheme.t3)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(FoliaTheme.onAccent)
                        .frame(width: 40, height: 40)
                        .background(FoliaTheme.accent, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(FoliaTheme.card2.opacity(0.92), in: Capsule())
            .overlay(Capsule().stroke(FoliaTheme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }
}
