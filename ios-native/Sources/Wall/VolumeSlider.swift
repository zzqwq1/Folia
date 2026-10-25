import SwiftUI

/// 自绘的音量滑条，替掉系统 `Slider`。规格逐条对应 `WallToolsButton.css`：
/// 4pt 圆角轨道，左侧填充 `--text-accent`、右侧 18% 白；14pt 纯白圆钮带 1px 22% 黑描边与投影，
/// 按下放大到 1.18。点按与横向拖动都能改值。
struct VolumeSlider: View {
    @Binding var value: Double

    @State private var isDragging = false

    private let trackHeight: CGFloat = 4
    private let knobSize: CGFloat = 14
    /// `input[type="range"]` 的 height: 22px
    private let rowHeight: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, knobSize)
            let clamped = min(max(value, 0), 1)
            let knobX = (width - knobSize) * CGFloat(clamped) + knobSize / 2

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(WallTheme.midnight.accent)
                    .frame(width: max(knobX, trackHeight), height: trackHeight)

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.22), lineWidth: 1))
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.30), radius: 3, x: 0, y: 2)
                    .scaleEffect(isDragging ? 1.18 : 1)
                    .offset(x: knobX - knobSize / 2)
            }
            .frame(width: width, height: rowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let ratio = (drag.location.x - knobSize / 2) / (width - knobSize)
                        value = Double(min(max(ratio, 0), 1))
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.12)) { isDragging = false }
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isDragging)
        }
        .frame(height: rowHeight)
    }
}
