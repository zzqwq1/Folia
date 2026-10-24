import Combine
import CoreGraphics
import SwiftUI
import UIKit

// MARK: - 常量

/// 直译 bravaisConstants.ts 里墙层用到的常量。
enum BravaisWallMetrics {
    static let overscan: CGFloat = 420
    static let cullEdgeMargin: CGFloat = 160
    static let narrowViewport: CGFloat = 900

    static let seamEdgeMargin: CGFloat = 14
    static let seamLineDistanceWeight: CGFloat = 0.15

    static let seamTween: Double = 0.36
    static let cameraTween: Double = 0.42

    /// 开口宽度（轴上总长）
    static let openWidthFull: CGFloat = 300
    static let openWidthHome: CGFloat = 120
    static let openWidthSpine: CGFloat = 64

    /// 横条（axis y）三档高度
    static let rowFullHeight: CGFloat = 212
    static let rowHomeHeight: CGFloat = 72
    static let rowSpineHeight: CGFloat = 52
}

enum BravaisSeamLevel {
    case full
    case home
    case spine
    case hidden
}

enum BravaisSeamSide {
    case top
    case bottom
}

// MARK: - 缝规划（直译 seamPlan.ts）

enum BravaisSeamPlan {
    struct Plan {
        let anchor: CGFloat
        let camera: CGFloat
        let shift: CGFloat
    }

    struct Geometry {
        let screen: CGFloat
        let width: CGFloat
        let collapsed: Bool
        let side: BravaisSeamSide
    }

    struct Span {
        let min: CGFloat
        let max: CGFloat
    }

    /// 单轴让位：在相邻三条缝里挑「位移 + 偏移代价」最小的一条。
    static func planOnAxis(
        camera: CGFloat,
        line: CGFloat,
        extent: CGFloat,
        openWidth: CGFloat,
        scale: CGFloat,
        blockSpan: CGFloat,
        boundary: (Int) -> CGFloat,
        prefer: CGFloat? = nil
    ) -> Plan {
        let need = openWidth / 2 + BravaisWallMetrics.seamEdgeMargin
        let base = Int(((camera + BravaisMetrics.gap / 2) / blockSpan).rounded())
        let candidates: [CGFloat] = prefer.map { [$0] } ?? [base - 1, base, base + 1].map(boundary)

        var best: Plan?
        // 记下最优候选的原始得分（含「离屏幕中线多远」这一项）。
        var bestScore = CGFloat.greatestFiniteMagnitude
        for at in candidates {
            let screen = line + (at - camera) * scale
            let fit = max(need, min(extent - need, screen))
            let nextCamera = at - (fit - line) / scale
            let shift = abs(nextCamera - camera) * scale
            let score = shift + abs(fit - line) * BravaisWallMetrics.seamLineDistanceWeight
            if score < bestScore {
                bestScore = score
                best = Plan(anchor: at, camera: nextCamera, shift: shift)
            }
        }
        return best ?? Plan(anchor: boundary(base), camera: camera, shift: 0)
    }

    /// 开口几何：垂直缝落在屏幕 line 上，向两侧留 edge 的余量。
    static func geometryOnAxis(
        anchor: CGFloat,
        camera: CGFloat,
        line: CGFloat,
        extent: CGFloat,
        openWidth: CGFloat,
        scale: CGFloat
    ) -> Geometry {
        let screen = line + (anchor - camera) * scale
        let room = min(screen, extent - screen) - BravaisWallMetrics.seamEdgeMargin
        let width = max(0, min(openWidth, room * 2))
        return Geometry(
            screen: screen,
            width: width,
            collapsed: openWidth > 1 && width < 2,
            side: screen < line ? .top : .bottom
        )
    }

    /// 相机在轴上的允许区间（保证缝完整落在视口里）。
    static func cameraSpanOnAxis(
        anchor: CGFloat,
        line: CGFloat,
        extent: CGFloat,
        openWidth: CGFloat,
        scale: CGFloat
    ) -> Span {
        let need = openWidth / 2 + BravaisWallMetrics.seamEdgeMargin
        let minCamera = anchor - (extent - need - line) / scale
        let maxCamera = anchor + (line - need) / scale
        if minCamera > maxCamera {
            let mid = (minCamera + maxCamera) / 2
            return Span(min: mid, max: mid)
        }
        return Span(min: minCamera, max: maxCamera)
    }

    /// 上下两半墙的相机补偿：缝的半个高度再叠 gap*scale 的一半。
    static func splitOffsets(width: CGFloat, scale: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let pad = (BravaisMetrics.gap / 2) * scale * min(1, width / 16)
        return (top: -(width / 2 + pad), bottom: width / 2 + pad)
    }

    static func contentOpacity(width: CGFloat, contentWidth: CGFloat) -> Double {
        let raw = width / max(contentWidth, 1) - 0.35
        return Double(min(1, max(0, raw / 0.65)))
    }
}

// MARK: - 相机（世界层状态 + 惯性）

@MainActor
final class BravaisCamera: ObservableObject {
    @Published var x: CGFloat = 0
    @Published var y: CGFloat = 0

    /// 交互开始前，若正处在相机补间中需要打断。
    private var tween: AnyCancellable?
    private var inertia: AnyCancellable?

    func stopAll() {
        tween?.cancel(); tween = nil
        inertia?.cancel(); inertia = nil
    }

    func tween(to point: CGPoint, duration: Double = BravaisWallMetrics.cameraTween, immediate: Bool = false) {
        stopAll()
        guard !immediate, duration > 0 else {
            x = point.x
            y = point.y
            return
        }
        let from = CGPoint(x: x, y: y)
        let start = Date()
        tween = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let t = min(1, Date().timeIntervalSince(start) / duration)
                let e = 1 - pow(1 - t, 3)
                self.x = from.x + (point.x - from.x) * e
                self.y = from.y + (point.y - from.y) * e
                if t >= 1 {
                    self.tween?.cancel(); self.tween = nil
                }
            }
    }

    /// 松手后的惯性：速度按 0.3 次幂衰减，时间常数 280ms。
    func inertialPan(velocity: CGPoint, limit: CGRect? = nil) {
        stopAll()
        var vx = velocity.x
        var vy = velocity.y
        let speed = hypot(vx, vy)
        guard speed > 40 else { return }
        let clamped = min(speed, 4000)
        let factor = clamped / speed
        vx *= factor
        vy *= factor

        let timeConstant: Double = 0.28
        var last = Date()
        inertia = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let now = Date()
                let dt = min(0.05, now.timeIntervalSince(last))
                last = now
                let decay = pow(0.3, dt / timeConstant)
                vx *= decay
                vy *= decay
                self.pan(dx: vx * dt, dy: vy * dt, limit: limit)
                if hypot(vx, vy) < 40 {
                    self.inertia?.cancel(); self.inertia = nil
                }
            }
    }

    /// 拖动平移；limit 为相机允许区间（nil 表示自由）。
    func pan(dx: CGFloat, dy: CGFloat, limit: CGRect? = nil) {
        var nx = x - dx
        var ny = y - dy
        if let limit {
            nx = min(limit.maxX, max(limit.minX, nx))
            ny = min(limit.maxY, max(limit.minY, ny))
        }
        x = nx
        y = ny
    }
}

// MARK: - 墙（世界层 + 底板遮罩 + 卡片）

/// 墙面（对应网页 bravais.css 的 `--bravais-wall-surface`）：
/// 底色 + 两团定位在视口上的主题光晕（左上 accent 16%，右下 secondary 20%）。底板画不出这两团，
/// 所以底板用纯 bg，光晕由上面一层屏幕固定的叠加层补；这里只把同一套底色铺给墙用。
enum BravaisWallSurface {
    static let accentGlow: (point: UnitPoint, radius: CGFloat, opacity: Double) = (.init(x: 0.14, y: 0.12), 760, 0.16)
    static let secondaryGlow: (point: UnitPoint, radius: CGFloat, opacity: Double) = (.init(x: 0.86, y: 0.82), 820, 0.20)
}

/// 墙：每块一块底板（evenodd 路径 = 外框减窗洞），窗里是空画框。
/// 直译 bravais.css 的 `.bravais-block-plate` + `.lattice-poster`（空态）：海报底是
/// color-mix(bg 88%, ink)，空画框再叠一道底部压暗与极淡的 accent 光晕。
struct BravaisWall: View {
    @ObservedObject var camera: BravaisCamera
    /// 当前横缝的锚点（世界坐标 y），nil 表示没有横缝参与底板边界。
    let anchorY: CGFloat?
    let scale: CGFloat
    let viewport: CGSize

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            draw(context: &context, size: size)
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let visible = CGRect(
            x: camera.x - size.width / 2 / scale,
            y: camera.y - size.height / 2 / scale,
            width: size.width / scale,
            height: size.height / scale
        ).insetBy(dx: -BravaisWallMetrics.overscan, dy: -BravaisWallMetrics.overscan)

        let colMin = Int(floor(visible.minX / BravaisMetrics.blockWidth))
        let colMax = Int(ceil(visible.maxX / BravaisMetrics.blockWidth))
        let rowMin = Int(floor(visible.minY / BravaisMetrics.blockHeight))
        let rowMax = Int(ceil(visible.maxY / BravaisMetrics.blockHeight))

        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -camera.x, y: -camera.y)

        let plateColor = GraphicsContext.Shading.color(FoliaTheme.bg)

        for row in rowMin...rowMax {
            for col in colMin...colMax {
                drawBlock(context: &context, col: col, row: row, plate: plateColor)
            }
        }
    }

    private func drawBlock(context: inout GraphicsContext, col: Int, row: Int, plate: GraphicsContext.Shading) {
        let slots = BravaisMetrics.slots(column: col, row: row)
        let frame = BravaisPlate.frame(column: col, row: row, anchorY: anchorY)
        // 实色档无窗：不挖洞，只画底板。
        context.fill(Path(BravaisPlate.path(frame: frame, holes: [])), with: plate, style: FillStyle(eoFill: true))

        for slot in slots {
            drawSlot(context: &context, slot: slot)
        }
    }

    /// 空画框：底 = color-mix(bg 88%, 主文字)。web 端这是 #232325（网页 bg #070707）；底色跟 FoliaTheme.bg
    /// 走，混合比例不变，≈ #2a2a2e。
    private func drawSlot(context: inout GraphicsContext, slot: CGRect) {
        var card = context
        card.translateBy(x: slot.minX, y: slot.minY)

        let rect = CGRect(origin: .zero, size: slot.size)
        card.fill(Path(rect), with: .color(Self.posterBackground))

        // 底部压暗，让空位有「窗」的纵深（.lattice-poster-shade）
        card.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(0.05), location: 0),
                    .init(color: .black.opacity(0.34), location: 0.34),
                    .init(color: .black.opacity(0.24), location: 0.56),
                    .init(color: .black.opacity(0.92), location: 1),
                ]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            )
        )

        // 空窗的窗光：--bravais-window-glow，radial-gradient(ellipse at 50% 40%, accent 9%, transparent 70%)
        card.fill(
            Path(rect),
            with: .radialGradient(
                Gradient(colors: [FoliaTheme.accent.opacity(0.09), .clear]),
                center: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.4),
                startRadius: 0,
                endRadius: max(rect.width, rect.height) * 0.58
            )
        )
    }

    /// color-mix(in srgb, bg 88%, 主文字) —— 与网页同一个公式。
    static let posterBackground: Color = {
        let bg = UIColor(FoliaTheme.bg).rgba
        let ink = UIColor(Color(hex: "#f7f4ee")).rgba
        return Color(
            .sRGB,
            red: bg.r * 0.88 + ink.r * 0.12,
            green: bg.g * 0.88 + ink.g * 0.12,
            blue: bg.b * 0.88 + ink.b * 0.12,
            opacity: 1
        )
    }()
}

private extension UIColor {
    var rgba: (r: Double, g: Double, b: Double, a: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }
}
