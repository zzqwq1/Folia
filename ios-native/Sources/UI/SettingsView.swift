import SwiftUI

/// 复刻原版 Web 的设置窗口（src/components/shared/Sheet.tsx + modal/settings 的 kit 家族）。
///
/// 层级：窗底 #1a1a1d / 24pt 圆角 → Sheet 页头（16pt 半粗标题 + 32×32 关闭钮）
/// → 分区条（SettingsSideList 窄屏形态：横向滚动的 32pt 条目）
/// → 可滚内容（左右 24pt / 下 20pt）→ PageHeader 风格分区标题（20pt 半粗 / 32pt 行高，下 1px 8% 线）
/// → 若干 Group 卡片（#232327 / 12pt 圆角 / 1px 8% 外描边）与其中的 Row
/// （最小高 56pt / 上下 10pt / 左右 16pt / 14pt 标签 / 行上 1px 8% 发丝线，左缩进 16pt）。
/// 原版设置页没有 `@media (max-width:640px)` 分支，手机竖屏直接取固定值，窄处按 flex-wrap 的原意换行。
struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .account
    @State private var showLogin = false

    /// 手机上做得到的四个分区（原版 13 个分区里挑出跟本工程功能对得上的）
    enum Section: String, CaseIterable, Identifiable {
        case account = "账号"
        case playback = "播放控制"
        case appearance = "外观"
        case general = "通用"

        var id: String { rawValue }
    }

    /// Sheet / Group / Row 的像素值（Tailwind × 4）
    private enum M {
        static let corner: CGFloat = 24           // Sheet rounded-2xl
        static let headerTop: CGFloat = 16        // header pt-4
        static let headerLead: CGFloat = 24       // header pl-6
        static let headerTrail: CGFloat = 16      // header pr-4
        static let headerGap: CGFloat = 12        // header gap-3
        static let titleLine: CGFloat = 32        // leading-8
        static let closeSize: CGFloat = 32        // h-8 w-8
        static let closeCorner: CGFloat = 8       // rounded-lg

        static let chipHeight: CGFloat = 32       // 分区条目 h-8
        static let chipCorner: CGFloat = 8        // rounded-lg
        static let chipGap: CGFloat = 4           // nav gap-1
        static let chipInset: CGFloat = 12        // aside px-3
        static let stripTop: CGFloat = 8          // nav mt-2
        static let stripBottom: CGFloat = 8       // aside pb-2

        static let bodyLead: CGFloat = 24         // body px-6
        static let bodyTop: CGFloat = 4           // body pt-3 减去页头标题下沿 8pt
        static let bodyBottom: CGFloat = 20       // body pb-5

        static let pageTop: CGFloat = 8           // PageHeader pt-4 减去页头标题下沿 8pt
        static let pageGap: CGFloat = 12          // PageHeader pb-3
        static let pageLine: CGFloat = 1          // border-b
        static let pageTitleLine: CGFloat = 32    // leading-8

        static let groupFirstTop: CGFloat = 20    // first:mt-5
        static let groupTop: CGFloat = 28         // mt-7
        static let groupTitleBottom: CGFloat = 8  // mb-2
        static let groupTitleLine: CGFloat = 20   // leading-5
        static let groupTitleMin: CGFloat = 24    // min-h-6
        static let groupTitleInset: CGFloat = 4   // px-1
        static let groupCorner: CGFloat = 12      // rounded-xl

        static let rowMin: CGFloat = 56           // min-h-14
        static let rowV: CGFloat = 10             // py-2.5
        static let rowLead: CGFloat = 16          // pl-4
        static let rowTrail: CGFloat = 16         // pr-4
        static let rowGap: CGFloat = 24           // gap-x-6
        static let rowGapY: CGFloat = 8           // flex-wrap 的行间距
        static let rowLabelLine: CGFloat = 20     // leading-5
        static let rowHintLine: CGFloat = 18      // leading-[18px]
        static let hairlineInset: CGFloat = 16    // .st-row::before left:16px
        static let controlGap: CGFloat = 8        // 控制区 gap-2
    }

    /// 与原版 CSS 变量一一对应（kitTheme.ts 的 --st-*，Sheet 的窗底 / kit 卡片色）
    private enum C {
        static let t1 = FoliaTheme.text
        static let t2 = FoliaTheme.text.opacity(0.62)
        static let t3 = FoliaTheme.text.opacity(0.42)
        static let line = FoliaTheme.text.opacity(0.08)
        static let line2 = FoliaTheme.text.opacity(0.16)
        static let fill = FoliaTheme.text.opacity(0.07)
        static let fill2 = FoliaTheme.text.opacity(0.12)
        static let track = FoliaTheme.text.opacity(0.17)
        static let accent = WallTheme.midnight.accent
        /// --st-win：设置窗口的底色
        static let win = Color(hex: 0x1A1A1D)
        /// --st-card：分组卡片的底色
        static let card = Color(hex: 0x232327)
        /// --st-raise：分段控件选中的底块
        static let raise = Color(hex: 0x45454C)
        /// --st-knob：开关的把手
        static let knob = Color(hex: 0xECECEE)
        static let warn = Color(hex: 0xE3A949)
    }

    /// kit 缓动：ease-out (0.22, 1, 0.36, 1)，fast 0.12 / move 0.22
    private static let chipAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.12)
    private static let moveAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)

    // MARK: - 主体

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            strip
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader
                    pageBody
                }
                .padding(.horizontal, M.bodyLead)
                .padding(.top, M.bodyTop)
                .padding(.bottom, M.bodyBottom)
            }
        }
        .background(C.win)
        .clipShape(RoundedRectangle(cornerRadius: M.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: M.corner, style: .continuous)
                .strokeBorder(C.line2, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 30, x: 0, y: 20)
        .preferredColorScheme(.dark)
    }

    // MARK: - Sheet 页头

    private var header: some View {
        HStack(alignment: .top, spacing: M.headerGap) {
            Text("设置")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(C.t1)
                .frame(height: M.titleLine)
                .frame(maxWidth: .infinity, alignment: .leading)
            SheetCloseButton { dismiss() }
                .frame(width: M.closeSize, height: M.closeSize)
        }
        .padding(.leading, M.headerLead)
        .padding(.trailing, M.headerTrail)
        .padding(.top, M.headerTop)
    }

    // MARK: - 分区条（SettingsSideList 的窄屏形态）

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: M.chipGap) {
                ForEach(Section.allCases) { item in
                    chip(item)
                }
            }
            .padding(.horizontal, M.chipInset)
            .padding(.top, M.stripTop)
            .padding(.bottom, M.stripBottom)
        }
    }

    private func chip(_ item: Section) -> some View {
        let active = item == section
        return Button {
            withAnimation(Self.chipAnimation) { section = item }
        } label: {
            Text(item.rawValue)
                .font(.system(size: 13))
                .foregroundStyle(active ? C.t1 : C.t2)
                .lineLimit(1)
                .padding(.horizontal, 10)   // px-2.5
                .frame(height: M.chipHeight)
                .background(
                    RoundedRectangle(cornerRadius: M.chipCorner, style: .continuous)
                        .fill(active ? C.fill2 : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(ChipPressStyle())
    }

    // MARK: - 分区页头（kit PageHeader）

    private var pageHeader: some View {
        HStack(spacing: M.headerGap) {
            Text(section.rawValue)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(C.t1)
                .lineLimit(1)
                .frame(height: M.pageTitleLine)
            Spacer(minLength: 0)
        }
        .padding(.top, M.pageTop)
        .padding(.bottom, M.pageGap)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(C.line)
                .frame(height: M.pageLine)
        }
    }

    // MARK: - 分区内容

    @ViewBuilder
    private var pageBody: some View {
        switch section {
        case .account:
            accountPage
        case .playback:
            playbackPage
        case .appearance:
            appearancePage
        case .general:
            generalPage
        }
    }

    /// 账号：头像 / 昵称 / VIP + 扫码登录 + 退出登录
    @ViewBuilder
    private var accountPage: some View {
        SettingGroup(title: "网易云音乐", isFirst: true) {
            if let account = library.account {
                SettingRow(hairline: false) {
                    HStack(spacing: 12) {
                        accountAvatar(account)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(account.nickname)
                                .font(.system(size: 14))
                                .foregroundStyle(C.t1)
                                .lineLimit(1)
                                .frame(height: M.rowLabelLine, alignment: .top)
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(account.isVip ? C.warn : C.t3)
                                    .frame(width: 5, height: 5)
                                Text(account.isVip ? "黑胶 VIP" : "普通用户")
                                    .font(.system(size: 12))
                                    .foregroundStyle(C.t2)
                                    .lineLimit(1)
                            }
                            .frame(height: M.rowHintLine)
                            .padding(.top, 2)
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                SettingRow(hairline: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("当前是访客")
                            .font(.system(size: 14))
                            .foregroundStyle(C.t1)
                            .frame(height: M.rowLabelLine, alignment: .top)
                        Text("扫码登录后，墙上会铺满你的收藏")
                            .font(.system(size: 12))
                            .foregroundStyle(C.t2)
                            .lineLimit(1)
                            .frame(height: M.rowHintLine)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
            }

            SettingRow(action: { showLogin = true }) {
                rowLabel("扫码登录网易云")
                Spacer(minLength: 0)
                NeteaseMark(size: 24)
                Chevron()
            }

            if library.isSignedIn {
                SettingRow(action: { Task { await library.signOut() } }) {
                    rowLabel("退出登录")
                    Spacer(minLength: 0)
                }
            }
        }
        .sheet(isPresented: $showLogin) {
            LoginView()
                .environmentObject(library)
        }
    }

    /// 账号头像：44pt 圆 + 角上 20pt 的网易云记号（原版 AccountPicture 的角标）
    private func accountAvatar(_ account: Account) -> some View {
        ZStack {
            Group {
                if let url = account.avatar {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            avatarLetter(account.nickname)
                        }
                    }
                } else {
                    avatarLetter(account.nickname)
                }
            }
            .frame(width: 44, height: 44)
            .background(C.fill)
            .clipShape(Circle())

            // 角标压在圆的右下（20pt 的记号移 25pt 到右下角），外层圆再裁掉外溢的部分
            NeteaseMark(size: 20)
                .overlay(Circle().strokeBorder(C.card, lineWidth: 2))
                .offset(x: 25, y: 25)
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
    }

    private func avatarLetter(_ nickname: String) -> some View {
        Text(String(nickname.prefix(1)))
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(C.t1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(C.fill2)
    }

    /// 播放：循环模式三选一 + 随机播放
    @ViewBuilder
    private var playbackPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingGroup(title: "播完一首之后", isFirst: true) {
                SettingRow {
                    VStack(alignment: .leading, spacing: 0) {
                        rowLabel("循环模式")
                        rowHint("队列走到末尾时做什么")
                    }
                    Spacer(minLength: 0)
                    segmented
                }
            }

            SettingGroup(title: "随机") {
                SettingRow {
                    VStack(alignment: .leading, spacing: 0) {
                        rowLabel("随机播放")
                        rowHint("下一首从队列里随机挑")
                    }
                    Spacer(minLength: 0)
                    SettingToggle(isOn: $player.isShuffleEnabled)
                }
            }
        }
    }

    /// kit Segmented：≥32pt 高、7% 底、2pt 内边距、选中块 --st-raise 6pt 圆角
    private var segmented: some View {
        HStack(spacing: 0) {
            repeatOption(.off)
            repeatOption(.all)
            repeatOption(.one)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(C.fill)
        )
    }

    private func repeatOption(_ mode: PlayerEngine.RepeatMode) -> some View {
        let active = player.repeatMode == mode
        return Button {
            withAnimation(Self.moveAnimation) { player.repeatMode = mode }
        } label: {
            Text(Self.repeatLabel(mode))
                .font(.system(size: 13))
                .foregroundStyle(active ? C.t1 : C.t2)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    Group {
                        if active {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(C.raise)
                                .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
                        }
                    }
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(ChipPressStyle())
    }

    private static func repeatLabel(_ mode: PlayerEngine.RepeatMode) -> String {
        switch mode {
        case .off: return "顺序"
        case .all: return "列表循环"
        case .one: return "单曲循环"
        }
    }

    /// 外观：主题 + 平台记号
    @ViewBuilder
    private var appearancePage: some View {
        SettingGroup(title: "主题", isFirst: true, foot: "原版有多套配色，原生先固定「午夜墨染」。") {
            SettingRow {
                VStack(alignment: .leading, spacing: 0) {
                    rowLabel("主题")
                    rowHint("原生端固定暗色")
                }
                Spacer(minLength: 0)
                Text("午夜墨染")
                    .font(.system(size: 13))
                    .foregroundStyle(C.t2)
                    .lineLimit(1)
            }
        } 

        SettingGroup(title: "平台", foot: "登录窗口标题前那个红底「云」字的记号。") {
            SettingRow {
                rowLabel("网易云音乐")
                Spacer(minLength: 0)
                NeteaseMark(size: 24)
            }
        } 
    }

    /// 通用：版本 + 登录入口
    @ViewBuilder
    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingGroup(title: "关于", isFirst: true) {
                SettingRow {
                    rowLabel("版本")
                    Spacer(minLength: 0)
                    Text("1.8.5 native")
                        .font(.system(size: 13))
                        .foregroundStyle(C.t2)
                        .lineLimit(1)
                }
            }

            SettingGroup(title: "账号") {
                SettingRow(action: { showLogin = true }) {
                    rowLabel("扫码登录网易云")
                    Spacer(minLength: 0)
                    NeteaseMark(size: 24)
                    Chevron()
                }
            }
            .sheet(isPresented: $showLogin) {
                LoginView()
                    .environmentObject(library)
            }
        }
    }

    // MARK: - 行内文字（kit Row：14pt/20 标签，12pt/18 62% 提示）

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(C.t1)
            .lineLimit(1)
            .frame(height: M.rowLabelLine)
    }

    private func rowHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(C.t2)
            .lineLimit(1)
            .frame(height: M.rowHintLine)
            .padding(.top, 2)
    }
}

// MARK: - Group / Row

/// kit Group：组标题（13pt 半粗 / 20pt 行高 / 62% 文字 / 下 8pt / 左右 4pt）
/// + 卡片（12pt 圆角 / #232327 / 1px 8% 外描边）+ 可选的说明（12pt / 42%）
private struct SettingGroup<Content: View>: View {
    let title: String
    var isFirst: Bool = false
    var foot: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FoliaTheme.text.opacity(0.62))
                    .frame(height: 20)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 24)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                content
            }
            .background(Color(hex: 0x232327))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(FoliaTheme.text.opacity(0.08), lineWidth: 1)
            )

            if let foot {
                Text(foot)
                    .font(.system(size: 12))
                    .foregroundStyle(FoliaTheme.text.opacity(0.42))
                    .lineLimit(2)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
        }
        .padding(.top, isFirst ? 20 : 28)
    }
}

/// kit Row：最小高 56pt、上下 10pt、左右 16pt；行上一条 1px 8% 发丝线（左缩进 16pt，首行传 hairline:false）
private struct SettingRow<Content: View>: View {
    var hairline: Bool = true
    var action: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            if let action {
                Button(action: action) { rowBody }
                    .buttonStyle(RowPressStyle())
            } else {
                rowBody
            }
        }
    }

    private var rowBody: some View {
        // 窄屏下标签与控制区按 flex-wrap 的原意上下折行
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                content
            }
            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if hairline {
                Rectangle()
                    .fill(FoliaTheme.text.opacity(0.08))
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
        .contentShape(Rectangle())
    }
}

/// 可点行的按下反馈：原版 hover 是 7% 填充
private struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(FoliaTheme.text.opacity(configuration.isPressed ? 0.07 : 0))
                    .padding(.horizontal, 4)
            )
            .animation(Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.12), value: configuration.isPressed)
    }
}

private struct ChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 控件

/// kit Toggle：40×24、关态 17% 轨道 / 开态 accent、把手 18pt --st-knob、位移 16pt、move 0.22
private struct SettingToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? WallTheme.midnight.accent : FoliaTheme.text.opacity(0.17))
                Circle()
                    .fill(Color(hex: 0xECECEE))
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                    .padding(3)
            }
            .frame(width: 40, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("随机播放")
        .accessibilityValue(isOn ? "开" : "关")
    }
}

/// 网易云的记号：红底白字「云」（原版 PlatformMark：mark.color #dc2626、字号 size × 0.42）
struct NeteaseMark: View {
    let size: CGFloat

    var body: some View {
        Text("云")
            .font(.system(size: (size * 0.42).rounded(), weight: .bold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(hex: 0xDC2626)))
    }
}

/// kit Row 的链接箭头（ChevronRight 16 / 62%）
private struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(FoliaTheme.text.opacity(0.62))
    }
}

/// Sheet 的关闭钮（设置与登录共用）：32×32 / 8pt 圆角 / 62% 文字；按下是 7% 底 + 满色文字
struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(SheetCloseButtonStyle())
        .accessibilityLabel("关闭")
    }
}

struct SheetCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(FoliaTheme.text.opacity(configuration.isPressed ? 1 : 0.62))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(FoliaTheme.text.opacity(configuration.isPressed ? 0.07 : 0))
            )
            .animation(Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.12), value: configuration.isPressed)
    }
}
