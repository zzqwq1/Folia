import SwiftUI

/// 全屏播放器：对齐 VisualizerShell 的视觉 ——
/// 全屏封面模糊背景 + 大封面 + serif 大标题 + 进度条 + 控制
struct PlayerView: View {
    let track: Track
    @Binding var isPresented: Bool
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var session: AppSession

    var body: some View {
        ZStack {
            // 背景：封面超大模糊（对齐 VisualizerShell 的换色 1s 过渡）
            if let url = track.coverUrl, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    }
                }
                .blur(radius: 80)
                .opacity(0.35)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 1.0), value: track.id)
            }
            FoliaTheme.bg.opacity(0.6).ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部返回
                HStack {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(FoliaTheme.t1)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.2), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Spacer()

                // 中央大封面
                AsyncImage(url: URL(string: track.coverUrl ?? "")) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        ZStack {
                            FoliaTheme.fill
                            Image(systemName: "opticaldisc")
                                .font(.system(size: 64))
                                .foregroundStyle(FoliaTheme.t3)
                        }
                    }
                }
                .frame(width: 280, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(FoliaTheme.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 32, y: 16)
                .padding(.bottom, 32)

                // 歌曲信息（serif 大标题，对齐 Visualizer 歌词字号层级）
                VStack(spacing: 6) {
                    Text(track.title)
                        .font(FoliaFont.serif(28, .bold))
                        .foregroundStyle(FoliaTheme.t1)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(track.artist)
                        .font(FoliaFont.sans(15))
                        .foregroundStyle(FoliaTheme.t2)
                        .lineLimit(1)
                    if let album = track.album {
                        Text(album)
                            .font(FoliaFont.mono(11))
                            .foregroundStyle(FoliaTheme.t3)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)

                Spacer()

                // 控制组
                HStack(spacing: 40) {
                    Button { /* TODO 上一首 */ } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(FoliaTheme.t2)
                    }
                    .buttonStyle(.plain)
                    .disabled(true)
                    .opacity(0.4)

                    Button {
                        player.toggle()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(FoliaTheme.onAccent)
                            .frame(width: 72, height: 72)
                            .background(FoliaTheme.accent, in: Circle())
                            .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                    }
                    .buttonStyle(.plain)

                    Button { /* TODO 下一首 */ } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(FoliaTheme.t2)
                    }
                    .buttonStyle(.plain)
                    .disabled(true)
                    .opacity(0.4)
                }
                .padding(.bottom, 60)
            }
        }
        .preferredColorScheme(.dark)
    }
}
