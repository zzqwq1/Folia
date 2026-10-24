import SwiftUI

/// 横条（axis y）里的首页信息条 —— 对齐网页 `.bravais-seam-home-row`。
///
/// 横贯全宽的一条，元素从左到右固定顺序：
/// 折叠 → 导航段（「书库」+ 页签 歌/电/探/专，宽屏再多一排二级切换）→ 账户入口 → 工具格（舞台 / 搜索 / 设置 / 队列 / ⋯）
/// → 展开（只有书脊态才画）。
///
/// 窄屏（横条宽 < 600px，手机竖屏）按网页的容器查询退让：间距 8、左右内边距 12、工具格间距 2、页签只留一个字。
/// 书脊态（compact）再把页签与图标收小一档（页签 12pt、图标 34pt），与网页 `is-compact` 一致。
struct BravaisSeamHomeRow: View {
    let compact: Bool
    let collapsed: Bool
    let isLoading: Bool
    let isLoggedIn: Bool
    let profile: UserProfile?
    let onFold: () -> Void
    let onExpand: () -> Void
    let onConnect: () -> Void
    let onSettings: () -> Void
    /// 舞台 / 搜索 / 队列。没有可播的歌单时舞台不画（点了也没反应）。
    let onStage: () -> Void
    let onSearch: () -> Void
    let onQueue: () -> Void
    let canStage: Bool

    @State private var tab: HomeTab = .playlists
    @State private var section: HomeSection = .secPlaylists
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

    /// 二级切换（本地四行；在线页签是歌单 / 电台 / 探索 / 专辑，本地是文件夹 / 专辑 / 艺术家 / 歌单）。
    /// 案名不能与 HomeTab 的 case 撞（同一个类型里两个 enum 的 case 会在成员查找上打架），用 sec 前缀。
    enum HomeSection: String, CaseIterable {
        case secFolders, secAlbums, secArtists, secPlaylists

        var label: String {
            switch self {
            case .secFolders: return "文件夹"
            case .secAlbums: return "专辑"
            case .secArtists: return "艺术家"
            case .secPlaylists: return "歌单"
            }
        }

        var icon: String {
            switch self {
            case .secFolders: return "folder"
            case .secAlbums: return "square.stack"
            case .secArtists: return "music.mic"
            case .secPlaylists: return "music.note.list"
            }
        }
    }

    // MARK: - 尺寸

    private var seamInk: Color { FoliaTheme.t1 }
    private var seamInkSoft: Color { FoliaTheme.t1.opacity(0.55) }
    /// 图标按钮的方框（网页 38px，compact 34px）。
    private var iconSize: CGFloat { compact ? 34 : 38 }
    /// 页签字号（网页 14px，compact 12px）。
    private var tabFontSize: CGFloat { compact ? 12 : 14 }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            // 网页容器查询：横条宽 < 600px（手机竖屏）收紧间距与内边距。
            let narrow = width < 600
            let gap: CGFloat = narrow ? 8 : (compact ? 10 : 14)

            HStack(spacing: gap) {
                iconButton(system: "arrow.down.right.and.arrow.up.left", label: "折叠信息条", action: onFold)

                nav(width: width, narrow: narrow)

                accountSlot

                tools(narrow: narrow)

                if compact {
                    iconButton(system: "arrow.up.left.and.arrow.down.right", label: "展开信息条", action: onExpand)
                }
            }
            .padding(.horizontal, narrow ? 12 : max(20, width * 0.024))
            .frame(width: width, height: geo.size.height)
        }
        .opacity(collapsed ? 0 : 1)
    }

    // MARK: - 导航段（书库 + 页签 + 二级切换）

    private func nav(width: CGFloat, narrow: Bool) -> some View {
        let shortTabs = compact || narrow
        return HStack(spacing: narrow ? 8 : 16) {
            if !compact && width >= 560 {
                Text("书库")
                    .font(.system(size: 15, weight: .bold))
                    .kerning(15 * 0.3)
                    .foregroundStyle(seamInk)
                    .fixedSize()
            }

            HStack(spacing: 4) {
                ForEach(HomeTab.allCases, id: \.self) { item in
                    tabButton(item, short: shortTabs)
                }
            }

            if !compact && width >= 700 {
                HStack(spacing: 2) {
                    ForEach(HomeSection.allCases, id: \.self) { item in
                        sectionButton(item)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tabButton(_ item: HomeTab, short: Bool) -> some View {
        let active = tab == item
        return Button {
            tab = item
        } label: {
            Text(short ? item.short : item.label)
                .font(.system(size: tabFontSize, weight: .bold))
                .kerning(short ? 0 : tabFontSize * 0.12)
                .foregroundStyle(active ? seamInk : seamInkSoft)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, short ? 8 : 12)
                // 网页 .bravais-seam-home-tab short：min-width 34px。
                .frame(minWidth: short ? 34 : 0, minHeight: iconSize)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(active ? seamInk.opacity(0.14) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label)
    }

    private func sectionButton(_ item: HomeSection) -> some View {
        let active = section == item
        return Button {
            section = item
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .medium))
                if active {
                    Text(item.label)
                        .font(.system(size: 12, weight: .bold))
                        .fixedSize()
                }
            }
            .foregroundStyle(active ? seamInk : seamInkSoft)
            .padding(.horizontal, 8)
            .frame(minHeight: iconSize)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label)
    }

    // MARK: - 账户入口

    private var accountSlot: some View {
        Button(action: onConnect) {
            HStack(spacing: 8) {
                avatar
                if !compact {
                    Text(isLoggedIn ? (profile?.nickname ?? "已连接") : "连接在线平台")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(seamInk.opacity(0.9))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLoggedIn ? (profile?.nickname ?? "已连接") : "连接在线平台")
    }

    private var avatar: some View {
        let size: CGFloat = compact ? 32 : 34
        return ZStack {
            Circle().fill(seamInk.opacity(isLoggedIn ? 0.10 : 0.05))
            Circle().stroke(seamInk.opacity(isLoggedIn ? 0.10 : 0.22), lineWidth: 1)
            if isLoggedIn, let urlString = profile?.avatarUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    } else {
                        placeholderMark(size: size)
                    }
                }
                .frame(width: size - 4, height: size - 4)
                .clipShape(Circle())
            } else {
                Image(systemName: "powerplug")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(seamInk.opacity(0.78))
            }
        }
        .frame(width: size, height: size)
    }

    private func placeholderMark(size: CGFloat) -> some View {
        Text(String((profile?.nickname ?? "F").prefix(1)))
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(seamInk.opacity(0.8))
    }

    // MARK: - 工具格（一排）

    private func tools(narrow: Bool) -> some View {
        HStack(spacing: narrow ? 2 : 6) {
            if canStage {
                iconButton(system: "display", label: "舞台播放器", action: onStage)
            }
            iconButton(system: "magnifyingglass", label: "搜索在线平台", action: onSearch)
            iconButton(system: "gearshape", label: "设置", action: onSettings)
            iconButton(system: "sidebar.left", label: "播放队列", action: onQueue)

            Button {
                showMenu.toggle()
            } label: {
                toolIcon(system: "ellipsis")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更多")
            .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                FoliaSeamMenu(
                    provider: profile?.provider ?? .netease,
                    onConnect: { showMenu = false; onConnect() },
                    onSettings: { showMenu = false; onSettings() }
                )
            }
        }
    }

    // MARK: - 基础按钮

    private func iconButton(
        system: String,
        label: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            toolIcon(system: system, disabled: disabled)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private func toolIcon(system: String, disabled: Bool = false) -> some View {
        Image(systemName: system)
            .font(.system(size: compact ? 15 : 16, weight: .semibold))
            .foregroundStyle(seamInk.opacity(disabled ? 0.26 : 0.72))
            .frame(width: iconSize, height: iconSize)
            .contentShape(Rectangle())
    }
}
