import SwiftUI

/// 设置：账号（扫码登录）+ 播放行为。原版桌面有 13 个分区，这里先覆盖手机上真正用得到的。
struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var showLogin = false

    var body: some View {
        NavigationStack {
            Form {
                Section("账号") {
                    if let account = library.account {
                        HStack(spacing: 12) {
                            AsyncImage(url: account.avatar) { phase in
                                ZStack {
                                    Circle().fill(FoliaTheme.surfaceRaised)
                                    if let image = phase.image {
                                        image.resizable().scaledToFill()
                                    }
                                }
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.nickname)
                                Text(account.isVip ? "黑胶 VIP" : "普通用户")
                                    .font(.system(size: 11))
                                    .foregroundStyle(FoliaTheme.textSecondary)
                            }
                        }
                        Button("退出登录", role: .destructive) {
                            Task { await library.signOut() }
                        }
                    } else {
                        Button("扫码登录网易云") { showLogin = true }
                    }
                }

                Section("播放") {
                    Picker("循环模式", selection: $player.repeatMode) {
                        Text("顺序播放").tag(PlayerEngine.RepeatMode.off)
                        Text("列表循环").tag(PlayerEngine.RepeatMode.all)
                        Text("单曲循环").tag(PlayerEngine.RepeatMode.one)
                    }
                    Toggle("随机播放", isOn: $player.isShuffleEnabled)
                }

                Section("关于") {
                    LabeledContent("版本", value: "1.8.5 native")
                }
            }
            .scrollContentBackground(.hidden)
            .background(FoliaTheme.background)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showLogin) {
                LoginView()
                    .environmentObject(library)
            }
        }
        .tint(FoliaTheme.text)
    }
}
