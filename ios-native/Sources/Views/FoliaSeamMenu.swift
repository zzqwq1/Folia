import SwiftUI

/// 共用的「⋯」菜单内容：账户（连接 / 切换平台 / 退出登录）+ 设置入口。
///
/// 横条里的工具格与墙上的浮层都用它，避免两处各写一份、行为走样。
struct FoliaSeamMenu: View {
    @EnvironmentObject private var session: AppSession
    let provider: Provider
    let onConnect: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 账户：未连接就一条「连接在线平台」；已连接就平台名 + 退出。
            if let profile = session.profile(for: provider) {
                Text(profile.nickname)
                    .font(FoliaFont.sans(13, .semibold))
                    .foregroundStyle(FoliaTheme.t1)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                Text("\(provider.displayName) · 已连接")
                    .font(FoliaFont.mono(10))
                    .foregroundStyle(FoliaTheme.t3)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)

                menuRow("rectangle.portrait.and.arrow.right", "退出登录") {
                    session.logout(provider)
                }
            } else {
                menuRow("powerplug", "连接在线平台") {
                    onConnect()
                }
            }

            Divider().overlay(FoliaTheme.line).padding(.vertical, 4)

            menuRow("gearshape", "设置") {
                onSettings()
            }
        }
        .frame(minWidth: 200, alignment: .leading)
        .padding(6)
    }

    private func menuRow(_ system: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: system)
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(title).font(FoliaFont.sans(13, .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(FoliaTheme.t1.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
