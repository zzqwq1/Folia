import SwiftUI

/// 海报墙容器。逐条移植 PosterWall.tsx：
/// - 相机写在 `@State` 里，世界层只做 `offset + scaleEffect`（origin 左上）
/// - 可见性由 `layoutLattice(bounds:overscan: 500)` 决定，最多 400 张
/// - 单指拖拽带惯性（WALL_PAN_INERTIA），双指捏合缩放，长按聚焦，点卡展开
/// - 点卡 → 让位表（layoutExpandedBlock）+ panTo（0.42s，cubic-bezier(0.22,1,0.36,1)）
/// - 入场波次（0.34s 封顶、抬升 90、0.88 → 1）只在第一次画出来后跑一遍
struct LatticeWallView: View {
    let items: [WallItem]
    let theme: WallTheme
    var lightsOut: Bool = false
    var hasPosterTint: Bool = false
    var autoFocusOnSongChange: Bool = true
    /// 空态文案（原版 i18n）
    var emptyTitle: String = "队列是空的"
    var emptyText: String = "开始播放任意歌曲后，队列会在这里铺开。"
    /// 左上角返回（nil 时不画，例如墙本身就是根页面时改放工具按钮）
    var onBack: (() -> Void)? = nil
    /// 右下角工具区（设置 / 账号）
    var toolbar: AnyView? = nil
    /// 点卡的自身动作：集合 → 打开集合页
    var onOpenItem: (WallItem) -> Void = { _ in }
    var onOpenPlayer: () -> Void = {}
    /// 外部（集合页的定位按钮）请求把某一首歌移到视口中心
    var locateRequest: WallLocateRequest? = nil

    @EnvironmentObject private var player: PlayerEngine

    // MARK: - 常量（PosterWall.tsx）

    private static let metrics = WallMetrics.standard
    private static let overscan: CGFloat = 500
    /// `padding = overscan - CULL_EDGE_MARGIN_PX(180)`
    private static let cullStep: CGFloat = 320
    private static let dragThreshold: CGFloat = 7
    private static let entranceLift: CGFloat = 90
    private static let entranceStagger: CGFloat = 0.03
    private static let entranceMaxDelay: CGFloat = 0.34
    private static let entranceWindow: Double = 1.1
    private static let panDuration: Double = 0.42
    private static let dragSpring = Animation.interpolatingSpring(stiffness: 300, damping: 34)

    // MARK: - 状态

    @State private var camera = WallCamera.home
    @State private var viewport: CGSize = .zero
    @State private var measured = false
    @State private var entranceDone = false
    /// 首次画出来之前的卡「原地挂载」，不跑波次（`hasDrawnRef`）
    @State private var hasDrawn = false
    @State private var bounds = WallBounds(left: -100, top: -100, right: 1400, bottom: 900)
    @State private var activeId: String?
    @State private var focusedId: String?
    @State private var touchOpen = false
    /// 每个实例的入场延迟，挂载时冻结（`useRef(entranceDelay).current`）
    @State private var landingDelays: [String: Double] = [:]

    // MARK: - 手势状态

    @State private var pan: PanSession?
    @State private var inertia: PanTween?
    @State private var panTween: PanTween?
    /// 拖拽结束后吞掉那次点击
    @State private var didDrag = false
    @State private var magnifyBase: CGFloat?
    @State private var magnifyAnchor: CGPoint = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            backButton
            if measured { world }
            emptyState
            toolCluster
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 世界层自己铺满，外壳按视口左上角排（与 CSS 的 absolute + top/left 一致）
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { measure(geo.size) }
                    .onChange(of: geo.size) { measure($0) }
            }
        )
        .clipped()
        .contentShape(Rectangle())
        .gesture(dragGesture, including: .all)
        .simultaneousGesture(magnifyGesture)
        .simultaneousGesture(longPressGesture)
        .onChange(of: items) { _ in itemsChanged() }
        .onChange(of: currentSongKey) { key in focusPlaying(key) }
        .onChange(of: locateRequest) { request in
            guard let request else { return }
            locate(songId: request.songId)
        }
        .task { await runEntrance() }
    }

    // MARK: - 世界层

    private var world: some View {
        let drawn = drawnItems
        let rects = activeId.map { expandedRects(for: $0) } ?? [:]
        let pixelScale = (camera.scale * UIScreen.main.scale).rounded(.up)

        return ZStack(alignment: .topLeading) {
            ForEach(drawn) { instance in
                if let item = items(of: instance) {
                    let expanded = instance.instanceId == activeId
                    let rect = rects[instance.instanceId] ?? instance.rect

                    poster(item: item, instance: instance, rect: rect, expanded: expanded, pixelScale: pixelScale)
                        .scaleEffect(poppedScale(instance: instance, expanded: expanded), anchor: .center)
                        .offset(x: rect.x, y: rect.y)
                        .zIndex(expanded ? 20 : 0)
                        .allowsHitTesting(!isDragging)
                }
            }
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .scaleEffect(camera.scale, anchor: .topLeading)
        .offset(x: camera.x, y: camera.y)
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    }

    private func poster(
        item: WallItem,
        instance: QueueInstance,
        rect: WallRect,
        expanded: Bool,
        pixelScale: CGFloat
    ) -> some View {
        LatticePosterView(
            item: item,
            size: CGSize(width: rect.width, height: rect.height),
            theme: theme,
            pixelScale: pixelScale,
            isExpanded: expanded,
            isFocused: instance.instanceId == focusedId,
            chromeRevealed: expanded && touchOpen,
            lightsOut: lightsOut,
            hasPosterTint: hasPosterTint,
            onOpenCollection: { onOpenItem(item) },
            onOpenPlayer: onOpenPlayer
        )
        .modifier(PosterLanding(
            delay: landingDelay(for: instance.instanceId),
            mountsInPlace: !hasDrawn,
            lift: Self.entranceLift
        ))
        .contentShape(Rectangle())
        .onTapGesture { handleTap(instance: instance, expanded: expanded) }
    }

    // MARK: - 外壳

    /// `.lattice-back`：40×40 圆、白 8%、blur 8、阴影 0 10 30 / 24%
    @ViewBuilder
    private var backButton: some View {
        if let onBack {
            let compact = viewport.width > 0 && viewport.width < 640
            // 放在安全区内：原版是浏览器视口顶端；iOS 上让开刘海 / 状态栏
            VStack(spacing: 0) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .foregroundStyle(theme.ink)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().fill(Color.white.opacity(0.08)))
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.24), radius: 15, x: 0, y: 10)
                        .contentShape(Circle())
                }
                .buttonStyle(WallBackButtonStyle())
                .padding(.leading, compact ? 16 : 24)
                .padding(.top, compact ? 14 : 20)
                Spacer(minLength: 0)
            }
            .zIndex(5)
        }
    }

    /// `.lattice-empty`：居中、gap 9、strong 17px / 0.16em、span 12px / 0.5
    @ViewBuilder
    private var emptyState: some View {
        if items.isEmpty {
            VStack(spacing: 9) {
                Text(emptyTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(17 * 0.16)
                Text(emptyText)
                    .font(.system(size: 12))
                    .opacity(0.5)
            }
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .zIndex(3)
        }
    }

    @ViewBuilder
    private var toolCluster: some View {
        if let toolbar {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    toolbar
                }
                .padding(.trailing, 16)
                .padding(.bottom, 28)
            }
            .zIndex(4)
        }
    }

    // MARK: - 绘制列表

    private var geometry: LatticeGeometry {
        WallLayoutMath.geometry(totalEntries: items.count, metrics: Self.metrics)
    }

    private var drawnItems: [QueueInstance] {
        guard measured, !items.isEmpty else { return [] }
        let visible = WallLayoutMath.layoutLattice(
            geometry,
            totalEntries: items.count,
            bounds: bounds,
            overscan: Self.overscan,
            metrics: Self.metrics
        )
        guard let activeId, !visible.contains(where: { $0.instanceId == activeId }) else {
            return visible
        }
        guard let stale = instance(named: activeId) else { return visible }
        return visible + [stale]
    }

    /// 由 instanceId `"cellSlot:repeatX:repeatY"` 反推块坐标并重建实例
    private func instance(named instanceId: String) -> QueueInstance? {
        let parts = instanceId.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let layout = geometry
        guard layout.blockWidth > 0, layout.blockHeight > 0 else { return nil }
        let cellSlot = parts[0]
        let blockInCell = cellSlot / BlockTemplates.slotsPerBlock
        let localColumn = blockInCell % layout.blocksPerRow
        let localRow = blockInCell / layout.blocksPerRow
        return WallLayoutMath.buildInstance(
            layout,
            totalEntries: items.count,
            absoluteColumn: parts[1] * layout.blocksPerRow + localColumn,
            absoluteRow: parts[2] * layout.blockRows + localRow,
            slotIndex: cellSlot % BlockTemplates.slotsPerBlock,
            metrics: Self.metrics
        )
    }

    private func items(of instance: QueueInstance) -> WallItem? {
        guard instance.queueIndex >= 0, instance.queueIndex < items.count else { return nil }
        return items[instance.queueIndex]
    }

    /// 展开卡的让位表：整块重新排布，其余卡保持 base rect
    private func expandedRects(for instanceId: String) -> [String: WallRect] {
        guard let instance = instance(named: instanceId) else { return [:] }
        return WallLayoutMath.layoutExpandedBlock(
            geometry,
            totalEntries: items.count,
            active: instance,
            metrics: Self.metrics
        )
    }

    private func poppedScale(instance: QueueInstance, expanded: Bool) -> CGFloat {
        // popped = !expanded && (hovered || isFocused)；触屏上 hovered 只在 focused 时成立
        guard !expanded, instance.instanceId == focusedId else { return 1 }
        let gap = Self.metrics.gap
        guard instance.width > 0, instance.height > 0 else { return 1 }
        return min((instance.width + gap * 2) / instance.width, (instance.height + gap * 2) / instance.height)
    }

    private func landingDelay(for instanceId: String) -> Double? {
        landingDelays[instanceId]
    }

    // MARK: - 测量

    private func measure(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        if viewport == .zero {
            var next = WallCamera.home
            next.scale = WallCamera.scale(for: size.width)
            viewport = size
            applyCamera(next, updateBounds: true)
        } else {
            viewport = size
            var next = camera
            next.scale = WallCamera.scale(for: size.width)
            applyCamera(next, updateBounds: false)
        }
        measured = true
    }

    // MARK: - 入场波次

    private func runEntrance() async {
        while !measured {
            try? await Task.sleep(nanoseconds: 16_000_000)
            if Task.isCancelled { return }
        }
        guard !entranceDone else { return }
        freezeLandingDelays()
        try? await Task.sleep(nanoseconds: UInt64(Self.entranceWindow * 1_000_000_000))
        if Task.isCancelled { return }
        entranceDone = true
        hasDrawn = true
        landingDelays = [:]
    }

    /// `min(0.34, steps / pitch * 0.03)`，steps 从视口左上角量起
    private func freezeLandingDelays() {
        guard !entranceDone, landingDelays.isEmpty, !items.isEmpty else { return }
        let visible = WallLayoutMath.layoutLattice(
            geometry,
            totalEntries: items.count,
            bounds: bounds,
            overscan: Self.overscan,
            metrics: Self.metrics
        )
        var delays: [String: Double] = [:]
        for instance in visible {
            let steps = max(0, instance.x - bounds.left) + max(0, instance.y - bounds.top)
            delays[instance.instanceId] = min(
                Self.entranceMaxDelay,
                Double(steps / Self.metrics.pitch) * Self.entranceStagger
            )
        }
        landingDelays = delays
    }

    // MARK: - 相机

    private func applyCamera(_ next: WallCamera, updateBounds: Bool = false) {
        camera = next
        if updateBounds {
            bounds = WallBoundsReserve.merge(bounds, with: next.worldBounds(viewport: viewport))
        }
    }

    private func updateCamera(x: CGFloat, y: CGFloat) {
        let next = WallCamera(x: x, y: y, scale: camera.scale)
        let visible = next.worldBounds(viewport: viewport)
        let nearEdge = visible.left < bounds.left - Self.cullStep
            || visible.right > bounds.right + Self.cullStep
            || visible.top < bounds.top - Self.cullStep
            || visible.bottom > bounds.bottom + Self.cullStep
        applyCamera(next, updateBounds: nearEdge)
    }

    private func reserveBounds(_ target: WallCamera) {
        bounds = WallBoundsReserve.merge(bounds, with: target.worldBounds(viewport: viewport))
    }

    private func stopPan() {
        panTween?.stop()
        panTween = nil
    }

    private var viewportCenter: CGPoint {
        CGPoint(
            x: (viewport.width / 2 - camera.x) / camera.scale,
            y: (viewport.height / 2 - camera.y) / camera.scale
        )
    }

    private func panTo(_ rect: WallRect, instant: Bool = false) {
        stopPan()
        inertia?.stop()
        inertia = nil
        let from = camera
        let target = WallCamera.centering(rect, in: viewport, scale: from.scale)
        reserveBounds(target)
        guard !instant else {
            applyCamera(target, updateBounds: true)
            return
        }
        let tween = PanTween(
            from: CGPoint(x: from.x, y: from.y),
            to: CGPoint(x: target.x, y: target.y),
            duration: Self.panDuration
        ) { point in
            applyCamera(WallCamera(x: point.x, y: point.y, scale: from.scale))
        } onEnd: {
            applyCamera(target, updateBounds: true)
            panTween = nil
        }
        panTween = tween
        tween.start()
    }

    // MARK: - 拖拽

    private var isDragging: Bool { pan?.dragged == true }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pan == nil {
                    stopPan()
                    inertia?.stop()
                    inertia = nil
                    didDrag = false
                    pan = PanSession(
                        start: value.startLocation,
                        camera: CGPoint(x: camera.x, y: camera.y),
                        last: value.location,
                        time: value.time,
                        dragged: false
                    )
                }
                guard var session = pan else { return }
                let dx = value.location.x - session.start.x
                let dy = value.location.y - session.start.y
                if !session.dragged, hypot(dx, dy) > Self.dragThreshold {
                    session.dragged = true
                    didDrag = true
                }
                let elapsed = value.time.timeIntervalSince(session.time) * 1000
                if elapsed > 0 {
                    session.vx = (value.location.x - session.last.x) / elapsed * 1000
                    session.vy = (value.location.y - session.last.y) / elapsed * 1000
                }
                session.last = value.location
                session.time = value.time
                pan = session
                if session.dragged {
                    updateCamera(x: session.camera.x + dx, y: session.camera.y + dy)
                }
            }
            .onEnded { value in
                guard let session = pan else { return }
                pan = nil
                guard session.dragged else { return }
                let releasedAfter = value.time.timeIntervalSince(session.time) * 1000
                guard releasedAfter <= 80 else { return }
                let speed = hypot(session.vx, session.vy)
                guard speed >= 40 else { return }
                let velocity = min(speed, 4000)
                let from = CGPoint(x: camera.x, y: camera.y)
                let unit = CGPoint(x: session.vx / speed, y: session.vy / speed)
                // framer 的投影：位移 = velocity * power
                let projection = velocity * 0.3
                let tween = PanTween(
                    from: from,
                    to: CGPoint(x: from.x + projection * unit.x, y: from.y + projection * unit.y),
                    duration: 0
                ) { point in
                    updateCamera(x: point.x, y: point.y)
                } onEnd: {
                    inertia = nil
                }
                inertia = tween
                tween.startInertia(velocity: velocity, direction: unit)
            }
    }

    // MARK: - 捏合缩放

    /// 以视口中心为锚：中心下的世界点保持不动
    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if magnifyBase == nil {
                    magnifyBase = camera.scale
                    magnifyAnchor = viewportCenter
                    stopPan()
                    inertia?.stop()
                    inertia = nil
                }
                let base = magnifyBase ?? camera.scale
                let anchor = magnifyAnchor
                let scale = min(max(base * value, 0.24), 1.6)
                let next = WallCamera(
                    x: viewport.width / 2 - anchor.x * scale,
                    y: viewport.height / 2 - anchor.y * scale,
                    scale: scale
                )
                applyCamera(next, updateBounds: true)
            }
            .onEnded { _ in
                magnifyBase = nil
                let next = camera.snapped(pixelScale: UIScreen.main.scale)
                applyCamera(next, updateBounds: true)
            }
    }

    // MARK: - 长按聚焦

    /// 触屏没有 hover：长按聚焦（抬起 1 个 gap），再点一次展开
    private var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.42)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onEnded { value in
                guard case .second(true, let drag?) = value else { return }
                guard let instance = hitInstance(at: drag.startLocation) else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    focusedId = instance.instanceId
                }
            }
    }

    // MARK: - 点击

    private func handleTap(instance: QueueInstance, expanded: Bool) {
        if didDrag {
            didDrag = false
            return
        }
        if expanded {
            withAnimation(.easeInOut(duration: 0.2)) { touchOpen.toggle() }
            return
        }
        expand(instance.instanceId)
    }

    private func expand(_ instanceId: String) {
        guard let instance = instance(named: instanceId) else { return }
        withAnimation(Self.dragSpring) {
            focusedId = instanceId
            activeId = instanceId
            touchOpen = false
        }
        let rects = WallLayoutMath.layoutExpandedBlock(
            geometry,
            totalEntries: items.count,
            active: instance,
            metrics: Self.metrics
        )
        if let rect = rects[instanceId] {
            panTo(rect)
        }
    }

    private func collapse() {
        withAnimation(Self.dragSpring) {
            activeId = nil
            touchOpen = false
        }
    }

    /// 屏幕点命中的世界实例（视口坐标 → 世界坐标，从后往前找）
    private func hitInstance(at point: CGPoint) -> QueueInstance? {
        let world = CGPoint(
            x: (point.x - camera.x) / camera.scale,
            y: (point.y - camera.y) / camera.scale
        )
        let rects = activeId.map { expandedRects(for: $0) } ?? [:]
        return drawnItems.reversed().first { instance in
            let rect = rects[instance.instanceId] ?? instance.rect
            return world.x >= rect.x && world.x <= rect.x + rect.width
                && world.y >= rect.y && world.y <= rect.y + rect.height
        }
    }

    // MARK: - 队列变化

    private var currentSongKey: String? {
        player.currentSong.map { WallTile.key(for: $0) }
    }

    /// 队列变了：展开卡按最近的座位重新定位，相机跟着它移动同样的距离（原版 useLayoutEffect）
    private func itemsChanged() {
        guard let activeId, let tileId = focusedTileId(activeId) else { return }
        guard let queueIndex = items.firstIndex(where: { $0.id == tileId }) else {
            withAnimation(Self.dragSpring) { self.activeId = nil }
            return
        }
        let old = instance(named: activeId)
        guard let nearest = WallLayoutMath.locateNearestInstance(
            geometry,
            totalEntries: items.count,
            queueIndex: queueIndex,
            point: CGPoint(x: old?.rect.midX ?? 0, y: old?.rect.midY ?? 0),
            metrics: Self.metrics
        ) else {
            withAnimation(Self.dragSpring) { self.activeId = nil }
            return
        }
        let before = old?.rect
        let after = WallLayoutMath.layoutExpandedBlock(
            geometry,
            totalEntries: items.count,
            active: nearest,
            metrics: Self.metrics
        )[nearest.instanceId]
        self.activeId = nearest.instanceId
        focusedId = nearest.instanceId

        guard let before, let after else { return }
        let dx = after.x - before.x
        let dy = after.y - before.y
        guard dx != 0 || dy != 0 else { return }
        guard WallLayoutMath.overlaps(before.bounds, camera.worldBounds(viewport: viewport)) else { return }
        stopPan()
        inertia?.stop()
        inertia = nil
        let moved = WallCamera(
            x: camera.x - dx * camera.scale,
            y: camera.y - dy * camera.scale,
            scale: camera.scale
        )
        reserveBounds(moved)
        applyCamera(moved, updateBounds: true)
    }

    private func focusedTileId(_ instanceId: String) -> String? {
        guard let instance = instance(named: instanceId) else { return nil }
        guard instance.queueIndex >= 0, instance.queueIndex < items.count else { return nil }
        return items[instance.queueIndex].id
    }

    // MARK: - 播放跟随（useLatticePlaybackFocus）

    /// 集合页右下的定位按钮用：把某首歌移到视口中心（原版 grid 的 locateOnThisPage）
    func locate(songId: String) {
        guard measured, let queueIndex = items.firstIndex(where: { $0.id == songId }) else { return }
        focus(byIndex: queueIndex, instant: false)
    }

    /// 这首歌现在在不在视口里（原版 isPlayingSongHere）
    func isOnScreen(songId: String) -> Bool {
        guard measured, let queueIndex = items.firstIndex(where: { $0.id == songId }) else { return false }
        guard let instance = WallLayoutMath.locateNearestInstance(
            geometry,
            totalEntries: items.count,
            queueIndex: queueIndex,
            point: viewportCenter,
            metrics: Self.metrics
        ) else { return false }
        let bounds = instance.rect.bounds
        let visible = camera.worldBounds(viewport: viewport)
        return WallLayoutMath.overlaps(bounds, visible)
    }

    private func focus(byIndex queueIndex: Int, instant: Bool) {
        guard let instance = WallLayoutMath.locateNearestInstance(
            geometry,
            totalEntries: items.count,
            queueIndex: queueIndex,
            point: viewportCenter,
            metrics: Self.metrics
        ) else { return }
        focusedId = instance.instanceId
        let rect = WallLayoutMath.layoutExpandedBlock(
            geometry,
            totalEntries: items.count,
            active: instance,
            metrics: Self.metrics
        )[instance.instanceId]
        if let rect {
            panTo(rect, instant: instant)
        }
    }

    private func focusPlaying(_ key: String?) {
        guard measured else { return }
        guard let key, let queueIndex = items.firstIndex(where: { $0.id == key }) else { return }
        // 入场第一次：直接落在卡上，不做飞行
        let isEntry = activeId == nil
        guard let instance = WallLayoutMath.locateNearestInstance(
            geometry,
            totalEntries: items.count,
            queueIndex: queueIndex,
            point: viewportCenter,
            metrics: Self.metrics
        ) else { return }
        focusedId = instance.instanceId
        if !autoFocusOnSongChange && !isEntry { return }
        activeId = instance.instanceId
        let rect = WallLayoutMath.layoutExpandedBlock(
            geometry,
            totalEntries: items.count,
            active: instance,
            metrics: Self.metrics
        )[instance.instanceId]
        if let rect {
            panTo(rect, instant: isEntry)
        }
    }
}

// MARK: - 返回按钮样式

/// `.lattice-back`：hover 1.05、active 0.95，200ms
struct WallBackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - 手势会话

private struct PanSession {
    var start: CGPoint
    var camera: CGPoint
    var last: CGPoint
    var time: Date
    var dragged: Bool
    var vx: CGFloat = 0
    var vy: CGFloat = 0
}

/// 补间与惯性共用一条时间轴：按需刷新，结束时回调。
/// 用 `CADisplayLink` 而不是 SwiftUI 动画，因为相机每帧要写进同一个 `@State`，
/// 轨迹必须能随时被打断（原版 applyCamera + animationRef.stop）。
private final class PanTween {
    private let from: CGPoint
    private let to: CGPoint
    private let duration: Double
    private let onUpdate: (CGPoint) -> Void
    private let onEnd: () -> Void
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval?
    private var lastTime: CFTimeInterval?
    private var inertiaVelocity: CGFloat = 0
    private var inertiaDirection: CGPoint = .zero
    private var currentPoint: CGPoint = .zero
    private var direction: CGPoint = .zero

    init(
        from: CGPoint,
        to: CGPoint,
        duration: Double,
        onUpdate: @escaping (CGPoint) -> Void,
        onEnd: @escaping () -> Void
    ) {
        self.from = from
        self.to = to
        self.duration = duration
        self.onUpdate = onUpdate
        self.onEnd = onEnd
        self.currentPoint = from
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        if length > 0 {
            direction = CGPoint(x: dx / length, y: dy / length)
        }
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func startInertia(velocity: CGFloat, direction unit: CGPoint) {
        inertiaVelocity = velocity
        inertiaDirection = unit
        start()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if startTime == nil {
            startTime = now
            lastTime = now
        }
        let elapsed = now - (startTime ?? now)

        if duration > 0 {
            let progress = min(max(elapsed / duration, 0), 1)
            // cubic-bezier(0.22, 1, 0.36, 1) 的近似
            let eased = CGFloat(WallEasing.easeOutQuintLike(progress))
            let x = from.x + (to.x - from.x) * eased
            let y = from.y + (to.y - from.y) * eased
            onUpdate(CGPoint(x: x, y: y))
            if progress >= 1 {
                stop()
                onEnd()
            }
            return
        }

        // framer 惯性：速度按 τ = 280ms 指数衰减，逐帧累加位移
        let dt = min(max(now - (lastTime ?? now), 0), 0.05)
        lastTime = now
        inertiaVelocity *= CGFloat(exp(-dt / 0.28))
        let distance = inertiaVelocity * CGFloat(dt)
        currentPoint = CGPoint(
            x: currentPoint.x + distance * inertiaDirection.x,
            y: currentPoint.y + distance * inertiaDirection.y
        )
        onUpdate(currentPoint)
        if inertiaVelocity < 0.5 {
            stop()
            onEnd()
        }
    }
}

// MARK: - 挂载动画

/// 入场：从上方 90、0.88、透明落下（spring 360/24 + opacity 0.24s + scale 0.3s easeOut）；
/// 波次外：原地 0.94 淡入。`mountsInPlace` 为真时直接画在自己位置上。
private struct PosterLanding: ViewModifier {
    let delay: Double?
    let mountsInPlace: Bool
    let lift: CGFloat

    @State private var landed = false
    @State private var scheduled = false

    func body(content: Content) -> some View {
        let landing = mountsInPlace ? nil : delay
        let entering = !landed

        return content
            .opacity(entering ? 0 : 1)
            .scaleEffect(entering ? (landing == nil ? 0.94 : 0.88) : 1)
            .offset(y: entering && landing != nil ? -lift : 0)
            .onAppear {
                if mountsInPlace {
                    landed = true
                    return
                }
                guard !scheduled else { return }
                scheduled = true
                let delaySeconds = landing ?? 0
                DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) {
                    withAnimation(landing != nil
                        ? .interpolatingSpring(stiffness: 360, damping: 24)
                        : .easeOut(duration: 0.26)) {
                        landed = true
                    }
                }
            }
    }
}

// MARK: - 外部定位请求

/// 集合页右下的定位按钮：父视图把请求写进这个值，墙视图收到后把对应的卡移到视口中心。
/// 带 nonce，同一首歌连点两次也能重新触发。
struct WallLocateRequest: Equatable {
    let songId: String
    let nonce: Int
}

/// `cubic-bezier(0.22, 1, 0.36, 1)` 的近似：五次 ease-out，前段斜率足够陡、末段贴住 1
private enum WallEasing {
    static func easeOutQuintLike(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return 1 - pow(1 - x, 5)
    }
}
