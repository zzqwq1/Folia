import SwiftUI

/// 首页横条（axis y）：折叠 → 标题/页签 → 账户位 → 工具格，对应 BravaisSeamHomeRow.tsx。
struct BravaisSeamHomeRow: View {
    let compact: Bool
    let collapsed: Bool
    let playlists: [Playlist]
    let isLoading: Bool
    let isLoggedIn: Bool
    let profile: UserProfile?
    let onFold: () -> Void
    let onExpand: () -> Void
    let onConnect: () -> Void
    let onOpenPlaylist: (Playlist) -> Void

    @State private var tab: HomeTab = .playlists
    @State private var showMenu = false

    enum HomeTab: String, CaseIterable {
        case playlists, radio, explore, albums

        var label: String {
            switch self {
            case .playlists: return "歌单"
            case .radio: return "电台"
            case .explore: return "探索"
            case .albums: return "专辑"
            }
        }

        var short: String {
            switch self {
            case .playlists: return "歌"
            case .radio: return "电"
            case .explore: return "探"
            case .albums: return "专"
            }
        }
    }

    private var iconSize: CGFloat { compact ? 34 : 38 }
    private var gap: CGFloat { compact ? 10 : 14 }
    private var horizontalPadding: CGFloat { compact ? 12 : 20 }

    var body: some View {
        HStack(spacing: gap) {
            iconButton(system: "rectangle.compress.vertical", label: "折叠信息条", action: onFold)

            nav

            Spacer(minLength: 0).layoutPriority(-1)

            accountSlot

            tools

            if compact {
                iconButton(system: "rectangle.expand.vertical", label: "展开信息条", action: onExpand)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .opacity(collapsed ? 0 : 1)
    }

    // MARK: - 导航段（标题 + 页签）

    private var nav: some View {
        HStack(spacing: compact ? 10 : 16) {
            if !compact {
                Text("书库")
                    .font(.system(size: 15, weight: .heavy))
                    .kerning(15 * 0.3)
                    .foregroundStyle(FoliaTheme.t1)
                    .lineLimit(1)
                    .fixedSize()
            }

            HStack(spacing: 4) {
                ForEach(HomeTab.allCases, id: \.self) { item in
                    tabButton(item)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func tabButton(_ item: HomeTab) -> some View {
        let active = tab == item
        return Button {
            tab = item
        } label: {
            Text(compact ? item.short : item.label)
                .font(.system(size: compact ? 12 : 14, weight: .bold))
                .kerning(compact ? 12 * 0.06 : 14 * 0.12)
                .foregroundStyle(active ? FoliaTheme.t1 : FoliaTheme.t1.opacity(0.55))
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, compact ? 5 : 8)
                .padding(.horizontal, compact ? 9 : 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(active ? FoliaTheme.t1.opacity(0.14) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(active ? .clear : FoliaTheme.t1.opacity(0.0), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 账户位

    @ViewBuilder
    private var accountSlot: some View {
        Button(action: onConnect) {
            if compact {
                avatar
            } else {
                HStack(spacing: 8) {
                    avatar
                    Text(isLoggedIn ? (profile?.nickname ?? "已连接") : "连接在线平台")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(FoliaTheme.t1.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 6)
                .padding(.trailing, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(FoliaTheme.t1.opacity(0.02))
                )
                .frame(maxWidth: 220, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private var avatar: some View {
        let size: CGFloat = compact ? 28 : 32
        return ZStack {
            Circle()
                .fill(isLoggedIn ? FoliaTheme.t1.opacity(0.10) : FoliaTheme.t1.opacity(0.12))
            if isLoggedIn, let urlString = profile?.avatarUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    } else {
                        placeholderMark(size: size)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
            } else {
                Image(systemName: "powerplug")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(FoliaTheme.t1.opacity(0.75))
            }
        }
        .frame(width: size, height: size)
    }

    private func placeholderMark(size: CGFloat) -> some View {
        Text(String((profile?.nickname ?? "F").prefix(1)))
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(FoliaTheme.t1.opacity(0.8))
    }

    // MARK: - 工具格

    private var tools: some View {
        HStack(spacing: compact ? 2 : 6) {
            iconButton(system: "display", label: "舞台播放器", action: {})
            iconButton(system: "magnifyingglass", label: "搜索在线平台", action: {})
            Button {
                showMenu.toggle()
            } label: {
                toolIcon(system: "ellipsis")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                menuContent
            }
        }
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow("rectangle.stack", "队列拼贴")
            menuRow("gearshape", "设置")
            if isLoggedIn {
                Divider().opacity(0.2)
                menuRow("rectangle.portrait.and.arrow.right", "退出登录")
            }
        }
        .frame(minWidth: 200, alignment: .leading)
        .padding(6)
    }

    private func menuRow(_ system: String, _ title: String) -> some View {
        Button {
            showMenu = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: system)
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(FoliaTheme.t1.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 基础按钮

    private func iconButton(system: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            toolIcon(system: system)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func toolIcon(system: String) -> some View {
        Image(systemName: system)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(FoliaTheme.t1.opacity(0.72))
            .frame(width: iconSize, height: iconSize)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(FoliaTheme.t1.opacity(0.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(FoliaTheme.t1.opacity(0.0), lineWidth: 1)
            )
    }
}
