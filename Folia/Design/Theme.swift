//
//  Theme.swift
//  Folia
//
//  配色与排版令牌，取自 Web 版的设计变量（深色底 #09090b、强调色 #ff4d6d）。
//

import SwiftUI

enum Theme {
    static let background   = Color(hex: 0x09090B)
    static let surface      = Color(hex: 0x121216)
    static let surfaceHigh  = Color(hex: 0x1A1A20)
    static let stroke       = Color.white.opacity(0.08)
    static let accent       = Color(hex: 0xFF4D6D)
    static let accentSoft   = Color(hex: 0xFF7E9D)
    static let textPrimary  = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension View {
    /// 统一的卡片容器：圆角、描边、深色底。
    func foliaCard(radius: CGFloat = 18) -> some View {
        self
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }
}
