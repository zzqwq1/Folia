import SwiftUI

/// WallToolsButton.css 的配色（面板玻璃、分隔线、开关轨道等）
private enum C {
    static let ink = Color.white
    static let panelFill = Color.black.opacity(0.40)
    static let panelBorder = Color.white.opacity(0.08)
    static let hover = Color.white.opacity(0.10)
    static let quickFill = Color.white.opacity(0.06)
    static let quickHover = Color.white.opacity(0.13)
    static let track = Color.white.opacity(0.18)
    static let line = Color.white.opacity(0.10)
    static let helpFill = Color.white.opacity(0.06)
    static let helpLine = Color.white.opacity(0.07)
    static let heading = Color.white.opacity(0.52)
    /// `color-mix(in srgb, currentColor 58%, transparent)`
    static let lightsIdle = Color.white.opacity(0.58)
}

/// 墙面右下角的工具按钮与锚定玻璃面板，逐条移植 `src/components/wall/WallToolsButton.tsx` +
/// `WallToolsButton.css` + `WallToolsRows.tsx`：
///
/// - 按钮：44pt 玻璃圆（原版 SlideActionButton 的紧凑档），点按上下翻转图标（Settings2 ↔ X）
/// - 面板：宽 `min(296, 100vw - 32)`、`p-10`、`gap-2`、24 圆角、`rgb(0 0 0 / 40%)` + 24px 背景模糊、
///   1px 8% 描边、`0 24px 64px rgb(0 0 0 / 42%)` 阴影；入场 `opacity 0→1 / scale 0.9→1`，原点右下，0.2s easeOut
/// - 内容自上而下：6 格纯图标快捷排（40pt / 12 圆角 / 6% 底）→ 音量滑条行 → 墙自己的条目 → 海报叠色开关
///   → 灯光分段 + 帮助按钮 + 帮助列表
/// - 按钮上方的队列浮岛（`WallToolsQueueIsland`）与定位按钮不在这一份里，墙自己画
///
/// 尺寸按 CSS 像素 1:1 落到 pt，不做任何缩放：原版在窄窗（<640px）时 panel 已经是 `100vw - 32`，
/// iPhone 上直接走的就是这条窄版。
struct WallToolsPanel: View {
    enum Route: Equatable {
        case shuffleQueue
        case generateTheme
        case queue
        case destination
        case openPlayer
        case openSettings
    }

    struct QuickAction: Identifiable {
        let id: Route
        let icon: String
        let label: String
        var disabled: Bool = false
        /// 点完不收起面板（洗牌、主题、队列）
        var keepOpen: Bool = false
    }

    struct Entry: Identifiable {
        enum Kind {
            case action(icon: String, label: String, value: String?, disabled: Bool)
            case toggle(icon: String, label: String, isOn: Bool)
        }
        let id: String
        var kind: Kind
    }

    // MARK: - CSS 常量

    private enum M {
        /// `--wall-tools-panel-width: min(296px, calc(100vw - 32px))`
        static let panelWidthMax: CGFloat = 296
        static let panelInset: CGFloat = 32
        static let panelPadding: CGFloat = 10
        static let panelGap: CGFloat = 2
        static let panelRadius: CGFloat = 24
        static let stackGap: CGFloat = 8
        static let quickHeight: CGFloat = 40
        static let quickRadius: CGFloat = 12
        static let quickGap: CGFloat = 4
        static let rowHeight: CGFloat = 38
        static let rowRadius: CGFloat = 12
        static let rowGap: CGFloat = 11
        static let sliderIconBox: CGFloat = 30
        static let sliderIconRadius: CGFloat = 9
        static let toggleWidth: CGFloat = 30
        static let toggleHeight: CGFloat = 18
        static let toggleKnob: CGFloat = 12
        static let buttonSize: CGFloat = 44
        /// `@media (max-width: 640px) { .lattice-tools { right: 16px; bottom: 16px } }`
        static let edge: CGFloat = 16
    }

    // MARK: - 输入

    let quick: [QuickAction]
    var entries: [Entry] = []
    var isTintEnabled: Bool
    var isLightsOut: Bool
    var helpLines: [(String, String)] = []

    var onRoute: (Route) -> Void
    var onToggleTint: () -> Void
    var onSetLights: (Bool) -> Void
    /// 面板开合状态外传：原版队列浮岛跟着面板一起出现 / 收起（`showQueueIsland = isOpen && ...`）
    var onOpenChange: (Bool) -> Void = { _ in }

    // MARK: - 状态

    @EnvironmentObject private var player: PlayerEngine
    @State private var isOpen = false
    @State private var showHelp = false
    @State private var isLanding = false

    var body: some View {
        VStack(alignment: .trailing, spacing: M.stackGap) {
            if isOpen { panel }
            toolsButton
        }
        .padding(.trailing, M.edge)
        .padding(.bottom, M.edge)
        .onChange(of: isOpen) { open in onOpenChange(open) }
    }

    // MARK: - 面板

    private var panel: some View {
        VStack(alignment: .leading, spacing: M.panelGap) {
            quickRow
            volumeRow
            ForEach(entries) { entry in
                row(entry)
            }
            tintRow
            helpSection
        }
        .padding(M.panelPadding)
        .frame(width: min(M.panelWidthMax, UIScreen.main.bounds.width - M.panelInset), alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: M.panelRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: M.panelRadius, style: .continuous)
                        .fill(C.panelFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: M.panelRadius, style: .continuous)
                        .strokeBorder(C.panelBorder, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.42), radius: 32, x: 0, y: 24)
        )
        .scaleEffect(isLanding ? 0.9 : 1, anchor: .bottomTrailing)
        .opacity(isLanding ? 0 : 1)
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) { isLanding = false }
        }
    }

    /// 顶部一排纯图标快捷格：固定 6 列（缺的跳过，剩下的靠左）
    private var quickRow: some View {
        HStack(spacing: M.quickGap) {
            ForEach(quick) { action in
                Button {
                    onRoute(action.id)
                    if !action.keepOpen { close() }
                } label: {
                    Image(systemName: action.icon)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(C.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: M.quickHeight)
                        .background(
                            RoundedRectangle(cornerRadius: M.quickRadius, style: .continuous)
                                .fill(C.quickFill)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(ToolsPressStyle(normal: C.quickFill, pressed: C.quickHover, radius: M.quickRadius, height: M.quickHeight))
                .disabled(action.disabled)
                .opacity(action.disabled ? 0.35 : 1)
                .accessibilityLabel(action.label)
            }
        }
    }

    /// 音量行：左侧图标（点了静音）、轨道、右侧数值
    private var volumeRow: some View {
        HStack(spacing: 8) {
            Button {
                player.isMuted.toggle()
            } label: {
                Image(systemName: volumeIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(player.isMuted ? WallTheme.midnight.accent : C.ink)
                    .frame(width: M.sliderIconBox, height: M.sliderIconBox)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ToolsPressStyle(normal: .clear, pressed: C.hover, radius: M.sliderIconRadius, height: M.sliderIconBox))
            .accessibilityLabel(player.isMuted ? "取消静音" : "静音")

            Slider(
                value: Binding(
                    get: { player.isMuted ? 0 : Double(player.volume) },
                    set: { next in
                if player.isMuted { player.isMuted = false }
                player.volume = Float(next)
            }),
                in: 0...1
            )
            .tint(WallTheme.midnight.accent)

            Text(player.isMuted ? "静音" : "\(Int((player.volume * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(C.ink.opacity(0.66))
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .frame(height: M.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: M.rowRadius, style: .continuous)
                .fill(C.quickFill)
        )
    }

    private var volumeIcon: String {
        let value = player.isMuted ? 0 : player.volume
        if value <= 0 { return "speaker.slash.fill" }
        return value < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        switch entry.kind {
        case let .action(icon, label, value, disabled):
            Button {
                handle(entry.id)
            } label: {
                HStack(spacing: M.rowGap) {
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .frame(width: 17)
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let value {
                        Text(value)
                            .font(.system(size: 12, weight: .semibold))
                            .opacity(0.6)
                    }
                }
                .foregroundStyle(C.ink)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .frame(height: M.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(ToolsRowPressStyle())
            .disabled(disabled)
            .opacity(disabled ? 0.35 : 1)
        case let .toggle(icon, label, isOn):
            Button {
                handle(entry.id)
            } label: {
                HStack(spacing: M.rowGap) {
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .frame(width: 17)
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    ToolsSwitch(isOn: isOn)
                }
                .foregroundStyle(C.ink)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .frame(height: M.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(ToolsRowPressStyle())
        }
    }

    /// 海报叠色开关（两面墙都有）
    private var tintRow: some View {
        row(Entry(
            id: "poster-tint",
            kind: .toggle(icon: "square.3.layers.3d", label: "海报叠色", isOn: isTintEnabled)
        ))
    }

    /// 灯光分段 + 帮助按钮 + 帮助列表
    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                lightsToggle
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { showHelp.toggle() }
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(C.ink)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ToolsPressStyle(normal: .clear, pressed: C.hover, radius: 12, height: 32))
                .accessibilityLabel("墙的操作说明")
            }
            if showHelp {
                VStack(spacing: 0) {
                    ForEach(Array(helpLines.enumerated()), id: \.offset) { index, line in
                        HStack(spacing: 12) {
                            Text(line.0)
                                .font(.system(size: 12))
                                .foregroundStyle(C.ink.opacity(0.76))
                            Spacer(minLength: 0)
                            Text(line.1)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(C.ink.opacity(0.76))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(C.ink.opacity(0.36), lineWidth: 1)
                                )
                        }
                        .frame(minHeight: 30)
                        .overlay(alignment: .top) {
                            if index > 0 {
                                Rectangle().fill(C.helpLine).frame(height: 1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(C.helpFill)
                )
                .padding(.top, 6)
            }
        }
        .padding(.top, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(C.line).frame(height: 1)
        }
        .padding(.top, 4)
    }

    private var lightsToggle: some View {
        HStack(spacing: 2) {
            lightsSegment("开灯", active: !isLightsOut) { onSetLights(true) }
            lightsSegment("关灯", active: isLightsOut) { onSetLights(false) }
        }
        .padding(3)
        .background(
            Capsule().fill(Color.white.opacity(0.06))
        )
        .overlay(
            Capsule().strokeBorder(C.ink.opacity(0.18), lineWidth: 1)
        )
        .accessibilityLabel("墙面的灯")
    }

    private func lightsSegment(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(active ? WallTheme.midnight.bg : C.lightsIdle)
                .frame(minWidth: 44)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(active ? WallTheme.midnight.accent : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 按钮：点按开合（图标 Settings2 ↔ X）
    private var toolsButton: some View {
        Button {
            if isOpen {
                close()
            } else {
                isLanding = true
                showHelp = false
                isOpen = true
            }
        } label: {
            Image(systemName: isOpen ? "xmark" : "gearshape")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(WallTheme.midnight.ink)
                .frame(width: M.buttonSize, height: M.buttonSize)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().fill(Color.white.opacity(0.08)))
                )
                .shadow(color: .black.opacity(0.24), radius: 15, x: 0, y: 10)
                .contentShape(Circle())
        }
        .buttonStyle(WallBackButtonStyle())
        .accessibilityLabel(isOpen ? "收起工具面板" : "墙面工具")
    }

    private func close() {
        isOpen = false
        showHelp = false
    }

    private func handle(_ id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        switch entry.kind {
        case .toggle:
            if id == "poster-tint" { onToggleTint() }
        case .action:
            break
        }
    }
}

/// 快捷格与图标按钮的按下反馈：原版 hover 13% / 按下同一底色
private struct ToolsPressStyle: ButtonStyle {
    let normal: Color
    let pressed: Color
    let radius: CGFloat
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(configuration.isPressed ? pressed : normal)
            )
            .frame(height: height)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// 条目行：12 圆角，按下 10% 底
private struct ToolsRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? Color.white.opacity(0.10) : Color.clear)
            )
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// `.lattice-tools-toggle`：30×18、1px 描边、12pt 白旋钮，开时底变强调色、旋钮右移 12
private struct ToolsSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isOn ? WallTheme.midnight.accent : Color.clear)
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(isOn ? 0 : 0.42), lineWidth: 1)
                )
                .frame(width: 30, height: 18)
            Circle()
                .fill(isOn ? WallTheme.midnight.bg : Color.white.opacity(0.42))
                .frame(width: 12, height: 12)
                .padding(.leading, 2)
                .offset(x: isOn ? 12 : 0)
        }
        .frame(width: 30, height: 18)
        .animation(.easeOut(duration: 0.16), value: isOn)
    }
}

