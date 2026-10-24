import SwiftUI

/// 设置：原生版目前只有「播放」与「账户」两栏真实可用的项，其余按网页端列出但标成未接入，
/// 不做点了没反应的假开关。
struct FoliaSettingsView: View {
    @EnvironmentObject private var session: AppSession
    let provider: Provider
    let onConnect: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            FoliaTheme.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("设置")
                            .font(FoliaFont.serif(28, .bold))
                            .foregroundStyle(FoliaTheme.t1)
                        Text("Folia 原生版 · 与墙面共用同一套 token")
                            .font(FoliaFont.sans(12))
                            .foregroundStyle(FoliaTheme.t3)
                    }
                    .padding(.top, 56)

                    group("账户") {
                        row(provider.displayName,
                            detail: session.profile(for: provider)?.nickname ?? "未连接",
                            actionTitle: session.isLoggedIn(provider) ? "退出登录" : "连接") {
                            if session.isLoggedIn(provider) {
                                session.logout(provider)
                            } else {
                                onConnect()
                            }
                        }
                    }

                    group("播放") {
                        row("后台播放", detail: "已开启（AVAudioSession playback）", actionTitle: nil, action: nil)
                        row("锁屏 / 耳机控制", detail: "已开启（Now Playing + Remote Command）", actionTitle: nil, action: nil)
                    }

                    group("未接入") {
                        row("队列拼贴", detail: "原生版还没做这个页面", actionTitle: nil, action: nil)
                        row("在线平台切换", detail: "目前只有网易云接通", actionTitle: nil, action: nil)
                    }

                    Color.clear.frame(height: 80)
                }
                .padding(.horizontal, 20)
            }

            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FoliaTheme.t1)
                    .frame(width: 40, height: 40)
                    .background(FoliaTheme.card.opacity(0.8), in: Circle())
                    .overlay(Circle().stroke(FoliaTheme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.leading, 20)
            .padding(.top, 8)
        }
        .preferredColorScheme(.dark)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(FoliaFont.mono(10))
                .kerning(1.2)
                .foregroundStyle(FoliaTheme.t3)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(FoliaTheme.card.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(FoliaTheme.line, lineWidth: 1))
        }
    }

    private func row(_ title: String, detail: String, actionTitle: String?, action: (() -> Void)?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(FoliaFont.sans(14, .medium))
                    .foregroundStyle(FoliaTheme.t1)
                Text(detail)
                    .font(FoliaFont.sans(11))
                    .foregroundStyle(FoliaTheme.t3)
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(FoliaFont.sans(12, .semibold))
                        .foregroundStyle(FoliaTheme.onAccent)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(FoliaTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
