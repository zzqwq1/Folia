//
//  LyricView.swift
//  Folia
//
//  歌词滚动。以 0.25s 的播放进度驱动，用 ScrollViewReader 把当前行滚到中间，
//  逐行做透明度与缩放，还原 Web 版的「动态歌词」观感。
//

import SwiftUI

struct LyricView: View {
    let lines: [LyricLine]
    let currentTime: TimeInterval
    let onSeek: (TimeInterval) -> Void

    private var activeIndex: Int {
        guard !lines.isEmpty else { return 0 }
        var result = 0
        for (index, line) in lines.enumerated() where line.time <= currentTime + 0.15 {
            result = index
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 90)

                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        lyricLine(line, index: index)
                            .id(index)
                            .onTapGesture { onSeek(line.time) }
                    }

                    Color.clear.frame(height: 140)
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
            .onChange(of: activeIndex) { index in
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .onAppear {
                proxy.scrollTo(activeIndex, anchor: .center)
            }
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.22),
                .init(color: .black, location: 0.78),
                .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        )
    }

    @ViewBuilder
    private func lyricLine(_ line: LyricLine, index: Int) -> some View {
        let isActive = index == activeIndex
        Text(line.text)
            .font(.system(size: isActive ? 23 : 18,
                          weight: isActive ? .bold : .medium,
                          design: .rounded))
            .foregroundStyle(isActive ? Theme.textPrimary : Theme.textTertiary)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(isActive ? 1 : 0.97, anchor: .leading)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isActive)
    }
}
