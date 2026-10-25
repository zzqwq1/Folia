import SwiftUI

/// 墙面相机：`screen = camera + world * scale`。
///
/// 对应原版 PosterWall 里 `applyCamera` / `formatWorldTransform` / `getScale`：
/// - 平移量按整设备像素吸附（`Math.round(v*dpr)/dpr`），避免 1px 抖动
/// - 初始 scale 依视口宽度分三档，和桌面端一致
struct WallCamera: Equatable {
    var x: CGFloat
    var y: CGFloat
    var scale: CGFloat

    static let home = WallCamera(x: 34, y: 80, scale: 0.76)

    /// 原版 getScale(width)：窄屏（手机竖屏）落在 0.52，横屏进 0.64。
    static func scale(for width: CGFloat) -> CGFloat {
        if width < 640 { return 0.52 }
        if width < 1100 { return 0.64 }
        return 0.76
    }

    /// 世界坐标 → 屏幕坐标
    func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: x + point.x * scale, y: y + point.y * scale)
    }

    /// 一个世界矩形此刻的屏幕矩形
    func screenRect(_ rect: WallRect) -> CGRect {
        CGRect(
            x: x + rect.x * scale,
            y: y + rect.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    /// 视口可见的世界范围。对应原版 getWorldBounds。
    func worldBounds(viewport: CGSize) -> WallBounds {
        WallBounds(
            left: -x / scale,
            top: -y / scale,
            right: (viewport.width - x) / scale,
            bottom: (viewport.height - y) / scale
        )
    }

    /// 合并后的可见范围（用于裁剪时留出越界余量）
    func worldBounds(viewport: CGSize, padding: CGFloat) -> WallBounds {
        let bounds = worldBounds(viewport: viewport)
        return WallBounds(
            left: bounds.left - padding,
            top: bounds.top - padding,
            right: bounds.right + padding,
            bottom: bounds.bottom + padding
        )
    }

    /// 让 rect 居中：`x = w/2 - (rect.x + rect.width/2) * scale`
    static func centering(_ rect: WallRect, in viewport: CGSize, scale: CGFloat) -> WallCamera {
        WallCamera(
            x: viewport.width / 2 - rect.midX * scale,
            y: viewport.height / 2 - rect.midY * scale,
            scale: scale
        )
    }

    /// `formatWorldTransform` 里的像素吸附
    func snapped(pixelScale: CGFloat) -> WallCamera {
        WallCamera(
            x: (x * pixelScale).rounded() / pixelScale,
            y: (y * pixelScale).rounded() / pixelScale,
            scale: scale
        )
    }

    /// 世界层变换（translate + scale，origin 在左上角）
    var affine: CGAffineTransform {
        CGAffineTransform(translationX: x, y: y).scaledBy(x: scale, y: scale)
    }
}

/// `reserveBounds`：把新范围并进来，但限制增长，避免来回平移时无限制保留旧区域。
enum WallBoundsReserve {
    /// 原版阈值：合并后面积超过目标 3 倍就只保留目标
    static let growthLimit: CGFloat = 3

    static func merge(_ current: WallBounds?, with target: WallBounds) -> WallBounds {
        guard let current else { return target }

        let merged = WallBounds(
            left: min(current.left, target.left),
            top: min(current.top, target.top),
            right: max(current.right, target.right),
            bottom: max(current.bottom, target.bottom)
        )
        let mergedArea = (merged.right - merged.left) * (merged.bottom - merged.top)
        let targetArea = (target.right - target.left) * (target.bottom - target.top)
        if mergedArea > targetArea * growthLimit { return target }

        let covered = current.left <= target.left && current.right >= target.right
            && current.top <= target.top && current.bottom >= target.bottom
        return covered ? current : merged
    }
}
