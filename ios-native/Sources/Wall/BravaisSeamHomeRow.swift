import SwiftUI

/// 横条（axis y）里的首页窄缝 / 首页书脊。
///
/// 对齐网页 `BravaisSeamHomeRow` 的**横向信息条**形态：横条是横贯全宽、高 212 的一条，内容按网页竖缝的
/// 那一套排版竖着排——最上面是折叠，下面「书库」，再下面是一排竖排页签（像一排书脊）；中段（二级切换、
/// 状态）在剩余空间里竖直居中；账户入口贴在工具格上方；工具格（舞台 / 搜索 / ⋯）在最下。
/// 书脊（compact，高 52）不画中段，只排页签，末尾多一个展开。
///
/// 退让顺序与网页一致（useBravaisSeamRowFit 的竖缝版）：先藏「书库」→ 页签缩成一个字 → 还放不下，
/// 导航区在里面滚。这里按可用高度简单折算：低于标题所需的余量就藏标题，再低就缩字。
struct BravaisSeamHomeRow: View {
    let compact: Bool
    let collapsed: Bool
    /// 横条当前高度（开口宽度）。内容按它决定退让级别。
    let height: CGFloat
    let playlists: [Playlist]
    let isLoading: Bool
    let isLoggedIn: Bool
    let profile: UserProfile?
    let onFold: () -> Void
    let onExpand: () -> Void
    let onConnect: () -> Void
    let onSettings: () -> Void
    /// 舞台 / 搜索。没有可播的歌单时按钮置灰（不再点了没反应）。
    let onStage: () -> Void
    let onSearch: () -> Void
    let canStage: Bool
    let onOpenPlaylist: (Playlist) -> Void

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

        var short: String {
            switch self {
            case .secFolders: return "夹"
            case .secAlbums: return "专"
            case .secArtists: return "家"
            case .secPlaylists: return "单"
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

    // MARK: - 退让

    /// 藏「书库」：高度只够折叠 + 页签 + 工具格时。
    private var titled: Bool { !compact && height >= 168 }
    /// 页签缩成一个字。
    private var short: Bool { compact || height < 132 }
    /// 中段（二级切换 / 状态）只在有余量时出现；不够就让位。
    private var showsMiddle: Bool { !compact && height >= 150 }

    private var seamInk: Color { FoliaTheme.t1 }
    private var seamInkSoft: Color { FoliaTheme.t1.opacity(0.55) }
    private let inkColumnWidth: CGFloat = 34

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            head

            Spacer(minLength: 0)

            if showsMiddle {
                middle
            }

            Spacer(minLength: 0)

            accountSlot

            tools

            if compact {
                iconButton(system: "arrow.up.left.and.arrow.down.right", label: "展开信息条", action: onExpand)
            }
        }
        .padding(.top, compact ? 10 : 14)
        .padding(.bottom, compact ? 8 : 12)
        .opacity(collapsed ? 0 : 1)
    }

    // MARK: - 页头（折叠 → 书库 → 页签列）

    private var head: some View {
        VStack(spacing: compact ? 6 : 8) {
            iconButton(system: compact ? "arrow.down.right.and.arrow.up.left" : "rectangle.compress.vertical",
                       label: "折叠信息条", action: onFold)

            if titled {
                Text("书库")
                    .font(.system(size: 15, weight: .bold))
                    .kerning(15 * 0.3)
                    .foregroundStyle(seamInk)
                    .fixedSize()
            }

            VStack(spacing: short ? 4 : 6) {
                ForEach(HomeTab.allCases, id: \.self) { item in
                    tabButton(item)
                }
            }
        }
    }

    private func tabButton(_ item: HomeTab) -> some View {
        let active = tab == item
        let text = short ? item.short : item.label
        return Button {
            tab = item
        } label: {
            VerticalLabel(
                text: text,
                font: .system(size: compact ? 12 : 14, weight: .bold),
                kerning: short ? 0 : 14 * 0.18
            )
            .foregroundStyle(active ? seamInk : seamInkSoft)
            .padding(.vertical, compact ? 7 : 9)
            .padding(.horizontal, short ? 4 : 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(active ? seamInk.opacity(0.14) : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label)
    }

    // MARK: - 中段（二级切换 + 状态）

    private var middle: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                ForEach(HomeSection.allCases, id: \.self) { item in
                    sectionButton(item)
                }
            }

            if isLoading || !isLoggedIn {
                Text(isLoading ? "正在读取歌单…" : "尚未连接")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(seamInkSoft.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func sectionButton(_ item: HomeSection) -> some View {
        let active = section == item
        return Button {
            section = item
        } label: {
            VStack(spacing: 5) {
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .medium))
                if active {
                    VerticalLabel(
                        text: short ? item.short : item.label,
                        font: .system(size: 12, weight: .bold),
                        kerning: short ? 0 : 12 * 0.14
                    )
                }
            }
            .foregroundStyle(active ? seamInk : seamInkSoft)
            .padding(.horizontal, 6)
            .padding(.vertical, active ? 7 : 8)
            .frame(width: inkColumnWidth)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.clear)
            )
            .overlay(alignment: .leading) {
                if active {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(seamInk)
                        .frame(width: 2)
                        .padding(.vertical, 8)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label)
    }

    // MARK: - 账户入口（贴工具格）

    private var accountSlot: some View {
        Button(action: onConnect) {
            VStack(spacing: 5) {
                avatar
                if !compact {
                    Text(isLoggedIn ? (profile?.nickname ?? "已连接") : "连接在线平台")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(seamInk.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .frame(width: inkColumnWidth + 12)
                }
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLoggedIn ? (profile?.nickname ?? "已连接") : "连接在线平台")
    }

    private var avatar: some View {
        let size: CGFloat = compact ? 26 : 30
        return ZStack {
            Circle().fill(seamInk.opacity(0.10))
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(seamInk.opacity(0.75))
            }
        }
        .frame(width: size, height: size)
    }

    private func placeholderMark(size: CGFloat) -> some View {
        Text(String((profile?.nickname ?? "F").prefix(1)))
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(seamInk.opacity(0.8))
    }

    // MARK: - 工具格（一列）

    private var tools: some View {
        VStack(spacing: compact ? 2 : 6) {
            iconButton(system: "display", label: "舞台播放器", disabled: !canStage, action: onStage)
            iconButton(system: "magnifyingglass", label: "搜索在线平台", disabled: !canStage, action: onSearch)
            Button {
                showMenu.toggle()
            } label: {
                toolIcon(system: "ellipsis")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                FoliaSeamMenu(
                    provider: provider,
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
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(seamInk.opacity(disabled ? 0.26 : 0.72))
            .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
    }
}

/// 竖排文字（writing-mode: vertical-rl 的近似）：逐字竖着垒，可选字距。
/// 拉丁字母 / 数字不适合竖排，这里只用于中文页签名，与网页一致。
struct VerticalLabel: View {
    let text: String
    var font: Font = .system(size: 14, weight: .bold)
    var kerning: CGFloat = 0

    var body: some View {
        VStack(spacing: kerning) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, ch in
                Text(String(ch)).font(font)
            }
        }
    }
}
