import Combine
import SwiftUI

/// 首页：bravais 可拖动卡片墙 + 居中横条。
/// 逐项对齐网页端 BravaisWall / BravaisSeamHomeRow / BravaisWallHint。
struct BravaisHomeView: View {
    let provider: Provider
    let playlists: [Playlist]
    let isLoading: Bool
    let onConnect: () -> Void
    let onOpenPlaylist: (Playlist) -> Void
    let onSettings: () -> Void
    let onSearch: () -> Void
    let onQueue: () -> Void

    @EnvironmentObject private var session: AppSession

    @StateObject private var camera = BravaisCamera()
    @StateObject private var widthAnim = AnimatableFloat()
    @State private var viewport: CGSize = .zero
    @State private var level: BravaisSeamLevel = .full
    @State private var restoreLevel: BravaisSeamLevel = .home
    /// 当前横缝锚点（世界 y），nil 表示还没规划过。
    @State private var anchorY: CGFloat?
    @State private var targetOpenWidth: CGFloat = BravaisWallMetrics.rowSpineHeight
    @State private var initialised = false
    @State private var lastDrag: CGSize = .zero
    @State private var dragStart = Date()
    @State private var lastMove = Date()

    private var scale: CGFloat { BravaisMetrics.scale(for: viewport.width) }
    private var isNarrow: Bool { viewport.width < BravaisWallMetrics.narrowViewport }
    private var isLoggedIn: Bool { session.isLoggedIn(provider) }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let geometry = seamGeometry(size: size)
            let split = BravaisSeamPlan.splitOffsets(width: widthAnim.value, scale: scale)

            ZStack {
                wallSurface

                // 上下两半墙：缝把相机往两侧推开，两半各让一半
                wall(size: size, offsetY: split.top / 2)
                wall(size: size, offsetY: split.bottom / 2)

                // 横缝：全宽、高度 = 开口宽度，垂直居中于缝的屏幕位置
                seamStrip(size: size, geometry: geometry)

                wallHint(size: size, geometry: geometry)

                edgeTab
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size))
            .onAppear {
                viewport = size
                bootstrap(size: size)
            }
            .onChange(of: size) { newSize in
                handleResize(from: viewport.width, size: newSize)
                viewport = newSize
            }
        }
        .background(FoliaTheme.bg)
    }

    // MARK: - 墙面

    private var wallSurface: some View {
        FoliaTheme.bg
            .overlay(
                RadialGradient(
                    colors: [FoliaTheme.accent.opacity(BravaisWallSurface.accentGlow.opacity), .clear],
                    center: BravaisWallSurface.accentGlow.point,
                    startRadius: 0,
                    endRadius: BravaisWallSurface.accentGlow.radius
                )
            )
            .overlay(
                RadialGradient(
                    colors: [FoliaTheme.accent.opacity(BravaisWallSurface.secondaryGlow.opacity), .clear],
                    center: BravaisWallSurface.secondaryGlow.point,
                    startRadius: 0,
                    endRadius: BravaisWallSurface.secondaryGlow.radius
                )
            )
    }

    private func wall(size: CGSize, offsetY: CGFloat) -> some View {
        BravaisWall(
            camera: camera,
            anchorY: anchorY,
            scale: scale,
            viewport: size
        )
        .offset(y: offsetY)
    }

    // MARK: - 横缝

    private func seamGeometry(size: CGSize) -> BravaisSeamPlan.Geometry {
        let anchor = anchorY ?? BravaisMetrics.seamBoundaryY(0)
        return BravaisSeamPlan.geometryOnAxis(
            anchor: anchor,
            camera: camera.y,
            line: size.height / 2,
            extent: size.height,
            openWidth: widthAnim.value,
            scale: scale
        )
    }

    private func seamStrip(size: CGSize, geometry: BravaisSeamPlan.Geometry) -> some View {
        let w = widthAnim.value
        let visible = geometry.width >= 1
        let compact = level == .spine
        // 排版高度 = 当前档位的开口高度（首页层 full/home 都是 72、书脊 52）。
        // 网页 contentOpacity 就是拿「开口高度 / 排版高度」算的，两者相等时恒为 1；开口动画途中才渐显。
        let content = BravaisSeamPlan.contentOpacity(width: w, contentWidth: openWidth(for: level))

        return BravaisSeamHomeRow(
            compact: compact,
            collapsed: level == .hidden || geometry.collapsed,
            isLoading: isLoading,
            isLoggedIn: isLoggedIn,
            profile: session.profile(for: provider),
            onFold: { setLevel(.hidden) },
            onExpand: { setLevel(.full) },
            onConnect: onConnect,
            onSettings: onSettings,
            onStage: { if let first = playlists.first { onOpenPlaylist(first) } },
            onSearch: onSearch,
            onQueue: onQueue,
            canStage: !playlists.isEmpty
        )
        .frame(width: size.width, height: max(w, 1))
        // 缝纸 = 与墙面同一底色（--bravais-seam-paper = color-mix(bg 90%, ink)），叠同样两团主题光晕，
        // 让横条不像一块浮在墙上的浅色面板。
        .background(FoliaTheme.seamPaper)
        .overlay(
            RadialGradient(
                colors: [FoliaTheme.accent.opacity(BravaisWallSurface.accentGlow.opacity), .clear],
                center: BravaisWallSurface.accentGlow.point,
                startRadius: 0,
                endRadius: BravaisWallSurface.accentGlow.radius
            )
            .allowsHitTesting(false)
        )
        .overlay(
            RadialGradient(
                colors: [FoliaTheme.accent.opacity(BravaisWallSurface.secondaryGlow.opacity), .clear],
                center: BravaisWallSurface.secondaryGlow.point,
                startRadius: 0,
                endRadius: BravaisWallSurface.secondaryGlow.radius
            )
            .allowsHitTesting(false)
        )
        .overlay(alignment: .top) { hairline }
        .overlay(alignment: .bottom) { hairline }
        .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
        .opacity(visible ? content : 0)
        .position(x: size.width / 2, y: geometry.screen)
    }

    private var hairline: some View {
        Rectangle()
            .fill(FoliaTheme.t1.opacity(0.06))
            .frame(height: 1)
    }

    // MARK: - 空墙提示

    private func wallHint(size: CGSize, geometry: BravaisSeamPlan.Geometry) -> some View {
        // 只占缝上方或下方较大的一侧（对应 wallHintRowSpan）
        let seamTop = geometry.screen - widthAnim.value / 2
        let seamBottom = geometry.screen + widthAnim.value / 2
        let below = size.height - seamBottom
        let span: (top: CGFloat, height: CGFloat) = below >= seamTop
            ? (top: seamBottom, height: below)
            : (top: 0, height: seamTop)

        return VStack(spacing: 0) {
            Text("还没有连接在线平台")
                .font(.system(size: min(48, max(24, size.width * 0.032)), weight: .bold))
                .foregroundStyle(FoliaTheme.t1.opacity(0.22))
                .multilineTextAlignment(.center)

            Text("点信息条里的「连接在线平台」登录，你的歌单、电台和收藏的专辑会铺满这面墙。")
                .font(.system(size: min(16, max(13, size.width * 0.011))))
                .lineSpacing(4)
                .foregroundStyle(FoliaTheme.t1.opacity(0.36))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.top, 14)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(height: max(0, span.height))
        .position(x: size.width / 2, y: span.top + max(0, span.height) / 2)
        .opacity(isLoggedIn ? 0 : 1)
        .allowsHitTesting(false)
    }

    // MARK: - 左缘折叠标签

    private var edgeTab: some View {
        HStack {
            Button {
                setLevel(isNarrow ? .spine : .full)
            } label: {
                Text("书库")
                    .font(.system(size: 13, weight: .heavy))
                    .kerning(13 * 0.12)
                    .foregroundStyle(FoliaTheme.t1.opacity(0.55))
                    .fixedSize()
                    .frame(width: 20, height: 56)
                    .rotationEffect(.degrees(90))
                    .frame(width: 30, height: 60)
                    .background(FoliaTheme.seamPaper)
                    .clipShape(RoundedCorner(radius: 6, corners: [.topRight, .bottomRight]))
                    .shadow(color: .black.opacity(0.45), radius: 12, x: 4)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .opacity(level == .hidden ? 1 : 0)
        .allowsHitTesting(level == .hidden)
        .animation(.easeOut(duration: 0.24), value: level)
    }

    // MARK: - 手势

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 7)
            .onChanged { value in
                camera.stopAll()
                dragStart = value.time
                let dx = value.translation.width - lastDrag.width
                let dy = value.translation.height - lastDrag.height
                lastDrag = value.translation
                camera.pan(dx: dx, dy: dy)
            }
            .onEnded { value in
                let dt = max(0.016, value.time.timeIntervalSince(dragStart))
                // 拖动的世界位移 ≈ 手指位移；惯性阶段直接给速度
                let velocity = CGPoint(
                    x: (value.translation.width - lastDrag.width) / dt,
                    y: (value.translation.height - lastDrag.height) / dt
                )
                lastDrag = .zero
                camera.inertialPan(velocity: velocity)
            }
    }

    // MARK: - 等级 / 开口

    private func setLevel(_ next: BravaisSeamLevel) {
        if next == .hidden || next == .spine {
            if level == .full || level == .home { restoreLevel = level }
        }
        level = next
        let target = openWidth(for: next)
        targetOpenWidth = target
        widthAnim.animate(from: widthAnim.value, to: target, duration: BravaisWallMetrics.seamTween) { [self] in
            reflow(animated: true)
        }
        reflow(animated: true)
    }

    private func openWidth(for level: BravaisSeamLevel) -> CGFloat {
        switch level {
        // 首页层（surface=home）的 full 与 home 是同一档：网页在首页满档也用它自己的窄缝 72，
        // 212 只给集合页那类非首页层，首页这里用不到。
        case .full: return BravaisWallMetrics.rowHomeHeight
        case .home: return BravaisWallMetrics.rowHomeHeight
        case .spine: return BravaisWallMetrics.rowSpineHeight
        case .hidden: return 0
        }
    }

    private func handleResize(from oldWidth: CGFloat, size: CGSize) {
        let wasNarrow = oldWidth < BravaisWallMetrics.narrowViewport
        let nowNarrow = size.width < BravaisWallMetrics.narrowViewport
        if wasNarrow != nowNarrow, level != .hidden {
            // 网页 bravaisSeamLevel：窄屏默认书脊，宽屏默认满档。
            level = nowNarrow ? .spine : .full
            let target = openWidth(for: level)
            targetOpenWidth = target
            widthAnim.value = target
        }
        reflow(animated: false)
    }

    private func bootstrap(size: CGSize) {
        guard !initialised, size.width > 0 else { return }
        initialised = true
        level = isNarrow ? .spine : .full
        targetOpenWidth = openWidth(for: level)
        widthAnim.value = targetOpenWidth
        // 首帧：把第 0 条缝放到正中
        camera.y = BravaisMetrics.seamBoundaryY(0)
        anchorY = BravaisMetrics.seamBoundaryY(0)
        reflow(animated: false)
    }

    /// 把当前锚点对回屏幕中线，相机做补间。
    private func reflow(animated: Bool) {
        guard viewport.height > 0 else { return }
        let plan = BravaisSeamPlan.planOnAxis(
            camera: camera.y,
            line: viewport.height / 2,
            extent: viewport.height,
            openWidth: targetOpenWidth,
            scale: scale,
            blockSpan: BravaisMetrics.blockHeight,
            boundary: BravaisMetrics.seamBoundaryY,
            prefer: anchorY
        )
        anchorY = plan.anchor
        camera.tween(to: CGPoint(x: camera.x, y: plan.camera), immediate: !animated)
    }
}

// MARK: - 可动画的开口宽度

@MainActor
final class AnimatableFloat: ObservableObject {
    @Published var value: CGFloat = 0
    private var token = 0
    private var bag = Set<AnyCancellable>()

    func set(_ v: CGFloat) {
        token += 1
        bag.removeAll()
        value = v
    }

    func animate(from: CGFloat, to: CGFloat, duration: Double, completion: @escaping () -> Void) {
        token += 1
        bag.removeAll()
        let mine = token
        let start = Date()
        Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, mine == self.token else { return }
                let t = min(1, max(0, Date().timeIntervalSince(start) / duration))
                // cubic-bezier(.65, 0, .35, 1) 的平滑近似
                let e = t * t * (3 - 2 * t)
                self.value = from + (to - from) * e
                if t >= 1 {
                    self.bag.removeAll()
                    completion()
                }
            }
            .store(in: &bag)
    }
}

// MARK: - 只圆部分角

struct RoundedCorner: Shape {
    let radius: CGFloat
    let corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        ).cgPath)
    }
}

extension FoliaTheme {
    /// --bravais-seam-paper = color-mix(bg 90%, text-primary)
    static let seamPaper = Color(hex: "#1e1e20")
}
