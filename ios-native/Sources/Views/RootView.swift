import SwiftUI

/// 根视图：对齐网页版的「无 tab bar」结构 —— 全屏页切换 + 右下 SwitcherPill + 底部浮动播放胶囊。
struct RootView: View {
    @EnvironmentObject var session: AppSession
    @EnvironmentObject var player: PlayerModel
    @State private var currentProvider: Provider = .netease
    @State private var showPlayer = false
    @State private var showSwitcher = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            FoliaTheme.bg.ignoresSafeArea()

            // 主内容
            NavigationStack {
                ProviderView(provider: currentProvider)
                    .navigationBarHidden(true)
            }

            // 底部浮动播放胶囊（对齐 FloatingPlayerControls.tsx）
            if let current = player.current, !showPlayer {
                FloatingPlayerCapsule(track: current, showPlayer: $showPlayer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }

            // 右下 SwitcherPill（对齐 SwitcherPill.tsx）
            SwitcherPill(current: $currentProvider, showSwitcher: $showSwitcher)
                .padding(.trailing, 16)
                .padding(.bottom, player.current != nil && !showPlayer ? 96 : 32)
                .zIndex(11)
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showPlayer) {
            if let current = player.current {
                PlayerView(track: current, isPresented: $showPlayer)
            }
        }
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

/// 右下角平台切换胶囊：对齐 SwitcherPill.tsx
struct SwitcherPill: View {
    @Binding var current: Provider
    @Binding var showSwitcher: Bool
    @EnvironmentObject var session: AppSession

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if showSwitcher {
                VStack(spacing: 6) {
                    ForEach(Provider.allCases) { p in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                current = p
                                showSwitcher = false
                            }
                        } label: {
                            HStack(spacing: 8) {
                                PlatformMark(provider: p, size: 26)
                                Text(p.shortName)
                                    .font(FoliaFont.sans(13, .medium))
                                    .foregroundStyle(FoliaTheme.t1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                current == p ? FoliaTheme.fill2 : Color.clear,
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .opacity(p.isAvailable ? 1 : 0.42)
                        .disabled(!p.isAvailable)
                    }
                }
                .padding(8)
                .background(FoliaTheme.card2.opacity(0.96), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(FoliaTheme.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
            }

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    showSwitcher.toggle()
                }
            } label: {
                PlatformMark(provider: current, size: 40)
                    .shadow(color: Color(hex: current.accentColorHex).opacity(0.5), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
        }
    }
}
