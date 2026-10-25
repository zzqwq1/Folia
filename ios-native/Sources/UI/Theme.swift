import SwiftUI

/// 原版默认暗色主题「午夜墨染」（src/services/baseThemes.ts）
enum FoliaTheme {
    static let background = Color(hex: 0x09090B)
    static let surface = Color(hex: 0x18181B)
    static let surfaceRaised = Color(hex: 0x27272A)
    static let text = Color(hex: 0xF4F4F5)
    static let textSecondary = Color(hex: 0x71717A)
    static let border = Color(hex: 0x27272A)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
