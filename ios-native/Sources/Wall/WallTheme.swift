import SwiftUI

/// 主题色板。原版是 CSS 变量（--bg/--ink/--primary/--accent/--secondary/--surface/--surface-raised），
/// 这里换成结构体，日间/其他主题以后只需要换一份色值。
///
/// 原版配色里大量出现 `rgb(<shade> / N%)`：shade 通常是底色（bg）或纯黑，
/// 再叠到不透明的内容上。这里统一用 `blend(_:over:amount:)` 表达同一件事。
struct WallTheme: Equatable {
    var bg: Color
    var ink: Color
    var primary: Color
    var accent: Color
    var secondary: Color
    var surface: Color
    var surfaceRaised: Color

    static let midnight = WallTheme(
        bg: Color(hex: 0x09090B),
        ink: Color(hex: 0xF4F4F5),
        primary: Color(hex: 0xF4F4F5),
        accent: Color(hex: 0xF4F4F5),
        secondary: Color(hex: 0x71717A),
        surface: Color(hex: 0x18181B),
        surfaceRaised: Color(hex: 0x27272A)
    )

    /// `--lattice-poster-background`：bg 88% + ink（≈ #1C1C20）
    var posterBackground: Color {
        blend(FoliaTheme.text, over: FoliaTheme.background, amount: 0.12)
    }

    /// 无封面兜底 `linear-gradient(145deg, hsl(hue 68% 58%), hsl((hue+52) 62% 18%))`
    func fallbackGradient(for id: String) -> (Color, Color) {
        let hue = id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360
        return (
            Color(hue: Double(hue) / 360, saturation: 0.68, brightness: 0.58),
            Color(hue: Double((hue + 52) % 360) / 360, saturation: 0.62, brightness: 0.18)
        )
    }
}

/// 颜色混合：把 `top` 以 `amount` 不透明度压到 `base` 上，得到等价的不透明色。
/// 用于需要不透明结果（铺在封面底下、卡片阴影内环）而 CSS 写法是半透明叠层的地方。
func blend(_ top: Color, over base: Color, amount: Double) -> Color {
    let t = min(max(amount, 0), 1)
    let a = rgba(of: top)
    let b = rgba(of: base)
    return Color(
        .sRGB,
        red: a.r * t + b.r * (1 - t),
        green: a.g * t + b.g * (1 - t),
        blue: a.b * t + b.b * (1 - t),
        opacity: a.a * t + b.a * (1 - t)
    )
}

func rgba(of color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
    return (Double(r), Double(g), Double(b), Double(a))
}

/// 原版字体栈是 `'Inter', CJK sans`。iOS 上没有 Inter，系统 SF 的视觉重量
/// 与字重阶梯最接近；中文落到苹方。
enum WallFont {
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
    static func badge(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .heavy) }
    static func artist(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .semibold) }
    static func mono(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
}
