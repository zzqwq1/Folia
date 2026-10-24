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
}
