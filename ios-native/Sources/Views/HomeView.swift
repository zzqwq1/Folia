import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: AppSession

    var body: some View {
        NavigationStack {
            HomeView()
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var session: AppSession
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        List {
            Section(header: Text("选择平台")) {
                ForEach(Provider.allCases) { provider in
                    NavigationLink {
                        ProviderView(provider: provider)
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(hex: provider.accentColorHex))
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Text(provider.shortName.prefix(1))
                                        .foregroundStyle(.white)
                                        .font(.headline)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                    .font(.headline)
                                Text(session.isLoggedIn(provider) ? "已登录" : "未登录")
                                    .font(.caption)
                                    .foregroundStyle(session.isLoggedIn(provider) ? .green : .secondary)
                            }
                            Spacer()
                            if provider != .netease {
                                Text("即将上线")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.gray.opacity(0.15), in: Capsule())
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .disabled(provider != .netease)
                }
            }
        }
        .navigationTitle("Folia")
        .safeAreaInset(edge: .bottom) {
            if let current = player.current {
                MiniPlayerBar(track: current)
            }
        }
    }
}

struct MiniPlayerBar: View {
    let track: Track
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.subheadline).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b: UInt64
        switch s.count {
        case 3:
            (r, g, b) = ((v >> 8) * 17, (v >> 4 & 0xF) * 17, (v & 0xF) * 17)
        case 6:
            (r, g, b) = (v >> 16, v >> 8 & 0xFF, v & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: 1
        )
    }
}
