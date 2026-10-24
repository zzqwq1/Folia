import SwiftUI

/// 平台主页：对齐 Folia 官方视觉 —— 顶部品牌色氛围光 + 圆形徽章 + 蜂巢卡片墙
struct ProviderView: View {
    let provider: Provider
    @EnvironmentObject var session: AppSession
    @State private var userPlaylists: [Playlist] = []
    @State private var recommendPlaylists: [Playlist] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showLogin = false
    @State private var selectedPlaylist: Playlist?
    @State private var isShowingDetail = false

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        ZStack(alignment: .top) {
            FoliaTheme.bg.ignoresSafeArea()

            // 品牌色氛围光（对齐 LoginWindow 的 radial-gradient 右上氛围光）
            Circle()
                .fill(Color(hex: provider.accentColorHex).opacity(0.18))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: 120, y: -120)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    if provider == .netease {
                        accountSection
                    }

                    if !userPlaylists.isEmpty {
                        sectionHeader("我的歌单", count: userPlaylists.count)
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(userPlaylists) { p in
                                PlaylistCard(playlist: p) {
                                    selectedPlaylist = p
                                    isShowingDetail = true
                                }
                            }
                        }
                    }

                    sectionHeader("为你推荐", count: recommendPlaylists.count)

                    if isLoading && recommendPlaylists.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView().tint(FoliaTheme.t2)
                            Spacer()
                        }
                        .padding(.vertical, 40)
                    } else if let err = errorMessage, recommendPlaylists.isEmpty {
                        Text(err)
                            .font(FoliaFont.sans(13))
                            .foregroundStyle(FoliaTheme.t3)
                            .padding(.vertical, 24)
                    } else {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(recommendPlaylists) { p in
                                PlaylistCard(playlist: p) {
                                    selectedPlaylist = p
                                    isShowingDetail = true
                                }
                            }
                        }
                    }

                    Color.clear.frame(height: 120)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .refreshable { await load() }

            // iOS 16 兼容的 NavigationLink
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
        }
        .task { await load() }
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            PlatformMark(provider: provider, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Folia")
                    .font(FoliaFont.serif(28, .bold))
                    .foregroundStyle(FoliaTheme.t1)
                Text(provider.displayName)
                    .font(FoliaFont.sans(13))
                    .foregroundStyle(FoliaTheme.t2)
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Account

    @ViewBuilder
    private var accountSection: some View {
        if let profile = session.profile(for: provider) {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: profile.avatarUrl ?? "")) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: FoliaTheme.fill
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay(Circle().stroke(FoliaTheme.line, lineWidth: 1))

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.nickname)
                        .font(FoliaFont.sans(15, .semibold))
                        .foregroundStyle(FoliaTheme.t1)
                    HStack(spacing: 4) {
                        Circle().fill(FoliaTheme.ok).frame(width: 6, height: 6)
                        Text("已登录")
                            .font(FoliaFont.sans(11))
                            .foregroundStyle(FoliaTheme.t3)
                    }
                }

                Spacer()

                Button("退出") {
                    session.logout(provider)
                }
                .font(FoliaFont.sans(12, .medium))
                .foregroundStyle(FoliaTheme.t2)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(FoliaTheme.fill, in: Capsule())
            }
            .padding(14)
            .background(FoliaTheme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(FoliaTheme.line, lineWidth: 1))
        } else {
            Button {
                showLogin = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color(hex: provider.accentColorHex))
                        Image(systemName: "qrcode")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("扫码登录")
                            .font(FoliaFont.sans(15, .semibold))
                            .foregroundStyle(FoliaTheme.t1)
                        Text("用 \(provider.shortName) App 扫码")
                            .font(FoliaFont.sans(11))
                            .foregroundStyle(FoliaTheme.t3)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FoliaTheme.t3)
                }
                .padding(14)
                .background(FoliaTheme.card, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(FoliaTheme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(FoliaFont.serif(22, .bold))
                .foregroundStyle(FoliaTheme.t1)
            if count > 0 {
                Text("\(count)")
                    .font(FoliaFont.mono(11))
                    .foregroundStyle(FoliaTheme.t3)
            }
            Spacer()
        }
    }

    // MARK: - Load

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

/// 蜂巢卡片：对齐 PolaroidCard.tsx
/// 1:1 封面 + 12px 圆角 + 14/10/9 三档字号
struct PlaylistCard: View {
    let playlist: Playlist
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                AsyncImage(url: URL(string: playlist.coverUrl ?? "")) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        ZStack {
                            FoliaTheme.fill
                            Image(systemName: "opticaldisc")
                                .font(.system(size: 32))
                                .foregroundStyle(FoliaTheme.t3)
                        }
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.title)
                        .font(FoliaFont.sans(14, .bold))
                        .foregroundStyle(FoliaTheme.t1)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let creator = playlist.creator {
                        Text(creator)
                            .font(FoliaFont.sans(10))
                            .foregroundStyle(FoliaTheme.t3)
                            .lineLimit(1)
                    }

                    if playlist.trackCount > 0 {
                        Text("\(playlist.trackCount) 首")
                            .font(FoliaFont.mono(9))
                            .foregroundStyle(FoliaTheme.t3)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            .padding(8)
            .background(FoliaTheme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(FoliaTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
