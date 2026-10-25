import SwiftUI

/// 探索墙左上角的段落选择器（原版 `LatticeSectionFinder.tsx` + `LatticeSections.css`）：
/// - 胶囊：`left 120`、`top 20`、`height 40`、`r 999`、白 8% + blur、`gap 6`、左右内距 16 / 12、
///   13 / 650、数字等宽；展开时箭头转 180°；hover 1.02、active 0.98
/// - 列表：`top 68`、`left 120`、宽 `min(340, 100vw - 144)`、最高 `min(62vh, 520)`、
///   行 `gap 12`、`padding 9 16`、序号 11 / 800 / 0.55、当前行用 `--text-accent`
/// - 窄屏（≤640）：胶囊 `left 112`、列表 `top 62 / left 16 / width 100vw - 32`
struct LatticeSectionFinder: View {
    let sections: [WallSectionSpec]
    let current: Int
    let theme: WallTheme
    let onChoose: (Int) -> Void

    @State private var isOpen = false

    private var section: WallSectionSpec? {
        guard current >= 0, current < sections.count else { return nil }
        return sections[current]
    }

    private var name: String {
        guard let section else { return "" }
        let position = "\(current + 1)/\(sections.count)"
        return section.heading.isEmpty ? position : "\(position) · \(section.heading)"
    }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width > 0 && geo.size.width < 640
            ZStack(alignment: .topLeading) {
                pill(compact: compact)
                    .padding(.leading, compact ? 112 : 120)
                    .padding(.top, compact ? 14 : 20)

                if isOpen {
                    list(compact: compact)
                        .padding(.leading, compact ? 16 : 120)
                        .padding(.top, compact ? 62 : 68)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    // MARK: - 胶囊

    private func pill(compact: Bool) -> some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .animation(.easeOut(duration: 0.2), value: isOpen)
                    .opacity(0.7)
            }
            .foregroundStyle(theme.ink)
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(height: 40)
            .frame(maxWidth: min(UIScreen.main.bounds.width * 0.46, 420), alignment: .leading)
            .background(
                ZStack {
                    Capsule(style: .continuous).fill(.ultraThinMaterial)
                    Capsule(style: .continuous).fill(Color.white.opacity(0.08))
                }
            )
            .clipShape(Capsule(style: .continuous))
            .shadow(color: .black.opacity(0.24), radius: 15, x: 0, y: 10)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(LatticeFinderPillStyle())
        .accessibilityLabel("段落")
        .accessibilityValue(name)
    }

    // MARK: - 列表

    private func list(compact: Bool) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.offset) { index, entry in
                    Button {
                        choose(index)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(String(format: "%02d", index + 1))
                                .font(.system(size: 11, weight: .heavy))
                                .tracking(11 * 0.12)
                                .monospacedDigit()
                                .opacity(0.55)
                            Text(entry.heading.isEmpty ? entry.summary : entry.heading)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundStyle(index == current ? theme.accent : theme.ink)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(LatticeFinderRowStyle(ink: theme.ink))
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: compact ? UIScreen.main.bounds.width - 32 : min(340, UIScreen.main.bounds.width - 144))
        .frame(maxHeight: min(UIScreen.main.bounds.height * 0.62, 520))
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.posterBackground.opacity(0.92))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.36), radius: 24, x: 0, y: 18)
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.18)) { isOpen.toggle() }
    }

    private func choose(_ index: Int) {
        withAnimation(.easeOut(duration: 0.18)) { isOpen = false }
        onChoose(index)
    }
}

/// 胶囊：hover 1.02、active 0.98，200ms
struct LatticeFinderPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// 列表行：hover / focus 时 `color-mix(poster-ink 10%, transparent)` 底
struct LatticeFinderRowStyle: ButtonStyle {
    let ink: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(ink.opacity(configuration.isPressed ? 0.10 : 0))
    }
}
