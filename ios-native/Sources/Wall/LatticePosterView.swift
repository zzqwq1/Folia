import SwiftUI

/// 海报卡。像素与层级严格对齐原版 LatticePoster.tsx + wall.css + Lattice.css：
/// 直角、cover 底色、徽标 / 阴影 / 文案 / 控件四层、当前播放描边、聚焦外环、展开让位。
struct LatticePosterView: View {
    let item: WallItem
    /// 卡片当前的世界尺寸（展开时是 6×6 的 808pt）
    let size: CGSize
    let theme: WallTheme
    /// 相机缩放 × 屏幕倍率，用来决定取哪一档封面
    let pixelScale: CGFloat
    let isExpanded: Bool
    let isFocused: Bool
    /// 展开且控件已揭示（原版 revealed = expanded && (hovered || touchOpen || keyboardFocus)）
    let chromeRevealed: Bool
    var lightsOut: Bool = false
    var hasPosterTint: Bool = false
    var onOpenCollection: (() -> Void)? = nil
    var onOpenPlayer: (() -> Void)? = nil

    /// 目录卡（歌单 / 专辑）保留封面顶部的 16pt 双条，封面从这里往下画
    private var stripInset: CGFloat {
        guard !isExpanded else { return 0 }
        switch item.kind {
        case .playlist, .radio, .cloud: return 16
        default: return 0
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            theme.posterBackground

            artwork

            if stripInset > 0 {
                StripsBand(theme: theme)
            }

            if item.kind == .album, !isExpanded {
                RecordEdge()
            }

            shade
            lightsOutLayer
            tintLayer
            focusGlow
            badge
            copy
            controls
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .overlay(currentBorder)
        .contentShape(Rectangle())
    }

    // MARK: - 底图

    private var artwork: some View {
        WallArtwork(
            urlString: item.coverUrl,
            pixelSize: max(size.width, size.height) * pixelScale,
            seed: item.id,
            theme: theme
        )
        .frame(width: size.width, height: max(size.height - stripInset, 0))
        .offset(y: stripInset)
    }

    // MARK: - 叠层

    /// `.lattice-poster-shade`
    private var shade: some View {
        Group {
            if isExpanded {
                // 展开：纵向 86% → 62% @14% → 26% @30% → 0 @46%；横向 88% → 50% @52% → 8%
                ZStack {
                    LinearGradient(
                        stops: [
                            .init(color: Color.black.opacity(0.86), location: 0),
                            .init(color: Color.black.opacity(0.62), location: 0.14),
                            .init(color: Color.black.opacity(0.26), location: 0.30),
                            .init(color: Color.black.opacity(0), location: 0.46),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    LinearGradient(
                        stops: [
                            .init(color: Color.black.opacity(0.88), location: 0),
                            .init(color: Color.black.opacity(0.50), location: 0.52),
                            .init(color: Color.black.opacity(0.08), location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            } else {
                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0.05), location: 0.34),
                        .init(color: Color.black.opacity(0.24), location: 0.56),
                        .init(color: Color.black.opacity(0.92), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    /// `.lattice-poster-lights-out`：熄灯时非当前卡压黑 82%
    private var lightsOutLayer: some View {
        Color.black
            .opacity(lightsOut && !item.isCurrent ? 0.82 : 0)
            .allowsHitTesting(false)
    }

    /// `.lattice-poster-tint`：默认 0.5 不透明度，当前 / 聚焦时归零
    private var tintLayer: some View {
        LinearGradient(
            colors: [
                blend(theme.accent, over: theme.bg, amount: 0.78),
                blend(theme.secondary, over: theme.bg, amount: 0.84),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .opacity(hasPosterTint && !item.isCurrent && !isFocused ? 0.5 : 0)
        .allowsHitTesting(false)
    }

    /// `.lattice-poster::after`：聚焦时自顶向下的白色高光
    private var focusGlow: some View {
        LinearGradient(
            colors: [Color.white.opacity(0.10), .clear],
            startPoint: .top,
            endPoint: UnitPoint(x: 0.5, y: 0.6)
        )
        .opacity(isFocused ? 1 : 0)
        .allowsHitTesting(false)
    }

    /// 徽标：`top/left 14`
    private var badge: some View {
        Text(item.badge)
            .font(.system(size: 11, weight: .heavy))
            .tracking(11 * 0.12)
            .monospacedDigit()
            .foregroundStyle(item.isCurrent ? theme.accent : theme.ink)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(Color.black.opacity(item.isCurrent ? 0.78 : 0.62))
            .padding(.leading, 14)
            .padding(.top, 14)
            .allowsHitTesting(false)
    }

    /// `.lattice-poster.is-current::before`：2px accent 描边 + 1px 内衬 + 内侧微光
    @ViewBuilder
    private var currentBorder: some View {
        if item.isCurrent {
            ZStack {
                Rectangle().strokeBorder(theme.accent, lineWidth: 2)
                Rectangle().strokeBorder(Color.black.opacity(isFocused ? 0.62 : 0.52), lineWidth: 1)
                Rectangle()
                    .strokeBorder(theme.accent.opacity(isFocused ? 0.62 : 0.46), lineWidth: isFocused ? 13 : 7)
                    .blur(radius: isFocused ? 11 : 8)
                    .padding(isFocused ? 4 : 3)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - 文案

    private var copyInsets: (leading: CGFloat, trailing: CGFloat, bottom: CGFloat) {
        if isExpanded {
            // 集合展开时底部只有一颗按钮，文案要往下让
            if case .collection = item.source { return (32, 32, 100) }
            return (32, 32, 152)
        }
        return (17, 17, 17)
    }

    private var titleFontSize: CGFloat {
        if isExpanded {
            return size.width < 640 ? 44 : min(max(size.width * 0.06, 48), 82)
        }
        return min(max(size.width * 0.02, 22), 36)
    }

    private var copy: some View {
        let insets = copyInsets
        let available = size.width - insets.leading - insets.trailing
        let columnWidth = isExpanded ? min(available, size.width * 0.76) : available
        let fontSize = titleFontSize
        let fitted = WallTitleFit.fit(
            item.title,
            width: columnWidth,
            style: WallTitleFit.Style(fontSize: fontSize, trackingEm: -0.045)
        )

        return VStack(alignment: .leading, spacing: isExpanded ? 7 : 5) {
            Text(fitted)
                .font(.system(size: fontSize, weight: .bold))
                .tracking(fontSize * -0.045)
                .foregroundStyle(theme.ink)
                .lineLimit(WallTitleFit.maxLines)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: columnWidth, alignment: .leading)

            Text(item.subtitle)
                .font(.system(size: isExpanded ? 17 : 13, weight: .semibold))
                .foregroundStyle(theme.ink.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: columnWidth, alignment: .leading)
        }
        .padding(.leading, insets.leading)
        .padding(.trailing, insets.trailing)
        .padding(.bottom, insets.bottom)
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }

    // MARK: - 控件

    @ViewBuilder
    private var controls: some View {
        if isExpanded {
            LatticePosterControls(
                item: item,
                revealed: chromeRevealed,
                width: size.width,
                onOpenCollection: onOpenCollection,
                onOpenPlayer: onOpenPlayer
            )
            .padding(.leading, 32)
            .padding(.trailing, 24)
            .padding(.bottom, 28)
            .frame(width: size.width, height: size.height, alignment: .bottomLeading)
        }
    }
}

/// 歌单 / 推荐卡顶部的双条（原版 ::before 的两段 5px 线）
struct StripsBand: View {
    let theme: WallTheme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(blend(theme.ink, over: theme.posterBackground, amount: 0.34))
                    .frame(width: geo.size.width * 0.76, height: 5)
                    .offset(y: 0)
                Rectangle()
                    .fill(blend(theme.ink, over: theme.posterBackground, amount: 0.58))
                    .frame(width: geo.size.width * 0.88, height: 5)
                    .offset(y: 8)
            }
            .frame(width: geo.size.width, alignment: .center)
        }
        .frame(height: 16)
        .allowsHitTesting(false)
    }
}

/// 专辑卡的「黑胶边」：贴近右缘的一片同心圆环
struct RecordEdge: View {
    var body: some View {
        GeometryReader { geo in
            let diameter = min(geo.size.height * 0.86, geo.size.width * 0.86)
            Circle()
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: Color(hex: 0x0B0B0C), location: 0.0),
                            .init(color: Color(hex: 0x0B0B0C), location: 0.58),
                            .init(color: Color(hex: 0x252527), location: 0.59),
                            .init(color: Color(hex: 0x252527), location: 0.60),
                            .init(color: Color(hex: 0x0F0F10), location: 0.61),
                            .init(color: Color(hex: 0x0F0F10), location: 0.71),
                            .init(color: Color(hex: 0x252527), location: 0.72),
                            .init(color: Color(hex: 0x252527), location: 0.73),
                            .init(color: Color(hex: 0x0F0F10), location: 0.74),
                            .init(color: Color(hex: 0x0F0F10), location: 0.84),
                            .init(color: Color(hex: 0x252527), location: 0.85),
                            .init(color: Color(hex: 0x252527), location: 0.86),
                            .init(color: Color(hex: 0x0D0D0E), location: 0.87),
                            .init(color: Color(hex: 0x0D0D0E), location: 0.955),
                            .init(color: Color.white.opacity(0.34), location: 0.96),
                            .init(color: Color.white.opacity(0.34), location: 0.97),
                            .init(color: Color.black.opacity(0.38), location: 0.975),
                            .init(color: .clear, location: 1.0),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter / 2
                    )
                )
                .frame(width: diameter, height: diameter)
                .offset(x: geo.size.width - diameter * 0.21,
                        y: geo.size.height * 0.07 + (geo.size.height * 0.86 - diameter) / 2)
        }
        .allowsHitTesting(false)
    }
}
