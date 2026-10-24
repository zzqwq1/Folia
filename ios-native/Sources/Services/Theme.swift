import SwiftUI

/// Folia 官方设计 token（对齐网页版 src/services/baseThemes.ts / index.css / kitTheme.ts）
enum FoliaTheme {
    // 主背景（午夜墨染）
    static let bg = Color(hex: "#09090b")
    // 卡片底（zinc-900 ≈ 90% 不透明）
    static let card = Color(hex: "#18181b")
    // 卡片底二级
    static let card2 = Color(hex: "#232327")
    // 主文字（zinc-100）
    static let t1 = Color(hex: "#f4f4f5")
    // 次文字 62% 透明
    static let t2 = Color(hex: "#f4f4f5").opacity(0.62)
    // 三档文字 42% 透明
    static let t3 = Color(hex: "#f4f4f5").opacity(0.42)
    // 分隔线 8% 透明
    static let line = Color(hex: "#f4f4f5").opacity(0.08)
    // 填充 7%
    static let fill = Color(hex: "#f4f4f5").opacity(0.07)
    // 填充 12%
    static let fill2 = Color(hex: "#f4f4f5").opacity(0.12)
    // 强调（暗主题用主文字色）
    static let accent = Color(hex: "#f4f4f5")
    // 强调上的字（深色）
    static let onAccent = Color(hex: "#17171a")
    // 红心
    static let like = Color(hex: "#e0354f")
    // 成功绿
    static let ok = Color(hex: "#56c98d")
    // 警告黄
    static let warn = Color(hex: "#e3a949")
    // 错误红
    static let err = Color(hex: "#ef6f6f")
}

/// 字体（对齐 fontStacks.ts）
enum FoliaFont {
    /// UI 正文（系统自带就够用）
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    /// 歌词/区块大标题（衬线，产品灵魂）
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// mono 小字（时长/专辑）
    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}

/// 平台圆形字母徽章（对齐 PlatformMark.tsx）
struct PlatformMark: View {
    let provider: Provider
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: provider.accentColorHex))
            Text(provider.markLetter)
                .font(.system(size: round(size * 0.42), weight: .bold))
                .foregroundStyle(Self.onAccent(for: provider))
        }
        .frame(width: size, height: size)
        .overlay(
            Circle().stroke(FoliaTheme.card, lineWidth: 2)
        )
    }

    /// 根据背景品牌色自动选黑字或白字（对齐 onAccentColor()）
    private static func onAccent(for p: Provider) -> Color {
        // 简单亮度阈值：绿/青/蓝偏亮用深字，红用白字
        switch p {
        case .qq, .kugou, .bodian:
            return Color(hex: "#17171a")
        case .netease:
            return .white
        }
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r: UInt64
        let g: UInt64
        let b: UInt64
        if s.count == 6 {
            r = v >> 16
            g = v >> 8 & 0xFF
            b = v & 0xFF
        } else if s.count == 3 {
            r = (v >> 8) * 17
            g = (v >> 4 & 0xF) * 17
            b = (v & 0xF) * 17
        } else {
            r = 0; g = 0; b = 0
        }
        self.init(.sRGB, red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0, opacity: 1)
    }
}
